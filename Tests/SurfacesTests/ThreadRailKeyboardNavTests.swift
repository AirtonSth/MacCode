import XCTest
@testable import Surfaces

/// Tests for AgentThreadRailKeyboardNav.moveThreadSelection.
///
/// WHY: keyboard thread-rail navigation must move within bounds and never crash
/// on an empty rail or edge indices. A regression returning -1 or count would
/// cause an out-of-range array access when the view resolves threads[next].
final class ThreadRailKeyboardNavTests: XCTestCase {

    // MARK: - normal movement

    // WHY: Down from index 0 in a multi-row rail must advance to index 1.
    // This is the primary user action -- pressing Down selects the next thread.
    func test_move_down_from0_returns1() {
        let result = AgentThreadRailKeyboardNav.moveThreadSelection(current: 0, direction: 1, count: 3)
        XCTAssertEqual(result, 1,
                       "Down from index 0 in a 3-row rail must advance to index 1")
    }

    // MARK: - clamp at upper bound

    // WHY: pressing Down at the last thread must clamp instead of overflowing
    // past count, which would cause an out-of-range array access in the view.
    func test_move_down_fromLast_clampsToLast() {
        let result = AgentThreadRailKeyboardNav.moveThreadSelection(current: 2, direction: 1, count: 3)
        XCTAssertEqual(result, 2,
                       "Down at last index (2) in a 3-row rail must stay at 2 -- never return 3")
    }

    // MARK: - clamp at lower bound

    // WHY: pressing Up at the first thread must clamp to 0, not underflow to -1,
    // which would crash when used as an array subscript.
    func test_move_up_fromFirst_clampsToZero() {
        let result = AgentThreadRailKeyboardNav.moveThreadSelection(current: 0, direction: -1, count: 3)
        XCTAssertEqual(result, 0,
                       "Up at index 0 must clamp to 0 -- never return -1")
    }

    // MARK: - nil current (no thread selected)

    // WHY: pressing Down when no thread is selected must select the first one
    // (index 0). Without this, the first Down press is silently ignored.
    func test_move_nilCurrent_returnsZero() {
        let result = AgentThreadRailKeyboardNav.moveThreadSelection(current: nil, direction: 1, count: 3)
        XCTAssertEqual(result, 0,
                       "nil current with count > 0 must select first row (index 0)")
    }

    // MARK: - empty rail guard

    // WHY: an empty filteredThreads rail must return nil so the view never
    // indexes into an empty array with threads[next].
    func test_move_emptyRail_returnsNil() {
        let result = AgentThreadRailKeyboardNav.moveThreadSelection(current: nil, direction: 1, count: 0)
        XCTAssertNil(result, "empty rail must return nil -- no valid index exists")
    }
}
