import XCTest
@testable import CoreModel

final class LayoutReducerTests: XCTestCase {
    func test_createWorkspace_addsAndSelects() throws {
        let r = LayoutReducer()
        let s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        XCTAssertEqual(s.window.workspaces.count, 1)
        XCTAssertNotNil(s.window.selectedWorkspaceID)
    }

    func test_setWorkspaceColor_setsAndClears() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .setWorkspaceColor(wid, "purple"))
        XCTAssertEqual(s.workspaces[wid]?.metadata["color"], "purple")
        s = try r.reduce(s, .setWorkspaceColor(wid, ""))
        XCTAssertNil(s.workspaces[wid]?.metadata["color"], "empty clears the color key")
    }

    func test_workspacePinningAndReorder_keepPinnedWorkspacesFirst() throws {
        let r = LayoutReducer()
        var s = LayoutState()
        s = try r.reduce(s, .createWorkspace(name: "one", cwd: "/tmp", initial: nil))
        let one = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "two", cwd: "/tmp", initial: nil))
        let two = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "three", cwd: "/tmp", initial: nil))
        let three = s.window.selectedWorkspaceID!

        s = try r.reduce(s, .setWorkspacePinned(two, true))
        XCTAssertEqual(s.window.workspaces, [two, one, three],
                       "pinning a workspace must move it above unpinned workspaces without losing relative order")

        s = try r.reduce(s, .reorderWorkspace(three, position: 0))
        XCTAssertEqual(s.window.workspaces, [two, three, one],
                       "drag reorder must respect the pinned-first sort boundary")
    }

    func test_promoteWorkspace_movesOnlyInsidePinnedGroup() throws {
        let r = LayoutReducer()
        var s = LayoutState()
        s = try r.reduce(s, .createWorkspace(name: "one", cwd: "/tmp", initial: nil))
        let one = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "two", cwd: "/tmp", initial: nil))
        let two = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "three", cwd: "/tmp", initial: nil))
        let three = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .createWorkspace(name: "four", cwd: "/tmp", initial: nil))
        let four = s.window.selectedWorkspaceID!
        s = try r.reduce(s, .setWorkspacePinned(two, true))
        s = try r.reduce(s, .setWorkspacePinned(four, true))

        s = try r.reduce(s, .promoteWorkspace(three))
        XCTAssertEqual(s.window.workspaces, [two, four, three, one],
                       "a completed unpinned workspace must jump to the top of unpinned workspaces without crossing pinned workspaces")

        s = try r.reduce(s, .promoteWorkspace(four))
        XCTAssertEqual(s.window.workspaces, [four, two, three, one],
                       "a completed pinned workspace must jump to the top of pinned workspaces")
    }

    func test_setSurfaceColor_writesToDescriptorMetadata() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let surf = SurfaceDescriptor(type: .terminal, title: "term")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: surf))
        s = try r.reduce(s, .setSurfaceColor(wid, surf.id, "green"))
        let found = s.workspaces[wid]?.layout.paneIDs().compactMap {
            s.workspaces[wid]?.layout.find(paneID: $0)?.surfaces.first { $0.id == surf.id }
        }.first
        XCTAssertEqual(found?.metadata["color"], "green")
    }

    func test_addSurface_setsSelected() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let surface = SurfaceDescriptor(type: .terminal, title: "t1")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: surface))
        let ws = s.workspaces[wid]!
        guard case .pane(let pane) = ws.layout else { return XCTFail("not pane") }
        XCTAssertEqual(pane.surfaces.count, 1)
        XCTAssertEqual(pane.selectedSurfaceID, surface.id)
    }

    func test_split_createsSplitNode_andFocusesNewPane() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let initial = SurfaceDescriptor(type: .terminal, title: "left")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: initial))
        let ws0 = s.workspaces[wid]!
        guard case .pane(let pane0) = ws0.layout else { return XCTFail() }
        let newSurface = SurfaceDescriptor(type: .agentApp, title: "right")
        s = try r.reduce(s, .splitPane(wid, paneID: pane0.id, direction: .right, newSurface: newSurface))
        let ws = s.workspaces[wid]!
        guard case .split(let split) = ws.layout else { return XCTFail("expected split") }
        XCTAssertEqual(split.children.count, 2)
        XCTAssertEqual(split.orientation, .horizontal)
        XCTAssertTrue(ws.layout.contains(surfaceID: newSurface.id))
        XCTAssertNotEqual(ws.focusedPaneID, pane0.id)
    }

    func test_closeSurface_collapsesEmptyPane() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .browser, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p, direction: .right, newSurface: b))
        // close `b` -> split should collapse to single pane node
        s = try r.reduce(s, .closeSurface(wid, b.id))
        guard case .pane = s.workspaces[wid]!.layout else { return XCTFail("expected pane after collapse") }
    }

    func test_unknown_workspace_throws() {
        let r = LayoutReducer()
        XCTAssertThrowsError(try r.reduce(LayoutState(), .selectWorkspace(WorkspaceID()))) { e in
            XCTAssertEqual(e as? LayoutError, .workspaceNotFound)
        }
    }

    func test_focusSurface_movesFocusedPane() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .agentApp, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p, direction: .down, newSurface: b))
        s = try r.reduce(s, .focusSurface(wid, a.id))
        XCTAssertEqual(s.workspaces[wid]!.focusedPaneID, p)
    }
}
