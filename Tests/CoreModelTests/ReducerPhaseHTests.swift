import XCTest
@testable import CoreModel

final class ReducerPhaseHTests: XCTestCase {
    func test_surfaceMove_movesBetweenPanes() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .browser, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let leftPane = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: leftPane, direction: .right, newSurface: b))
        let panes = s.workspaces[wid]!.layout.paneIDs()
        let rightPane = panes.last!
        // move a (in leftPane) to rightPane
        s = try r.reduce(s, .moveSurfaceToPane(wid, surface: a.id, targetPane: rightPane))
        let right = s.workspaces[wid]!.layout.find(paneID: rightPane)!
        XCTAssertTrue(right.surfaces.contains(where: { $0.id == a.id }))
    }

    func test_resizeSplit_changesRatios() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .agentApp, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let leftPane = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: leftPane, direction: .right, newSurface: b))
        guard case .split(let split) = s.workspaces[wid]!.layout else { return XCTFail() }
        s = try r.reduce(s, .resizeSplit(wid, splitID: split.id, ratios: [0.3, 0.7]))
        guard case .split(let updated) = s.workspaces[wid]!.layout else { return XCTFail() }
        XCTAssertEqual(updated.ratios[0], 0.3, accuracy: 0.0001)
        XCTAssertEqual(updated.ratios[1], 0.7, accuracy: 0.0001)
    }

    func test_reorderSurface_placesAtPosition() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .browser, title: "b")
        let c = SurfaceDescriptor(type: .agentApp, title: "c")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: b))
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: c))
        let pane = s.workspaces[wid]!.layout.paneIDs().first!
        // move c to position 0
        s = try r.reduce(s, .reorderSurface(wid, surface: c.id, toPane: pane, position: 0))
        let updated = s.workspaces[wid]!.layout.find(paneID: pane)!
        XCTAssertEqual(updated.surfaces.first?.id, c.id)
    }
}
