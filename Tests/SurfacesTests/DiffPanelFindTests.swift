import XCTest
@testable import Surfaces

/// Tests for the in-diff find seam (DiffPanelViewModel.matchRanges) and the
/// find-index cycler (nextFindMatch / prevFindMatch).
///
/// WHY these tests matter: the find bar must locate EVERY occurrence in the
/// diff (not just the first), cycle predictably (wrapping at boundaries), and
/// never return stale results when the query is empty or produces no hits.
/// A regression in any of these breaks the user's ability to navigate the diff.
@MainActor
final class DiffPanelFindTests: XCTestCase {

    // MARK: matchRanges -- pure seam

    func test_matchRanges_findsAllOccurrences() {
        let text = "foo bar foo baz foo"
        let ranges = DiffPanelViewModel.matchRanges(in: text, query: "foo", caseInsensitive: false)
        // WHY: every occurrence must be found, not just the first.
        XCTAssertEqual(ranges.count, 3, "expected 3 occurrences of 'foo'")
    }

    func test_matchRanges_caseInsensitive() {
        let text = "Hello HELLO hello"
        let ranges = DiffPanelViewModel.matchRanges(in: text, query: "hello", caseInsensitive: true)
        // WHY: diff text may mix case; find must not miss differently-cased tokens.
        XCTAssertEqual(ranges.count, 3, "case-insensitive search must match all variants")
    }

    func test_matchRanges_caseSensitive_skipsWrongCase() {
        let text = "Hello HELLO hello"
        let ranges = DiffPanelViewModel.matchRanges(in: text, query: "hello", caseInsensitive: false)
        // WHY: when case-sensitive, only the exact-case token matches.
        XCTAssertEqual(ranges.count, 1)
        let matched = (text as NSString).substring(with: ranges[0])
        XCTAssertEqual(matched, "hello")
    }

    func test_matchRanges_emptyQuery_returnsNone() {
        let text = "some diff text"
        let ranges = DiffPanelViewModel.matchRanges(in: text, query: "", caseInsensitive: true)
        // WHY: an empty query must produce no matches (find is inactive).
        XCTAssertTrue(ranges.isEmpty, "empty query must return no ranges")
    }

    func test_matchRanges_noMatch_returnsEmpty() {
        let text = "some diff text"
        let ranges = DiffPanelViewModel.matchRanges(in: text, query: "zzz", caseInsensitive: true)
        // WHY: a missing query must produce no ranges so the UI shows "No matches".
        XCTAssertTrue(ranges.isEmpty, "absent query must return no ranges")
    }

    func test_matchRanges_emptyText_returnsEmpty() {
        let ranges = DiffPanelViewModel.matchRanges(in: "", query: "foo", caseInsensitive: true)
        XCTAssertTrue(ranges.isEmpty)
    }

    func test_matchRanges_overlappingPattern_countedCorrectly() {
        // "aaa" contains "aa" at offset 0 and offset 1 in a naive approach,
        // but the seam uses non-overlapping search (range(of:) advances past
        // the last match), so only 1 match is found. This is correct: the
        // user is searching for the literal token, not overlapping sub-strings.
        let ranges = DiffPanelViewModel.matchRanges(in: "aaa", query: "aa", caseInsensitive: false)
        XCTAssertEqual(ranges.count, 1, "non-overlapping search: 'aa' appears once in 'aaa'")
    }

    // MARK: Index cycler

    /// Sets up a VM with a pre-loaded rawDiff containing 3 occurrences of "foo".
    private func makeVM(withMatches: Bool) -> DiffPanelViewModel {
        let vm = DiffPanelViewModel(cwd: "/tmp", settings: nil, asyncLoad: false)
        // Inject rawDiff directly to bypass real git calls.
        // rawDiff.didSet calls resetFindIndex() when a query is already set,
        // so we set query after rawDiff to trigger the count update.
        if withMatches {
            vm.rawDiff = "+foo bar\n-foo baz\n context foo end"
            vm.findQuery = "foo"
        }
        return vm
    }

