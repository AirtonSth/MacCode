import XCTest
import CoreModel
@testable import AgentRuntime

// URLProtocol stub harness for AnthropicModelDiscovery.listModels.
// WHY: the fetch path (status gating, JSON parsing, fallback on failure,
// key-absent early-return) was entirely untested; only pure helpers had coverage.
final class AnthropicModelDiscoveryNetworkTests: XCTestCase {

    // MARK: - URLProtocol stub

    private final class URLProtocolStub: URLProtocol {
        typealias Handler = (URLRequest) throws -> (Int, Data)
        static var handler: Handler?
        private static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            let h = Self.handler
            Self.lock.unlock()

            guard let h else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (status, data) = try h(request)
                let resp = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}

        /// Installs handler, runs body, tears down handler. Serial-safe.
        static func withHandler<T>(
            _ handler: @escaping Handler,
            run: () async throws -> T
        ) async rethrows -> T {
            lock.lock()
            Self.handler = handler
            lock.unlock()
            defer {
                lock.lock()
                Self.handler = nil
                lock.unlock()
            }
            return try await run()
        }
    }

    // MARK: - Setup / teardown

    override func setUp() async throws {
        // WHY: AnthropicModelDiscovery._cache is a process-wide static actor; without reset
        // a success test populates it and subsequent failure tests see the cache hit instead
        // of hitting the stub, making them falsely pass with stale data.
        await AnthropicModelDiscovery._resetCacheForTesting()
    }

    // MARK: - Helpers

    /// Returns a URLSession wired exclusively to URLProtocolStub (no real network).
    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    /// Builds a minimal valid Anthropic list-models JSON response body.
    private func makeModelListBody(ids: [String]) -> Data {
        let items = ids
            .map { id in "{\"id\": \"\(id)\", \"display_name\": \"Label \(id)\"}" }
            .joined(separator: ", ")
        let json = "{\"data\": [\(items)]}"
        return Data(json.utf8)
    }

    // MARK: - Tests

    func test_listModels_success_parsesModels() async {
        // WHY: a 200 response with valid JSON must produce AgentModelDescriptor entries;
        // regression here means the picker never shows live models.
        let body = makeModelListBody(ids: ["claude-opus-4", "claude-haiku-3"])
        let session = stubbedSession()

        let models = await URLProtocolStub.withHandler({ _ in (200, body) }) {
            await AnthropicModelDiscovery.listModels(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertEqual(models.count, 2)
        let ids = models.map(\.id)
        XCTAssertTrue(ids.contains("claude-opus-4"), "opus id must be present; got \(ids)")
        XCTAssertTrue(ids.contains("claude-haiku-3"), "haiku id must be present; got \(ids)")
    }

    func test_listModels_non200_returnsEmpty() async {
        // WHY: a 4xx/5xx response must not produce descriptors; returning partial garbage
        // would populate the UI with invalid model IDs.
        let body = Data("{\"error\": \"unauthorized\"}".utf8)
        let session = stubbedSession()

        let models = await URLProtocolStub.withHandler({ _ in (401, body) }) {
            await AnthropicModelDiscovery.listModels(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-bad"],
                session: session
            )
        }

        XCTAssertTrue(models.isEmpty, "non-200 must return empty; got \(models.map(\.id))")
    }

    func test_listModels_networkError_returnsEmpty() async throws {
        // WHY: a thrown URLError (timeout, no connectivity) must be swallowed and return
        // empty, not crash or propagate; callers rely on graceful degradation.
        let session = stubbedSession()

        let models = try await URLProtocolStub.withHandler({ _ in throw URLError(.timedOut) }) {
            await AnthropicModelDiscovery.listModels(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertTrue(models.isEmpty, "network error must return empty; got \(models.map(\.id))")
    }

    func test_listModels_keyAbsent_returnsEmptyWithoutFetch() async {
        // WHY: without any credential the request builder returns nil and no fetch happens;
        // the stub must never be reached, and the result must be empty (not a crash).
        var stubCalled = false
        let session = stubbedSession()

        let models = await URLProtocolStub.withHandler({ _ in
            stubCalled = true
            return (200, self.makeModelListBody(ids: ["claude-opus-4"]))
        }) {
            await AnthropicModelDiscovery.listModels(
                environment: [:],
                session: session
            )
        }

        XCTAssertTrue(models.isEmpty, "absent key must return empty; got \(models.map(\.id))")
        XCTAssertFalse(stubCalled, "no network call must be made when credentials are absent")
    }

    func test_listModels_emptyDataArray_returnsEmpty() async {
        // WHY: a valid 200 with an empty data array must produce no descriptors; the
        // caller must not crash on zero results.
        let body = Data("{\"data\": []}".utf8)
        let session = stubbedSession()

        let models = await URLProtocolStub.withHandler({ _ in (200, body) }) {
            await AnthropicModelDiscovery.listModels(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertTrue(models.isEmpty, "empty data array must yield zero descriptors; got \(models.count)")
    }

    func test_listModels_skipsNonClaudeModels() async {
        // WHY: only models whose id starts with "claude-" must be returned;
        // third-party or malformed entries must be filtered out.
        let body = makeModelListBody(ids: ["claude-sonnet-4", "gpt-4o", "claude-haiku-3"])
        let session = stubbedSession()

        let models = await URLProtocolStub.withHandler({ _ in (200, body) }) {
            await AnthropicModelDiscovery.listModels(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        let ids = models.map(\.id)
        XCTAssertFalse(ids.contains("gpt-4o"), "non-claude id must be filtered; got \(ids)")
        XCTAssertTrue(ids.contains("claude-sonnet-4"), "claude id must be kept; got \(ids)")
        XCTAssertTrue(ids.contains("claude-haiku-3"), "claude id must be kept; got \(ids)")
    }
}
