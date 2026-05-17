import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence

@MainActor
final class PaneActionTests: XCTestCase {
    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "RC2PaneTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    func test_newWorkspace_opensTerminalByDefault_andAddCreatesAnother() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        // A new workspace opens with a terminal by default.
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        XCTAssertEqual(pane.surfaces.count, 1)
        XCTAssertEqual(pane.surfaces.first?.type, .terminal)

        let ptv = PaneTabsView(pane: pane, router: router)
        let desc = ptv.performAdd(.terminal, title: "terminal")
        XCTAssertNotNil(desc, "performAdd should return a descriptor")

        let updated = ctx.state.workspaces[ws.id]!
        guard case .pane(let p2) = updated.layout else { return XCTFail() }
        XCTAssertEqual(p2.surfaces.count, 2)
        XCTAssertTrue(p2.surfaces.allSatisfy { $0.type == .terminal })
        XCTAssertNotNil(SurfaceRegistry.shared.surface(p2.surfaces[0].id))
        XCTAssertNotNil(SurfaceRegistry.shared.surface(p2.surfaces[1].id))
    }

    func test_addAgent_then_splitRight_buildsSplitTree() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        let ptv = PaneTabsView(pane: pane, router: router)
        XCTAssertNotNil(ptv.performAdd(.agentApp, title: "Agent App"))
        XCTAssertNotNil(ptv.performSplit(.right, type: .browser, title: "browser"))
        let updated = ctx.state.workspaces[ws.id]!
        guard case .split(let s) = updated.layout else { return XCTFail("expected split after splitRight") }
        XCTAssertEqual(s.children.count, 2)
        XCTAssertEqual(updated.layout.paneIDs().count, 2)
    }

    func test_splitHorizontal_and_splitVertical_orientations() throws {
        let (ctx, router) = try makeContext()
        // Horizontal split → side-by-side (orientation .horizontal)
        let ws1 = try router.createWorkspace(name: "h", cwd: NSTemporaryDirectory())
        guard case .pane(let p1) = ws1.layout else { return XCTFail() }
        let v1 = PaneTabsView(pane: p1, router: router)
        XCTAssertNotNil(v1.performAdd(.terminal, title: "t"))
        XCTAssertNotNil(v1.performSplit(.right, type: .agentApp, title: "Agent App"))
        guard case .split(let sH) = ctx.state.workspaces[ws1.id]!.layout else { return XCTFail() }
        XCTAssertEqual(sH.orientation, .horizontal)

        // Vertical split → stacked (orientation .vertical)
        let ws2 = try router.createWorkspace(name: "v", cwd: NSTemporaryDirectory())
        guard case .pane(let p2) = ws2.layout else { return XCTFail() }
        let v2 = PaneTabsView(pane: p2, router: router)
        XCTAssertNotNil(v2.performAdd(.terminal, title: "t"))
        XCTAssertNotNil(v2.performSplit(.down, type: .agentApp, title: "Agent App"))
        guard case .split(let sV) = ctx.state.workspaces[ws2.id]!.layout else { return XCTFail() }
        XCTAssertEqual(sV.orientation, .vertical)
    }

    func test_surfaceChoices_haveSixDistinctTypes() {
        let types = PaneTabsView.surfaceChoices.map { $0.1 }
        XCTAssertEqual(Set(types).count, types.count)
        XCTAssertTrue(types.contains(.terminal))
        XCTAssertTrue(types.contains(.browser))
        XCTAssertTrue(types.contains(.agentApp))
        XCTAssertTrue(types.contains(.rightSidebarTool),
                      "Git must be available as a normal tab surface option")
    }

    func test_focusSurface_switchesSelectedTab() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "s", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let termID = pane0.surfaces.first!.id              // default terminal
        let v = PaneTabsView(pane: pane0, router: router)
        let agent = v.performAdd(.agentApp, title: "Agent App")!
        // Adding selects the new tab.
        guard case .pane(let p1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p1.selectedSurfaceID, agent.id)
        // Clicking the terminal tab must switch the selection back.
        try router.focusSurface(workspace: ws.id, surface: termID)
        guard case .pane(let p2) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p2.selectedSurfaceID, termID,
                       "focusing another tab must change the visible surface")
    }

    func test_performReorderSurface_movesTabBeforeTargetInSamePane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "drag", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let first = pane0.surfaces.first!.id
        let v = PaneTabsView(pane: pane0, router: router)
        let second = try XCTUnwrap(v.performAdd(.browser, title: "browser"))

        guard case .pane(let pane1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        let dragView = PaneTabsView(pane: pane1, router: router)
        XCTAssertTrue(dragView.performReorderSurface(second.id, toPane: pane1.id, position: 0),
                      "dragging a tab before another tab must change the host-visible pane order")

        guard case .pane(let pane2) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(pane2.surfaces.map(\.id), [second.id, first])
    }

    func test_performReorderSurface_movesTabAcrossSplitPanes() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "split-drag", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let sourceSurface = pane0.surfaces.first!.id
        let v = PaneTabsView(pane: pane0, router: router)
        let right = try XCTUnwrap(v.performSplit(.right, type: .browser, title: "browser"))

        let updated = ctx.state.workspaces[ws.id]!
        let targetPane = try XCTUnwrap(updated.layout.paneIDs().first {
            updated.layout.find(paneID: $0)?.surfaces.contains(where: { $0.id == right.id }) == true
        })
        let dragView = PaneTabsView(pane: updated.layout.find(paneID: pane0.id)!, router: router)
        XCTAssertTrue(dragView.performReorderSurface(sourceSurface, toPane: targetPane, position: 0),
                      "dragging a tab into another split pane must move ownership, not only local order")

        let final = ctx.state.workspaces[ws.id]!
        XCTAssertEqual(final.layout.find(paneID: targetPane)?.surfaces.first?.id, sourceSurface)
    }

    func test_closeSurface_removesTabFromPane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "c", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        // Workspace already has a default terminal (1); add two more (3).
        let v = PaneTabsView(pane: pane, router: router)
        let a = v.performAdd(.terminal, title: "t")
        _ = v.performAdd(.browser, title: "b")
        guard case .pane(let p1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p1.surfaces.count, 3)
        try router.closeSurface(workspace: ws.id, surface: a!.id)
        guard case .pane(let p2) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p2.surfaces.count, 2)
        XCTAssertFalse(p2.surfaces.contains { $0.id == a!.id })
    }

    func test_symbolForType_isDistinctNonEmpty() {
        let syms = SurfaceType.allCases.map { PaneTabsView.symbol(for: $0) }
        XCTAssertTrue(syms.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(syms).count, syms.count)
    }

    func test_buttons_noop_without_workspace() throws {
        let (_, router) = try makeContext()
        // No workspace selected.
        let emptyPane = PaneNode(surfaces: [])
        let ptv = PaneTabsView(pane: emptyPane, router: router)
        XCTAssertNil(ptv.performAdd(.terminal, title: "terminal"),
                     "with no selected workspace performAdd must return nil, not crash")
    }

    func test_tabHeaderControls_doNotBecomeWindowDragTargets() throws {
        let (ctx, router) = try makeContext()
        _ = ctx
        let ws = try router.createWorkspace(name: "controls", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let ptv = PaneTabsView(pane: pane, router: router)

        let buttons = allSubviews(of: ptv.view).compactMap { $0 as? NSButton }
        XCTAssertGreaterThanOrEqual(buttons.count, 4, "pane header should expose add/split/close controls")
        XCTAssertTrue(buttons.allSatisfy { !$0.mouseDownCanMoveWindow },
                      "tab add and close buttons live in the titlebar band, so they must receive clicks instead of starting a window drag")
    }

    func test_secondaryPaneHeader_onlyShowsPaneLocalControls() throws {
        let (ctx, router) = try makeContext()
        _ = ctx
        let ws = try router.createWorkspace(name: "secondary", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let ptv = PaneTabsView(pane: pane, router: router, showsWorkspaceControls: false)

        let tooltips = allSubviews(of: ptv.view)
            .compactMap { ($0 as? NSButton)?.toolTip }
        XCTAssertFalse(tooltips.contains("Toggle sidebar"),
                       "sidebar toggling belongs in the sidebar header, not pane tabs")
        XCTAssertFalse(tooltips.contains("Open Git (changed files & diff)"),
                       "Git is created from the + menu as a tab, not from a persistent pane header button")
        XCTAssertTrue(tooltips.contains("Split right (side by side)"))
        XCTAssertTrue(tooltips.contains("Split down (stacked)"))
    }

    func test_visibleSidebarHeader_hasOnlyToggleBecauseWorkspaceCreationLivesInSidebarList() throws {
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "visible", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let visibleButtons = visibleSubviews(of: controller.window.contentView!)
            .compactMap { $0 as? NSButton }
        let visibleTooltips = visibleButtons.compactMap(\.toolTip)

        XCTAssertEqual(visibleTooltips.filter { $0 == "Toggle sidebar" }.count, 1,
                       "the visible sidebar must keep one collapse affordance")
        XCTAssertFalse(visibleTooltips.contains("New workspace"),
                       "workspace creation moved into the sidebar body as New Workspace; the top + must stay removed")
    }

    func test_sidebarViewModel_listsWindowWorkspacesAndSelectedWorkspaceForSidebarBody() throws {
        let (ctx, router) = try makeContext()
        let first = try router.createWorkspace(name: "alpha", cwd: NSTemporaryDirectory())
        let second = try router.createWorkspace(name: "beta", cwd: NSTemporaryDirectory())

        let vm = SidebarViewModel(context: ctx, router: router)
        vm.reload()

        XCTAssertEqual(vm.workspaces.map(\.name), ["alpha", "beta"],
                       "the visible sidebar Workspaces section must render the current window workspaces in order")
        XCTAssertEqual(vm.selectedWorkspaceID, second.id,
                       "the workspace row highlight must follow the router's selected workspace")

        try router.selectWorkspace(first.id)
        vm.reload()
        XCTAssertEqual(vm.selectedWorkspaceID, first.id,
                       "selecting a workspace must update the model that drives the sidebar row selection")
    }

    func test_collapsedSidebar_usesFullWidthHeaderWithToggleLeftPlusRightAndTabsBelow() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "collapsed", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let extra = PaneTabsView(pane: pane, router: router)
        XCTAssertNotNil(extra.performAdd(.terminal, title: "Terminal"))

        let controller = MainWindowController(context: ctx, router: router)
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(controller.window.contentView)
        let buttons = visibleSubviews(of: content).compactMap { $0 as? NSButton }
        let toggle = try XCTUnwrap(buttons.first { $0.toolTip == "Toggle sidebar" },
                                   "collapsed header must expose a left-side sidebar toggle")
        let plus = try XCTUnwrap(buttons.first { $0.toolTip == "New workspace" },
                                 "collapsed header must keep the workspace + on the right")
        let toggleFrame = toggle.convert(toggle.bounds, to: content)
        let plusFrame = plus.convert(plus.bounds, to: content)

        XCTAssertLessThan(toggleFrame.minX, 130,
                          "the collapsed-header toggle should sit near the left edge, not drift toward the center")
        XCTAssertGreaterThan(plusFrame.minX, content.bounds.width - 60,
                             "the collapsed-header + should remain on the right edge")
        XCTAssertLessThan(toggleFrame.maxX, plusFrame.minX,
                          "toggle and + must stay on opposite sides of the hidden-sidebar header")

        let split = try XCTUnwrap(allSubviews(of: content).first { $0 is NSSplitView } as? NSSplitView)
        let splitTop = try XCTUnwrap(content.constraints.first {
            ($0.firstItem as? NSSplitView) === split && $0.firstAttribute == .top && $0.secondAttribute == .top
        })
        XCTAssertEqual(splitTop.constant, 34, accuracy: 0.1,
                       "when the sidebar is hidden, tabs must move below the full-width workspace header")
    }

    func test_ratioSplit_laysOutSideBySideWithoutFreeSpace() {
        let split = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 901, height: 300))
        split.isVertical = true
        split.ratios = [0.5, 0.5]
        let left = NSView()
        let right = NSView()
        split.addSubview(left)
        split.addSubview(right)

        split.relayoutNow()

        XCTAssertEqual(left.frame.minX, 0)
        XCTAssertEqual(left.frame.height, split.bounds.height)
        XCTAssertEqual(right.frame.maxX, split.bounds.width)
        XCTAssertEqual(right.frame.minX, left.frame.maxX + split.dividerThickness,
                       "side-by-side splits must allocate every pixel except the single divider")
    }

    func test_ratioSplit_laysOutStackedTopToBottomWithoutFreeSpace() {
        let split = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 500, height: 601))
        split.isVertical = false
        split.ratios = [0.5, 0.5]
        let top = NSView()
        let bottom = NSView()
        split.addSubview(top)
        split.addSubview(bottom)

        split.relayoutNow()

        XCTAssertEqual(top.frame.maxY, split.bounds.height)
        XCTAssertEqual(top.frame.width, split.bounds.width)
        XCTAssertEqual(bottom.frame.minY, 0)
        XCTAssertEqual(top.frame.minY, bottom.frame.maxY + split.dividerThickness,
                       "stacked splits must allocate every pixel except the single divider, with the original pane on top")
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func visibleSubviews(of view: NSView) -> [NSView] {
        allSubviews(of: view).filter { isVisibleInTree($0) }
    }

    private func isVisibleInTree(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden { return false }
            current = candidate.superview
        }
        return true
    }
}
