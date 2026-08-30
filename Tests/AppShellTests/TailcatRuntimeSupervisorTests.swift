import Foundation
import SocketServer
import XCTest
@testable import AppShell

final class TailcatRuntimeSupervisorTests: XCTestCase {
    func testExactTransportContractAndLinkedBridgeBuildID() throws {
        XCTAssertEqual(TailcatTransportContract.buildID, "tailcat-88929418b1a3f3c74904a3136d6a9e87b1b5b9bb+rcpatch1")
        XCTAssertEqual(TailcatTransportContract.primaryDERPHost, "derp.remotecode.io")
        XCTAssertEqual(TailcatTransportContract.primaryDERPIPv4, "82.25.69.175")
        XCTAssertEqual(TailcatTransportContract.primaryDERPPort, 444)
        XCTAssertEqual(TailcatTransportContract.primarySTUNPort, 3478)
        XCTAssertEqual(TailcatTransportContract.primaryRegionID, 1)
        XCTAssertEqual(TailcatTransportContract.loopbackPort, 18_217)
        XCTAssertEqual(TailcatTransportContract.pollInterval, 15)
        XCTAssertEqual(TailcatTransportContract.renewalInterval, 5 * 60)
        XCTAssertEqual(TailcatTransportContract.hostLease, 15 * 60)
        XCTAssertEqual(try LinkedTailcatBridge().buildID(), TailcatTransportContract.buildID)
    }

