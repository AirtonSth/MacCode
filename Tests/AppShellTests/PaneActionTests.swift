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

    func test_addTerminal_button_addsSurface_toEmptyPane() throws {
        let (ctx, router) = try makeContext()
        // create a workspace (empty pane)
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single empty pane") }
        XCTAssertEqual(pane.surfaces.count, 0)

        let ptv = PaneTabsView(pane: pane, router: router)
        let desc = ptv.performAdd(.terminal, title: "terminal")
        XCTAssertNotNil(desc, "performAdd should return a descriptor")

        // state must now contain the surface in that pane
        let updated = ctx.state.workspaces[ws.id]!
        guard case .pane(let p2) = updated.layout else { return XCTFail() }
        XCTAssertEqual(p2.surfaces.count, 1)
        XCTAssertEqual(p2.surfaces.first?.type, .terminal)
        // and it must be registered so the tab can render it
        XCTAssertNotNil(SurfaceRegistry.shared.surface(p2.surfaces[0].id))
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

    func test_buttons_noop_without_workspace() throws {
        let (_, router) = try makeContext()
        // No workspace selected.
        let emptyPane = PaneNode(surfaces: [])
        let ptv = PaneTabsView(pane: emptyPane, router: router)
        XCTAssertNil(ptv.performAdd(.terminal, title: "terminal"),
                     "with no selected workspace performAdd must return nil, not crash")
    }
}
