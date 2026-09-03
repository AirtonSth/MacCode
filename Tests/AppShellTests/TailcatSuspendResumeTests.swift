import Foundation
import SocketServer
import XCTest
@testable import AppShell

final class TailcatSuspendResumeTests: XCTestCase {
    /// WHY: a delayed sleep Task used to call shutdown() after wake re-enabled
    /// the supervisor, deleting the published host and forcing a key rotation.
    /// Suspend must yield during close so resume can win the generation fence.
    func testDelayedSuspendCannotDisableAfterResume() async throws {
        let snapshot = makeSnapshot(epoch: "epoch-sleep", revision: 1, peers: [peer(0xaa)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
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
        XCTAssertEqual(store.state?.phase, .active)
        let keysBefore = Set(bridge.startCalls.map(\.key.privateKey))
        XCTAssertEqual(keysBefore.count, 2)
        let activeBefore = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBefore)

        await supervisor.pauseNextSuspendForTesting()
        let suspendTask = Task { await supervisor.suspend() }
        var paused = false
        for _ in 0..<100 {
            paused = await supervisor.isSuspendPausedForTesting
            if paused { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(paused, "suspend must yield so resume can win the generation fence")

        await supervisor.resume()
        let activeAfterResume = await supervisor.hasActiveRuntimeForTesting
        let enabledAfterResume = await supervisor.isEnabled
        XCTAssertTrue(activeAfterResume, "resume must restart transport while the delayed suspend is still paused")
        XCTAssertTrue(enabledAfterResume)
        let keysAfterResume = Set(bridge.startCalls.map(\.key.privateKey))
        XCTAssertEqual(keysAfterResume, keysBefore, "wake must restart with the same identity keys")

        await supervisor.continuePausedSuspendForTesting()
        await suspendTask.value

        let activeAfterDelayedSuspend = await supervisor.hasActiveRuntimeForTesting
        let enabledAfterDelayedSuspend = await supervisor.isEnabled
        XCTAssertTrue(
            activeAfterDelayedSuspend,
            "a delayed suspend must not disable after resume has already won the generation"
        )
        XCTAssertTrue(enabledAfterDelayedSuspend)
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertNotNil(store.state?.active)
        XCTAssertEqual(
            Set([store.state?.active?.primary.privateKey, store.state?.active?.fallback.privateKey].compactMap { $0 }),
            keysBefore
        )
        let deletes = await catalog.deleteAccessTokens
        XCTAssertTrue(deletes.isEmpty, "sleep/wake must not delete the published host")
        XCTAssertFalse(statuses.values.contains(.requiresSubscription))
        XCTAssertNotEqual(statuses.values.last, .off)
        await supervisor.setEnabled(false)
    }

    /// WHY: the opposite interleaving (wake in-flight, then sleep) must still
    /// let the later suspend win — without treating it as a subscription revoke
    /// or deleting the catalog host.
    func testDelayedResumeCannotReenableAfterLaterSuspend() async throws {
        let snapshot = makeSnapshot(epoch: "epoch-wake", revision: 1, peers: [peer(0xbb)])
        let catalog = FakeTailcatCatalog(snapshot: snapshot)
        let bridge = FakeTailcatBridge()
        let store = FakeTailcatStore()
        let supervisor = makeSupervisor(bridge: bridge, catalog: catalog, store: store)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let activeBeforeWake = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBeforeWake)
        await catalog.holdNextHostCall()

        let resumeTask = Task { await supervisor.resume() }
        var holding = false
        for _ in 0..<100 {
            holding = await catalog.isHoldingHost
            if holding { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(holding, "resume must block in catalog.host so suspend can overtake it")

        await supervisor.suspend()
        await catalog.releaseHostCall()
        await resumeTask.value

        let activeAfterLaterSuspend = await supervisor.hasActiveRuntimeForTesting
        let enabledAfterLaterSuspend = await supervisor.isEnabled
        XCTAssertFalse(
            activeAfterLaterSuspend,
            "a later suspend must keep sockets down after a stale resume tick returns"
        )
        XCTAssertTrue(enabledAfterLaterSuspend, "sleep keeps the enabled intention")
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertNotNil(store.state?.active)
        let deletes = await catalog.deleteAccessTokens
        XCTAssertTrue(deletes.isEmpty, "suspend must not delete the published host")
        await supervisor.setEnabled(false)
    }

    func testSuspendThenResumeRestartsWithSameKeysAndKeepsPublication() async throws {
        let snapshot = makeSnapshot(epoch: "epoch-roundtrip", revision: 4, peers: [peer(0xcc)])
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
        let keysBefore = Set(bridge.startCalls.map(\.key.privateKey))
        let startsBefore = bridge.startCalls.count
        let stopsBefore = listener.stopCount
        XCTAssertEqual(startsBefore, 2)

        await supervisor.suspend()
        let activeAfterSuspend = await supervisor.hasActiveRuntimeForTesting
        let enabledAfterSuspend = await supervisor.isEnabled
        XCTAssertFalse(activeAfterSuspend)
        XCTAssertEqual(listener.stopCount, stopsBefore + 1)
        XCTAssertEqual(Set(bridge.closedHandles), [101, 202])
        XCTAssertTrue(enabledAfterSuspend)
        XCTAssertEqual(store.state?.phase, .active)
        XCTAssertEqual(
            Set([store.state?.active?.primary.privateKey, store.state?.active?.fallback.privateKey].compactMap { $0 }),
            keysBefore
        )
        let deletesAfterSleep = await catalog.deleteAccessTokens
        XCTAssertTrue(deletesAfterSleep.isEmpty)

        await supervisor.resume()
        let activeAfterWake = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeAfterWake)
        XCTAssertEqual(bridge.startCalls.count, startsBefore + 2)
        let restartedKeys = Set(bridge.startCalls.suffix(2).map(\.key.privateKey))
        XCTAssertEqual(restartedKeys, keysBefore)
        XCTAssertEqual(store.state?.phase, .active)
        let deletesAfterWake = await catalog.deleteAccessTokens
        XCTAssertTrue(deletesAfterWake.isEmpty)
        await supervisor.setEnabled(false)
    }

    private func makeSupervisor(
        bridge: FakeTailcatBridge,
        catalog: FakeTailcatCatalog,
        store: FakeTailcatStore,
        listener: FakeTailcatListener = FakeTailcatListener(),
        statusHandler: @escaping TailcatRuntimeSupervisor.StatusHandler = { _ in }
    ) -> TailcatRuntimeSupervisor {
        TailcatRuntimeSupervisor(
            serverID: "server-1",
            displayName: "Test Mac",
            bridge: bridge,
            catalog: catalog,
            secureStore: store,
            sessionProvider: { Self.session },
            authenticator: TailcatRemoteConnectionAuthenticator(),
            listener: listener,
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