    func testCatalogUsesFrozenHostSchemaBuildHeaderAndETagCAS() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TailcatCatalogURLProtocol.self]
        TailcatCatalogURLProtocol.reset()
        let api = URLSessionTailcatCatalogAPI(
            baseURL: URL(string: "https://private.example")!,
            session: URLSession(configuration: configuration)
        )

        let fetched = try await api.host(serverID: "server-1", accessToken: "access-token")
        _ = try await api.publishHost(
            serverID: "server-1",
            displayName: "Test Mac",
            endpoints: [.init(kind: .derp, priority: 0, connBlob: "primary-blob")],
            accessToken: "access-token",
            ifMatch: fetched.eTag
        )

        let requests = TailcatCatalogURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/v1/private/tailcat/hosts/server-1")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-tailcat-transport-build-id"), TailcatTransportContract.buildID)
        XCTAssertEqual(requests[1].httpMethod, "PUT")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-Match"), "\"1\"")
        let body = try XCTUnwrap(requests[1].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["displayName", "endpoints"])
        XCTAssertEqual(json["displayName"] as? String, "Test Mac")
        let endpoints = try XCTUnwrap(json["endpoints"] as? [[String: Any]])
        XCTAssertEqual(Set(endpoints[0].keys), ["kind", "priority", "connBlob"])
    }

    func testAdmittedSnapshotStartsDistinctServersPublishesBothAndDisableStopsThem() async throws {
        let snapshot = makeSnapshot(epoch: 4, revision: 7, peers: [peer(0xaa)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let starts = bridge.startCalls
        XCTAssertEqual(starts.count, 2)
        XCTAssertNotEqual(starts[0].key, starts[1].key)
        XCTAssertNotEqual(starts[0].secret, starts[1].secret)
        XCTAssertNotEqual(starts[0].listenerID, starts[1].listenerID)
        XCTAssertEqual(Set(starts.map(\.serverID)), ["server-1.primary", "server-1.fallback"])
        XCTAssertTrue(starts.allSatisfy { $0.allowedNodePublics == [peer(0xaa)] })
        let publish = await catalog.lastPublish
        XCTAssertEqual(publish?.ifMatch, "\"1\"")
        XCTAssertEqual(publish?.endpoints.map(\.priority), [0, 1])
        XCTAssertEqual(publish?.endpoints.map(\.kind), [.derp, .derp])
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertNotNil(store.state?.active)
        XCTAssertNil(store.state?.pending)
        let activeBeforeDisable = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBeforeDisable)

        await supervisor.setEnabled(false)
        XCTAssertEqual(Set(bridge.closedHandles), [101, 202])
        let activeAfterDisable = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeAfterDisable)
    }

    func testEmptyAllowlistIsDurablyRevokedAndNeverStartedOrPublished() async {
        let snapshot = makeSnapshot(epoch: 8, revision: 2, peers: [])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        XCTAssertTrue(bridge.startCalls.isEmpty)
        let emptyPublish = await catalog.lastPublish
        XCTAssertNil(emptyPublish)
        XCTAssertEqual(store.state?.phase, .revoked)
        XCTAssertNil(store.state?.active)
        XCTAssertNil(store.state?.pending)
        let emptyRuntime = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(emptyRuntime)
    }

    func testPartialServerStartIsClosedAndNotPublished() async {
        let snapshot = makeSnapshot(epoch: 2, revision: 3, peers: [peer(0xbb)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge(failingRelay: .publicFallback)
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        XCTAssertEqual(bridge.closedHandles, [101])
        let partialPublish = await catalog.lastPublish
        XCTAssertNil(partialPublish)
        XCTAssertEqual(store.state?.phase, .publishing)
        XCTAssertNotNil(store.state?.pending)
        let partialRuntime = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(partialRuntime)
    }

    func testBackendOutageKeepsRuntimeUntilHostLeaseThenFailsClosed() async {
        let clock = FakeTailcatClock(Date(timeIntervalSince1970: 10_000))
        let snapshot = makeSnapshot(epoch: 1, revision: 1, peers: [peer(0xcc)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            now: { clock.now }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        await catalog.setUnavailable(true)
        clock.advance(899)
        await supervisor.reconcileNowForTesting()
        let activeBeforeExpiry = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBeforeExpiry)

        clock.advance(2)
        await supervisor.reconcileNowForTesting()
        let activeAfterExpiry = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeAfterExpiry)
        XCTAssertEqual(Set(bridge.closedHandles), [101, 202])
        XCTAssertEqual(store.state?.phase, .revoked)
    }

    private func makeSupervisor(
        bridge: FakeTailcatBridge,
        catalog: FakeTailcatCatalog,
        store: FakeTailcatStore,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) }
    ) -> TailcatRuntimeSupervisor {
        TailcatRuntimeSupervisor(
            serverID: "server-1",
            displayName: "Test Mac",
            bridge: bridge,
            catalog: catalog,
            secureStore: store,
            sessionProvider: { Self.session },
            authenticator: TailcatRemoteConnectionAuthenticator(),
            now: now,
            automaticPolling: false,
            statusHandler: { _ in }
        )
    }

    private static let session = PrivateAccountSession(
        accessToken: "access-token",
        refreshToken: "refresh-token",
        user: PrivateAccountUser(
            daysRemaing: nil,
            daysRemaining: 30,
            email: "subscriber@example.com",
            id: "account-1",
            subscribed: true
        )
    )

    private func peer(_ byte: UInt8) -> String {
        "nodekey:" + String(repeating: String(format: "%02x", byte), count: 32)
    }

    private func makeSnapshot(epoch: Int64, revision: Int64, peers: [String]) -> TailcatAllowlistSnapshot {
        TailcatAllowlistSnapshot(
            epoch: epoch,
            revision: revision,
            clients: peers.enumerated().map { index, nodePublic in
                TailcatCatalogClient(
                    clientId: "client-\(index)",
                    displayName: "Client \(index)",
                    nodePublic: nodePublic,
                    transportBuildId: TailcatTransportContract.buildID,
                    createdAt: "2026-08-30T00:00:00Z",
                    updatedAt: "2026-08-30T00:00:00Z",
                    leaseExpiresAt: "2026-09-06T00:00:00Z",
                    version: 1
                )
            }
        )
    }
}

private final class FakeTailcatClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private final class FakeTailcatStore: TailcatSecureStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TailcatSecureState?

    var state: TailcatSecureState? { lock.withLock { stored } }
    func load() throws -> TailcatSecureState? { state }
    func save(_ state: TailcatSecureState) throws { lock.withLock { stored = state } }
    func clear() throws { lock.withLock { stored = nil } }
}

private final class FakeTailcatBridge: TailcatBridgeRuntime, @unchecked Sendable {
    struct StartCall: Sendable {
        let key: TailcatBridgeKey
        let allowedNodePublics: [String]
        let secret: Data
        let listenerID: Data
        let serverID: String
        let relay: TailcatRelay
    }

    private let lock = NSLock()
    private var keyCounter = 0
    private var starts: [StartCall] = []
    private var closes: [UInt64] = []
    private let failingRelay: TailcatRelay?

    init(failingRelay: TailcatRelay? = nil) { self.failingRelay = failingRelay }

