import Foundation
import SocketServer
import XCTest
@testable import AppShell

final class Tailcat401RefreshRetryTests: XCTestCase {
    /// WHY: an expired access token must refresh once and continue as an
    /// authenticated runtime. Treating 401 as a missing subscription revokes
    /// the host the user still pays for.
    func testCatalog401ThenRefreshedTokenSucceedsWithoutRequiresSubscription() async throws {
        let snapshot = makeSnapshot(epoch: "epoch-401", revision: 1, peers: [peer(0xaa)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let statuses = FakeTailcatStatuses()
        let refresh = OneShotTokenRefresh(token: "refreshed-token")
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            tokenRefresh: { await refresh.call() },
            statusHandler: { statuses.append($0) }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        XCTAssertEqual(store.state?.phase, .active)
        let activeBefore = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBefore)

        await catalog.setUnauthorizedTokens(["access-token"])
        await supervisor.reconcileNowForTesting()

        XCTAssertEqual(refresh.calls, 1)
        let hostTokens = await catalog.hostAccessTokens
        XCTAssertEqual(Array(hostTokens.suffix(2)), ["access-token", "refreshed-token"])
        XCTAssertFalse(
            statuses.values.contains(.requiresSubscription),
            "a successful refresh retry must not take the subscription-revoke path"
        )
        XCTAssertNotEqual(statuses.values.last, .requiresReauthentication)
        XCTAssertEqual(store.state?.phase, .active)
        let activeAfterRefresh = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeAfterRefresh)
        XCTAssertTrue(bridge.closedHandles.isEmpty)
        await supervisor.setEnabled(false)
    }

    /// WHY: a second 401 after the one allowed refresh is a real sign-in
    /// failure, not a billing failure. Runtime and keys stay until the user
    /// reauthenticates.
    func testSecond401StaysRequiresReauthenticationAndDoesNotRevokeSubscription() async throws {
        let snapshot = makeSnapshot(epoch: "epoch-401-again", revision: 2, peers: [peer(0xbb)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let statuses = FakeTailcatStatuses()
        let refresh = OneShotTokenRefresh(token: "refreshed-token")
        let supervisor = makeSupervisor(
            bridge: bridge,
            catalog: catalog,
            store: store,
            tokenRefresh: { await refresh.call() },
            statusHandler: { statuses.append($0) }
        )

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let started = bridge.startCalls.count
        XCTAssertEqual(started, 2)

        await catalog.setUnauthorizedTokens(["access-token", "refreshed-token"])
        await supervisor.reconcileNowForTesting()

        XCTAssertEqual(refresh.calls, 1)
        let hostTokens = await catalog.hostAccessTokens
        XCTAssertEqual(Array(hostTokens.suffix(2)), ["access-token", "refreshed-token"])
        XCTAssertFalse(
            statuses.values.contains(.requiresSubscription),
            "repeated 401 must not be classified as a missing subscription"
        )
        XCTAssertEqual(statuses.values.last, .requiresReauthentication)
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertEqual(bridge.startCalls.count, started)
        XCTAssertTrue(bridge.closedHandles.isEmpty)
        let activeAfterSecond401 = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeAfterSecond401)
        let deletes = await catalog.deleteAccessTokens
        XCTAssertTrue(deletes.isEmpty)
        await supervisor.setEnabled(false)
    }

    private func makeSupervisor(
        bridge: FakeTailcatBridge,
        catalog: FakeTailcatCatalog,
        store: FakeTailcatStore,
        tokenRefresh: TailcatRuntimeSupervisor.TokenRefresh?,
        statusHandler: @escaping TailcatRuntimeSupervisor.StatusHandler
    ) -> TailcatRuntimeSupervisor {
        TailcatRuntimeSupervisor(
            serverID: "server-1",
            displayName: "Test Mac",
            bridge: bridge,
            catalog: catalog,
            secureStore: store,
            sessionProvider: { Self.session },
            tokenRefresh: tokenRefresh,
            authenticator: TailcatRemoteConnectionAuthenticator(),
            listener: FakeTailcatListener(),
            now: { Date(timeIntervalSince1970: 1_000) },
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

private final class OneShotTokenRefresh: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var callCount = 0

    init(token: String?) { self.token = token }

    var calls: Int { lock.withLock { callCount } }

    func call() async -> String? {
        lock.withLock {
            callCount += 1
            let value = token
            token = nil
            return value
        }
    }
}
