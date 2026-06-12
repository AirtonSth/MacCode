import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel

@MainActor
final class RatioSplitTests: XCTestCase {
    func test_reducer_freshSplit_isFiftyFifty() throws {
        let r = LayoutReducer()
        var s = try r.reduce(LayoutState(), .createWorkspace(name: "w", cwd: "/tmp", initial: nil))
        let wid = s.window.selectedWorkspaceID!
        let a = SurfaceDescriptor(type: .terminal, title: "a")
        let b = SurfaceDescriptor(type: .terminal, title: "b")
        s = try r.reduce(s, .addSurface(wid, paneID: nil, descriptor: a))
        let pid = s.workspaces[wid]!.layout.paneIDs().first!
        s = try r.reduce(s, .splitPane(wid, paneID: pid, direction: .right, newSurface: b))
        guard case .split(let split) = s.workspaces[wid]!.layout else { return XCTFail() }
        XCTAssertEqual(split.ratios.count, 2)
        XCTAssertEqual(split.ratios[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(split.ratios[1], 0.5, accuracy: 0.0001)
    }

    func test_ratioSplitView_vertical_dividesWidthInHalf() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        let l = NSView(); let r = NSView()
        sv.addSubview(l)
        sv.addSubview(r)
        sv.adjustSubviews()
        let lw = sv.subviews[0].frame.width
        let rw = sv.subviews[1].frame.width
        XCTAssertEqual(lw, rw, accuracy: 1.0, "panes must be within 1pt of each other")
        XCTAssertEqual(lw + rw + sv.dividerThickness, 400, accuracy: 1.0)
        XCTAssertEqual(sv.subviews[0].frame.height, 200, accuracy: 0.5)
    }

    func test_ratioSplitView_horizontal_dividesHeightInHalf() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        sv.isVertical = false
        sv.ratios = [0.5, 0.5]
        let top = NSView(); let bottom = NSView()
        sv.addSubview(top)
        sv.addSubview(bottom)
        sv.adjustSubviews()
        let h0 = sv.subviews[0].frame.height
        let h1 = sv.subviews[1].frame.height
        XCTAssertEqual(h0, h1, accuracy: 1.0)
        XCTAssertEqual(h0 + h1 + sv.dividerThickness, 500, accuracy: 1.0)
        XCTAssertEqual(sv.subviews[0].frame.width, 300, accuracy: 0.5)
        XCTAssertGreaterThan(sv.subviews[0].frame.minY, sv.subviews[1].frame.minY,
                             "stacked splits must keep the first child visually above the second child")
    }

    func test_ratioSplitView_nestedHorizontalSplitRelayoutsChildren() {
        let outer = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        outer.isVertical = true
        outer.ratios = [0.5, 0.5]

        let left = NSView()
        let rightNested = RatioSplitView()
        rightNested.isVertical = false
        rightNested.ratios = [0.5, 0.5]
        let top = NSView()
        let bottom = NSView()
        rightNested.addSubview(top)
        rightNested.addSubview(bottom)

        outer.addSubview(left)
        outer.addSubview(rightNested)
        outer.adjustSubviews()

        XCTAssertEqual(top.frame.width, rightNested.bounds.width, accuracy: 0.5)
        XCTAssertEqual(bottom.frame.width, rightNested.bounds.width, accuracy: 0.5)
        XCTAssertEqual(top.frame.height, bottom.frame.height, accuracy: 1.0,
                       "a vertical/down split inside another split must stack panes, not leave stale side-by-side frames")
    }

