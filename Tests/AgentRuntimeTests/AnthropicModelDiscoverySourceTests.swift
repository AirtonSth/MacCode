import XCTest
import CoreModel
@testable import AgentRuntime

// Tests for ModelListResult.isFallback signal and AnthropicModelDiscovery.refresh().
// WHY: a user opening the model picker must be able to distinguish the live API
// list from the static built-in fallback; these tests guard that contract.
final class AnthropicModelDiscoverySourceTests: XCTestCase {

    // MARK: - URLProtocol stub (mirrors NetworkTests harness)

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

    // MARK: - Setup

    override func setUp() async throws {
        await AnthropicModelDiscovery._resetCacheForTesting()
    }

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    private func makeModelListBody(ids: [String]) -> Data {
        let items = ids
            .map { id in "{\"id\": \"\(id)\", \"display_name\": \"Label \(id)\"}" }
            .joined(separator: ", ")
        return Data("{\"data\": [\(items)]}".utf8)
    }

    // MARK: - isFallback signal

    func test_listModelsResult_isFallback_false_whenLiveDataReturned() async {
        // WHY: when the API returns 200 with models, isFallback must be false;
        // a user seeing "using built-in defaults" when live data is present is a false alarm.
        let body = makeModelListBody(ids: ["claude-opus-4", "claude-haiku-3"])
        let session = stubbedSession()

        let result = await URLProtocolStub.withHandler({ _ in (200, body) }) {
            await AnthropicModelDiscovery.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertFalse(result.isFallback, "live 200 response must set isFallback=false; got true")
        XCTAssertEqual(result.models.count, 2)
    }

    func test_listModelsResult_isFallback_true_whenNoCredential() async {
        // WHY: without a credential no request is made and the static aliases are the
        // only option; isFallback must be true so the picker can warn the user.
        let result = await AnthropicModelDiscovery.listModelsResult(environment: [:])

        XCTAssertTrue(result.isFallback, "absent credential must set isFallback=true; got false")
        XCTAssertTrue(result.models.isEmpty, "models must be empty when no credential is present")
    }

    func test_listModelsResult_isFallback_true_onNetworkError() async throws {
        // WHY: a network error means no live data; isFallback=true lets the picker
        // show the "built-in defaults" warning and offer a refresh.
        let session = stubbedSession()

        let result = try await URLProtocolStub.withHandler({ _ in throw URLError(.timedOut) }) {
            await AnthropicModelDiscovery.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertTrue(result.isFallback, "network error must set isFallback=true; got false")
    }

    func test_listModelsResult_isFallback_true_onNon200Response() async {
        // WHY: a 401/500 means the live list could not be obtained; isFallback must
        // be true regardless of the specific error status.
        let body = Data("{\"error\": \"unauthorized\"}".utf8)
        let session = stubbedSession()

        let result = await URLProtocolStub.withHandler({ _ in (401, body) }) {
            await AnthropicModelDiscovery.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-bad"],
                session: session
            )
        }

        XCTAssertTrue(result.isFallback, "non-200 must set isFallback=true; got false")
    }

    func test_listModelsResult_isFallback_false_onCacheHit() async {
        // WHY: a cache hit was previously populated by a successful live fetch;
        // isFallback must stay false — the data is live, just cached.
        let body = makeModelListBody(ids: ["claude-sonnet-4"])
        let session = stubbedSession()

        // First call populates cache.
        _ = await URLProtocolStub.withHandler({ _ in (200, body) }) {
            await AnthropicModelDiscovery.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        // Second call hits cache (no stub handler installed).
        let cached = await AnthropicModelDiscovery.listModelsResult(
            environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
            session: stubbedSession()
        )

        XCTAssertFalse(cached.isFallback, "cache hit of live data must set isFallback=false; got true")
        XCTAssertEqual(cached.models.count, 1)
    }

    func test_cache_isKeyedByCredential_secondAccountRefetches() async {
        // WHY: the 1h cache used to be global — after account A's fetch, account B
        // (a different credential, e.g. one WITH Fable access) was served A's list
        // for up to an hour. The cache must be keyed by the credential so switching
        // accounts triggers a fresh fetch, while each account keeps its own entry.
        let session = stubbedSession()

        // Account A populates its cache entry.
        _ = await URLProtocolStub.withHandler({ _ in (200, self.makeModelListBody(ids: ["claude-opus-4-8"])) }) {
            await AnthropicModelDiscovery.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-account-a"],
                session: session
            )
        }

        // Account B must hit the network, not account A's cache.
        let accountB = await URLProtocolStub.withHandler({ _ in (200, self.makeModelListBody(ids: ["claude-fable-5"])) }) {
            await AnthropicModelDiscovery.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-account-b"],
                session: self.stubbedSession()
            )
        }
        XCTAssertEqual(accountB.models.map(\.id), ["claude-fable-5"],
            "a different credential must trigger a fresh fetch, not serve account A's cached list; got \(accountB.models.map(\.id))")
        XCTAssertFalse(accountB.isFallback)

        // Account A's entry must survive account B's fetch (no handler installed:
        // a cache miss here would fail the fetch and return the empty fallback).
        let accountA = await AnthropicModelDiscovery.listModelsResult(
            environment: ["ANTHROPIC_API_KEY": "sk-ant-account-a"],
            session: stubbedSession()
        )
        XCTAssertEqual(accountA.models.map(\.id), ["claude-opus-4-8"],
            "account A's cached list must survive account B's fetch; got \(accountA.models.map(\.id))")
    }