    var startCalls: [StartCall] { lock.withLock { starts } }
    var closedHandles: [UInt64] { lock.withLock { closes } }
    func buildID() throws -> String { TailcatTransportContract.buildID }

    func generateKey() throws -> TailcatBridgeKey {
        lock.withLock {
            keyCounter += 1
            return TailcatBridgeKey(privateKey: "private-\(keyCounter)", publicKey: "public-\(keyCounter)")
        }
    }

    func startServer(
        key: TailcatBridgeKey,
        allowedNodePublics: [String],
        secret: Data,
        listenerID: Data,
        serverID: String,
        relay: TailcatRelay
    ) throws -> TailcatRunningServer {
        let call = StartCall(
            key: key,
            allowedNodePublics: allowedNodePublics,
            secret: secret,
            listenerID: listenerID,
            serverID: serverID,
            relay: relay
        )
        lock.withLock { starts.append(call) }
        if matches(relay, failingRelay) { throw TailcatBridgeError.rejected("start_failed") }
        switch relay {
        case .primary: return TailcatRunningServer(handle: 101, connBlob: "primary-blob", nodePublic: key.publicKey)
        case .publicFallback: return TailcatRunningServer(handle: 202, connBlob: "fallback-blob", nodePublic: key.publicKey)
        }
    }

    func closeServer(handle: UInt64) throws { lock.withLock { closes.append(handle) } }

    private func matches(_ lhs: TailcatRelay, _ rhs: TailcatRelay?) -> Bool {
        guard let rhs else { return false }
        switch (lhs, rhs) {
        case (.primary, .primary), (.publicFallback, .publicFallback): return true
        default: return false
        }
    }
}

private actor FakeTailcatCatalog: TailcatCatalogAPI {
    struct Publish: Sendable {
        let endpoints: [TailcatCatalogEndpoint]
        let ifMatch: String?
    }

    private let snapshot: TailcatAllowlistSnapshot
    private var unavailable = false
    private(set) var lastPublish: Publish?

    init(snapshot: TailcatAllowlistSnapshot) { self.snapshot = snapshot }

    func setUnavailable(_ unavailable: Bool) { self.unavailable = unavailable }

    func host(serverID: String, accessToken: String) async throws -> TailcatHostSnapshot {
        if unavailable { throw URLError(.notConnectedToInternet) }
        return TailcatHostSnapshot(host: hostValue(serverID: serverID, version: 1), snapshot: snapshot, eTag: "\"1\"")
    }

    func publishHost(
        serverID: String,
        displayName: String,
        endpoints: [TailcatCatalogEndpoint],
        accessToken: String,
        ifMatch: String?
    ) async throws -> TailcatPublishedHost {
        if unavailable { throw URLError(.notConnectedToInternet) }
        lastPublish = Publish(endpoints: endpoints, ifMatch: ifMatch)
        return TailcatPublishedHost(host: hostValue(serverID: serverID, version: 2, endpoints: endpoints), eTag: "\"2\"")
    }

    private func hostValue(
        serverID: String,
        version: Int64,
        endpoints: [TailcatCatalogEndpoint] = []
    ) -> TailcatCatalogHost {
        TailcatCatalogHost(
            serverId: serverID,
            displayName: "Test Mac",
            endpoints: endpoints,
            transportBuildId: TailcatTransportContract.buildID,
            createdAt: "2026-08-30T00:00:00Z",
            updatedAt: "2026-08-30T00:00:00Z",
            leaseExpiresAt: "2026-08-30T00:15:00Z",
            version: version
        )
    }
}

private final class TailcatCatalogURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []

    static var capturedRequests: [URLRequest] { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer[..<count])
            }
            captured.httpBody = body
        }
        Self.lock.withLock { Self.requests.append(captured) }
        let method = request.httpMethod ?? "GET"
        let host = """
        {"serverId":"server-1","displayName":"Test Mac","endpoints":[],"transportBuildId":"\(TailcatTransportContract.buildID)","createdAt":"2026-08-30T00:00:00Z","updatedAt":"2026-08-30T00:00:00Z","leaseExpiresAt":"2026-08-30T00:15:00Z","version":\(method == "PUT" ? 2 : 1)}
        """
        let body = method == "PUT"
            ? "{\"host\":\(host)}"
            : "{\"host\":\(host),\"snapshot\":{\"epoch\":1,\"revision\":1,\"clients\":[]}}"
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["ETag": method == "PUT" ? "\"2\"" : "\"1\""]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
