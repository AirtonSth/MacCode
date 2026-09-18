import XCTest
@testable import CoreModel

// P1 — Guard the lone-tab `moveSurfaceToPane` data-loss path.
//
// WHY this matters: `moveSurfaceToPane` removes the surface from its pane
// before adding it to the target pane. When the surface is the ONLY tab in a
// pane that lives inside a split, the removal collapses (prunes) that pane, so
// the source pane id no longer exists. If the target IS that same pane — or any
// pane id that vanished/never existed — `addSurface` silently no-ops on a
// missing pane and the surface is LOST: it leaves the layout, its runtime is
// orphaned and the persisted snapshot no longer contains it, so the user cannot
// reopen the tab. `surface.move` is a paired-device RPC, so this is reachable
// from iOS, not only from a local drag.
//
// The identical hole was already closed for `reorderSurface`
// (ReorderLoneTabSelfDropTests). These tests pin the same contract for the
// position-less move: the reduce must throw `paneNotFound`, and the surface
// must survive either way.
final class MoveSurfaceLoneTabSelfDropTests: XCTestCase {

    /// Build a workspace whose layout is a split of two lone-tab panes (A:a, B:b).
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
        s = try r.reduce(s, .splitPane(wid, paneID: paneA, direction: .right, newSurface: b))
        let paneB = s.workspaces[wid]!.layout.paneIDs().first { $0 != paneA }!
        return (r, s, wid, paneA, a, paneB, b)
    }

    /// Asserts the "never silently drop" contract: the reduce either throws
    /// `paneNotFound` (leaving the caller's state untouched) or, if it reports
    /// success, the moved surface is still reachable in the layout.
    private func assertMoveRefusedWithoutLoss(
        _ reducer: LayoutReducer,
        _ state: LayoutState,
        _ wid: WorkspaceID,
        _ surface: SurfaceDescriptor,
        _ action: LayoutAction,
        _ why: String
    ) {
        do {
            let next = try reducer.reduce(state, action)
            XCTAssertTrue(next.workspaces[wid]!.layout.contains(surfaceID: surface.id),
                          "move reported success but the surface left the layout — \(why)")
            XCTFail("a move that cannot be placed must throw paneNotFound instead of silently succeeding — \(why)")
        } catch {
            XCTAssertEqual(error as? LayoutError, .paneNotFound,
                           "a move that cannot be placed must throw paneNotFound — \(why)")
            XCTAssertTrue(state.workspaces[wid]!.layout.contains(surfaceID: surface.id),
                          "the throwing reduce must not mutate the caller's state — \(why)")
        }
    }

    /// Why the invariant: moving a lone tab "into" its own pane is exactly the
    /// path that loses it — removing `a` prunes paneA, `addSurface(paneA)`
    /// no-ops, and before the fix the reduce still reported success.
    func test_loneTabSelfMove_intoVanishedPane_doesNotDropSurface() throws {
        let (r, s, wid, paneA, a, _, _) = try makeTwoLonePanes()

        assertMoveRefusedWithoutLoss(
            r, s, wid, a,
            .moveSurfaceToPane(wid, surface: a.id, targetPane: paneA),
            "self-moving a lone tab whose pane is pruned"
        )
    }

    /// Second loss path of the same shape: a source pane that survives the
    /// removal (two tabs) still loses the moved tab when the target pane id does
    /// not exist, because `addSurface` no-ops instead of failing.
    func test_move_intoNonexistentPane_doesNotDropSurface() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws1", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let c = SurfaceDescriptor(type: .terminal, title: "c")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let paneA = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .addSurface(wid, paneID: paneA, descriptor: c))
        let ghost = PaneID() // never present in the layout

        assertMoveRefusedWithoutLoss(
            r, s, wid, c,
            .moveSurfaceToPane(wid, surface: c.id, targetPane: ghost),
            "moving into a vanished/unknown pane"
        )
    }

    /// Regression guard: a genuine cross-pane move must still succeed, and the
    /// collapsed source pane must not take the moved tab down with it.
    func test_move_crossPaneMove_stillSucceeds() throws {
        let (r, s, wid, _, a, paneB, b) = try makeTwoLonePanes()

        let next = try r.reduce(s, .moveSurfaceToPane(wid, surface: a.id, targetPane: paneB))

        let surfaces = next.workspaces[wid]!.layout.find(paneID: paneB)?.surfaces.map(\.id) ?? []
        XCTAssertEqual(Set(surfaces), Set([a.id, b.id]),
                       "the moved tab must land in the target pane and the sibling tab must stay")
        XCTAssertTrue(next.workspaces[wid]!.layout.contains(surfaceID: a.id),
                      "moved surface must still exist after a valid cross-pane move")
    }
}
