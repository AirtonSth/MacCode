import XCTest
@testable import AppShell

/// Tests for SSHHostKeyboardNav.moveHostSelection.
///
/// WHY: keyboard host navigation must stay within bounds and never crash on
/// empty lists or edge indices. A regression that returns -1 or count would
/// cause a force-unwrap or out-of-range array access in SSHSidebarView.
final class SSHHostKeyboardNavTests: XCTestCase {

    // MARK: - nil current (no prior keyboard selection)

    // WHY: pressing Down with no prior selection must land on the first row.
    // Without this, the first Down press is silently ignored and the user
    // sees no feedback.
    func test_move_nilCurrent_down_returnsZero() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: nil, direction: 1, count: 3)
        XCTAssertEqual(result, 0,
                       "nil current + Down must select first row (index 0)")
    }

    // WHY: pressing Up with no prior selection should also land on index 0
    // (same "first row" behaviour) rather than returning -1.
    func test_move_nilCurrent_up_returnsZero() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: nil, direction: -1, count: 3)
        XCTAssertEqual(result, 0,
                       "nil current + Up must select first row (index 0), not -1")
    }

    // MARK: - empty list guard

    // WHY: empty filteredHosts must return nil so SSHSidebarView never sets
    // keyboardHighlightedHostIndex to an index into an empty array.
    func test_move_emptyList_returnsNil() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: nil, direction: 1, count: 0)
        XCTAssertNil(result, "empty list must return nil -- no valid index exists")
    }

    func test_move_emptyList_withCurrentIndex_returnsNil() {
        // Should never happen in practice, but must not crash.
        let result = SSHHostKeyboardNav.moveHostSelection(current: 0, direction: 1, count: 0)
        XCTAssertNil(result, "count == 0 must always return nil regardless of current")
    }

    // MARK: - normal movement

    // WHY: Down from index 0 in a 3-row list must advance to index 1.
    func test_move_down_from0_returns1() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: 0, direction: 1, count: 3)
        XCTAssertEqual(result, 1,
                       "Down from index 0 in a 3-row list must advance to index 1")
    }

    // WHY: Up from index 1 must retreat to index 0.
    func test_move_up_from1_returns0() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: 1, direction: -1, count: 3)
        XCTAssertEqual(result, 0,
                       "Up from index 1 must retreat to index 0")
    }

    // MARK: - clamp at lower bound

    // WHY: pressing Up at the first row must clamp to 0, not underflow to -1.
    func test_move_up_fromFirst_clampsToZero() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: 0, direction: -1, count: 3)
        XCTAssertEqual(result, 0,
                       "Up at index 0 must clamp to 0 -- never return -1")
    }

    // MARK: - clamp at upper bound

    // WHY: pressing Down at the last row must clamp to last, not overflow past count.
    func test_move_down_fromLast_clampsToLast() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: 2, direction: 1, count: 3)
        XCTAssertEqual(result, 2,
                       "Down at last index (2) in a 3-row list must stay at 2 -- never return 3")
    }

    // Single-row list: both directions must stay at 0.
    func test_move_singleRow_down_staysAtZero() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: 0, direction: 1, count: 1)
        XCTAssertEqual(result, 0,
                       "single-row list: Down must stay at index 0")
    }

    func test_move_singleRow_up_staysAtZero() {
        let result = SSHHostKeyboardNav.moveHostSelection(current: 0, direction: -1, count: 1)
        XCTAssertEqual(result, 0,
                       "single-row list: Up must stay at index 0")
    }
}
