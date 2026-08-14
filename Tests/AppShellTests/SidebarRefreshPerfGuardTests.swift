import XCTest
import Combine
@testable import AppShell
@testable import CoreModel
import Persistence

/// Perf regression guard for PERF-MAC_SIDEBAR-001 (todo-QA/macos-app.md:79).
///
/// WHY: busy tooltip rendering happens during frequent runtime updates. It must
/// stay entirely in-memory so those updates never turn into synchronous SQLite
/// work on the main actor.
@MainActor
final class SidebarRefreshPerfGuardTests: XCTestCase {

    // MARK: - Helpers

    private func make(prefix: String) throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let dir = NSTemporaryDirectory() + "RC2SidebarPerf-\(prefix)-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)
        return (ctx, router, vm)
    }

    // MARK: - Seam correctness

    /// WHY: a tooltip call must not perform a durable thread read.
    func test_busyTooltip_doesNotReadSQLite() throws {
        let (_, router, vm) = try make(prefix: "seam")
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        vm.reload()
        let wsValue = try XCTUnwrap(vm.workspaces.first(where: { $0.id == ws.id }))

        _ = vm.busyTooltip(for: wsValue)

        XCTAssertEqual(vm.threadListCallCount, 0,
            "busyTooltip must not synchronously query SQLite")
    }

    /// WHY: repeated tooltip rendering must remain read-free regardless of the
    /// number of workspaces.
    func test_busyTooltip_remainsReadFreeAcrossWorkspaces() throws {
        let M = 5
        let (_, router, vm) = try make(prefix: "linear")
        for i in 0..<M {
            _ = try router.createWorkspace(name: "ws\(i)", cwd: NSTemporaryDirectory())
        }
        vm.reload()
        let loaded = vm.workspaces

        for ws in loaded {
            _ = vm.busyTooltip(for: ws)
        }

        XCTAssertEqual(vm.threadListCallCount, 0,
            "busyTooltip must not issue one SQLite read per workspace")
    }

    func test_busyTooltip_remainsReadFreeAcrossRefreshes() throws {
        let N = 4  // synthetic health events
        let M = 3  // workspaces
        let (_, router, vm) = try make(prefix: "NxM")

        for i in 0..<M {
            _ = try router.createWorkspace(name: "ws\(i)", cwd: NSTemporaryDirectory())
        }
        vm.reload()
        let loaded = vm.workspaces
        XCTAssertEqual(loaded.count, M,
            "must have exactly M=\(M) workspaces for the N*M calculation to be meaningful")

        // Simulate N health event refresh cycles, each visiting every workspace.
        for _ in 0..<N {
            for ws in loaded {
                _ = vm.busyTooltip(for: ws)
            }
        }

        XCTAssertEqual(vm.threadListCallCount, 0,
            "repeated runtime refreshes must not add synchronous SQLite reads")
    }

    func test_busyTooltip_hasNoSynchronousDatabaseCeiling() throws {

        let N = 4
        let M = 3
        let (_, router, vm) = try make(prefix: "coalesced")

        for i in 0..<M {
            _ = try router.createWorkspace(name: "ws\(i)", cwd: NSTemporaryDirectory())
        }
        vm.reload()
        let loaded = vm.workspaces

        for _ in 0..<N {
            for ws in loaded {
                _ = vm.busyTooltip(for: ws)
            }
        }

        XCTAssertEqual(vm.threadListCallCount, 0,
            "busyTooltip must remain read-free after repeated runtime refreshes")
    }

    // MARK: - PERF-MAC_SIDEBAR-002 no-op reload

    /// WHY: `sidebar.refresh()` runs on every coalesced refreshFromState and
    /// busy projection. The account blob is peeked so save+reload stays
    /// synchronous, but an unchanged blob must not JSONDecoder or assign
    /// `@Published` (that rebuilt the always-on sidebar).
    func test_reload_doesNotRedecodeUnchangedPrivateAccount() throws {
        let (_, _, vm) = try make(prefix: "account-hot")
        let afterInit = vm.privateAccountLoadCount
        XCTAssertGreaterThan(afterInit, 0, "init must materialize the account once")

        vm.reload()
        vm.reload()

        XCTAssertEqual(
            vm.privateAccountLoadCount,
            afterInit,
            "unchanged account JSON must not be decoded again on workspace reload"
        )
    }

    /// WHY: a true account change still has to paint (Token Saver footer,
    /// subscribe CTA). The `.rc2PrivateAccountChanged` observer is the only
    /// intended reread path after init.
    func test_privateAccountNotification_stillReloadsUser() async throws {
        let (ctx, _, vm) = try make(prefix: "account-note")
        XCTAssertNil(vm.privateAccountUser)
        let loadsBefore = vm.privateAccountLoadCount

        PrivateAccountSessionStore(repo: ctx.settingsRepo).save(
            PrivateAccountSession(
                accessToken: "access",
                refreshToken: "refresh",
                user: PrivateAccountUser(
                    daysRemaing: nil,
                    daysRemaining: 30,
                    email: "paid@example.com",
                    id: "paid",
                    subscribed: true
                )
            )
        )

        let deadline = Date().addingTimeInterval(1.0)
        while vm.privateAccountUser == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(vm.privateAccountUser?.id, "paid")
        XCTAssertGreaterThan(
            vm.privateAccountLoadCount,
            loadsBefore,
            "account notification must still decode the new session"
        )
    }

    /// WHY: a no-op refresh (same workspaces, selection, busy, account) must
    /// not fire objectWillChange. `@Published` assignment always publishes,
    /// so even an equal Set/optional rewrite rebuilt the sidebar body.
    func test_reload_doesNotPublishWhenSnapshotUnchanged() throws {
        let (_, router, vm) = try make(prefix: "noop-publish")
        _ = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        vm.reload()

        var publishes = 0
        let sub = vm.objectWillChange.sink { publishes += 1 }
        vm.reload()
        vm.reload()
        _ = sub

        XCTAssertEqual(
            publishes,
            0,
            "unchanged reload must not invalidate the sidebar SwiftUI tree"
        )
    }
}
