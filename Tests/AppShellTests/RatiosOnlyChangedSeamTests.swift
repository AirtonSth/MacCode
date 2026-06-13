import XCTest
@testable import Surfaces
import AppKit
@testable import AppShell
@testable import CoreModel

// MARK: - PERF-MAC_SHELL_WINDOW-MED-126 seam tests
//
// WHY: When a divider is released (mouse-up), onRatiosChanged fires and calls
// paneResize, which calls refreshFromState. Before this fix, ratios were part
// of the structural signature, so every resize-end triggered a full container
// teardown + rebuild — re-parenting live terminal surfaces (flash + jank).
//
// The fix has two parts:
//   1. ratiosOnlyChanged(old:new:) — pure seam detecting ratio-only diffs.
//   2. Structural signature excludes ratios; applyRatiosInPlace is called when
//      signature matches but ratios differ.
//
// These tests guard both seam correctness and the rebuild-count contract.
@MainActor
final class RatiosOnlyChangedSeamTests: XCTestCase {

    // MARK: - ratiosOnlyChanged pure seam

    /// WHY: the seam must return true when two layout trees are identical
    /// except for split ratios — this is the only case where an in-place
    /// apply is safe. If false positives occur the in-place path is skipped
    /// and a full rebuild fires (regression to the original jank).
    func test_ratiosOnlyChanged_singlePane_sameID_returnsTrue() {
        let pane = PaneNode(id: PaneID())
        let old = LayoutNode.pane(pane)
        let new = LayoutNode.pane(pane)
        XCTAssertTrue(
            MainWindowController.ratiosOnlyChanged(old: old, new: new),
            "identical pane nodes must return true — no structural or ratio change means " +
            "the in-place path is safe and a full rebuild would be wasted work")
    }

    /// WHY: the seam must return false when pane ids differ — a pane was
    /// added, removed, or swapped. Returning true here would skip a rebuild
    /// that is genuinely required, leaving the container stale.
    func test_ratiosOnlyChanged_singlePane_differentID_returnsFalse() {
        let p1 = PaneNode(id: PaneID())
        let p2 = PaneNode(id: PaneID())
        XCTAssertFalse(
            MainWindowController.ratiosOnlyChanged(old: .pane(p1), new: .pane(p2)),
            "pane nodes with different ids must return false — the pane set changed " +
            "and a full rebuild is required to create the correct pane controllers")
    }

    /// WHY: the seam must return true when a split tree is structurally
    /// identical but ratios changed. This is the hot path: divider drag-end
    /// fires this; returning false causes a full rebuild (flash).
    func test_ratiosOnlyChanged_splitWithDifferentRatios_returnsTrue() {
        let pane = PaneNode(id: PaneID())
        let splitID = UUID()
        let old = LayoutNode.split(SplitNode(
            id: splitID, orientation: .horizontal,
            children: [.pane(pane), .pane(pane)], ratios: [0.5, 0.5]))
        let new = LayoutNode.split(SplitNode(
            id: splitID, orientation: .horizontal,
            children: [.pane(pane), .pane(pane)], ratios: [0.3, 0.7]))
        XCTAssertTrue(
            MainWindowController.ratiosOnlyChanged(old: old, new: new),
            "split nodes with identical structure but different ratios must return true " +
            "so the in-place ratio apply path is taken instead of a full rebuild; " +
            "a full rebuild here re-parents live terminal views causing a visible flash")
    }

    /// WHY: the seam must return false when a child pane id changes inside a
    /// split, even if the split node id and ratios are identical. The structural
    /// change requires a rebuild to wire the correct pane controller.
    func test_ratiosOnlyChanged_splitWithDifferentChildPaneID_returnsFalse() {
        let splitID = UUID()
        let p1 = PaneNode(id: PaneID())
        let p2 = PaneNode(id: PaneID())
        let old = LayoutNode.split(SplitNode(
            id: splitID, orientation: .horizontal,
            children: [.pane(p1), .pane(p1)], ratios: [0.5, 0.5]))
        let new = LayoutNode.split(SplitNode(
            id: splitID, orientation: .horizontal,
            children: [.pane(p1), .pane(p2)], ratios: [0.5, 0.5]))
        XCTAssertFalse(
            MainWindowController.ratiosOnlyChanged(old: old, new: new),
            "a split whose child pane ids differ must return false even when ratios match — " +
            "the pane set changed and the in-place path would leave a stale pane controller")
    }

    /// WHY: the seam must return false when a split orientation changes. The
    /// child views must be rebuilt with the correct isVertical flag.
    func test_ratiosOnlyChanged_splitOrientationChanged_returnsFalse() {
        let pane = PaneNode(id: PaneID())
        let splitID = UUID()
        let old = LayoutNode.split(SplitNode(
            id: splitID, orientation: .horizontal,
            children: [.pane(pane), .pane(pane)], ratios: [0.5, 0.5]))
        let new = LayoutNode.split(SplitNode(
            id: splitID, orientation: .vertical,
            children: [.pane(pane), .pane(pane)], ratios: [0.5, 0.5]))
        XCTAssertFalse(
            MainWindowController.ratiosOnlyChanged(old: old, new: new),
            "a split whose orientation changed must return false — the RatioSplitView " +
            "isVertical flag is set at build time and cannot be patched in place")
    }

    // MARK: - Rebuild count contract

    private var retainedControllers: [MainWindowController] = []

    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        retainedControllers.removeAll()
        super.tearDown()
    }

    private func makeController(prefix: String) throws -> (AppContext, AppCommandRouter, MainWindowController) {
        let dir = NSTemporaryDirectory() + "RC2RatiosOnly-\(prefix)-\(UUID().uuidString)"
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

    /// WHY: after a paneResize (ratio-only change), rebuildCount must NOT
    /// increment — ratios are excluded from the structural signature so the
    /// reconcile-in-place path is taken. A rebuild here re-parents live
    /// terminal surfaces, causing a visible flash on every divider release.
    func test_rebuildCount_doesNotIncrement_onPaneResizeRatioOnlyChange() throws {
        let (_, router, wc) = try makeController(prefix: "resize")
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        let ctx = wc.context!
        let paneID = ctx.state.workspaces[ws.id]!.layout.paneIDs().first!
        try router.splitPane(workspace: ws.id, paneID: paneID, direction: .right,
                             surfaceType: .terminal, title: "b")

        wc.refreshFromState()
        drainMainQueue()
        let countAfterBuild = wc.rebuildCount

        // Simulate a ratio-only change (divider mouse-up).
        guard case .split(let split) = ctx.state.workspaces[ws.id]?.layout else {
            return XCTFail("expected split layout after splitPane")
        }
        try router.paneResize(workspace: ws.id, splitID: split.id, ratios: [0.3, 0.7])
        drainMainQueue()

        XCTAssertEqual(wc.rebuildCount, countAfterBuild,
            "paneResize (ratio-only change) must NOT increment rebuildCount — ratios are " +
            "excluded from the structural signature so applyRatiosInPlace handles this; " +
            "a rebuild here re-parents live terminal surfaces causing the divider-release flash " +
            "(PERF-MAC_SHELL_WINDOW-MED-126)")
    }
}
