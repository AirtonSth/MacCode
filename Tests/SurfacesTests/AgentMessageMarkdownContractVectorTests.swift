import XCTest
@testable import Surfaces

/// Contract §5 shared vectors (Mac ↔ iOS). Both platforms must produce the
/// same block structure for these inputs; a divergence means a reply reads
/// differently on the phone than on the Mac.
final class AgentMessageMarkdownContractVectorTests: XCTestCase {
    private typealias Block = AgentMessageMarkdownBlock

    /// Rendered inline text with in-paragraph breaks shown as "\n".
    private func plain(_ markdown: String) -> String {
        String(AgentMessageMarkdown.attributedInline(markdown).characters)
            .replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    // MARK: M1–M9

    /// WHY: emphasis that spans a soft line break used to be fine only by
    /// accident; it must stay one bold run, not literal `**` on two lines.
    func test_M1_headingThenParagraphWithBoldAcrossSoftBreak() throws {
        let blocks = AgentMessageMarkdown.blocks(from: "# T\n\nPara with **bold\nacross** lines.", cache: false)
        XCTAssertEqual(blocks, [
            Block(kind: .heading(1), text: "T"),
            Block(kind: .paragraph, text: "Para with **bold\nacross** lines."),
        ])
        let inline = AgentMessageMarkdown.attributedInline(blocks[1].text)
        let bold = inline.runs
            .filter { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
            .map { String(inline.characters[$0.range]) }
            .joined()
        XCTAssertEqual(
            bold.replacingOccurrences(of: "\u{2028}", with: " "), "bold across",
            "the bold run must cover both words around the soft break"
        )
        XCTAssertFalse(plain(blocks[1].text).contains("**"), "no literal asterisks may leak into the prose")
    }

    /// WHY: nesting follows the parent's text column (2 or 4 spaces), and
    /// task items must be checkboxes, not "[x]" text.
    func test_M2_nestedListDepthsThenTaskItems() {
        let blocks = AgentMessageMarkdown.blocks(from: "- a\n  - b\n    - c\n- [x] done\n- [ ] todo", cache: false)
        XCTAssertEqual(blocks.map(\.kind), [
            .bullet(indent: 0), .bullet(indent: 1), .bullet(indent: 2),
            .task(checked: true, indent: 0), .task(checked: false, indent: 0),
        ])
        XCTAssertEqual(blocks.map(\.text), ["a", "b", "c", "done", "todo"])
    }

    /// WHY: nested quotes and lists inside quotes used to render as plain
    /// text with a leading ">" or a single flat bar.
    func test_M3_nestedQuoteAndListInsideQuote() {
        let blocks = AgentMessageMarkdown.blocks(from: "> q1\n>> q2\n> - item", cache: false)
        XCTAssertEqual(blocks, [
            Block(kind: .blockquote, text: "q1", quoteDepth: 1),
            Block(kind: .blockquote, text: "q2", quoteDepth: 2),
            Block(kind: .bullet(indent: 0), text: "item", quoteDepth: 1),
        ])
    }

    /// WHY: ~~~ fences and 4+ backtick fences (used to show ``` inside code)
    /// used to fall through as prose and swallow the rest of the reply.
    func test_M4_tildeFenceAndFourBacktickFence() {
        let blocks = AgentMessageMarkdown.blocks(from: "~~~swift\nlet a = 1\n~~~\n````\n```inner```\n````", cache: false)
        XCTAssertEqual(blocks, [
            Block(kind: .code(language: "swift"), text: "let a = 1"),
            Block(kind: .code(language: ""), text: "```inner```"),
        ])
    }

    /// WHY: escaped pipes and pipes inside code used to split cells, and a
    /// short row used to shift every later column.
    func test_M5_tableAlignmentEscapedPipeCodePipeAndRaggedRow() throws {
        let blocks = AgentMessageMarkdown.blocks(
            from: "| L | C | R |\n|:--|:-:|--:|\n| a \\| b | `x|y` | z |\n| only |",
            cache: false
        )
        XCTAssertEqual(blocks.count, 1)
        guard case .table(let headers, let rows, let alignments) = blocks[0].kind else {
            return XCTFail("expected a table, got \(blocks[0].kind)")
        }
        XCTAssertEqual(headers, ["L", "C", "R"])
        XCTAssertEqual(alignments, [.left, .center, .right])
        XCTAssertEqual(rows.map { $0.map(plain) }, [["a | b", "x|y", "z"], ["only", "", ""]],
                       "rendered cells: escaped pipe literal, code pipe kept, ragged row padded")
    }

    func test_M6_horizontalRulesBetweenParagraphs() {
        let blocks = AgentMessageMarkdown.blocks(from: "text\n\n---\n\n***\n\nmore", cache: false)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .rule, .rule, .paragraph])
    }

