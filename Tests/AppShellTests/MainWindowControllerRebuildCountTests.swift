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

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func makeDescriptor(_ index: Int) -> SurfaceDescriptor {
        SurfaceDescriptor(
            type: .browser,
            title: "wide-tab-\(index)",
            iconName: "browser",
            metadata: ["test": "wide-layout"]
        )
    }

    private func surfaceCount(in node: LayoutNode) -> Int {
        switch node {
        case .pane(let pane):
            return pane.surfaces.count
        case .split(let split):
            return split.children.reduce(0) { $0 + surfaceCount(in: $1) }
        }
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

    // MARK: - PERF-MAC_SHELL_WINDOW-125: focus/tab-select does not rebuild

    /// WHY: selecting a tab (focusSurface) changes only selectedSurfaceID and
    /// focusedPaneID in the layout -- the structural signature (pane id set,
    /// surface id set, order) is unchanged. applyFocusChangeInPlace must be
    /// taken instead of refreshFromState, so rebuildCount must NOT increment.
    /// If it increments, every tab click tears down the container (hundreds of
    /// allocations per click, jank visible on tab strip).
    func test_rebuildCount_doesNotIncrement_forFocusSurface() throws {
        let (ctx, router, wc) = try makeController(prefix: "focusSurface")
        let ws = try router.createWorkspace(name: "ws", cwd: NSTemporaryDirectory())
        // Add a second surface so we have something to switch between.
        let _ = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "Tab2")
        wc.refreshFromState()
        drainMainQueue()

        guard let wid = ctx.state.window.selectedWorkspaceID,
              let freshWS = ctx.state.workspaces[wid],
              let firstSurfaceID = freshWS.layout.find(paneID: freshWS.layout.paneIDs()[0])?.surfaces.first?.id,
              let secondSurfaceID = freshWS.layout.find(paneID: freshWS.layout.paneIDs()[0])?.surfaces.last?.id,
              firstSurfaceID != secondSurfaceID else {
            XCTFail("Expected workspace with two surfaces in the same pane")
            return
        }

        // Select first surface to ensure a known selected state.
        try router.focusSurface(workspace: wid, surface: firstSurfaceID)
        drainMainQueue()
        let countBefore = wc.rebuildCount

        // Select second surface -- focus-only change, structural signature unchanged.
        try router.focusSurface(workspace: wid, surface: secondSurfaceID)
        drainMainQueue()

        XCTAssertEqual(wc.rebuildCount, countBefore,
            "focusSurface (tab selection) must NOT increment rebuildCount: selecting a tab " +
            "changes only selectedSurfaceID, not the structural signature. " +
            "applyFocusChangeInPlace must reconcile in place (PERF-MAC_SHELL_WINDOW-125). " +
            "If this fails, every tab click performs a full container teardown/rebuild.")
    }

    /// WHY: the same fast path that prevents a full rebuild must still replace
    /// the visible content view. Otherwise a clicked tab looks selected while
    /// the pane keeps rendering the old tab's surface.
    func test_focusSurfaceUpdatesVisibleContentWithoutFullRebuild() throws {
        let (ctx, router, wc) = try makeController(prefix: "focusSurfaceContent")
        let ws = try router.createWorkspace(name: "ws-content", cwd: NSTemporaryDirectory())
        let _ = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "Tab2")
        wc.refreshFromState()
        drainMainQueue()

        guard let wid = ctx.state.window.selectedWorkspaceID,
              let freshWS = ctx.state.workspaces[wid],
              let pane = freshWS.layout.find(paneID: freshWS.layout.paneIDs()[0]),
              let firstSurfaceID = pane.surfaces.first?.id,
              let secondSurfaceID = pane.surfaces.last?.id,
              firstSurfaceID != secondSurfaceID,
              let firstView = SurfaceRegistry.shared.surface(firstSurfaceID)?.view,
              let secondView = SurfaceRegistry.shared.surface(secondSurfaceID)?.view,
              let contentView = wc.window.contentView else {
            XCTFail("Expected workspace with two registered surfaces in the same pane")
            return
        }

        try router.focusSurface(workspace: wid, surface: firstSurfaceID)
        drainMainQueue()
        XCTAssertTrue(allSubviews(of: contentView).contains { $0 === firstView },
                      "known starting point: the first selected tab's surface is mounted before switching")
        let countBefore = wc.rebuildCount

        try router.focusSurface(workspace: wid, surface: secondSurfaceID)
        drainMainQueue()
        let liveSubviews = allSubviews(of: contentView)

        XCTAssertEqual(wc.rebuildCount, countBefore,
                       "tab selection must stay on the in-place reconcile path, not hide the bug behind a full rebuild")
        XCTAssertFalse(liveSubviews.contains { $0 === firstView },
                       "the previously selected tab's surface must be removed from the content area")
        XCTAssertTrue(liveSubviews.contains { $0 === secondView },
                      "the newly selected tab's surface must be mounted so selected chrome and visible content match")
    }

    /// WHY: clicking a pane to focus it (focusPane) changes only focusedPaneID --
    /// the structural signature is unchanged. applyFocusChangeInPlace must be
    /// taken; rebuildCount must NOT increment.
    /// If it increments, every pane focus click (e.g. clicking into a terminal
    /// after working in a browser pane) causes a full container rebuild.
    func test_rebuildCount_doesNotIncrement_forFocusPane() throws {
        let (ctx, router, wc) = try makeController(prefix: "focusPane")
        let ws = try router.createWorkspace(name: "ws2", cwd: NSTemporaryDirectory())
        // Split to get two panes.
        guard let paneID = ctx.state.workspaces[ws.id]?.layout.paneIDs().first else {
            XCTFail("Expected at least one pane after createWorkspace")
            return
        }
        let _ = try router.splitPane(workspace: ws.id, paneID: paneID, direction: .right, surfaceType: .browser, title: "Split")
        wc.refreshFromState()
        drainMainQueue()

        guard let wid = ctx.state.window.selectedWorkspaceID,
              let freshWS = ctx.state.workspaces[wid] else {
            XCTFail("Workspace not found after split")
            return
        }
        let paneIDs = freshWS.layout.paneIDs()
        guard paneIDs.count >= 2 else {
            XCTFail("Expected two panes after split, got \(paneIDs.count)")
            return
        }

        // Focus pane 0 as baseline.
        try router.focusPane(workspace: wid, pane: paneIDs[0])
        drainMainQueue()
        let countBefore = wc.rebuildCount

        // Focus pane 1 -- pane-focus-only change, structural signature unchanged.
        try router.focusPane(workspace: wid, pane: paneIDs[1])
        drainMainQueue()

        XCTAssertEqual(wc.rebuildCount, countBefore,
            "focusPane (pane-focus click) must NOT increment rebuildCount: only focusedPaneID " +
            "changes, not the structural signature. applyFocusChangeInPlace must reconcile in " +
            "place (PERF-MAC_SHELL_WINDOW-125). If this fails, every pane-content click " +
            "performs a full container teardown/rebuild.")
    }

    /// WHY: structural changes (addSurface / closeSurface) alter the surface id
    /// set and MUST still trigger a full rebuild even after the focus-only fast
    /// path is in place. Verifies the seam boundary -- a close must increment.
    func test_rebuildCount_increments_forStructuralChange_afterFocusFastPath() throws {
        let (ctx, router, wc) = try makeController(prefix: "structural")
        let ws = try router.createWorkspace(name: "ws3", cwd: NSTemporaryDirectory())
        let tab2 = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "Tab2")
        wc.refreshFromState()
        drainMainQueue()

        guard let wid = ctx.state.window.selectedWorkspaceID,
              let freshWS = ctx.state.workspaces[wid],
              let firstSurfaceID = freshWS.layout.find(paneID: freshWS.layout.paneIDs()[0])?.surfaces.first?.id else {
            XCTFail("Setup failed")
            return
        }

        // Do a focus-only change first (exercises the fast path).
        try router.focusSurface(workspace: wid, surface: firstSurfaceID)
        drainMainQueue()
        let countAfterFocus = wc.rebuildCount

        // Now close a surface -- structural change; must rebuild.
        try router.closeSurface(workspace: wid, surface: tab2.id)
        drainMainQueue()

        XCTAssertGreaterThan(wc.rebuildCount, countAfterFocus,
            "closeSurface changes the structural signature (surface id set shrinks) and must " +
            "trigger a full rebuild (rebuildCount must increment) even when the focus fast path " +
            "is active. If this does not increment, the structural-change rebuild gate is broken.")
    }

    // MARK: - PERF #3/#4: wide layout rebuild budget

    func test_wideLayoutSixPanesFortyTabs_rebuildsWithinBudget() throws {
        let dir = NSTemporaryDirectory() + "RC2WideLayout-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router

        try ctx.apply(.createWorkspace(name: "wide", cwd: dir, initial: nil))
        let workspaceID = try XCTUnwrap(ctx.state.window.selectedWorkspaceID)
        try ctx.apply(.addSurface(workspaceID, paneID: nil, descriptor: makeDescriptor(0)))

        for index in 1..<6 {
            let targetPane = try XCTUnwrap(ctx.state.workspaces[workspaceID]?.layout.paneIDs().last)
            try ctx.apply(.splitPane(
                workspaceID,
                paneID: targetPane,
                direction: index.isMultiple(of: 2) ? .down : .right,
                newSurface: makeDescriptor(index)
            ))
        }

        let paneIDs = try XCTUnwrap(ctx.state.workspaces[workspaceID]?.layout.paneIDs())
        XCTAssertEqual(paneIDs.count, 6, "wide-layout benchmark fixture must have exactly 6 panes")
        for index in 6..<39 {
            try ctx.apply(.addSurface(workspaceID, paneID: paneIDs[index % paneIDs.count], descriptor: makeDescriptor(index)))
        }

        let wc = MainWindowController(context: ctx, router: router)
        router.windowController = wc
        retainedControllers.append(wc)
        wc.refreshFromState()
        drainMainQueue()
        let countBeforeMeasuredRebuild = wc.rebuildCount

        try ctx.apply(.addSurface(workspaceID, paneID: paneIDs[0], descriptor: makeDescriptor(39)))

        let start = DispatchTime.now()
        wc.refreshFromState()
        drainMainQueue()
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let budgetMs = 750.0
        let wideLayout = try XCTUnwrap(ctx.state.workspaces[workspaceID]?.layout)

        print("WideLayoutRebuildBenchmark panes=6 tabs=40 elapsedMs=\(Int(elapsedMs)) budgetMs=\(Int(budgetMs))")
        XCTAssertEqual(wideLayout.paneIDs().count, 6,
                       "wide-layout rebuild must preserve all 6 panes")
        XCTAssertEqual(surfaceCount(in: wideLayout), 40,
                       "wide-layout rebuild must preserve all 40 tabs")
        XCTAssertGreaterThan(wc.rebuildCount, countBeforeMeasuredRebuild,
                             "adding the 40th tab changes the structural signature and must trigger one full rebuild")
        XCTAssertLessThanOrEqual(elapsedMs, budgetMs,
                                 "6-pane/40-tab structural rebuild must stay under the CI budget to catch O(N) sync-RPC/DB regressions")
    }
}
