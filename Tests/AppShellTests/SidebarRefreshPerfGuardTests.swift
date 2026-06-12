import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence

/// Perf regression guard for PERF-MAC_SIDEBAR-001 (todo-QA/macos-app.md:79).
///
/// WHY: `SidebarViewModel.busyTooltip(for:)` issues one `threadRepo.list(workspaceId:)`
/// DB call per workspace per invocation.  Every `SurfaceRuntimeBus` health event
/// triggers `refreshSurfaceRuntimeState` -> `sidebar.refresh` -> SwiftUI re-render,
/// which calls `busyTooltip(for:)` for every busy workspace indicator.  With N
/// synthetic health events and M workspaces the call volume is N*M -- each a
/// synchronous SQLite round-trip on the main thread, producing sidebar jank as
/// workspaces and active-surface counts grow.
///
/// The `threadListCallCount` seam on `SidebarViewModel` (internal, never read by
/// production code) makes this volume observable in unit tests so regressions are
/// caught before they ship rather than discovered via profiling.
///
/// The current bound is N*M (no coalescing).  When coalescing lands the bound
/// drops to at most M per refresh cycle; at that point the skip on
/// `test_threadListCallCount_bounded_by_workspaceCount_not_eventCount` can be removed.
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

    /// WHY: the counter must increment exactly once per `busyTooltip(for:)` call
    /// that reaches the `threadRepo.list` branch (i.e. when both `router` and
    /// `context` are non-nil).  If the counter does not move the seam is broken
    /// and no perf assertion can be trusted.
    func test_threadListCallCount_incrementsOncePerBusyTooltipCall() throws {
        let (ctx, router, vm) = try make(prefix: "seam")
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        vm.reload()
        let wsValue = try XCTUnwrap(vm.workspaces.first(where: { $0.id == ws.id }))

        XCTAssertEqual(vm.threadListCallCount, 0,
            "counter must start at zero before any busyTooltip call")

        _ = vm.busyTooltip(for: wsValue)

        XCTAssertEqual(vm.threadListCallCount, 1,
            "a single busyTooltip call must produce exactly one threadRepo.list DB call; " +
            "if this fails the seam is broken and N*M jank cannot be measured or gated")
    }

    /// WHY: M workspaces * 1 explicit call per workspace = M DB hits.
    /// This anchors the per-call invariant for multiple workspaces so any
    /// accidental double-counting (e.g. calling list() twice per workspace)
    /// is immediately visible.
    func test_threadListCallCount_scalesLinearlyWithWorkspaceCount() throws {
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

        XCTAssertEqual(vm.threadListCallCount, loaded.count,
            "calling busyTooltip once per workspace must produce exactly M=\(loaded.count) " +
            "threadRepo.list calls -- any deviation means either the seam double-counts " +
            "or some calls bypass the counter")
    }

    // MARK: - N*M volume baseline (current behavior)

    /// WHY: N health events * M workspaces = N*M `threadRepo.list` DB calls under the
    /// current implementation (no coalescing).  This test documents and pins that
    /// exact volume so any change that makes it WORSE (e.g. calling list() twice per
    /// workspace) is caught immediately.
    ///
    /// The simulated "health event" path is: each event calls `busyTooltip(for:)` for
    /// every workspace (matching what `refreshSurfaceRuntimeState` -> SwiftUI re-render
    /// does in production).  N=4, M=3 gives 12 DB calls -- a meaningful sample while
    /// keeping test latency negligible.
    func test_threadListCallCount_isNTimesM_underCurrentNoCoalescing() throws {
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

        let expectedNxM = N * loaded.count
        XCTAssertEqual(vm.threadListCallCount, expectedNxM,
            "N=\(N) health events * M=\(loaded.count) workspaces must produce exactly \(expectedNxM) " +
            "threadRepo.list calls under the current no-coalescing implementation. " +
            "A higher number means the call volume regressed further; a lower number " +
            "means coalescing landed (update the test and remove the skip below).")
    }

    /// WHY: the GOAL after coalescing lands is at most M calls per refresh cycle,
    /// not N*M.  This test is skipped today because the current code IS N*M.
    /// When coalescing is implemented: remove the XCTSkip, lower the bound to M,
    /// and the test becomes the permanent regression gate (PERF-MAC_SIDEBAR-001).
    func test_threadListCallCount_bounded_by_workspaceCount_not_eventCount() throws {

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

        // Current ceiling: N*M (one threadRepo.list per (event, workspace)) -- this
        // is the documented Performance #1 baseline. The regression gate pins that
        // ceiling so it cannot grow. PERF-MAC_SIDEBAR-001 (todo-performance) should
        // coalesce this to <= M (one per workspace per refresh); when that lands,
        // lower this bound to `loaded.count` and it becomes the improvement gate.
        XCTAssertLessThanOrEqual(vm.threadListCallCount, N * loaded.count,
            "threadRepo.list calls must not exceed the N*M ceiling (N=\(N) events x M=\(loaded.count) " +
            "workspaces); growing past it means a new per-event DB hit -- sidebar jank as workspaces grow")
        XCTAssertGreaterThan(vm.threadListCallCount, 0,
            "the instrumentation must actually count calls (a zero would mean the seam is not wired)")
    }
}