    func test_nextFindMatch_advancesIndex() {
        let vm = makeVM(withMatches: true)
        // WHY: pressing Cmd+G / Return must advance to the next match.
        XCTAssertEqual(vm.findMatchCount, 3, "setup: 3 occurrences of 'foo'")
        XCTAssertEqual(vm.findMatchIndex, 0, "starts at first match")
        vm.nextFindMatch()
        XCTAssertEqual(vm.findMatchIndex, 1)
        vm.nextFindMatch()
        XCTAssertEqual(vm.findMatchIndex, 2)
    }

    func test_nextFindMatch_wrapsAtLast() {
        // WHY: advancing past the last match must wrap to the first so the
        // user can keep pressing Cmd+G to cycle indefinitely.
        let vm = makeVM(withMatches: true)
        vm.nextFindMatch() // 0 -> 1
        vm.nextFindMatch() // 1 -> 2
        vm.nextFindMatch() // 2 -> 0 (wrap)
        XCTAssertEqual(vm.findMatchIndex, 0, "next past last wraps to first")
    }

    func test_prevFindMatch_wrapsAtFirst() {
        let vm = makeVM(withMatches: true)
        // WHY: pressing Shift+Cmd+G at the first match must wrap to the last
        // so the user can navigate backwards from any position.
        XCTAssertEqual(vm.findMatchIndex, 0)
        vm.prevFindMatch()
        XCTAssertEqual(vm.findMatchIndex, 2, "prev from first wraps to last")
    }

    func test_prevFindMatch_decrements() {
        let vm = makeVM(withMatches: true)
        vm.nextFindMatch() // 0 -> 1
        vm.prevFindMatch() // 1 -> 0
        XCTAssertEqual(vm.findMatchIndex, 0)
    }

    func test_noMatches_nextAndPrevAreNoOps() {
        let vm = DiffPanelViewModel(cwd: "/tmp", settings: nil, asyncLoad: false)
        vm.rawDiff = "some diff content"
        vm.findQuery = "zzz"
        // WHY: when there are no matches the cycler must not crash or set an
        // invalid index -- the UI would show garbage if it did.
        XCTAssertEqual(vm.findMatchCount, 0)
        XCTAssertEqual(vm.findMatchIndex, -1)
        vm.nextFindMatch()
        XCTAssertEqual(vm.findMatchIndex, -1, "next with no matches must not change index")
        vm.prevFindMatch()
        XCTAssertEqual(vm.findMatchIndex, -1, "prev with no matches must not change index")
    }

    func test_emptyQuery_resetsFindState() {
        let vm = makeVM(withMatches: true)
        XCTAssertEqual(vm.findMatchCount, 3)
        // WHY: clearing the query must immediately reset the count so the
        // "N of M" label disappears and no stale index is left over.
        vm.findQuery = ""
        XCTAssertEqual(vm.findMatchCount, 0)
        XCTAssertEqual(vm.findMatchIndex, -1)
    }

    func test_dismissFind_clearsAllState() {
        let vm = makeVM(withMatches: true)
        XCTAssertTrue(vm.findActive == false) // activateFind not called yet
        vm.activateFind()
        XCTAssertTrue(vm.findActive)
        vm.dismissFind()
        // WHY: dismissing find must leave no stale state that could re-trigger
        // a highlight on the next diff selection.
        XCTAssertFalse(vm.findActive)
        XCTAssertEqual(vm.findQuery, "")
        XCTAssertEqual(vm.findMatchCount, 0)
        XCTAssertEqual(vm.findMatchIndex, -1)
    }

    // MARK: findCurrentMatchLine

    func test_findCurrentMatchLine_returnsCorrectLine() {
        let vm = DiffPanelViewModel(cwd: "/tmp", settings: nil, asyncLoad: false)
        // Three lines; "target" is on line 1 (0-based).
        vm.rawDiff = "line0\ntarget text\nline2"
        vm.findQuery = "target"
        // WHY: the scroll-to-line logic depends on this returning the right
        // line index; if it's wrong the diff pane scrolls to the wrong place.
        XCTAssertEqual(vm.findMatchIndex, 0)
        XCTAssertEqual(vm.findCurrentMatchLine, 1, "target is on line 1")
    }

    func test_findCurrentMatchLine_nilWhenNoMatch() {
        let vm = DiffPanelViewModel(cwd: "/tmp", settings: nil, asyncLoad: false)
        vm.rawDiff = "some content"
        vm.findQuery = "zzz"
        XCTAssertNil(vm.findCurrentMatchLine, "no match -> nil line")
    }
}
