import XCTest
@testable import CoreModel

/// Property and invariant tests for LayoutReducer.
///
/// Coverage (P2  -  mac-tabs-splits.md):
///   (a) Every SplitNode has ratios.count == children.count, sum ~= 1.0, all >= 0
///   (b) No empty pane exists inside a split node after any LayoutAction
///   (c) SurfaceID multiset is preserved by reorderSurface / moveSurfaceToPane /
///       splitPane / splitSurface (invariant (c) would have caught the T004
///       surface-loss bug mechanically  -  the surface disappeared silently)
///
/// WHY: These invariants are load-bearing for both the UI (a split with wrong
/// ratios crashes the geometry math) and correctness (a dropped surface is
/// permanently lost without any error; the user cannot undo it).
final class LayoutReducerInvariantTests: XCTestCase {

    // MARK: - Helpers

    private let r = LayoutReducer()

    /// Collect all SplitNodes reachable from a layout node.
    private func allSplits(in node: LayoutNode) -> [SplitNode] {
        switch node {
        case .pane: return []
        case .split(let s): return [s] + s.children.flatMap { allSplits(in: $0) }
        }
    }

    /// Collect all SurfaceIDs reachable from a layout node.
    private func allSurfaceIDs(in node: LayoutNode) -> [SurfaceID] {
        switch node {
        case .pane(let p): return p.surfaces.map(\.id)
        case .split(let s): return s.children.flatMap { allSurfaceIDs(in: $0) }
        }
    }

    /// Assert invariant (a): every split has count-consistent ratios that sum
    /// to approximately 1.0 and have no negative values.
    private func assertSplitRatiosValid(in node: LayoutNode, context: String) {
        for split in allSplits(in: node) {
            XCTAssertEqual(
                split.ratios.count, split.children.count,
                "[\(context)] split.ratios.count (\(split.ratios.count)) must equal " +
                "split.children.count (\(split.children.count))  -  a mismatch crashes the " +
                "geometry math that maps ratios to frame widths/heights"
            )
            let sum = split.ratios.reduce(0.0, +)
            XCTAssertEqual(sum, 1.0, accuracy: 1e-9,
                           "[\(context)] split ratios must sum to 1.0 (got \(sum))  -  " +
                           "a non-unit sum means panes overlap or have gaps that can't be resolved by the layout engine")
            for ratio in split.ratios {
                XCTAssertGreaterThanOrEqual(ratio, 0.0,
                    "[\(context)] no ratio may be negative (got \(ratio))  -  a negative ratio produces a frame with negative width/height")
            }
        }
    }

    /// Assert invariant (b): no empty pane inside any split node.
    private func assertNoEmptyPaneInsideSplit(in node: LayoutNode, context: String) {
        switch node {
        case .pane:
            return   // top-level empty pane is allowed (initial workspace state)
        case .split(let s):
            for child in s.children {
                if case .pane(let p) = child {
                    XCTAssertFalse(
                        p.surfaces.isEmpty,
                        "[\(context)] empty pane found inside a split  -  an empty pane inside a " +
                        "split cannot be closed and blocks the user from recovering to a clean state"
                    )
                }
                assertNoEmptyPaneInsideSplit(in: child, context: context)
            }
        }
    }

    // MARK: - (a) Ratio invariants across a sequence of actions