    // MARK: - refresh()

    func test_refresh_bypassesCache_andReturnsFreshData() async {
        // WHY: refresh() must evict the cache so the user gets truly up-to-date
        // models when they explicitly request a reload; serving stale cached data
        // after a refresh defeats the purpose.
        let firstBody = makeModelListBody(ids: ["claude-opus-4"])
        let secondBody = makeModelListBody(ids: ["claude-opus-4", "claude-sonnet-4-5"])
        let session = stubbedSession()

        // Populate cache with first response.
        _ = await URLProtocolStub.withHandler({ _ in (200, firstBody) }) {
            await AnthropicModelDiscovery.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        // refresh() must ignore cache and fetch second response.
        let refreshed = await URLProtocolStub.withHandler({ _ in (200, secondBody) }) {
            await AnthropicModelDiscovery.refresh(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertFalse(refreshed.isFallback, "successful refresh must set isFallback=false")
        XCTAssertEqual(refreshed.models.count, 2, "refresh must return updated model count; got \(refreshed.models.count)")
    }

    func test_refresh_isFallback_true_whenFetchFails() async throws {
        // WHY: if refresh() encounters a network error the result must report
        // isFallback=true so the picker still shows the "built-in defaults" warning.
        let session = stubbedSession()

        let result = try await URLProtocolStub.withHandler({ _ in throw URLError(.notConnectedToInternet) }) {
            await AnthropicModelDiscovery.refresh(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertTrue(result.isFallback, "failed refresh must set isFallback=true; got false")
    }

    // MARK: - ClaudeRunner integration

    func test_claudeRunner_listModelsResult_isFallback_false_whenLiveDataPresent() async {
        // WHY: ClaudeRunner.listModelsResult() must propagate isFallback=false when
        // live models are available; callers that gate the "built-in defaults" hint
        // on this value must see the correct signal.
        let body = makeModelListBody(ids: ["claude-opus-4"])
        let session = stubbedSession()
        let runner = ClaudeRunner()

        let result = await URLProtocolStub.withHandler({ _ in (200, body) }) {
            await runner.listModelsResult(
                environment: ["ANTHROPIC_API_KEY": "sk-ant-test"],
                session: session
            )
        }

        XCTAssertFalse(result.isFallback, "live data must set isFallback=false; got true")
        XCTAssertFalse(result.models.isEmpty, "live data must return models; got empty")
    }

    func test_claudeRunner_listModelsResult_isFallback_true_returnsStaticAliases() async {
        // WHY: when discovery returns no credential/error, ClaudeRunner must substitute
        // the static alias list AND set isFallback=true so the picker knows these are defaults.
        // Pass an explicit empty env so the test is not affected by CI/machine env vars.
        let runner = ClaudeRunner()
        let result = await runner.listModelsResult(environment: [:], session: stubbedSession())

        XCTAssertTrue(result.isFallback, "ClaudeRunner must report isFallback=true when using static aliases; got false")
        let staticAliasIds = AnthropicModelDiscovery.latestAliasModels().map(\.id)
        let resultIds = result.models.map(\.id)
        XCTAssertEqual(resultIds, staticAliasIds,
            "ClaudeRunner fallback must equal latestAliasModels(); got \(resultIds)")
    }
}