    /// WHY: `![alt](src)` must leave the prose (the image shows in the
    /// gallery), bare image URLs stay links, and a link whose URL contains
    /// parentheses keeps its full target.
    func test_M7_imagesLeaveProseAndLinksKeepParentheses() throws {
        let source = "See ![shot](/tmp/a.png) and https://ex.com/b.JPG and [doc](https://ex.com/(x)/y)."
        XCTAssertEqual(plain(source), "See  and https://ex.com/b.JPG and doc.")
        let inline = AgentMessageMarkdown.attributedInline(source)
        let doc = try XCTUnwrap(inline.runs.first { String(inline.characters[$0.range]) == "doc" })
        XCTAssertEqual(doc.link?.absoluteString, "https://ex.com/(x)/y")
        XCTAssertEqual(
            AgentChatImageGallery.refs(text: source, attachments: []).map(\.ref),
            ["/tmp/a.png", "https://ex.com/b.JPG"]
        )
    }

    func test_M8_setextHeadingAndIndentedCode() {
        let blocks = AgentMessageMarkdown.blocks(from: "Title\n===\n\n    code line", cache: false)
        XCTAssertEqual(blocks, [
            Block(kind: .heading(1), text: "Title"),
            Block(kind: .code(language: ""), text: "code line"),
        ])
    }

