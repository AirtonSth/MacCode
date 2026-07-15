import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence

@MainActor
final class SplitLayoutRuntimeTests: XCTestCase {
    private static var retainedWindowControllers: [MainWindowController] = []

    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    private func findSplit(_ v: NSView) -> RatioSplitView? {
        if let s = v as? RatioSplitView { return s }
        for sub in v.subviews { if let f = findSplit(sub) { return f } }
        return nil
    }

    private func findRootSplit(_ v: NSView) -> NSSplitView? {
        if let s = v as? NSSplitView { return s }
        for sub in v.subviews { if let f = findRootSplit(sub) { return f } }
        return nil
    }

    private func findButton(_ v: NSView, toolTip: String) -> NSButton? {
        if let button = v as? NSButton, button.toolTip == toolTip { return button }
        for sub in v.subviews { if let f = findButton(sub, toolTip: toolTip) { return f } }
        return nil
    }

    private func rootSplit(in node: LayoutNode?) throws -> SplitNode {
        guard case .split(let split) = node else {
            throw LayoutError.paneNotFound
        }
        return split
    }

    private func makeWindowController() throws -> (AppContext, AppCommandRouter, MainWindowController) {
        let dir = NSTemporaryDirectory() + "RC2Split-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let wc = MainWindowController(context: ctx, router: router)
        router.windowController = wc
        Self.retainedWindowControllers.append(wc)
        return (ctx, router, wc)
    }

    private func createWorkspaceWithoutTerminal(
        in ctx: AppContext,
        windowController: MainWindowController,
        name: String = "w"
    ) throws -> Workspace {
        let descriptor = SurfaceDescriptor(type: .agentApp, title: "Agent App")
        try ctx.apply(.createWorkspace(name: name, cwd: NSTemporaryDirectory(), initial: descriptor))
        windowController.refreshFromState()
        guard let id = ctx.state.window.selectedWorkspaceID,
              let workspace = ctx.state.workspaces[id] else {
            throw LayoutError.workspaceNotFound
        }
        return workspace
    }

    private func drainMainQueue(seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func test_horizontalSplit_panesAreEqualWidthAtRuntime() throws {
        let (ctx, router, wc) = try makeWindowController()
        _ = ctx // keep AppContext alive (router.context is weak)
        defer { closeAndUnregisterAllSurfaces() }
        wc.window.setContentSize(NSSize(width: 1200, height: 800))

        let ws = try createWorkspaceWithoutTerminal(in: ctx, windowController: wc)
        let pid = ws.layout.paneIDs().first!
        _ = try router.splitPane(workspace: ws.id, paneID: pid,
                                 direction: .right, surfaceType: .agentApp, title: "Agent App")

        drainMainQueue()   // flush the coalesced refreshFromState before inspecting the view tree
        wc.window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(findSplit(wc.window.contentView!), "RatioSplitView must exist")
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.subviews.count, 2)
        let w0 = split.subviews[0].frame.width
        let w1 = split.subviews[1].frame.width
        XCTAssertGreaterThan(w0, 0)
        XCTAssertEqual(w0, w1, accuracy: 1.5, "side-by-side panes must each be 50% width")
    }

