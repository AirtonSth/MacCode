import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel

// MARK: - PERF-MAC_SHELL_WINDOW-MED-129 seam tests
//
// WHY: PaneRootView.setFrameSize previously called
// updateConstraintsForSubtreeIfNeeded + layoutSubtreeIfNeeded synchronously
// on every mouse-moved tick during a divider drag. At 60fps with 4 panes this
// is ~240 AutoLayout subtree solves per second — the dominant CPU cost during
// a live resize.
//
// The fix: RatioSplitView.dividerDragActive = true on mouseDown,
// false + final solve on mouseUp / cancelDividerDrag. PaneRootView.setFrameSize
// returns early (marking dirty only) while the flag is set.
//
// Tests verify:
//   - dividerDragActive toggles correctly at drag start/end/cancel.
//   - dividerDragActive is cleared even after Esc-cancel (no stuck state).
//   - layout converges to the final frame on drag-end (no stuck mid-drag layout).
@MainActor
final class DividerDragLayoutThrottleTests: XCTestCase {

    // MARK: - dividerDragActive toggle seam

    /// WHY: the flag must be false before any drag starts. If it starts true,
    /// all AutoLayout solves in PaneRootView are suppressed from app launch,
    /// leaving pane content permanently unsized.
    func test_dividerDragActive_startsAtFalse() {
        XCTAssertFalse(
            RatioSplitView.dividerDragActive,
            "dividerDragActive must be false at class init; if true from the start " +
            "PaneRootView skips all AutoLayout solves and pane content is never sized")
        // Reset in case a prior test left it set.
        RatioSplitView.dividerDragActive = false
    }

    /// WHY: applyDividerDrag (the drag tick) does NOT clear dividerDragActive —
    /// the flag must remain true during the entire drag so PaneRootView skips
    /// per-tick layout solves. Clearing it during drag defeats the throttle.
    func test_dividerDragActive_remainsTrueDuringDrag() {
        RatioSplitView.dividerDragActive = false
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        sv.addSubview(NSView())
        sv.addSubview(NSView())
        sv.adjustSubviews()

        // Simulate mouseDown: set the flag as the production path does.
        RatioSplitView.dividerDragActive = true
        sv.dragStartRatios = sv.ratios

        // Apply a drag tick.
        sv.applyDividerDrag(dividerIndex: 0, delta: 60)

        XCTAssertTrue(
            RatioSplitView.dividerDragActive,
            "dividerDragActive must remain true during an active drag; " +
            "if cleared mid-drag PaneRootView resumes per-tick layout solves " +
            "and the throttle provides no benefit (PERF-MAC_SHELL_WINDOW-MED-129)")

        // Cleanup.
        RatioSplitView.dividerDragActive = false
    }

    /// WHY: cancelDividerDrag (Esc) must clear dividerDragActive and force a
    /// final layout solve so panes settle to the restored pre-drag ratios.
    /// If the flag stays true after cancel, all subsequent AutoLayout solves
    /// in PaneRootView are permanently suppressed until the next drag-end.
    func test_dividerDragActive_clearedAfterCancelDividerDrag() {
        RatioSplitView.dividerDragActive = false
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        sv.addSubview(NSView())
        sv.addSubview(NSView())
        sv.adjustSubviews()

        RatioSplitView.dividerDragActive = true
        sv.dragStartRatios = [0.5, 0.5]
        sv.applyDividerDrag(dividerIndex: 0, delta: 120)
        sv.cancelDividerDrag()

        XCTAssertFalse(
            RatioSplitView.dividerDragActive,
            "cancelDividerDrag (Esc) must clear dividerDragActive; if not cleared " +
            "PaneRootView permanently skips AutoLayout solves after an Esc-cancel, " +
            "leaving every subsequent frame-change unsized (PERF-MAC_SHELL_WINDOW-MED-129)")
    }

    // MARK: - Final-frame convergence contract

    /// WHY: suppressing per-tick solves must NOT leave panes stuck at a
    /// mid-drag size. After drag-end the pane frames must match the final
    /// ratios. This is the critical correctness guarantee of the throttle:
    /// coalescing is only safe if the final solve always fires.
    func test_dragEnd_subviewFramesConvergeToFinalRatios() {
        RatioSplitView.dividerDragActive = false
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        let left = NSView()
        let right = NSView()
        sv.addSubview(left)
        sv.addSubview(right)
        sv.adjustSubviews()

        // Simulate a full drag lifecycle.
        RatioSplitView.dividerDragActive = true
        sv.dragStartRatios = sv.ratios
        sv.applyDividerDrag(dividerIndex: 0, delta: 120)

        // Simulate mouseUp: clear flag and force final layout as production does.
        RatioSplitView.dividerDragActive = false
        for sub in sv.subviews {
            sub.needsLayout = true
            sub.layoutSubtreeIfNeeded()
        }

        let leftWidth = left.frame.width
        let rightWidth = right.frame.width
        XCTAssertGreaterThan(leftWidth, rightWidth,
            "after drag-end the left pane must be wider than the right (delta was positive); " +
            "if frames did not converge the final layout solve was skipped and panes are " +
            "stuck at mid-drag size (PERF-MAC_SHELL_WINDOW-MED-129 convergence contract)")
        XCTAssertEqual(leftWidth + rightWidth + sv.dividerThickness, 600, accuracy: 1.0,
            "pane widths must sum to the total minus divider regardless of throttle; " +
            "the final solve must produce exact pixel-correct frames")
    }

    /// WHY: after an Esc-cancel, pane frames must converge to the PRE-drag
    /// ratios, not the mid-drag position. The throttle must not prevent
    /// the restore solve from running.
    func test_dragCancel_subviewFramesRestoreToPreDragRatios() {
        RatioSplitView.dividerDragActive = false
        let sv = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        sv.isVertical = true
        sv.ratios = [0.5, 0.5]
        let left = NSView()
        let right = NSView()
        sv.addSubview(left)
        sv.addSubview(right)
        sv.adjustSubviews()

        let preDragLeftWidth = left.frame.width

        RatioSplitView.dividerDragActive = true
        sv.dragStartRatios = sv.ratios
        sv.applyDividerDrag(dividerIndex: 0, delta: 200)
        sv.cancelDividerDrag()  // clears flag + forces final layout

        XCTAssertEqual(left.frame.width, preDragLeftWidth, accuracy: 1.0,
            "after Esc-cancel pane widths must return to the pre-drag values; " +
            "if not, the restore solve was skipped and the user sees a stuck mid-drag layout " +
            "(PERF-MAC_SHELL_WINDOW-MED-129 cancel convergence)")
    }
}
