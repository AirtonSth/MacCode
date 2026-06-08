import XCTest
import CryptoKit
@testable import DistillCore

final class DistillReversibleStoreServiceTests: XCTestCase {
    /// In-memory CCR store for the HTTP boundary test (no Persistence dependency).
    private final class InMemoryReversibleStore: ReversibleStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var blobs: [String: Data] = [:]
        private(set) var storeCount = 0

        func storeOriginal(_ data: Data) throws -> String {
            let handle = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            lock.lock(); defer { lock.unlock() }
            blobs[handle] = data
            storeCount += 1
            return handle
        }

        func retrieveOriginal(_ handle: String) throws -> Data? {
            lock.lock(); defer { lock.unlock() }
            return blobs[handle]
        }
    }

    /// Runtime that discards its input — proves the original is recoverable even
    /// when the runtime returns something lossy/unrelated (store happens upstream).
    private struct DiscardingRuntime: DistillRuntime {
        func distill(_ request: DistillRequest) async throws -> String { "X" }
    }

    private struct Retrieved: Decodable {
        let handle: String
        let found: Bool
        let original: String?
    }

    func test_storeBeforeLoss_retrievesByteIdenticalOriginal_over24k() async throws {
        let store = InMemoryReversibleStore()
        let configuration = try DistillServiceConfiguration(
            authToken: "tok",
            appSupportDirectory: NSTemporaryDirectory()
        )
        let scheduler = DistillScheduler(runtime: DiscardingRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            reversibleStore: store,
            reversibleStoreMinBytes: 1_024
        )
        let ready = try await server.start()
        defer { server.stop() }

        let big = String(repeating: "log line of stuff with detail\n", count: 1_200) // ~36k > 24k
        XCTAssertGreaterThan(big.utf8.count, 24_000)
        let request = DistillRequest(mode: .longText, input: big, maxOutputCharacters: 4_000)
        let body = try JSONEncoder().encode(request)

        let distill = try await http(ready.baseURL + "/v1/distill", method: "POST", token: "tok", body: body)
        XCTAssertEqual(distill.status, 200)
        let response = try JSONDecoder().decode(DistillResponse.self, from: distill.data)
        let handle = try XCTUnwrap(response.originalHandle, "large input must be stored before loss")

        let retrieve = try await http(ready.baseURL + "/v1/retrieve/\(handle)", token: "tok")
        XCTAssertEqual(retrieve.status, 200)
        let recovered = try JSONDecoder().decode(Retrieved.self, from: retrieve.data)
        XCTAssertTrue(recovered.found)
        XCTAssertEqual(recovered.original, big, "the >24k original is recovered byte-for-byte despite a discarding runtime")
    }

    func test_smallInputIsNotStored_andUnknownHandleReturns404() async throws {
        let store = InMemoryReversibleStore()
        let configuration = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(
            configuration: configuration,
            scheduler: scheduler,
            reversibleStore: store,
            reversibleStoreMinBytes: 1_024
        )
        let ready = try await server.start()
        defer { server.stop() }

        let request = DistillRequest(mode: .longText, input: "tiny input", maxOutputCharacters: 200)
        let body = try JSONEncoder().encode(request)
        let distill = try await http(ready.baseURL + "/v1/distill", method: "POST", token: "tok", body: body)
        XCTAssertEqual(distill.status, 200)
        let response = try JSONDecoder().decode(DistillResponse.self, from: distill.data)
        XCTAssertNil(response.originalHandle, "small inputs are not worth storing")
        XCTAssertEqual(store.storeCount, 0)

        let retrieve = try await http(ready.baseURL + "/v1/retrieve/deadbeef", token: "tok")
        XCTAssertEqual(retrieve.status, 404, "unknown handle => typed 404, never empty/hang")
        let body404 = try JSONDecoder().decode(Retrieved.self, from: retrieve.data)
        XCTAssertFalse(body404.found)
    }

    func test_retrieveRequiresBearerToken() async throws {
        let store = InMemoryReversibleStore()
        let configuration = try DistillServiceConfiguration(authToken: "tok", appSupportDirectory: NSTemporaryDirectory())
        let scheduler = DistillScheduler(runtime: LocalDistillRuntime(), maxConcurrentRequests: 2)
        let server = DistillHTTPServer(configuration: configuration, scheduler: scheduler, reversibleStore: store)
        let ready = try await server.start()
        defer { server.stop() }

        let retrieve = try await http(ready.baseURL + "/v1/retrieve/whatever") // no token
        XCTAssertEqual(retrieve.status, 401)
    }

    private func http(
        _ url: String,
        method: String = "GET",
        token: String? = nil,
        body: Data? = nil
    ) async throws -> (status: Int, data: Data) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 5
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        return (http.statusCode, data)
    }
}