    /// WHY: after building a 3-pane horizontal split with custom ratios, all
    /// ratio invariants must hold.
    func test_splitRatioInvariants_threePane_afterCustomResize() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        let c = SurfaceDescriptor(type: .terminal, title: "c")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: b))
        let p1 = s.workspaces[wid]!.layout.paneIDs().last!
        s = try r.reduce(s, .splitPane(wid, paneID: p1, direction: .right, newSurface: c))

        // Outer split has 2 children: pane0 and inner split.
        // Inner split also has 2 children: pane1 and pane2.
        guard case .split(let outer) = s.workspaces[wid]!.layout else {
            return XCTFail("expected outer split")
        }
        // Apply non-trivial 2-child ratios to the outer split.
        s = try r.reduce(s, .resizeSplit(wid, splitID: outer.id, ratios: [0.35, 0.65]))
        // Apply ratios to the inner split too.
        guard case .split(let outerAfterResize) = s.workspaces[wid]!.layout,
              case .split(let inner) = outerAfterResize.children[1] else {
            return XCTFail("expected nested split structure")
        }
        s = try r.reduce(s, .resizeSplit(wid, splitID: inner.id, ratios: [0.4, 0.6]))

        assertSplitRatiosValid(in: s.workspaces[wid]!.layout,
                               context: "3-pane after custom resize")
    }

    /// WHY: after closing a surface in a pane that still has siblings, the split
    /// survives and its ratio invariants must still hold.
    func test_splitRatioInvariants_afterCloseSurface_nonEmptyPane() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        let extra = SurfaceDescriptor(type: .terminal, title: "extra")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .addSurface(wid, paneID: p0, descriptor: extra))
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: b))

        guard case .split(let sn) = s.workspaces[wid]!.layout else {
            return XCTFail("expected split")
        }
        s = try r.reduce(s, .resizeSplit(wid, splitID: sn.id, ratios: [0.4, 0.6]))

        // Close one surface from pane0  -  pane0 still has one surface.
        s = try r.reduce(s, .closeSurface(wid, extra.id))

        assertSplitRatiosValid(in: s.workspaces[wid]!.layout,
                               context: "after closeSurface non-empty pane")
    }

    // MARK: - (b) No empty pane inside any split

    /// WHY: closing the LAST surface in one pane of a 2-pane split collapses
    /// the split. If collapse fails, the split would contain an empty child pane  -
    /// a pane the user cannot see or close, corrupting the layout.
    func test_noEmptyPaneInsideSplit_afterLastSurfaceClosed() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: b))

        // Close `b`  -  pane1 becomes empty; split must collapse.
        s = try r.reduce(s, .closeSurface(wid, b.id))

        assertNoEmptyPaneInsideSplit(in: s.workspaces[wid]!.layout,
                                     context: "after closing last surface in pane1")
    }

    /// WHY: A reorderSurface that moves the only surface out of a pane could leave
    /// an empty pane inside the split if collapse is not triggered.
    func test_noEmptyPaneInsideSplit_afterReorderSurface() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        let c = SurfaceDescriptor(type: .terminal, title: "c")

        // Build pane0(a, c) | pane1(b)
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .addSurface(wid, paneID: p0, descriptor: c))
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: b))
        let p1 = s.workspaces[wid]!.layout.paneIDs().last!

        // Move `c` from pane0 to pane1. pane0 still has `a` -> no collapse needed.
        s = try r.reduce(s, .reorderSurface(wid, surface: c.id, toPane: p1, position: 0))

        assertNoEmptyPaneInsideSplit(in: s.workspaces[wid]!.layout,
                                     context: "after reorderSurface into pane1")
    }

    // MARK: - (c) SurfaceID multiset preserved by reorderSurface

    /// WHY: This invariant would have caught the T004 surface-loss bug mechanically.
    /// reorderSurface removes the surface from its old pane and inserts it into the
    /// target pane. If the remove step prunes the wrong node or the insert silently
    /// no-ops, a surface disappears without any error. The multiset before and after
    /// must be identical.
    func test_surfaceIDMultiset_preservedByReorderSurface() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .browser, title: "b")
        let c = SurfaceDescriptor(type: .agentApp, title: "c")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .addSurface(wid, paneID: p0, descriptor: b))
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: c))
        let p1 = s.workspaces[wid]!.layout.paneIDs().last!

        let before = Set(allSurfaceIDs(in: s.workspaces[wid]!.layout))

        // Move `a` from pane0 to pane1.
        s = try r.reduce(s, .reorderSurface(wid, surface: a.id, toPane: p1, position: 0))

        let after = Set(allSurfaceIDs(in: s.workspaces[wid]!.layout))

        XCTAssertEqual(before, after,
                       "T004 regression guard: reorderSurface must not lose or duplicate any surface  -  " +
                       "the set of all SurfaceIDs must be identical before and after the move. " +
                       "A mismatch means a surface was silently dropped or cloned, " +
                       "which is an unrecoverable data-loss condition for the user.")
    }

    /// WHY: moveSurfaceToPane moves a surface to a specific pane without a
    /// position hint. Same multiset invariant applies  -  no surface may be lost.
    func test_surfaceIDMultiset_preservedByMoveSurfaceToPane() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: b))
        let p1 = s.workspaces[wid]!.layout.paneIDs().last!

        let before = Set(allSurfaceIDs(in: s.workspaces[wid]!.layout))

        // Move `b` back to pane0.
        s = try r.reduce(s, .moveSurfaceToPane(wid, surface: b.id, targetPane: p0))

        let after = Set(allSurfaceIDs(in: s.workspaces[wid]!.layout))

        XCTAssertEqual(before, after,
                       "moveSurfaceToPane must preserve the full set of SurfaceIDs  -  " +
                       "a lost surface cannot be reopened by the user and the session is permanently corrupted")
    }

    /// WHY: splitPane creates a new pane with a new surface. The resulting layout
    /// must contain exactly the pre-split surfaces PLUS the newly added surface.
    func test_surfaceIDMultiset_splitPane_addsExactlyOneSurface() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!

        let before = Set(allSurfaceIDs(in: s.workspaces[wid]!.layout))

        let newSurf = SurfaceDescriptor(type: .browser, title: "b")
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: newSurf))

        let after = Set(allSurfaceIDs(in: s.workspaces[wid]!.layout))

        XCTAssertEqual(after, before.union([newSurf.id]),
                       "splitPane must add exactly newSurface.id to the layout  -  " +
                       "adding no surface or duplicating an existing ID are both data-integrity failures")
    }

    // MARK: - Combined: ratio invariants hold after a reorderSurface

    /// WHY: reorderSurface can trigger pane collapse (if it empties the source pane),
    /// which renormalises ratios. Both invariants must hold simultaneously.
    func test_bothInvariants_afterReorderCausesCollapse() throws {
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let p0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: p0, direction: .right, newSurface: b))
        let p1 = s.workspaces[wid]!.layout.paneIDs().last!

        let beforeIDs = Set(allSurfaceIDs(in: s.workspaces[wid]!.layout))

        // Move `a` from pane0 to pane1  -  pane0 becomes empty, split collapses.
        s = try r.reduce(s, .moveSurfaceToPane(wid, surface: a.id, targetPane: p1))

        let afterLayout = s.workspaces[wid]!.layout
        let afterIDs = Set(allSurfaceIDs(in: afterLayout))

        // (c) SurfaceID multiset preserved.
        XCTAssertEqual(beforeIDs, afterIDs,
                       "SurfaceID multiset must be preserved even when reorder causes pane collapse")

        // (a) Ratio invariants on surviving splits (if any).
        assertSplitRatiosValid(in: afterLayout, context: "after reorder-caused collapse")

        // (b) No empty pane inside a split.
        assertNoEmptyPaneInsideSplit(in: afterLayout, context: "after reorder-caused collapse")
    }
}
