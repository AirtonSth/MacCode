import XCTest
@testable import AppShell

/// Verifies CommandPaletteFilter.matchedRanges(title:query:) - the pure helper
/// that maps a (title, query) pair to the character ranges that should be
/// bolded in the palette row cell.
///
/// WHY: without this helper the UI cannot communicate WHY a row matched (Rule
/// 8). Tests must break if matched ranges stop covering query characters in
/// order, if a no-match returns non-empty ranges, or if an empty query returns
/// ranges (nothing to highlight when the user has not typed yet).
final class PaletteMatchHighlightTests: XCTestCase {

    // MARK: - Empty query -> empty ranges

    func test_matchedRanges_emptyQuery_returnsEmpty() {
        // WHY: with no query the default view shows all commands; no characters
        // should be bolded (nothing was searched for).
        let ranges = CommandPaletteFilter.matchedRanges(title: "New Terminal Surface", query: "")
        XCTAssertTrue(ranges.isEmpty,
            "empty query must produce no highlighted ranges")
    }

    // MARK: - No match -> empty ranges

    func test_matchedRanges_noMatchQuery_returnsEmpty() {
        // WHY: if the filter would exclude this row, the highlight helper must
        // also return no ranges - rendering bold on a non-matching row is
        // misleading to the user.
        let ranges = CommandPaletteFilter.matchedRanges(title: "New Terminal Surface", query: "zzz")
        XCTAssertTrue(ranges.isEmpty,
            "a query that does not match must produce no highlighted ranges")
    }

    // MARK: - Exact prefix match

    func test_matchedRanges_prefixMatch_rangeCoversPrefix() {
        // WHY: querying "new" against "New Terminal Surface" must highlight
        // the first 3 characters. The matched-range count is 1 and it covers
        // exactly [0, 3) (case-insensitive).
        let title = "New Terminal Surface"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: "new")
        XCTAssertFalse(ranges.isEmpty,
            "prefix query must yield at least one highlighted range")
        // The characters covered by the ranges must spell "New".
        let covered = coveredCharacters(in: title, ranges: ranges)
        XCTAssertEqual(covered.lowercased(), "new",
            "prefix match must cover exactly the matched prefix characters")
    }

    // MARK: - Substring match mid-title

    func test_matchedRanges_substringMatch_rangeCoversSubstring() {
        // WHY: "term" matches inside "New Terminal Surface"; the highlighted
        // range must cover "Term" (the matched span), not the whole title.
        let title = "New Terminal Surface"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: "term")
        XCTAssertFalse(ranges.isEmpty,
            "substring match must yield at least one highlighted range")
        let covered = coveredCharacters(in: title, ranges: ranges)
        XCTAssertEqual(covered.lowercased(), "term",
            "substring match must highlight only the matched span")
    }

    // MARK: - Subsequence match: ranges cover query chars in order

    func test_matchedRanges_subsequenceMatch_rangesAreInOrder() {
        // WHY: "nts" is a subsequence of "New Terminal Surface" (N-T-S at
        // positions 0, 4, 13). The helper must return ranges that are strictly
        // ascending so the bolded characters appear left-to-right in the label.
        let title = "New Terminal Surface"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: "nts")
        XCTAssertFalse(ranges.isEmpty,
            "subsequence query must yield highlighted ranges")
        // Ranges must be in strictly ascending order.
        for i in 1..<ranges.count {
            XCTAssertTrue(ranges[i].lowerBound > ranges[i - 1].upperBound,
                "ranges must be non-overlapping and in ascending order")
        }
        // The characters at those positions must match the query characters.
        let covered = coveredCharacters(in: title, ranges: ranges)
        XCTAssertEqual(covered.lowercased(), "nts",
            "subsequence ranges must exactly cover the query characters in order")
    }

    func test_matchedRanges_subsequenceRangeCount_equalsQueryLength() {
        // WHY: for a subsequence hit the helper returns one Range per query
        // character so the caller can bold each independently. If two adjacent
        // query chars happen to be contiguous in the title they MAY be merged,
        // but the total covered characters must equal the query length.
        let title = "Open Workspace in Editor"
        let query = "owe"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: query)
        let totalCovered = ranges.reduce(0) { $0 + title.distance(from: $1.lowerBound, to: $1.upperBound) }
        XCTAssertEqual(totalCovered, query.count,
            "total covered characters must equal query length for subsequence hit")
    }

    // MARK: - Case insensitivity

    func test_matchedRanges_caseInsensitive() {
        // WHY: the filter is case-insensitive; the highlight must also be
        // case-insensitive so "TERM" highlights "Term" in "New Terminal Surface".
        let title = "New Terminal Surface"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: "TERM")
        XCTAssertFalse(ranges.isEmpty,
            "upper-case query must still produce highlighted ranges (case-insensitive)")
        let covered = coveredCharacters(in: title, ranges: ranges)
        XCTAssertEqual(covered.lowercased(), "term",
            "case-insensitive match must highlight the correct span")
    }

    // MARK: - Query longer than title -> empty

    func test_matchedRanges_queryLongerThanTitle_returnsEmpty() {
        // WHY: a query that cannot possibly be a subsequence of the title must
        // return empty ranges, consistent with the filter returning nil score.
        let title = "Git"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: "github actions workflow")
        XCTAssertTrue(ranges.isEmpty,
            "impossible-match query must produce no highlighted ranges")
    }

    // MARK: - Single-character query

    func test_matchedRanges_singleChar_highlightsFirstOccurrence() {
        // WHY: "t" must highlight the first "T" (index 0) in "Terminal", not
        // the second or a later occurrence. Greedy-first matching is correct
        // for single-char queries.
        let title = "Terminal"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: "t")
        guard !ranges.isEmpty else {
            XCTFail("single-char query must yield a highlighted range")
            return
        }
        let start = title.distance(from: title.startIndex, to: ranges[0].lowerBound)
        XCTAssertEqual(start, 0,
            "single-char query must highlight the first (earliest) occurrence")
    }

    // MARK: - Ranges do not exceed title bounds

    func test_matchedRanges_rangesWithinBounds() {
        // WHY: an out-of-bounds range would crash the NSAttributedString API.
        // Every returned range must be a valid index pair within the title.
        let title = "Save Session Snapshot"
        let ranges = CommandPaletteFilter.matchedRanges(title: title, query: "ses")
        for range in ranges {
            XCTAssertTrue(range.lowerBound >= title.startIndex && range.upperBound <= title.endIndex,
                "all highlighted ranges must be within the title's valid index bounds")
        }
    }

    // MARK: - Helper

    /// Extract the characters in `str` covered by `ranges`, in order.
    private func coveredCharacters(in str: String, ranges: [Range<String.Index>]) -> String {
        ranges.map { String(str[$0]) }.joined()
    }
}
