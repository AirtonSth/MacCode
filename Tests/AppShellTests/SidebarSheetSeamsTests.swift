import XCTest
@testable import AppShell

// Pure seam tests -- no AppKit modal, no @MainActor required.
// Rule 8: every assertion states WHY the behavior matters.

final class SidebarSheetSeamsTests: XCTestCase {

    // MARK: - :15 confirmRemoveDecision

    /// WHY: the "Remove" button is the first button in the NSAlert. Returning
    /// true on .alertFirstButtonReturn is the single gate that guards the
    /// destructive closeWorkspace call. If this maps incorrectly, the user
    /// either loses data without confirming or can never remove a workspace.
    func test_confirmRemoveDecision_firstButton_returnsTrue() {
        XCTAssertTrue(
            SidebarRootView.confirmRemoveDecision(response: .alertFirstButtonReturn),
            "alertFirstButtonReturn (Remove) must return true -- it is the confirmed-remove gate; " +
            "false here means the workspace is never deleted when the user clicks Remove"
        )
    }

    /// WHY: the "Cancel" button maps to .alertSecondButtonReturn. Returning
    /// true here would delete the workspace despite the user cancelling.
    func test_confirmRemoveDecision_secondButton_returnsFalse() {
        XCTAssertFalse(
            SidebarRootView.confirmRemoveDecision(response: .alertSecondButtonReturn),
            "alertSecondButtonReturn (Cancel) must return false -- returning true here would " +
            "delete the workspace even after the user explicitly cancelled"
        )
    }

    /// WHY: sheet dismissal without button click produces .alertThirdButtonReturn
    /// or other codes. Any non-first-button response must be treated as cancel
    /// to avoid accidental deletion.
    func test_confirmRemoveDecision_thirdButton_returnsFalse() {
        XCTAssertFalse(
            SidebarRootView.confirmRemoveDecision(response: .alertThirdButtonReturn),
            "any response other than the first button must be treated as cancel -- " +
            "sheet dismissal must never trigger the destructive remove action"
        )
    }

    // MARK: - :18 autoScrollDirection

    /// WHY: a pointer near the top of the scroll view must return -1 so the
    /// timer scrolls the list upward. Returning 0 here means the user can
    /// never drag from the bottom of a long list to the top in one motion.
    func test_autoScrollDirection_topEdge_returnsMinusOne() {
        // pointerY=10 is within the 40-pt edge zone at the top of a 400-pt view.
        let result = SidebarRootView.autoScrollDirection(pointerY: 10, viewHeight: 400, edgeZone: 40)
        XCTAssertEqual(result, -1,
            "pointer 10pt from the top of a 400-pt view with a 40-pt zone must return -1 (scroll up) -- " +
            "returning 0 blocks upward auto-scroll, making long-list bottom-to-top drags impossible")
    }

    /// WHY: a pointer near the bottom must return +1 so the timer scrolls
    /// the list downward. Returning 0 blocks top-to-bottom drags on long lists.
    func test_autoScrollDirection_bottomEdge_returnsPlusOne() {
        // pointerY=390 is within the 40-pt edge zone at the bottom of a 400-pt view.
        let result = SidebarRootView.autoScrollDirection(pointerY: 390, viewHeight: 400, edgeZone: 40)
        XCTAssertEqual(result, 1,
            "pointer 10pt from the bottom of a 400-pt view with a 40-pt zone must return +1 (scroll down) -- " +
            "returning 0 blocks downward auto-scroll so the user cannot drag to the end of a long list")
    }

    /// WHY: a pointer in the middle of the view must return 0 so the list does
    /// not scroll during a normal drag. Returning non-zero would cause the list
    /// to scroll unexpectedly whenever the pointer is anywhere in the sidebar.
    func test_autoScrollDirection_middle_returnsZero() {
        let result = SidebarRootView.autoScrollDirection(pointerY: 200, viewHeight: 400, edgeZone: 40)
        XCTAssertEqual(result, 0,
            "pointer in the middle of the view must return 0 (no scroll) -- " +
            "a non-zero result would scroll the list on every normal drag pass, making reorder unusable")
    }

    /// WHY: exactly at the edge zone boundary (pointerY == edgeZone) is NOT
    /// in the zone (the condition is strict <), so 0 must be returned.
    /// A half-open interval prevents a flicker at exactly the boundary pixel.
    func test_autoScrollDirection_exactlyAtTopBoundary_returnsZero() {
        // pointerY == edgeZone: not strictly less than, so no scroll.
        let result = SidebarRootView.autoScrollDirection(pointerY: 40, viewHeight: 400, edgeZone: 40)
        XCTAssertEqual(result, 0,
            "pointer exactly at the edge-zone boundary must return 0 -- " +
            "the boundary is exclusive to avoid flicker at the transition pixel")
    }

    /// WHY: a zero viewHeight is a degenerate input (view not yet laid out).
    /// Returning 0 avoids a divide-by-zero or nonsensical scroll direction
    /// before the scroll view has measured its frame.
    func test_autoScrollDirection_zeroViewHeight_returnsZero() {
        let result = SidebarRootView.autoScrollDirection(pointerY: 5, viewHeight: 0, edgeZone: 40)
        XCTAssertEqual(result, 0,
            "zero viewHeight (not yet laid out) must return 0 -- " +
            "a non-zero result before layout would trigger a spurious scroll on first drag")
    }

    /// WHY: a zero edgeZone disables auto-scroll entirely. Returning non-zero
    /// would scroll when the caller explicitly passed 0 to opt out.
    func test_autoScrollDirection_zeroEdgeZone_returnsZero() {
        let result = SidebarRootView.autoScrollDirection(pointerY: 5, viewHeight: 400, edgeZone: 0)
        XCTAssertEqual(result, 0,
            "edgeZone=0 must always return 0 -- the caller can disable auto-scroll by " +
            "passing edgeZone=0; a non-zero result would ignore that intent")
    }
}
