import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence

/// Regression guard for PERF-MAC_SHELL_WINDOW-002 (todo-QA/macos-app.md:102).
///
/// WHY: `MainWindowController.rebuildWorkspaceContainer` has two paths:
///   1. Signature unchanged + pane controllers non-empty -> reconcile in place (FAST).
///   2. Signature changed or controllers empty -> full teardown + rebuild (SLOW).
///
/// Path 2 is expensive: it calls `window.disableScreenUpdatesUntilFlush`,
/// tears down every subview, and reconstructs the full layout from scratch.
/// Spurious rebuilds on focus/key-window/app-activate events cause the
/// resize-end strip flash and jank described in PERF-MAC_SHELL_WINDOW-002.
///
/// `os.log` records the rebuild time but tests cannot query `os.log`.
/// The `rebuildCount` seam (internal `Int`, never read by production code)
/// makes the rebuild count observable so a T011-style regression test can
/// assert "no rebuild happened" when only non-structural state changed.
@MainActor
final class MainWindowControllerRebuildCountTests: XCTestCase {

    // Retain controllers so their @objc targets and AppKit windows are not
    // deallocated mid-test (matching the pattern in SplitLayoutRuntimeTests).
    private var retainedControllers: [MainWindowController] = []

    private func makeController(prefix: String) throws -> (AppContext, AppCommandRouter, MainWindowController) {
        let dir = NSTemporaryDirectory() + "RC2RebuildCount-\(prefix)-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let wc = MainWindowController(context: ctx, router: router)
        router.windowController = wc
        retainedControllers.append(wc)
        return (ctx, router, wc)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    override func tearDown() {
        // Close all surfaces and windows created during the test.
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        retainedControllers.removeAll()
        super.tearDown()
    }

    // MARK: - Seam correctness

    /// WHY: the counter must start at zero before any rebuild fires.  If the
    /// counter starts non-zero the seam itself is broken and no assertion about
    /// rebuild counts can be trusted.
    func test_rebuildCount_startsAtZero_beforeAnyRefresh() throws {
        let dir = NSTemporaryDirectory() + "RC2RebuildCount-zero-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        // Do NOT call refreshFromState; inspect the raw initial value.
        let wc = MainWindowController(context: ctx, router: router)
        retainedControllers.append(wc)
        // The init queues a refresh but has not drained yet.
        XCTAssertEqual(wc.rebuildCount, 0,
            "rebuildCount must be zero immediately after construction, before the queued " +
            "async refreshFromState flush fires; if non-zero the seam increments in the wrong place")
    }

    /// WHY: after the first refreshFromState drains, a rebuild must have fired
    /// (initial state: no workspace, so an empty-state view is built).
    /// If the count stays at zero the seam does not instrument the full-rebuild path.
    func test_rebuildCount_incrementsAfterFirstRefresh() throws {
        let (_, _, wc) = try makeController(prefix: "first")
        drainMainQueue()  // flush the queued refreshFromState from init

        XCTAssertGreaterThanOrEqual(wc.rebuildCount, 1,
            "after the first refreshFromState drains, rebuildCount must be >= 1 because " +
            "the initial no-workspace empty state is a full rebuild (pane controllers are " +
            "empty so the early-return guard never fires); if zero the seam misses the rebuild path")
    }

    // MARK: - Signature-based coalescing

    /// WHY: the structural-signature check (PERF-MAC_SHELL_WINDOW-002) must
    /// prevent redundant rebuilds when the layout has not changed.  A second
    /// `refreshFromState` with the same workspace/layout must NOT increment
    /// `rebuildCount` -- it must reconcile in place instead.
    ///
    /// Without this guard, app-become-key / app-activate events (which fire
    /// `refreshFromState`) would repeatedly tear down and rebuild the pane
    /// layout even when nothing changed, causing the resize-end strip flash.
    func test_rebuildCount_doesNotIncrement_whenSignatureIsUnchanged() throws {
        let (_, router, wc) = try makeController(prefix: "sig")
        _ = try router.createWorkspace(name: "stable", cwd: NSTemporaryDirectory())
        wc.refreshFromState()
        drainMainQueue()

        let countAfterFirst = wc.rebuildCount

        // Second refresh with identical state -- signature must match.
        wc.refreshFromState()
        drainMainQueue()

        XCTAssertEqual(wc.rebuildCount, countAfterFirst,
            "a refreshFromState call with an unchanged layout signature must NOT increment " +
            "rebuildCount -- the reconcile-in-place fast path must be taken instead. " +
            "If this fails, app-become-key events will spuriously rebuild the pane layout, " +
            "causing the resize-end strip flash (PERF-MAC_SHELL_WINDOW-002).")
    }

    /// WHY: when the selected workspace changes (a structural signature change),
    /// a full rebuild IS required.  The counter must increment so we know
    /// the branch was taken and pane controllers were re-created for the new
    /// workspace layout.
    func test_rebuildCount_increments_whenSelectedWorkspaceChanges() throws {
        let (_, router, wc) = try makeController(prefix: "wschange")
        let first = try router.createWorkspace(name: "first", cwd: NSTemporaryDirectory())
        let second = try router.createWorkspace(name: "second", cwd: NSTemporaryDirectory())
        wc.refreshFromState()
        drainMainQueue()

        // Select 'second' to change the structural signature.
        try router.selectWorkspace(second.id)
        wc.refreshFromState()
        drainMainQueue()
        let countAfterSecond = wc.rebuildCount

        // Select 'first' -- another structural change.
        try router.selectWorkspace(first.id)
        wc.refreshFromState()
        drainMainQueue()

        XCTAssertGreaterThan(wc.rebuildCount, countAfterSecond,
            "selecting a different workspace changes the structural signature and must trigger " +
            "a full rebuild (rebuildCount must increment) so the pane layout reflects the new " +
            "workspace; if it does not increment the new workspace layout is never built")
    }

    // MARK: - Non-structural changes do not rebuild

    /// WHY: renaming a workspace changes its title but not its layout signature
    /// (the signature covers workspace-id + pane-id set + surface-id set, not title).
    /// A title-only change must NOT rebuild the pane controllers -- rebuilding for
    /// cosmetic changes causes the flicker and jank described in PERF-MAC_SHELL_WINDOW-002.
    func test_rebuildCount_doesNotIncrement_forWorkspaceRenameOnly() throws {
        let (_, router, wc) = try makeController(prefix: "rename")
        let ws = try router.createWorkspace(name: "original", cwd: NSTemporaryDirectory())
        wc.refreshFromState()
        drainMainQueue()

        let countBefore = wc.rebuildCount

        try router.renameWorkspace(ws.id, "renamed")
        wc.refreshFromState()
        drainMainQueue()

        XCTAssertEqual(wc.rebuildCount, countBefore,
            "renaming a workspace (title-only change) must NOT increment rebuildCount -- " +
            "the structural signature does not cover workspace names so the reconcile-in-place " +
            "path must be taken; a rebuild here would cause the pane-header flash reported as " +
            "the resize-end jank in PERF-MAC_SHELL_WINDOW-002")
    }
}
