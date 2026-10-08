import Foundation
import SocketServer
import XCTest
@testable import AppShell

/// WHY: sleep and wake serialize their supervisor calls on one task chain.
/// A Tailcat setting change that leaves that chain lets a parked `suspend()`
/// run after a newer `resume()`. `suspend()` never restarts anything, so the
/// Mac then stays enabled with no polling loop and no runtime (unreachable
/// from anywhere) until the next sleep/wake, toggle or relaunch.
@MainActor
final class TailcatSettingTaskChainTests: XCTestCase {
    func testSuspendParkedBehindSlowWakeCannotRunAfterTheNextWake() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let (delegate, supervisor, catalog, bridge, statuses) =
            (fixture.delegate, fixture.supervisor, fixture.catalog, fixture.bridge, fixture.statuses)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let activeBefore = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBefore, "fixture: the runtime must be up before the sleep/wake sequence")
        XCTAssertEqual(bridge.startCalls.count, 2)
        let keysBefore = Set(bridge.startCalls.map(\.key.privateKey))

        // Wake 1 stays inside resume() until the catalog answers.
        await catalog.holdNextHostCall()
        _ = delegate.perform(NSSelectorFromString("workspaceDidWake"))
        let wakeHeld = await waitUntil { await catalog.isHoldingHost }
        XCTAssertTrue(wakeHeld, "fixture: wake 1 must be held inside its reconcile")

        // Sleep parks its suspend behind wake 1.
        _ = delegate.perform(NSSelectorFromString("workspaceWillSleep"))

        // Wake 2: the Direct HTTP restart re-applies the setting, then the
        // wake task resumes.
        let checkingBefore = statuses.values.filter { $0 == .checking }.count
        delegate.tailcatAccessSettingAuthority.apply(true)
        _ = delegate.perform(NSSelectorFromString("workspaceDidWake"))

        // Settle: off the chain, setEnabled(true) and resume() run right now,
        // while wake 1 is still held. Let them finish so the release below
        // cannot reorder them against the parked suspend. On the chain both
        // are parked and this wait just runs out.
        _ = await waitUntil(timeout: 0.5) {
            statuses.values.filter { $0 == .checking }.count >= checkingBefore + 2
        }

        await catalog.releaseHostCall()
        let suspendRan = await waitUntil { bridge.closedHandles.count == 2 }
        XCTAssertTrue(suspendRan, "fixture: the parked suspend must have stopped the runtime")
        _ = await waitUntil {
            let active = await supervisor.hasActiveRuntimeForTesting
            return active && bridge.startCalls.count == 4
        }

        let activeAfter = await supervisor.hasActiveRuntimeForTesting
        let enabledAfter = await supervisor.isEnabled
        XCTAssertTrue(activeAfter, "the last wake must leave the runtime running: a stale suspend may not run after it")
        XCTAssertTrue(enabledAfter)
        XCTAssertEqual(bridge.startCalls.count, 4, "the wake after the parked suspend must restart both relays")
        XCTAssertEqual(
            Set(bridge.startCalls.suffix(2).map(\.key.privateKey)),
            keysBefore,
            "sleep/wake must restart with the same identity keys"
        )
        let deletes = await catalog.deleteAccessTokens
        XCTAssertTrue(deletes.isEmpty, "sleep/wake must not delete the published host")
        await supervisor.setEnabled(false)
    }

    /// Guard for the strict FIFO order: an off toggle waits for the tasks
    /// before it, so an older queued enable cannot run after it and turn
    /// Tailcat back on against the user's choice. Accepted limit: an off
    /// toggle made during a wake reconcile applies only when that task ends
    /// (catalog timeout 12 s plus relay start up to 30 s).
    func testOffToggleQueuedBehindOlderEnableIsTheFinalState() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let (delegate, supervisor, catalog, bridge, statuses) =
            (fixture.delegate, fixture.supervisor, fixture.catalog, fixture.bridge, fixture.statuses)

        await supervisor.setEnabled(true)
        await supervisor.reconcileNowForTesting()
        let activeBefore = await supervisor.hasActiveRuntimeForTesting
        XCTAssertTrue(activeBefore, "fixture: the runtime must be up before the toggle")

        await catalog.holdNextHostCall()
        _ = delegate.perform(NSSelectorFromString("workspaceDidWake"))
        let wakeHeld = await waitUntil { await catalog.isHoldingHost }
        XCTAssertTrue(wakeHeld, "fixture: the wake must be held inside its reconcile")

        // The Direct HTTP restart queues an enable, then the user turns
        // Tailcat off (Settings persists the choice before applying it).
        delegate.tailcatAccessSettingAuthority.apply(true)
        try fixture.context.settingsRepo.set("tailcat_access_enabled", "0")
        delegate.tailcatAccessSettingAuthority.apply(false)

        await catalog.releaseHostCall()
        _ = await waitUntil { statuses.values.last == .off && bridge.closedHandles.count == 2 }

        let enabledAfter = await supervisor.isEnabled
        let activeAfter = await supervisor.hasActiveRuntimeForTesting
        XCTAssertFalse(enabledAfter, "the user's off must be the final state")
        XCTAssertFalse(activeAfter)
        XCTAssertEqual(statuses.values.last, .off)
        let deletes = await catalog.deleteAccessTokens
        XCTAssertEqual(deletes, ["access-token"], "turning Tailcat off must delete the published host exactly once")
    }

    private struct Fixture {
        let directory: String
        let context: AppContext
        let delegate: AppDelegate
        let supervisor: TailcatRuntimeSupervisor
        let catalog: FakeTailcatCatalog
        let bridge: FakeTailcatBridge
        let statuses: FakeTailcatStatuses
    }

    private func makeFixture() throws -> Fixture {
        let directory = NSTemporaryDirectory() + "RCTailcatSettingChain-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let catalog = FakeTailcatCatalog(snapshot: makeSnapshot())
        let bridge = FakeTailcatBridge()
        let statuses = FakeTailcatStatuses()
        let session = Self.session
        let supervisor = TailcatRuntimeSupervisor(
            serverID: "server-1",
            displayName: "Test Mac",
            bridge: bridge,
            catalog: catalog,
            secureStore: FakeTailcatStore(),
            sessionProvider: { session },
            authenticator: TailcatRemoteConnectionAuthenticator(),
            listener: FakeTailcatListener(),
            now: { Date(timeIntervalSince1970: 1_000) },
            automaticPolling: false,
            statusHandler: { statuses.append($0) }
        )
        let delegate = AppDelegate(channel: .debug, appSupportOverride: directory)
        delegate.context = context
        delegate.tailcatSupervisor = supervisor
        let router = AppCommandRouter(context: context)
        context.router = router
        // Never started: it only makes the setting path see a ready listener.
        delegate.httpServer = DirectHTTPServer(
            port: 0,
            loopbackOnly: true,
            dispatcher: JSONRPCDispatcher(router: router),
            bootEpoch: 1
        )
        return Fixture(
            directory: directory,
            context: context,
            delegate: delegate,
            supervisor: supervisor,
            catalog: catalog,
            bridge: bridge,
            statuses: statuses
        )
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
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

    private func makeSnapshot() -> TailcatAllowlistSnapshot {
        TailcatAllowlistSnapshot(
            epoch: "epoch-setting-chain",
            revision: 1,
            clients: [
                TailcatCatalogClient(
                    clientId: "client-0",
                    displayName: "Client 0",
                    nodePublic: "nodekey:" + String(repeating: "c2", count: 32),
                    transportBuildId: TailcatTransportContract.buildID,
                    createdAt: "2026-08-30T00:00:00Z",
                    updatedAt: "2026-08-30T00:00:00Z",
                    leaseExpiresAt: "2026-09-06T00:00:00Z",
                    version: 1
                ),
            ]
        )
    }
}
