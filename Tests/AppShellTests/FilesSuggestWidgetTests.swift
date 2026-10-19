import AppKit
import XCTest
@testable import AppShell

final class FilesSuggestWidgetTests: XCTestCase {
    private func entry(
        _ label: String,
        insert: String? = nil,
        source: SuggestEntry.Source = .languageServer,
        sortText: String? = nil,
        filterText: String? = nil
    ) -> SuggestEntry {
        SuggestEntry(
            label: label,
            insertText: insert ?? label,
            kind: .variable,
            detail: nil,
            documentation: nil,
            sortText: sortText,
            filterText: filterText,
            replaceRange: nil,
            source: source
        )
    }

    // MARK: Fuzzy

    func testFuzzyMatchesSubsequenceWithIndices() {
        // Fuzzy highlights must point at the matched letters so the UI bolds the right characters.
        let m = SuggestFuzzy.score(pattern: "pv", word: "printValue")
        XCTAssertEqual(m?.matches, [0, 5], "pv must match p at 0 and V at 5 for highlighting")
    }

    func testFuzzyRejectsNonSubsequence() {
        XCTAssertNil(SuggestFuzzy.score(pattern: "xyz", word: "printValue"), "non-subsequence must not appear in completions")
    }

    func testFuzzyRanksPrefixAboveInfix() {
        let prefix = SuggestFuzzy.score(pattern: "pri", word: "print")!.score
        let infix = SuggestFuzzy.score(pattern: "pri", word: "sprint")!.score
        XCTAssertGreaterThan(prefix, infix, "prefix matches must rank above infix matches so the likely item is first")
    }

    func testFuzzyEmptyPatternScoresZero() {
        XCTAssertEqual(SuggestFuzzy.score(pattern: "", word: "anything"), FuzzyMatch(score: 0, matches: []), "empty prefix must keep every item at zero score")
    }

    // MARK: Model

    func testModelSortsBySourceThenSortTextAndDedupes() {
        let entries = [
            entry("beta", source: .word),
            entry("beta2", insert: "beta", source: .languageServer),
            entry("alpha", source: .languageServer, sortText: "2"),
            entry("aardvark", source: .languageServer, sortText: "1"),
        ]
        let model = SuggestModel(entries: entries, prefix: "")
        XCTAssertEqual(model.items.map(\.label), ["aardvark", "alpha", "beta2"],
                       "language server items sort first by sortText; word item with duplicate insertText must be dropped")
    }

    func testModelUpdateNarrowsAndKeepsSelectionLabel() {
        var model = SuggestModel(entries: [entry("print"), entry("printValue"), entry("paint")], prefix: "p")
        model.selectNext()
        let selected = model.selected?.label
        model.update(prefix: "pri")
        XCTAssertEqual(model.items.map(\.label).sorted(), ["print", "printValue"], "narrowing must drop non-matching items")
        XCTAssertEqual(model.selected?.label, selected, "selection must stay on the same label while it still matches")
    }

    func testModelSelectionWrapsAndPageDownClamps() {
        var model = SuggestModel(entries: [entry("a"), entry("b"), entry("c")], prefix: "")
        model.selectPrevious()
        XCTAssertEqual(model.selectedIndex, 2, "selectPrevious from first must wrap to last")
        model.selectNext()
        XCTAssertEqual(model.selectedIndex, 0, "selectNext from last must wrap to first")
        model.pageDown(10)
        XCTAssertEqual(model.selectedIndex, 2, "pageDown must clamp to last item, not wrap")
        model.pageUp(10)
        XCTAssertEqual(model.selectedIndex, 0, "pageUp must clamp to first item, not wrap")
    }

    // MARK: Kind

    func testSuggestKindFromLspKind() {
        XCTAssertEqual(SuggestKind(lspKind: 2), .method)
        XCTAssertEqual(SuggestKind(lspKind: 7), .class)
        XCTAssertEqual(SuggestKind(lspKind: nil), .text, "missing LSP kind must fall back to text")
        XCTAssertEqual(SuggestKind(lspKind: 99), .text, "unknown LSP kind must fall back to text")
    }

    func testEveryKindHasSymbolImage() {
        for kind in SuggestKind.allCases {
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind) must have a symbol name")
            XCTAssertNotNil(NSImage(systemSymbolName: kind.symbolName, accessibilityDescription: nil),
                            "SF Symbol \(kind.symbolName) must exist for the kind icon")
        }
    }

    // MARK: Controller

    @MainActor
    func testControllerAcceptsSelectedItemAndHidesOnEscape() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(textView)

        let controller = SuggestWidgetController()
        var accepted: [SuggestEntry] = []
        controller.onAccept = { accepted.append($0) }

        controller.show(entries: [entry("alpha"), entry("beta"), entry("gamma")], prefix: "",
                        anchor: NSRect(x: 10, y: 100, width: 1, height: 16), in: textView)
        XCTAssertTrue(controller.isVisible, "widget must show when entries are non-empty")

        XCTAssertTrue(controller.handle(keyCode: 125), "down must be consumed while visible")
        XCTAssertTrue(controller.handle(keyCode: 36), "return must be consumed while visible")
        XCTAssertEqual(accepted.map(\.label), ["beta"], "return must accept the second item after one down press")
        XCTAssertFalse(controller.isVisible, "accepting must hide the widget")

        controller.show(entries: [entry("alpha")], prefix: "", anchor: NSRect(x: 10, y: 100, width: 1, height: 16), in: textView)
        var dismissed = 0
        controller.onDismiss = { dismissed += 1 }
        XCTAssertTrue(controller.handle(keyCode: 53), "escape must be consumed while visible")
        XCTAssertFalse(controller.isVisible, "escape must hide the widget")
        XCTAssertEqual(dismissed, 1, "escape must notify onDismiss so pending LSP results are dropped")
        XCTAssertFalse(controller.handle(keyCode: 125), "keys must not be consumed while hidden so the editor keeps them")
        XCTAssertEqual(accepted.count, 1, "escape must not accept anything")
    }

    @MainActor
    func testControllerUpdateHidesWhenNothingMatches() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(textView)

        let controller = SuggestWidgetController()
        controller.show(entries: [entry("alpha"), entry("beta")], prefix: "",
                        anchor: NSRect(x: 10, y: 100, width: 1, height: 16), in: textView)
        controller.update(prefix: "zzz")
        XCTAssertFalse(controller.isVisible, "typing a prefix with no matches must hide the widget")
    }

    // MARK: Ghost text

    func testGhostTextSplitsMultilineCompletion() {
        let result = GhostTextLayout.split("foo()\n  bar\nbaz")
        XCTAssertEqual(result.inline, "foo()", "first line must be the inline part after the caret")
        XCTAssertEqual(result.lines, ["  bar", "baz"], "following lines must render below, indentation kept")
    }

    func testGhostTextNextWordChunk() {
        XCTAssertEqual(GhostTextLayout.nextWordChunk("  value + 1"), "  value", "leading whitespace plus identifier must be one chunk")
        XCTAssertEqual(GhostTextLayout.nextWordChunk("(x)"), "(", "punctuation run must be accepted as its own chunk")
    }
}
