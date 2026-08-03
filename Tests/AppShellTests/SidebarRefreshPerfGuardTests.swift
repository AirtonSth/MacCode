import XCTest
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
}
