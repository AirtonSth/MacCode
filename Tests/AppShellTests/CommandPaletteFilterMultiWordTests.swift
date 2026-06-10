import XCTest
@testable import AppShell

/// Verifies multi-word AND matching added in P2.
/// WHY: users type natural phrases like "term new" or "new term"; single-token
/// contiguous search excluded those items even though every word was present.
/// Rule: ALL space-separated tokens must match some field; one bad token -> nil.
final class CommandPaletteFilterMultiWordTests: XCTestCase {

    // MARK: - AND semantics

    func test_multiWord_bothTokensMatchTitle_returnsNonNil() {
        // "term new" — neither token is a contiguous prefix of "New Terminal"
        // but both are contained in the title. Must not return nil.
        XCTAssertNotNil(
            CommandPaletteFilter.score(query: "term new", title: "New Terminal"),
            "both tokens present in title -> should match"
        )
    }

    func test_multiWord_reversedTokenOrder_sameResult() {
        let fwd = CommandPaletteFilter.score(query: "new term", title: "New Terminal")
        let rev = CommandPaletteFilter.score(query: "term new", title: "New Terminal")
        XCTAssertNotNil(fwd)
        XCTAssertNotNil(rev)
        XCTAssertEqual(fwd, rev, "token order must not affect match/score")
    }

    func test_multiWord_oneTokenMissing_returnsNil() {
        // "term zzz" — \"zzz\" is absent from all fields; AND requires every token
        XCTAssertNil(
            CommandPaletteFilter.score(query: "term zzz", title: "New Terminal"),
            "one unmatched token must exclude the item"
        )
    }

    func test_multiWord_allTokensMissing_returnsNil() {
        XCTAssertNil(
            CommandPaletteFilter.score(query: "aaa bbb", title: "New Terminal"),
            "all tokens missing -> nil"
        )
    }

    func test_multiWord_tokenMatchesSubtitle_returnsNonNil() {
        // title has "term", subtitle has "shell"
        XCTAssertNotNil(
            CommandPaletteFilter.score(
                query: "term shell",
                title: "Terminal",
                subtitle: "open a shell session"
            ),
            "token may match subtitle; cross-field AND should succeed"
        )
    }

    func test_multiWord_tokenMatchesKeyword_returnsNonNil() {
        XCTAssertNotNil(
            CommandPaletteFilter.score(
                query: "new web",
                title: "New Browser",
                keywords: ["web", "internet"]
            ),
            "second token matched via keyword -> include"
        )
    }

    // MARK: - Score is minimum of per-token scores (weakest link)

    func test_multiWord_scoreIsMinOfTokenScores() {
        // "new" prefix-matches \"New Terminal\" -> 80
        // "term" contains-matches \"New Terminal\" -> 60
        // multi-word score must be min(80, 60) = 60
        let s = CommandPaletteFilter.score(query: "new term", title: "New Terminal")
        XCTAssertEqual(s, 60, "multi-word score = min of per-token scores (weakest link)")
    }

    // MARK: - Single-token path unchanged

    func test_singleToken_behaviorUnchanged_prefix() {
        XCTAssertEqual(
            CommandPaletteFilter.score(query: "new", title: "New Terminal"),
            80,
            "single token: prefix tier (80) must be preserved"
        )
    }

    func test_multiWord_exactFullTitleQuery_scoreIsMinOfTokens() {
        // query="new terminal" title="new terminal": two tokens -> multi-word path.
        // "new" prefix-matches -> 80; "terminal" contains-matches -> 60. min=60.
        // WHY: multi-word AND splits on spaces; exact-100 tier only fires in
        // single-token path when the whole trimmed query equals the title.
        XCTAssertEqual(
            CommandPaletteFilter.score(query: "new terminal", title: "new terminal"),
            60,
            "two-token query: score = min(80,60) = 60, not 100"
        )
    }

    // MARK: - Empty query still returns 0 (all-pass)

    func test_emptyQuery_returnsZero() {
        XCTAssertEqual(
            CommandPaletteFilter.score(query: "", title: "New Terminal"),
            0,
            "empty query must match everything at floor score 0"
        )
    }

    // MARK: - rank integration

    func test_rank_multiWord_filtersAndOrders() {
        let items = [
            ("New Terminal", "", [String]()),
            ("New Browser",  "", ["web"]),
            ("Settings",     "", [])
        ]
        let ranked = CommandPaletteFilter.rank(items, query: "new term") { ($0.0, $0.1, $0.2) }
        // Only \"New Terminal\" matches both tokens; others excluded
        XCTAssertEqual(ranked.map(\.0), ["New Terminal"],
                       "rank must exclude items that fail multi-word AND")
    }

    func test_rank_multiWord_emptyQuery_keepAll() {
        let items = ["a", "b", "c"]
        XCTAssertEqual(
            CommandPaletteFilter.rank(items, query: "   ") { ($0, "", []) },
            ["a", "b", "c"],
            "whitespace-only query treated as empty -> all items in insertion order"
        )
    }
}