    func test_verticalSplit_panesAreEqualHeightAtRuntime() throws {
        let (ctx, router, wc) = try makeWindowController()
        _ = ctx // keep AppContext alive (router.context is weak)
        defer { closeAndUnregisterAllSurfaces() }
        wc.window.setContentSize(NSSize(width: 1200, height: 800))

        let ws = try createWorkspaceWithoutTerminal(in: ctx, windowController: wc)
        let pid = ws.layout.paneIDs().first!
        _ = try router.splitPane(workspace: ws.id, paneID: pid,
                                 direction: .down, surfaceType: .agentApp, title: "Agent App")

        drainMainQueue()   // flush the coalesced refreshFromState before inspecting the view tree
        wc.window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(findSplit(wc.window.contentView!))
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.subviews.count, 2)
        let h0 = split.subviews[0].frame.height
        let h1 = split.subviews[1].frame.height
        XCTAssertGreaterThan(h0, 0)
        XCTAssertEqual(h0, h1, accuracy: 1.5, "stacked panes must each be 50% height")
    }

    func test_minimizedStackedPaneRestoreButtonRestoresPaneAtRuntime() throws {
        let (ctx, router, wc) = try makeWindowController()
        _ = ctx // keep AppContext alive (router.context is weak)
        defer { closeAndUnregisterAllSurfaces() }
        wc.window.setContentSize(NSSize(width: 1200, height: 800))

        let ws = try createWorkspaceWithoutTerminal(in: ctx, windowController: wc)
        let pid = ws.layout.paneIDs().first!
        _ = try router.splitPane(workspace: ws.id, paneID: pid,
                                 direction: .down, surfaceType: .agentApp, title: "Agent App")

        drainMainQueue()
        let split = try rootSplit(in: ctx.state.workspaces[ws.id]?.layout)
        let rebuildsAfterSplit = wc.rebuildCount

        try router.paneResize(workspace: ws.id, splitID: split.id, ratios: [0.04, 0.96])

        drainMainQueue()
        wc.window.contentView?.layoutSubtreeIfNeeded()
        let minimizedSplit = try XCTUnwrap(findSplit(wc.window.contentView!))
        minimizedSplit.layoutSubtreeIfNeeded()
        XCTAssertEqual(minimizedSplit.subviews[0].frame.height, 35, accuracy: 1,
                       "minimizing a stacked pane must collapse it to the tab-row height")
        XCTAssertGreaterThan(wc.rebuildCount, rebuildsAfterSplit,
                             "crossing the minimized threshold must rebuild pane chrome so the restore control gets fresh ratios")

        let restore = try XCTUnwrap(findButton(wc.window.contentView!, toolTip: "Maximize pane"),
                                    "a minimized pane must expose a restore control")
        restore.performClick(nil)

        drainMainQueue()
        wc.window.contentView?.layoutSubtreeIfNeeded()
        let restored = try rootSplit(in: ctx.state.workspaces[ws.id]?.layout)
        XCTAssertEqual(restored.ratios[0], 0.5, accuracy: 0.0001,
                       "clicking the restore control must use the minimized ratios and restore an even split")
        XCTAssertEqual(restored.ratios[1], 0.5, accuracy: 0.0001)
        let restoredSplit = try XCTUnwrap(findSplit(wc.window.contentView!))
        restoredSplit.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(restoredSplit.subviews[0].frame.height, 300,
                             "the pane must be visibly expanded again after restore")
    }

    func test_sidebarDividerCanResizeWorkspaceList() throws {
        let (ctx, _, wc) = try makeWindowController()
        _ = ctx
        defer { closeAndUnregisterAllSurfaces() }
        wc.window.setContentSize(NSSize(width: 1200, height: 800))
        drainMainQueue()
        wc.window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(findRootSplit(wc.window.contentView!))

        split.setPosition(340, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()

        XCTAssertEqual(split.subviews.first?.frame.width ?? 0, 340, accuracy: 2,
                       "the workspace sidebar divider must be resizable; a fixed sidebar width makes the user drag do nothing")
    }

    func test_sidebarDefaultWidthMatchesDesignUntilUserResizes() throws {
        let (ctx, _, wc) = try makeWindowController()
        _ = ctx
        defer { closeAndUnregisterAllSurfaces() }
        wc.window.setContentSize(NSSize(width: 1200, height: 800))
        drainMainQueue()
        wc.window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(findRootSplit(wc.window.contentView!))

        XCTAssertEqual(split.subviews.first?.frame.width ?? 0, 444, accuracy: 2,
                       "fresh windows must use the product sidebar width instead of inheriting a transient oversized split width")
    }

    func test_sidebarUserWidthPersistsAcrossWindowRecreation() throws {
        let dir = NSTemporaryDirectory() + "RC2SplitPersist-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        defer {
            closeAndUnregisterAllSurfaces()
        }
        let first = MainWindowController(context: ctx, router: router)
        Self.retainedWindowControllers.append(first)
        first.window.setContentSize(NSSize(width: 1200, height: 800))
        drainMainQueue()
        first.window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(findRootSplit(first.window.contentView!))
        split.setPosition(360, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()
        drainMainQueue(seconds: 0.35)
        XCTAssertEqual(split.subviews.first?.frame.width ?? 0, 360, accuracy: 2,
                       "the first window must finish the user resize before persistence is evaluated")
        XCTAssertEqual(MainWindowController.storedSidebarWidth(context: ctx), 360, accuracy: 2,
                       "the debounced width must be durable before a replacement window reads it")

        let second = MainWindowController(context: ctx, router: router)
        Self.retainedWindowControllers.append(second)
        second.window.setContentSize(NSSize(width: 1200, height: 800))
        drainMainQueue()
        second.window.contentView?.layoutSubtreeIfNeeded()
        let restored = try XCTUnwrap(findRootSplit(second.window.contentView!))

        XCTAssertEqual(restored.subviews.first?.frame.width ?? 0, 360, accuracy: 2,
                       "after the user resizes the sidebar, later windows must restore that user-defined width")
    }
}
