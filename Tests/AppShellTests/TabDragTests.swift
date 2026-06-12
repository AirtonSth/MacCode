import XCTest
import CoreModel
import DesignSystemKit
@testable import AppShell

/// Drag threshold, split-drop direction, and preview geometry for tab reordering.
/// Pins the live manual-drag contract so regressions surface before the UI does.
@MainActor
final class TabDragTests: XCTestCase {

    func test_dragThreshold_ignoresClickJitter() {
        XCTAssertFalse(PaneTabButton.hasMovedBeyondDragThreshold(
            from: NSPoint(x: 40, y: 12),
            to: NSPoint(x: 43, y: 15),
            threshold: 8
        ), "small pointer jitter while selecting a tab must not start reorder mode")
    }

    func test_dragThreshold_allowsIntentionalDrag() {
        XCTAssertTrue(PaneTabButton.hasMovedBeyondDragThreshold(
            from: NSPoint(x: 40, y: 12),
            to: NSPoint(x: 49, y: 12),
            threshold: 8
        ), "moving beyond the threshold should still allow intentional tab reordering")
    }

    func test_splitDropDirection_detectsRightAndDownZones() {
        let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertEqual(PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 340, y: 240)), .right,
                       "dragging a tab toward the side of its pane should create a side-by-side split")
        XCTAssertEqual(PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 120, y: 40)), .down,
                       "dragging a tab toward the bottom of its pane should create a stacked split")
        XCTAssertNil(PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 200, y: 150)),
                     "the exact center has zero displacement on both axes -- no direction, no split")
    }

    func test_splitDropPreview_usesCmuxBluePaneOverlay() {
        let root = PaneRootView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        root.setSplitDropHighlighted(true, direction: .right)
        root.layoutSubtreeIfNeeded()

        let overlay = root.layer?.sublayers?.first { $0.name == PaneRootView.splitDropOverlayLayerName }
        XCTAssertNotNil(overlay, "split preview must be a real overlay above pane content, not only a border behind it")
        XCTAssertFalse(overlay?.isHidden ?? true)
        XCTAssertEqual(overlay?.frame, NSRect(x: 202, y: 2, width: 196, height: 296),
                       "side split preview must turn exactly the future right pane blue, matching cmux")
        XCTAssertEqual(NSColor(cgColor: overlay?.borderColor ?? CGColor.clear), DS.NS.splitPreviewStroke,
                       "split preview stroke must use the cmux/system blue, not the lighter app accent")
        XCTAssertEqual(overlay?.borderWidth, 2)

        root.setSplitDropHighlighted(true, direction: .down)
        XCTAssertEqual(overlay?.frame, NSRect(x: 2, y: 2, width: 396, height: 146),
                       "down split preview must turn exactly the future lower pane blue, matching cmux")

        root.setSplitDropHighlighted(false)
        XCTAssertTrue(overlay?.isHidden ?? false,
                      "ending a drag must remove the blue preview without leaving stale pane chrome")
    }
}