    /// WHY: bold around a link (the PR card style agents use) must render as
    /// one bold, clickable "Draft PR #3109", not `**` around a link.
    func test_M9_boldLink() throws {
        let inline = AgentMessageMarkdown.attributedInline("**[Draft PR #3109](https://github.com/o/r/pull/3109)** ok")
        XCTAssertEqual(String(inline.characters), "Draft PR #3109 ok")
        let link = try XCTUnwrap(inline.runs.first { String(inline.characters[$0.range]) == "Draft PR #3109" })
        XCTAssertEqual(link.link?.absoluteString, "https://github.com/o/r/pull/3109")
        XCTAssertTrue(link.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    // MARK: Other §5 rules

    func test_setextLevelTwoAndRuleVariants() {
        XCTAssertEqual(AgentMessageMarkdown.blocks(from: "Sub\n---", cache: false).map(\.kind), [.heading(2)])
        for rule in ["___", "* * *", "- - -", "-----"] {
            XCTAssertEqual(AgentMessageMarkdown.blocks(from: "a\n\n\(rule)\n\nb", cache: false).map(\.kind),
                           [.paragraph, .rule, .paragraph], "\(rule) is a thematic break")
        }
    }

    /// WHY: a later paragraph of a list item must stay attached to its item,
    /// and an unindented line right after an item continues it (lazy).
    func test_multiParagraphAndLazyContinuationListItems() {
        let blocks = AgentMessageMarkdown.blocks(from: "1. a\n\n   more\n2. b\n- x\nlazy line", cache: false)
        XCTAssertEqual(blocks, [
            Block(kind: .numbered(number: 1, indent: 0), text: "a"),
            Block(kind: .listContinuation(indent: 0), text: "more"),
            Block(kind: .numbered(number: 2, indent: 0), text: "b"),
            Block(kind: .bullet(indent: 0), text: "x\nlazy line"),
        ])
    }

    func test_tabNestedListAndListInsideNestedQuote() {
        XCTAssertEqual(AgentMessageMarkdown.blocks(from: "- a\n\t- b", cache: false).map(\.kind),
                       [.bullet(indent: 0), .bullet(indent: 1)])
        XCTAssertEqual(AgentMessageMarkdown.blocks(from: ">> - deep", cache: false),
                       [Block(kind: .bullet(indent: 0), text: "deep", quoteDepth: 2)])
    }

    /// WHY: unbalanced markup must stay literal and must never swallow the
    /// content that follows it.
    func test_unbalancedMarkupDegradesToLiteralWithoutSwallowing() {
        let blocks = AgentMessageMarkdown.blocks(from: "**open and `tick\n\nnext para", cache: false)
        XCTAssertEqual(blocks.map(\.kind), [.paragraph, .paragraph])
        XCTAssertEqual(plain(blocks[0].text), "**open and `tick")
        XCTAssertEqual(plain(blocks[1].text), "next para")
    }

    func test_brIsALineBreakAndOtherRawHTMLStaysLiteralUnlinked() {
        let inline = AgentMessageMarkdown.attributedInline("a<br>b <span>x</span> c<BR/>d")
        XCTAssertEqual(String(inline.characters), "a\u{2028}b <span>x</span> c\u{2028}d")
        XCTAssertTrue(inline.runs.allSatisfy { $0.link == nil }, "`</span>` is markup, not a file path link")
    }

    func test_autolinksAndBareURLsWithParentheses() {
        let inline = AgentMessageMarkdown.attributedInline(
            "<https://a.b/c> https://en.wikipedia.org/wiki/Foo_(bar) (see https://x.com/a)"
        )
        let links = inline.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(links, ["https://a.b/c", "https://en.wikipedia.org/wiki/Foo_(bar)", "https://x.com/a"])
    }

    func test_tableEndsAtBlankLineAndExtraCellsAreDropped() {
        let blocks = AgentMessageMarkdown.blocks(from: "| a | b |\n|---|---|\n| 1 | 2 | 3 |\n\nafter", cache: false)
        guard case .table(_, let rows, _) = blocks.first?.kind else { return XCTFail("expected table") }
        XCTAssertEqual(rows, [["1", "2"]])
        XCTAssertEqual(blocks.last, Block(kind: .paragraph, text: "after"))
    }

    // MARK: Streaming

    /// WHY: the live row parses a cached stable prefix plus the growing tail;
    /// every prefix must equal a full parse, including inside ~~~ fences with
    /// blank lines, indented code, list continuations and quotes — or the
    /// reply would flicker / restructure while streaming.
    func test_liveSplitParseEqualsFullParseForNewConstructs() {
        let document = """
        Intro
        ===

        - item one

          continued item paragraph
        - item two

        ~~~text
        inside fence

        still fence
        ~~~

            indented code

            more code

        > quote
        >
        > - quoted item

        | a | b |
        |:-|-:|
        | 1 | 2 |

        ````
        ```
        ````

        tail **bold**
        """
        var text = ""
        for character in document {
            text.append(character)
            let live = AgentMessageMarkdown.blocks(from: text, cache: false)
            let full = AgentMessageMarkdown.blocks(from: text + "", cache: true)
            XCTAssertEqual(live, full, "prefix diverged at:\n\(text.suffix(80))")
            if live != full { return }
        }
    }

    func test_unclosedFenceRendersProgressivelyAsCode() {
        XCTAssertEqual(AgentMessageMarkdown.blocks(from: "Look:\n\n```py\nprint(1)\n\nprint(2)", cache: false), [
            Block(kind: .paragraph, text: "Look:"),
            Block(kind: .code(language: "py"), text: "print(1)\n\nprint(2)"),
        ])
    }

    /// WHY: an indented line after a blank line can still belong to the block
    /// above (list item, indented code), so a live chunk never starts there.
    func test_stableLiveChunksNeverStartAtAnIndentedLine() {
        let chunks = AgentMessageMarkdown.stableLiveChunks("- a\n\n  b\n\nc\n\n    code\n\nd\n")
        XCTAssertEqual(chunks.map(String.init), ["- a\n\n  b\n", "c\n\n    code\n", "d\n"])
    }
}
