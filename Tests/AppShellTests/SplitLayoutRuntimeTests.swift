import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel
import Persistence

@MainActor
final class SplitLayoutRuntimeTests: XCTestCase {
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

    private func makeWindowController() throws -> (AppContext, AppCommandRouter, MainWindowController) {
        let dir = NSTemporaryDirectory() + "RC2Split-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let wc = MainWindowController(context: ctx, router: router)
        router.windowController = wc
        return (ctx, router, wc)
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func test_horizontalSplit_panesAreEqualWidthAtRuntime() throws {
        let (ctx, router, wc) = try makeWindowController()
        _ = ctx // keep AppContext alive (router.context is weak)
        wc.window.setContentSize(NSSize(width: 1200, height: 800))

        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        let pid = ws.layout.paneIDs().first!
        _ = try router.splitPane(workspace: ws.id, paneID: pid,
                                 direction: .right, surfaceType: .terminal, title: "t")

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
        wc.window.setContentSize(NSSize(width: 1200, height: 800))

        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        let pid = ws.layout.paneIDs().first!
        _ = try router.splitPane(workspace: ws.id, paneID: pid,
                                 direction: .down, surfaceType: .terminal, title: "t")

        wc.window.contentView?.layoutSubtreeIfNeeded()
        let split = try XCTUnwrap(findSplit(wc.window.contentView!))
        split.layoutSubtreeIfNeeded()
        XCTAssertEqual(split.subviews.count, 2)
        let h0 = split.subviews[0].frame.height
        let h1 = split.subviews[1].frame.height
        XCTAssertGreaterThan(h0, 0)
        XCTAssertEqual(h0, h1, accuracy: 1.5, "stacked panes must each be 50% height")
    }

    func test_sidebarDividerCanResizeWorkspaceList() throws {
        let (ctx, _, wc) = try makeWindowController()
        _ = ctx
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
        let first = MainWindowController(context: ctx, router: router)
        first.window.setContentSize(NSSize(width: 1200, height: 800))
        drainMainQueue()
        let split = try XCTUnwrap(findRootSplit(first.window.contentView!))
        split.setPosition(360, ofDividerAt: 0)
        split.layoutSubtreeIfNeeded()

        let second = MainWindowController(context: ctx, router: router)
        second.window.setContentSize(NSSize(width: 1200, height: 800))
        drainMainQueue()
        second.window.contentView?.layoutSubtreeIfNeeded()
        let restored = try XCTUnwrap(findRootSplit(second.window.contentView!))

        XCTAssertEqual(restored.subviews.first?.frame.width ?? 0, 360, accuracy: 2,
                       "after the user resizes the sidebar, later windows must restore that user-defined width")
    }
}
