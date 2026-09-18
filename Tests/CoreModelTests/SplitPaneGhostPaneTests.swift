import XCTest
@testable import CoreModel

// P2 — A split into a pane that is not in the layout must be refused.
//
// WHY this matters: `split()` walks the layout and returns it untouched when
// the requested pane id is not there, but the reducer still stored the result
// with `focusedPaneID` = the new pane id — a pane that does not exist. The split
// was reported as applied (`surface.split` answers success and publishes
// `pane.split`), and the dangling focus then poisoned later pane-less adds,
// which resolve their target from `focusedPaneID`.
final class SplitPaneGhostPaneTests: XCTestCase {

    private func makeWorkspace() throws -> (LayoutReducer, LayoutState, WorkspaceID, PaneID, SurfaceDescriptor) {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let pane = s.workspaces[wid]!.layout.paneIDs().first!
        return (r, s, wid, pane, a)
    }

    func test_splitPane_intoUnknownPane_doesNotCorruptFocusOrPublishASplit() throws {
        let (r, s, wid, _, _) = try makeWorkspace()
        let ghost = PaneID()
        let b = SurfaceDescriptor(type: .browser, title: "b")

        do {
            let next = try r.reduce(s, .splitPane(wid, paneID: ghost, direction: .right, newSurface: b))
            let ws = next.workspaces[wid]!
            XCTAssertTrue(ws.layout.contains(surfaceID: b.id),
                          "the reported split never added its surface — the split was silently skipped")
            XCTAssertNotEqual(ws.focusedPaneID, ghost,
                              "focus must never be left on a pane id that is not in the layout")
            XCTFail("a split targeting a pane outside the layout must throw paneNotFound")
        } catch {
            XCTAssertEqual(error as? LayoutError, .paneNotFound,
                           "a split targeting a pane outside the layout must throw paneNotFound")
        }
    }

    /// Control leg: the same split into a pane that exists still adds exactly one
    /// panel and focuses it.
    func test_splitPane_intoExistingPane_stillSplitsAndFocuses() throws {
        let (r, s, wid, pane, a) = try makeWorkspace()
        let b = SurfaceDescriptor(type: .browser, title: "b")

        let next = try r.reduce(s, .splitPane(wid, paneID: pane, direction: .right, newSurface: b))
        let ws = next.workspaces[wid]!
        let paneIDs = ws.layout.paneIDs()

        XCTAssertEqual(paneIDs.count, 2, "a valid split creates the second pane")
        XCTAssertTrue(ws.layout.contains(surfaceID: a.id) && ws.layout.contains(surfaceID: b.id),
                      "both the original and the new surface must stay in the layout")
        XCTAssertEqual(ws.focusedPaneID, paneIDs.first { $0 != pane },
                       "a valid split focuses the newly created pane")
    }
}
