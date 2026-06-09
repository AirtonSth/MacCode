import XCTest
@testable import CoreModel

/// Tests that closing a surface preserves the surviving panes' split ratios.
///
/// Business rule: users resize splits to reflect their working preferences.
/// Silently resetting proportions on every surface-close destroys UX state.
///
/// Root cause (before fix): Reducer.removeSurface always reset ratios to equal
/// regardless of whether any pane was actually collapsed.
final class PreserveSplitRatiosOnRemoveTests: XCTestCase {

    // MARK: - 2-pane split: close one surface from a multi-surface pane (no collapse)

    /// Closing a surface from a pane that STILL HAS other surfaces must not touch
    /// the split ratios — no pane collapses, so survivors' ratios are unchanged.
    ///
    /// Setup: split([pane0(a,b), pane1(c)], ratios:[0.3, 0.7])
    /// Action: closeSurface(a) — pane0 still has b, no collapse.
    /// Expected: ratios remain [0.3, 0.7].
    func test_closeSurface_nonEmptyPane_ratiosUnchanged() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!

        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        let c = SurfaceDescriptor(type: .terminal, title: "c")

        // Build pane0 with surfaces a + b
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let pane0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .addSurface(wid, paneID: pane0, descriptor: b))

        // Split right: pane0(a,b) | pane1(c)
        s = try r.reduce(s, .splitPane(wid, paneID: pane0, direction: .right, newSurface: c))

        guard case .split(let sn) = s.workspaces[wid]!.layout else {
            return XCTFail("expected split node")
        }
        XCTAssertEqual(sn.children.count, 2)

        // Apply custom ratios 30:70
        s = try r.reduce(s, .resizeSplit(wid, splitID: sn.id, ratios: [0.3, 0.7]))

        // Verify ratios applied
        guard case .split(let snBefore) = s.workspaces[wid]!.layout else {
            return XCTFail("expected split before close")
        }
        XCTAssertEqual(snBefore.ratios[0], 0.3, accuracy: 1e-10)
        XCTAssertEqual(snBefore.ratios[1], 0.7, accuracy: 1e-10)

        // Close surface `a` — pane0 still has `b`, split must survive unchanged
        s = try r.reduce(s, .closeSurface(wid, a.id))

        guard case .split(let snAfter) = s.workspaces[wid]!.layout else {
            return XCTFail("expected split after closing one surface from multi-surface pane")
        }

        XCTAssertEqual(snAfter.ratios.count, 2)
        XCTAssertEqual(snAfter.ratios.reduce(0, +), 1.0, accuracy: 1e-10)
        XCTAssertEqual(snAfter.ratios[0], 0.3, accuracy: 1e-10,
                       "left pane ratio must be preserved — no pane collapsed")
        XCTAssertEqual(snAfter.ratios[1], 0.7, accuracy: 1e-10,
                       "right pane ratio must be preserved — no pane collapsed")
    }

    // MARK: - 2-pane split: close last surface in one pane (collapse)
    // Redistributes the collapsed pane's share to the survivor proportionally.
    // With only 1 survivor the split collapses to a plain .pane node.

    /// When the only surface in pane1 is closed, the split collapses to a single
    /// pane and no ratio information is needed; this must not crash.
    func test_closeSurface_emptyPane_collapses_noCrash() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!

        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let pane0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: pane0, direction: .right, newSurface: b))

        guard case .split(let sn) = s.workspaces[wid]!.layout else {
            return XCTFail("expected split")
        }
        s = try r.reduce(s, .resizeSplit(wid, splitID: sn.id, ratios: [0.25, 0.75]))

        // Close sole surface in right pane — triggers collapse
        s = try r.reduce(s, .closeSurface(wid, b.id))

        guard case .pane = s.workspaces[wid]!.layout else {
            return XCTFail("2-pane with one empty pane must collapse to .pane node")
        }
        XCTAssertTrue(s.workspaces[wid]!.layout.contains(surfaceID: a.id),
                      "survivor surface `a` must still exist after collapse")
    }

    // MARK: - 3-pane nested: inner split ratio preserved on surface close

    /// In a nested split  outer([pane0, inner([pane1(x,y), pane2(z)])]),
    /// closing `x` from inner-pane1 (still has `y`) must preserve the inner
    /// split ratios exactly.
    ///
    /// Inner custom ratios: [0.35, 0.65].  After close(x): still [0.35, 0.65].
    func test_closeSurface_nestedSplit_innerRatiosPreserved() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!

        let a = SurfaceDescriptor(type: .terminal, title: "a")  // pane0
        let x = SurfaceDescriptor(type: .terminal, title: "x")  // inner-pane1, surface 1
        let y = SurfaceDescriptor(type: .terminal, title: "y")  // inner-pane1, surface 2
        let z = SurfaceDescriptor(type: .terminal, title: "z")  // inner-pane2

        // pane0(a), then split right with x → outer([pane0(a), pane1(x)])
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let pane0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: pane0, direction: .right, newSurface: x))

        // Add y to pane1 (the new right pane = last pane)
        let pane1 = s.workspaces[wid]!.layout.paneIDs().last!
        s = try r.reduce(s, .addSurface(wid, paneID: pane1, descriptor: y))

        // Split pane1 right with z → inner split inside outer
        s = try r.reduce(s, .splitPane(wid, paneID: pane1, direction: .right, newSurface: z))

        // At this point: outer([pane0(a), inner([pane1(x,y), pane2(z)])])
        // The inner split has pane1 and pane2; apply custom ratios to inner split
        guard case .split(let outer) = s.workspaces[wid]!.layout else {
            return XCTFail("expected outer split")
        }
        // Find the inner split node (child index 1 of outer)
        guard case .split(let inner) = outer.children[1] else {
            return XCTFail("expected inner split as second child of outer")
        }
        s = try r.reduce(s, .resizeSplit(wid, splitID: inner.id, ratios: [0.35, 0.65]))

        // Verify inner ratios set
        guard case .split(let outerBefore) = s.workspaces[wid]!.layout,
              case .split(let innerBefore) = outerBefore.children[1] else {
            return XCTFail("structure changed unexpectedly")
        }
        XCTAssertEqual(innerBefore.ratios[0], 0.35, accuracy: 1e-10)
        XCTAssertEqual(innerBefore.ratios[1], 0.65, accuracy: 1e-10)

        // Close `x` from pane1 — pane1 still has `y`, no collapse
        s = try r.reduce(s, .closeSurface(wid, x.id))

        guard case .split(let outerAfter) = s.workspaces[wid]!.layout,
              case .split(let innerAfter) = outerAfter.children[1] else {
            return XCTFail("inner split must survive — pane1 still has surface y")
        }

        XCTAssertEqual(innerAfter.ratios.count, 2)
        XCTAssertEqual(innerAfter.ratios[0], 0.35, accuracy: 1e-10,
                       "inner-pane1 ratio must be preserved — it still has surface y")
        XCTAssertEqual(innerAfter.ratios[1], 0.65, accuracy: 1e-10,
                       "inner-pane2 ratio must be preserved — unaffected by close")
    }

    // MARK: - Ratio sum invariant: always sums to 1.0 after any surface close

    /// Regardless of which surface is closed, the split's ratios must sum to 1.0.
    /// This is a regression guard for floating-point edge cases.
    func test_closeSurface_ratiosSumToOne_after_anyClose() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "ws", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!

        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        let extra = SurfaceDescriptor(type: .terminal, title: "extra")

        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let pane0 = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .addSurface(wid, paneID: pane0, descriptor: extra))
        s = try r.reduce(s, .splitPane(wid, paneID: pane0, direction: .right, newSurface: b))

        guard case .split(let sn) = s.workspaces[wid]!.layout else {
            return XCTFail("expected split")
        }
        // Odd ratio to stress floating point
        s = try r.reduce(s, .resizeSplit(wid, splitID: sn.id, ratios: [0.333, 0.667]))
        s = try r.reduce(s, .closeSurface(wid, extra.id))

        if case .split(let snAfter) = s.workspaces[wid]!.layout {
            let sum = snAfter.ratios.reduce(0.0, +)
            XCTAssertEqual(sum, 1.0, accuracy: 1e-10, "ratios must sum to 1.0 after close")
        }
        // If layout collapsed to pane, that's also fine (no ratios to check)
    }
}
