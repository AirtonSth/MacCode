import XCTest
import CoreModel
@testable import AppShell

/// Tests for PaneTabsView.splitDropDirection(in:at:).
///
/// WHY: The split-drop gesture dispatches to the router only when the point
/// lands in an edge region. An off-by-one here silently routes a drag to
/// the wrong direction (e.g. .down instead of .up) producing a split on the
/// wrong side -- a data-loss-level UX error. These tests pin all four
/// quadrant mappings and the deterministic boundary rules.
///
/// Coordinate system: NSRect, y=0 at bottom. Lower on screen = smaller y.
///   rightIntent = point.x - midX   (positive in right half)
///   downIntent  = midY - point.y   (positive in lower half)
@MainActor
final class SplitDropDirectionTests: XCTestCase {

    // bounds: 400x300, center = (200, 150)
    private let bounds = NSRect(x: 0, y: 0, width: 400, height: 300)

    // MARK: - Right quadrant

    func test_rightDominant_returnsRight() {
        // point (340, 150): rightIntent=140, downIntent=0 -- horizontal wins, right half
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 340, y: 150)),
            .right,
            "point strictly in right half along the horizontal midline must yield .right"
        )
    }

    func test_rightDominantOverUp_returnsRight() {
        // point (390, 260): rightIntent=190, upIntent=110 -- horizontal abs dominates
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 390, y: 260)),
            .right,
            "upper-right corner: rightIntent(190) > upIntent(110) -- .right must win"
        )
    }

    // MARK: - Left quadrant

    func test_leftDominant_returnsLeft() {
        // point (60, 150): rightIntent=-140, downIntent=0 -- horizontal wins, left half
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 60, y: 150)),
            .left,
            "point strictly in left half along horizontal midline must yield .left"
        )
    }

    func test_leftDominantOverDown_returnsLeft() {
        // point (10, 40): rightIntent=-190, downIntent=110 -- abs horizontal > abs vertical
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 10, y: 40)),
            .left,
            "lower-left corner: abs(leftIntent)(190) > abs(downIntent)(110) -- .left must win"
        )
    }

    func test_leftDominantOverUp_returnsLeft() {
        // point (10, 260): rightIntent=-190, downIntent=-110 -- abs horizontal dominates
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 10, y: 260)),
            .left,
            "upper-left corner: abs(leftIntent)(190) > abs(upIntent)(110) -- .left must win"
        )
    }

    // MARK: - Down quadrant

    func test_downDominant_returnsDown() {
        // point (200, 40): rightIntent=0, downIntent=110 -- vertical wins, lower half
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 200, y: 40)),
            .down,
            "point strictly in lower half along the vertical midline must yield .down"
        )
    }

    func test_downDominantOverRight_returnsDown() {
        // point (300, 10): rightIntent=100, downIntent=140 -- abs vertical > abs horizontal
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 300, y: 10)),
            .down,
            "lower-right corner: abs(downIntent)(140) > abs(rightIntent)(100) -- .down must win"
        )
    }

    // MARK: - Up quadrant

    func test_upDominant_returnsUp() {
        // point (200, 260): rightIntent=0, downIntent=-110 -- vertical wins, upper half
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 200, y: 260)),
            .up,
            "point strictly in upper half along the vertical midline must yield .up"
        )
    }

    func test_upDominantOverRight_returnsUp() {
        // point (300, 290): rightIntent=100, downIntent=-140 -- abs vertical > abs horizontal
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 300, y: 290)),
            .up,
            "upper-right corner: abs(upIntent)(140) > abs(rightIntent)(100) -- .up must win"
        )
    }

    func test_upDominantOverLeft_returnsUp() {
        // point (60, 290): rightIntent=-140, downIntent=-140 -- tie: horizontal wins at >=, right half? no, left
        // Recalculate: rightIntent = 60-200 = -140, downIntent = 150-290 = -140 -- tie goes to horizontal (.left)
        // Use asymmetric point instead: (100, 290): rightIntent=-100, downIntent=-140 -- abs vertical > abs horizontal
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 100, y: 290)),
            .up,
            "upper-left corner: abs(upIntent)(140) > abs(leftIntent)(100) -- .up must win"
        )
    }

    // MARK: - Exact center is nil

    func test_exactCenter_returnsNil() {
        XCTAssertNil(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 200, y: 150)),
            "the center point has zero displacement on both axes -- no direction, no split"
        )
    }

    // MARK: - Outside bounds is nil

    func test_outsideBounds_returnsNil() {
        XCTAssertNil(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 500, y: 150)),
            "a point outside the pane must never trigger a split"
        )
        XCTAssertNil(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: -1, y: 150))
        )
        XCTAssertNil(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 200, y: -1))
        )
        XCTAssertNil(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 200, y: 400))
        )
    }

    // MARK: - Tie-breaking: horizontal wins on equal magnitude

    func test_tieGoesToHorizontal_rightWins() {
        // rightIntent = 100, downIntent = 100 -- tie, absH == absV, horizontal branch taken, rightIntent >= 0 => .right
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 300, y: 50)),
            .right,
            "on equal abs displacement horizontal axis wins; positive rightIntent => .right"
        )
    }

    func test_tieGoesToHorizontal_leftWins() {
        // rightIntent = -100, downIntent = 100 -- tie, horizontal wins, .left
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 100, y: 50)),
            .left,
            "on equal abs displacement horizontal axis wins; negative rightIntent => .left"
        )
    }

    // MARK: - Existing right/down coverage preserved (regression)

    func test_regression_rightAndDown_stillWork() {
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 340, y: 240)),
            .right,
            "regression: existing right-zone drop must still yield .right"
        )
        XCTAssertEqual(
            PaneTabsView.splitDropDirection(in: bounds, at: NSPoint(x: 120, y: 40)),
            .down,
            "regression: existing down-zone drop must still yield .down"
        )
    }
}
