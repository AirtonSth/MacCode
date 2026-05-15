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
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "controls", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let ptv = PaneTabsView(pane: pane, router: router)

        let buttons = allSubviews(of: ptv.view).compactMap { $0 as? NSButton }
        XCTAssertGreaterThanOrEqual(buttons.count, 4, "pane header should expose add/split/close controls")
        XCTAssertTrue(buttons.allSatisfy { !$0.mouseDownCanMoveWindow },
                      "tab add and close buttons live in the titlebar band, so they must receive clicks instead of starting a window drag")
    }

    func test_secondaryPaneHeader_onlyShowsPaneLocalControls() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "secondary", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let ptv = PaneTabsView(pane: pane, router: router, showsWorkspaceControls: false)

        let tooltips = allSubviews(of: ptv.view)
            .compactMap { ($0 as? NSButton)?.toolTip }
        XCTAssertFalse(tooltips.contains("Toggle sidebar"),
                       "only the first pane should own workspace-level sidebar controls")
        XCTAssertFalse(tooltips.contains("Open Git (changed files & diff)"),
                       "only the first pane should own the workspace-level Git tab")
        XCTAssertTrue(tooltips.contains("Split right (side by side)"))
        XCTAssertTrue(tooltips.contains("Split down (stacked)"))
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}
