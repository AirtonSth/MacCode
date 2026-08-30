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
        XCTAssertEqual(TailcatTransportContract.pollInterval, 15)
        XCTAssertEqual(TailcatTransportContract.renewalInterval, 5 * 60)
        XCTAssertEqual(TailcatTransportContract.hostLease, 15 * 60)
        XCTAssertEqual(try LinkedTailcatBridge().buildID(), TailcatTransportContract.buildID)
    }

    func testCatalogBootstrapsMissingHostWithoutETagThenPublishesWithoutIfMatch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TailcatCatalogURLProtocol.self]
        TailcatCatalogURLProtocol.reset()
        let api = URLSessionTailcatCatalogAPI(
            baseURL: URL(string: "https://private.example")!,
            session: URLSession(configuration: configuration)
        )

        let fetched = try await api.host(serverID: "server-1", accessToken: "access-token")
        XCTAssertNil(fetched.host)
        XCTAssertNil(fetched.eTag)
        _ = try await api.publishHost(
            serverID: "server-1",
            displayName: "Test Mac",
            endpoints: [.init(kind: .derp, priority: 0, connBlob: "primary-blob")],
            accessToken: "access-token",
            ifMatch: fetched.eTag
        )
        try await api.deleteHost(serverID: "server-1", accessToken: "access-token")

        let requests = TailcatCatalogURLProtocol.capturedRequests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.path, "/v1/private/tailcat/hosts/server-1")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-tailcat-transport-build-id"), TailcatTransportContract.buildID)
        XCTAssertEqual(requests[1].httpMethod, "PUT")
        XCTAssertNil(requests[1].value(forHTTPHeaderField: "If-Match"))
        let body = try XCTUnwrap(requests[1].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["displayName", "endpoints"])
        XCTAssertEqual(json["displayName"] as? String, "Test Mac")
        let endpoints = try XCTUnwrap(json["endpoints"] as? [[String: Any]])
        XCTAssertEqual(Set(endpoints[0].keys), ["kind", "priority", "connBlob"])
        XCTAssertEqual(requests[2].httpMethod, "DELETE")
        XCTAssertEqual(requests[2].url?.path, "/v1/private/tailcat/hosts/server-1")
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "x-tailcat-transport-build-id"),
            TailcatTransportContract.buildID
        )
        XCTAssertEqual(requests[3].httpMethod, "GET")
        XCTAssertEqual(requests[3].url?.path, "/v1/private/tailcat/hosts/server-1")
        XCTAssertEqual(requests[3].value(forHTTPHeaderField: "Authorization"), "Bearer access-token")
    }

    func testCatalogDeleteRejectsPersistedHostReadback() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TailcatCatalogURLProtocol.self]
        TailcatCatalogURLProtocol.reset(retainHostOnReadback: true)
        let api = URLSessionTailcatCatalogAPI(
            baseURL: URL(string: "https://private.example")!,
            session: URLSession(configuration: configuration)
        )

        do {
            try await api.deleteHost(serverID: "server-1", accessToken: "access-token")
            XCTFail("delete must not succeed while the host remains published")
        } catch {
            XCTAssertEqual(error as? TailcatCatalogError, .invalidResponse)
        }
        XCTAssertEqual(TailcatCatalogURLProtocol.capturedRequests.map(\.httpMethod), ["DELETE", "GET"])
    }

    @MainActor
    func testSettingsToggleOffInvokesDirectTailcatAuthorityAfterPersistence() throws {
        let directory = NSTemporaryDirectory() + "RCTailcatSettings-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        try context.settingsRepo.set("tailcat_access_enabled", "1")
        let settings = SettingsViewModel(context: context, loadImmediately: false)
        var applied: [Bool] = []
        context.onTailcatAccessSettingChanged = { applied.append($0) }

        settings.setTailcatAccess(false)

        XCTAssertEqual(try context.settingsRepo.get("tailcat_access_enabled"), "0")
        XCTAssertEqual(applied, [false])
    }

    func testAdmittedSnapshotStartsDistinctServersPublishesBothAndDisableStopsThem() async throws {
        let snapshot = makeSnapshot(epoch: "epoch-4", revision: 7, peers: [peer(0xaa)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let starts = bridge.startCalls
        XCTAssertEqual(starts.count, 2)
        XCTAssertNotEqual(starts[0].key, starts[1].key)
        XCTAssertEqual(starts[0].secret, starts[1].secret)
        XCTAssertEqual(starts[0].listenerID, starts[1].listenerID)
        XCTAssertTrue(starts.allSatisfy { $0.loopbackPort == 45_123 })
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
        let snapshot = makeSnapshot(epoch: "epoch-8", revision: 2, peers: [])
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

    func testDisableDeletesPublishedHostOnceAndStopsTailcatRuntime() async {
        let snapshot = makeSnapshot(epoch: "epoch-disable", revision: 1, peers: [peer(0xba)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let listener = FakeTailcatListener()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            listener: listener
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let listenerStopsBeforeDisable = listener.stopCount

        await supervisor.setEnabled(false)

        let deleteAccessTokens = await catalog.deleteAccessTokens
        XCTAssertEqual(deleteAccessTokens, ["access-token"])
        XCTAssertEqual(Set(bridge.closedHandles), [101, 202])
        XCTAssertEqual(listener.stopCount, listenerStopsBeforeDisable + 1)
        let activeRuntime = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeRuntime)
    }

    func testLogoutDeletesPublishedHostWithLastMemoryHeldToken() async {
        let snapshot = makeSnapshot(epoch: "epoch-logout", revision: 1, peers: [peer(0xca)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let sessions = FakeTailcatSessions(Self.session)
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            sessionProvider: { sessions.value }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        sessions.value = nil

        await supervisor.accountChanged()

        let deleteAccessTokens = await catalog.deleteAccessTokens
        XCTAssertEqual(deleteAccessTokens, ["access-token"])
        XCTAssertEqual(Set(bridge.closedHandles), [101, 202])
        XCTAssertNil(store.state)
        let activeRuntime = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeRuntime)
    }

    func testPrimaryFailurePublishesFallbackOnly() async {
        let snapshot = makeSnapshot(epoch: "epoch-2", revision: 3, peers: [peer(0xbb)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge(failingRelay: .primary)
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let publish = await catalog.lastPublish
        XCTAssertEqual(publish?.endpoints, [
            TailcatCatalogEndpoint(kind: .derp, priority: 1, connBlob: "fallback-blob"),
        ])
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertNotEqual(store.state?.active?.primary, store.state?.active?.fallback)
        let activeRuntime = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeRuntime)

        await supervisor.setEnabled(false)
        XCTAssertEqual(bridge.closedHandles, [202])
    }

    func testFallbackFailurePublishesPrimaryOnly() async {
        let snapshot = makeSnapshot(epoch: "epoch-2", revision: 3, peers: [peer(0xbb)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge(failingRelay: .publicFallback)
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let publish = await catalog.lastPublish
        XCTAssertEqual(publish?.endpoints, [
            TailcatCatalogEndpoint(kind: .derp, priority: 0, connBlob: "primary-blob"),
        ])
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertNotEqual(store.state?.active?.primary, store.state?.active?.fallback)
        let activeRuntime = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeRuntime)

        await supervisor.setEnabled(false)
        XCTAssertEqual(bridge.closedHandles, [101])
    }

    func testBothRelayFailuresDoNotPublishOrActivate() async {
        let snapshot = makeSnapshot(epoch: "epoch-2", revision: 3, peers: [peer(0xbb)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge(failAll: true)
        let store = FakeTailcatStore()
        let statuses = FakeTailcatStatuses()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            statusHandler: { statuses.append($0) }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let publish = await catalog.lastPublish
        XCTAssertNil(publish)
        XCTAssertEqual(store.state?.phase, .publishing)
        XCTAssertNotNil(store.state?.pending)
        let activeRuntime = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(activeRuntime)
        XCTAssertTrue(bridge.closedHandles.isEmpty)
        XCTAssertEqual(statuses.values.last, .unavailable)
    }

    func testPublishingCrashRecoveryRotatesAwayFromOldAndPendingKeys() async {
        let snapshot = makeSnapshot(epoch: "epoch-3", revision: 9, peers: [peer(0xdd)])
        let staleActive = TailcatKeyVersion(
            primary: .init(privateKey: "old-primary", publicKey: "old-primary-public"),
            fallback: .init(privateKey: "old-fallback", publicKey: "old-fallback-public")
        )
        let interruptedPending = TailcatKeyVersion(
            primary: .init(privateKey: "pending-primary", publicKey: "pending-primary-public"),
            fallback: .init(privateKey: "pending-fallback", publicKey: "pending-fallback-public")
        )
        let store = FakeTailcatStore(TailcatSecureState(
            phase: .publishing,
            accountID: "account-1",
            allowlistEpoch: snapshot.epoch,
            revision: snapshot.revision,
            snapshotHash: snapshot.hash,
            eTag: "\"1\"",
            active: staleActive,
            pending: interruptedPending
        ))
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        let startedKeys = Set(bridge.startCalls.map(\.key.privateKey))
        XCTAssertTrue(startedKeys.isDisjoint(with: ["old-primary", "old-fallback", "pending-primary", "pending-fallback"]))
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertNil(store.state?.pending)
        XCTAssertNotEqual(store.state?.active, staleActive)
        XCTAssertNotEqual(store.state?.active, interruptedPending)
    }

    func testRevokedRecordNeverResurrectsRetainedActiveKeys() async {
        let snapshot = makeSnapshot(epoch: "epoch-5", revision: 6, peers: [peer(0xee)])
        let revokedKeys = TailcatKeyVersion(
            primary: .init(privateKey: "revoked-primary", publicKey: "revoked-primary-public"),
            fallback: .init(privateKey: "revoked-fallback", publicKey: "revoked-fallback-public")
        )
        let store = FakeTailcatStore(TailcatSecureState(
            phase: .revoked,
            accountID: "account-1",
            allowlistEpoch: snapshot.epoch,
            revision: snapshot.revision,
            snapshotHash: snapshot.hash,
            eTag: "\"1\"",
            active: revokedKeys,
            pending: nil
        ))
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        XCTAssertTrue(Set(bridge.startCalls.map(\.key.privateKey)).isDisjoint(with: ["revoked-primary", "revoked-fallback"]))
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertNotEqual(store.state?.active, revokedKeys)
    }

    func testEpochChangeRotatesEvenWhenRevisionResets() async {
        let oldSnapshot = makeSnapshot(epoch: "epoch-old", revision: 99, peers: [peer(0xab)])
        let newSnapshot = makeSnapshot(epoch: "epoch-new", revision: 1, peers: [peer(0xab)])
        let oldKeys = TailcatKeyVersion(
            primary: .init(privateKey: "old-primary", publicKey: "old-primary-public"),
            fallback: .init(privateKey: "old-fallback", publicKey: "old-fallback-public")
        )
        let store = FakeTailcatStore(TailcatSecureState(
            phase: .active,
            accountID: "account-1",
            allowlistEpoch: oldSnapshot.epoch,
            revision: oldSnapshot.revision,
            snapshotHash: oldSnapshot.hash,
            eTag: "\"1\"",
            active: oldKeys,
            pending: nil
        ))
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: FakeTailcatCatalog(snapshot: newSnapshot),
            store: store
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        XCTAssertEqual(bridge.startCalls.count, 2)
        XCTAssertEqual(store.state?.allowlistEpoch, "epoch-new")
        XCTAssertEqual(store.state?.revision, 1)
        XCTAssertEqual(store.state?.phase, .active)
    }

    func testSameEpochRejectsLowerRevision() async {
        let storedSnapshot = makeSnapshot(epoch: "epoch-stable", revision: 10, peers: [peer(0xbc)])
        let staleSnapshot = makeSnapshot(epoch: "epoch-stable", revision: 9, peers: [peer(0xbc)])
        let store = FakeTailcatStore(TailcatSecureState(
            phase: .active,
            accountID: "account-1",
            allowlistEpoch: storedSnapshot.epoch,
            revision: storedSnapshot.revision,
            snapshotHash: storedSnapshot.hash,
            eTag: "\"1\"",
            active: TailcatKeyVersion(
                primary: .init(privateKey: "active-primary", publicKey: "active-primary-public"),
                fallback: .init(privateKey: "active-fallback", publicKey: "active-fallback-public")
            ),
            pending: nil
        ))
        let bridge = FakeTailcatBridge()
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: FakeTailcatCatalog(snapshot: staleSnapshot),
            store: store
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()

        XCTAssertTrue(bridge.startCalls.isEmpty)
        XCTAssertEqual(store.state?.revision, 10)
        XCTAssertEqual(store.state?.allowlistEpoch, "epoch-stable")
    }

    func testBackendOutageKeepsRuntimeUntilHostLeaseThenFailsClosed() async {
        let clock = FakeTailcatClock(Date(timeIntervalSince1970: 10_000))
        let snapshot = makeSnapshot(epoch: "epoch-1", revision: 1, peers: [peer(0xcc)])
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
        let deleteAccessTokens = await catalog.deleteAccessTokens
        XCTAssertTrue(deleteAccessTokens.isEmpty)
    }

    private func makeSupervisor(
        bridge: FakeTailcatBridge,
        catalog: FakeTailcatCatalog,
        store: FakeTailcatStore,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_000) },
        listener: FakeTailcatListener = FakeTailcatListener(),
        sessionProvider: @escaping TailcatRuntimeSupervisor.SessionProvider = {
            TailcatRuntimeSupervisorTests.session
        },
        statusHandler: @escaping TailcatRuntimeSupervisor.StatusHandler = { _ in }
    ) -> TailcatRuntimeSupervisor {
        TailcatRuntimeSupervisor(
            serverID: "server-1",
            displayName: "Test Mac",
            bridge: bridge,
            catalog: catalog,
            secureStore: store,
            sessionProvider: sessionProvider,
            authenticator: TailcatRemoteConnectionAuthenticator(),
            listener: listener,
            now: now,
            automaticPolling: false,
            statusHandler: statusHandler
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

    private func makeSnapshot(epoch: String, revision: Int64, peers: [String]) -> TailcatAllowlistSnapshot {
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

private final class FakeTailcatStatuses: @unchecked Sendable {
    private let lock = NSLock()
    private var statuses: [TailcatRuntimeStatus] = []

    var values: [TailcatRuntimeStatus] { lock.withLock { statuses } }
    func append(_ status: TailcatRuntimeStatus) { lock.withLock { statuses.append(status) } }
}

private final class FakeTailcatSessions: @unchecked Sendable {
    private let lock = NSLock()
    private var session: PrivateAccountSession?

    init(_ session: PrivateAccountSession?) { self.session = session }

    var value: PrivateAccountSession? {
        get { lock.withLock { session } }
        set { lock.withLock { session = newValue } }
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

    init(_ stored: TailcatSecureState? = nil) { self.stored = stored }

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
        let loopbackPort: UInt16
        let relay: TailcatRelay
    }

    private let lock = NSLock()
    private var keyCounter = 0
    private var starts: [StartCall] = []
    private var closes: [UInt64] = []
    private let failingRelay: TailcatRelay?
    private let failAll: Bool

    init(failingRelay: TailcatRelay? = nil, failAll: Bool = false) {
        self.failingRelay = failingRelay
        self.failAll = failAll
    }

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
        loopbackPort: UInt16,
        relay: TailcatRelay
    ) throws -> TailcatRunningServer {
        let call = StartCall(
            key: key,
            allowedNodePublics: allowedNodePublics,
            secret: secret,
            listenerID: listenerID,
            serverID: serverID,
            loopbackPort: loopbackPort,
            relay: relay
        )
        lock.withLock { starts.append(call) }
        if failAll || matches(relay, failingRelay) { throw TailcatBridgeError.rejected("start_failed") }
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

private final class FakeTailcatListener: TailcatLoopbackListening, @unchecked Sendable {
    private let lock = NSLock()
    private var stops = 0

    var stopCount: Int { lock.withLock { stops } }
    func start() throws -> UInt16 { 45_123 }
    func stop() { lock.withLock { stops += 1 } }
}

private actor FakeTailcatCatalog: TailcatCatalogAPI {
    struct Publish: Sendable {
        let endpoints: [TailcatCatalogEndpoint]
        let ifMatch: String?
    }

    private let snapshot: TailcatAllowlistSnapshot
    private var unavailable = false
    private(set) var lastPublish: Publish?
    private(set) var deleteAccessTokens: [String] = []

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

    func deleteHost(serverID: String, accessToken: String) async throws {
        if unavailable { throw URLError(.notConnectedToInternet) }
        deleteAccessTokens.append(accessToken)
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
    private static var retainHostOnReadback = false

    static var capturedRequests: [URLRequest] { lock.withLock { requests } }
    static func reset(retainHostOnReadback: Bool = false) {
        lock.withLock {
            requests = []
            self.retainHostOnReadback = retainHostOnReadback
        }
    }

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
        let retainHostOnReadback = Self.lock.withLock {
            Self.requests.append(captured)
            return Self.retainHostOnReadback
        }
        let method = request.httpMethod ?? "GET"
        let host = """
        {"serverId":"server-1","displayName":"Test Mac","endpoints":[],"transportBuildId":"\(TailcatTransportContract.buildID)","createdAt":"2026-08-30T00:00:00Z","updatedAt":"2026-08-30T00:00:00Z","leaseExpiresAt":"2026-08-30T00:15:00Z","version":\(method == "PUT" ? 2 : 1)}
        """
        let body: String
        switch method {
        case "PUT": body = "{\"host\":\(host)}"
        case "DELETE": body = ""
        default:
            body = retainHostOnReadback
                ? "{\"host\":\(host),\"snapshot\":{\"epoch\":\"epoch-1\",\"revision\":1,\"clients\":[]}}"
                : "{\"host\":null,\"snapshot\":{\"epoch\":\"epoch-1\",\"revision\":1,\"clients\":[]}}"
        }
        let headers = method == "PUT" ? ["ETag": "\"2\""] : [:]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: method == "DELETE" ? 204 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