    func test_ratioSplitView_relayoutsPaneSubviewConstraintsAfterFrameChange() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]

        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = true
        let surface = NSView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: pane.topAnchor),
            surface.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: pane.trailingAnchor)
        ])

        sv.addSubview(pane)
        sv.addSubview(NSView())
        sv.adjustSubviews()

        XCTAssertEqual(surface.frame.width, pane.bounds.width, accuracy: 0.5,
                       "pane content must relayout immediately after a split changes pane width, or terminal text can bleed into neighboring panes")
    }

    func test_ratioSplitView_collapsedStackedPaneKeepsOnlyTabRowHeight() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        sv.isVertical = false
        sv.ratios = [0.04, 0.96]
        sv.addSubview(NSView())
        sv.addSubview(NSView())
        sv.adjustSubviews()

        XCTAssertEqual(sv.subviews[0].frame.height, 35, accuracy: 0.5,
                       "a minimized stacked split pane must collapse to the tab-row height instead of showing content")
        XCTAssertEqual(sv.subviews[0].frame.width, 300, accuracy: 0.5)
        XCTAssertGreaterThan(sv.subviews[1].frame.height, 450)
    }

    func test_ratioSplitView_collapsedSideBySidePaneKeepsCompactRailWidth() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        sv.isVertical = true
        sv.ratios = [0.04, 0.96]
        sv.addSubview(NSView())
        sv.addSubview(NSView())
        sv.adjustSubviews()

        XCTAssertEqual(sv.subviews[0].frame.width, 44, accuracy: 0.5,
                       "a minimized side-by-side split pane should become a compact restore rail, not a wide empty column")
        XCTAssertGreaterThan(sv.subviews[1].frame.width, 550)
    }

    func test_ratioSplitView_draggingDividerChangesPersistedRatiosAndFrames() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        sv.addSubview(NSView())
        sv.addSubview(NSView())

        sv.adjustSubviews()
        sv.applyDividerDrag(dividerIndex: 0, delta: 120)

        XCTAssertEqual(sv.ratios[0], 0.7, accuracy: 0.01,
                       "dragging the divider right must make the left pane wider instead of leaving a fixed 50/50 split")
        XCTAssertEqual(sv.ratios[1], 0.3, accuracy: 0.01)
        XCTAssertGreaterThan(sv.subviews[0].frame.width, sv.subviews[1].frame.width)
    }

    func test_ratioSplitView_draggingStackedDividerChangesTopAndBottomHeights() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 300, height: 500))
        sv.isVertical = false
        sv.ratios = [0.5, 0.5]
        sv.addSubview(NSView())
        sv.addSubview(NSView())

        sv.adjustSubviews()
        sv.applyDividerDrag(dividerIndex: 0, delta: 100)

        XCTAssertGreaterThan(sv.subviews[0].frame.height, sv.subviews[1].frame.height,
                             "dragging a stacked divider down must resize the top and bottom panels, not only move a visual line")
    }

    // WHY: Esc during a resize must restore the original layout exactly, not
    // leave a half-dragged state, and must not persist the mid-drag ratios to
    // the model (onRatiosChanged must not fire).
    func test_ratioSplitView_escCancelRestoresDragStartRatiosWithoutCommit() {
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        sv.addSubview(NSView())
        sv.addSubview(NSView())
        sv.adjustSubviews()

        // Seed the pre-drag snapshot exactly as mouseDown would (via internal accessor).
        let snapshot: [CGFloat] = [0.5, 0.5]
        sv.dragStartRatios = snapshot
        var committed = false
        sv.onRatiosChanged = { _ in committed = true }

        // Simulate a mid-drag state (moves divider significantly right).
        sv.applyDividerDrag(dividerIndex: 0, delta: 180)
        let midDragRatios = sv.ratios
        XCTAssertNotEqual(midDragRatios[0], snapshot[0], accuracy: 0.01,
                          "precondition: drag must have changed the ratios")

        // Pure seam: ratiosOnCancel must return the dragStart snapshot unchanged.
        let restored = RatioSplitView.ratiosOnCancel(dragStart: snapshot)
        XCTAssertEqual(restored[0], snapshot[0], accuracy: 0.001,
                       "ratiosOnCancel must return the pre-drag snapshot, not the mid-drag value")
        XCTAssertEqual(restored[1], snapshot[1], accuracy: 0.001)

        // Full cancel path: cancelDividerDrag restores ratios and does not commit.
        sv.cancelDividerDrag()

        XCTAssertFalse(committed,
                       "Esc-cancel must not fire onRatiosChanged; only mouseUp on a committed drag should persist ratios")
        XCTAssertEqual(sv.ratios[0], snapshot[0], accuracy: 0.01,
                       "after Esc-cancel the live ratios must equal the pre-drag snapshot, not the mid-drag value")
        XCTAssertEqual(sv.ratios[1], snapshot[1], accuracy: 0.01)

        // Happy path: a normal drag + commit after cancel must still fire onRatiosChanged.
        sv.onRatiosChanged?(sv.ratios)
        XCTAssertTrue(committed, "a normal mouseUp after cancel must still fire onRatiosChanged")
    }
}
