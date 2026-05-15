import XCTest
@testable import AppShell

/// Pure ranking contract for the command palette: tiering, case
/// insensitivity, stable ordering, and dropping non-matches.
final class CommandPaletteFilterTests: XCTestCase {

    func test_score_tiersFromExactToKeyword() {
        XCTAssertEqual(CommandPaletteFilter.score(query: "", title: "Anything"), 0,
                       "an empty query matches everything at the floor score")
        XCTAssertEqual(CommandPaletteFilter.score(query: "new", title: "new"), 100)
        XCTAssertEqual(CommandPaletteFilter.score(query: "new", title: "New Terminal"), 80)
        XCTAssertEqual(CommandPaletteFilter.score(query: "term", title: "New Terminal"), 60)
        XCTAssertEqual(CommandPaletteFilter.score(query: "shell", title: "New Terminal", subtitle: "open a shell"), 40)
        XCTAssertEqual(CommandPaletteFilter.score(query: "web", title: "Browser", keywords: ["web"]), 20)
        XCTAssertNil(CommandPaletteFilter.score(query: "zzz", title: "Browser", subtitle: "x", keywords: ["web"]),
                     "no match anywhere must be nil so the row is excluded")
    }

    func test_score_isCaseInsensitive() {
        XCTAssertEqual(CommandPaletteFilter.score(query: "NEW", title: "new terminal"), 80)
    }

    func test_rank_ordersByScoreThenStableInsertion() {
        let items = [("New Browser", "", ["web"]),
                     ("New Terminal", "", ["shell"]),
                     ("Terminal tricks", "", [])]
        let ranked = CommandPaletteFilter.rank(items, query: "terminal") { ($0.0, $0.1, $0.2) }
        XCTAssertEqual(ranked.map(\.0), ["Terminal tricks", "New Terminal"],
                       "title-prefix must outrank title-contains; non-matches dropped")
    }

    func test_rank_emptyQueryKeepsEverythingInInsertionOrder() {
        XCTAssertEqual(CommandPaletteFilter.rank(["a", "b", "c"], query: "") { ($0, "", []) },
                       ["a", "b", "c"])
    }
}
