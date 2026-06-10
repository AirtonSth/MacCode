import XCTest
@testable import CoreModel

// P1 - Guard the lone-tab self-reorder data-loss path.
//
// WHY this matters: reorderSurface removes the dragged surface from its pane
// before re-inserting it at the target pane. When the surface is the ONLY tab
// in a pane that lives inside a split, removing it collapses (prunes) that pane,
// so the original pane id no longer exists. If the drop target IS that same
// (now-vanished) pane, insertSurface silently no-ops and the surface is LOST.
// These tests pin the contract: such a drop must NOT drop the surface - it must
// either be a safe no-op or throw paneNotFound, and the surface must survive.
final class ReorderLoneTabSelfDropTests: XCTestCase {

    /// Build a workspace whose layout is a split of two lone-tab panes (A:a, B:b).
    /// Returns (reducer, state, wid, paneA, surfaceA, paneB, surfaceB).
    private func makeTwoLonePanes() throws
        -> (LayoutReducer, LayoutState, WorkspaceID, PaneID, SurfaceDescriptor, PaneID, SurfaceDescriptor)
    {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .browser, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let paneA = s.workspaces[wid]!.layout.paneIDs().first!
        // split puts `b` in its own new pane; `a` remains the lone tab of paneA.
        s = try r.reduce(s, .splitPane(wid, paneID: paneA, direction: .right, newSurface: b))
        let paneB = s.workspaces[wid]!.layout.paneIDs().first { $0 != paneA }!
        return (r, s, wid, paneA, a, paneB, b)
    }

    // A lone tab re-dropped onto its OWN pane (inside a split) must not vanish.
    // Before the fix: removeSurface prunes paneA, insertSurface(paneA) no-ops,
    // surface `a` is silently lost. After the fix: throws paneNotFound, and
    // because reduce throws, the surface remains in the unchanged prior state.
    func test_loneTabSelfReorder_intoVanishedPane_doesNotDropSurface() throws {
        let (r, s, wid, paneA, a, _, _) = try makeTwoLonePanes()

        XCTAssertThrowsError(try r.reduce(s, .reorderSurface(wid, surface: a.id, toPane: paneA, position: 0))) { e in
            XCTAssertEqual(e as? LayoutError, .paneNotFound,
                           "self-reordering a lone tab whose pane is pruned must throw paneNotFound, never silently drop the surface")
        }

        // The throwing reduce must not have mutated the caller's state: surface survives.
        XCTAssertTrue(s.workspaces[wid]!.layout.contains(surfaceID: a.id),
                      "the dragged surface must still exist after a guarded self-drop")
    }

    // Explicitly reordering onto a target pane that no longer exists must throw
    // paneNotFound rather than discard the surface.
    func test_reorder_intoNonexistentPane_throwsPaneNotFound() throws {
        let (r, s, wid, _, a, _, _) = try makeTwoLonePanes()
        let ghost = PaneID() // never present in the layout

        XCTAssertThrowsError(try r.reduce(s, .reorderSurface(wid, surface: a.id, toPane: ghost, position: 0))) { e in
            XCTAssertEqual(e as? LayoutError, .paneNotFound,
                           "reordering into a vanished/unknown pane must throw paneNotFound, not lose the surface")
        }
        XCTAssertTrue(s.workspaces[wid]!.layout.contains(surfaceID: a.id),
                      "surface must survive a reorder targeting a nonexistent pane")
    }

    // Regression guard: a genuine cross-pane move must still succeed and relocate
    // the surface, proving the guard does not break normal reorder behavior.
    func test_reorder_crossPaneMove_stillSucceeds() throws {
        let (r, s, wid, paneA, _, paneB, b) = try makeTwoLonePanes()

        // Move `b` from paneB into paneA (paneA stays alive because `a` keeps it
        // non-empty), so the target pane does not vanish.
        let next = try r.reduce(s, .reorderSurface(wid, surface: b.id, toPane: paneA, position: 0))

        XCTAssertTrue(next.workspaces[wid]!.layout.contains(surfaceID: b.id),
                      "moved surface must still exist after a valid cross-pane reorder")
        let destSurfaces = next.workspaces[wid]!.layout.find(paneID: paneA)?.surfaces.map(\.id) ?? []
        XCTAssertTrue(destSurfaces.contains(b.id),
                      "surface b must land in the target pane after a valid cross-pane reorder")
    }
}
