import XCTest
@testable import Surfaces

/// Pure search/match layer behind the terminal find bar (Cmd+F). These assert the
/// business rules the find bar depends on: case-insensitive matching, every
/// occurrence found in order, none when absent, and prev/next navigation that
/// wraps around the match set. The class is @MainActor because the match layer
/// lives in a file with @MainActor view types; the tested symbols are nonisolated
/// static helpers but the annotation keeps the test compiling alongside them.
@MainActor
final class TerminalScrollbackSearchTests: XCTestCase {
    private func matchedSubstrings(_ text: String, _ query: String) -> [String] {
        TerminalScrollbackSearch.matchRanges(in: text, query: query).map { String(text[$0]) }
    }

    func test_matchRangesFindsEveryOccurrenceInDocumentOrder() {
        let text = "error: build error then runtime error"
        let ranges = TerminalScrollbackSearch.matchRanges(in: text, query: "error")
        // Three "error" tokens — a find bar that reported fewer would skip
        // matches the user can clearly see in the scrollback.
        XCTAssertEqual(ranges.count, 3, "every occurrence in the scrollback snapshot must be found")
        XCTAssertEqual(ranges.map { text.distance(from: text.startIndex, to: $0.lowerBound) },
                       [0, 13, 32],
                       "matches must be returned in document order so next/prev navigation moves through the text top-to-bottom")
    }

    func test_matchRangesIsCaseInsensitive() {
        // Terminal output mixes case (ERROR, Error, error); search must not be
        // case-sensitive or it would miss the real failure line.
        XCTAssertEqual(matchedSubstrings("ERROR Error error", "error"),
                       ["ERROR", "Error", "error"],
                       "search must be case-insensitive to match terminal output regardless of casing")
    }

    func test_matchRangesReturnsNoneWhenAbsentOrEmptyQuery() {
        XCTAssertTrue(TerminalScrollbackSearch.matchRanges(in: "hello world", query: "zzz").isEmpty,
                      "a query that does not occur must yield zero matches, not a false positive")
        XCTAssertTrue(TerminalScrollbackSearch.matchRanges(in: "hello world", query: "").isEmpty,
                      "an empty query must clear matches rather than matching every position")
        XCTAssertTrue(TerminalScrollbackSearch.matchRanges(in: "", query: "x").isEmpty,
                      "searching an empty scrollback snapshot must yield no matches")
    }

    func test_matchRangesDoesNotOverlapRepeatedPattern() {
        // "aa" in "aaaa" must be non-overlapping (2 matches), so navigation
        // count and indices are stable and terminate.
        XCTAssertEqual(TerminalScrollbackSearch.matchRanges(in: "aaaa", query: "aa").count, 2,
                       "repeated patterns must match non-overlapping so the match count is well-defined and the scan terminates")
    }

    func test_nextIndexStartsAtFirstOrLastWhenNoneSelected() {
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: nil, count: 3, forward: true, wrap: true), 0,
                       "first Next with nothing selected must land on the first match")
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: nil, count: 3, forward: false, wrap: true), 2,
                       "first Prev with nothing selected must land on the last match")
    }

    func test_nextIndexWrapsAtBothEnds() {
        // Wrapping is the documented find-bar behavior: Next past the end returns
        // to the top, Prev before the start returns to the bottom.
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: 2, count: 3, forward: true, wrap: true), 0,
                       "Next past the last match must wrap to the first")
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: 0, count: 3, forward: false, wrap: true), 2,
                       "Prev before the first match must wrap to the last")
    }

    func test_nextIndexClampsWhenWrapDisabled() {
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: 2, count: 3, forward: true, wrap: false), 2,
                       "without wrap, Next at the last match must stay on the last match")
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: 0, count: 3, forward: false, wrap: false), 0,
                       "without wrap, Prev at the first match must stay on the first match")
    }

    func test_nextIndexReturnsNilWhenNoMatches() {
        XCTAssertNil(TerminalScrollbackSearch.nextIndex(current: nil, count: 0, forward: true, wrap: true),
                     "navigation over an empty match set must yield no selection")
    }

    func test_nextIndexAdvancesNormallyInsideRange() {
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: 0, count: 3, forward: true, wrap: true), 1,
                       "Next inside the range must move to the following match")
        XCTAssertEqual(TerminalScrollbackSearch.nextIndex(current: 2, count: 3, forward: false, wrap: true), 1,
                       "Prev inside the range must move to the preceding match")
    }
}
