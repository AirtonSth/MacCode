import AppKit
import DesignSystemKit
import SwiftUI
import XCTest
@testable import Surfaces

/// WHY: the transcript prose is drawn by an NSTextView, which ignores SwiftUI
/// `.font` / `.foregroundColor` runs and Foundation's inline intents. Headings,
/// bold, italic and code once all rendered as 13 pt body text because only
/// those were set, and `NSTextView.font =` then restyled the whole storage.
/// These tests read the attributes the text view really holds.
@MainActor
final class AgentMessageMarkdownRenderTests: XCTestCase {
    private func font(_ text: NSAttributedString, at token: String) throws -> NSFont {
        let range = (text.string as NSString).range(of: token)
        XCTAssertNotEqual(range.location, NSNotFound, "missing \(token)")
        return try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
    }

    /// Mounts the real markdown view and returns the storage of its first
    /// prose NSTextView.
    private func mountedProseStorage(_ markdown: String) throws -> NSAttributedString {
        let host = NSHostingView(rootView: AgentMessageMarkdownView(text: markdown).frame(width: 480))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 800)
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> IntrinsicHeightTextView? {
            if let textView = view as? IntrinsicHeightTextView { return textView }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        let textView = try XCTUnwrap(find(host), "the prose group must be an AppKit text view")
        return try XCTUnwrap(textView.textStorage)
    }

    func test_mountedTextViewKeepsHeadingSizeBoldItalicAndMonospacedCode() throws {
        let storage = try mountedProseStorage("# Title\n\nbody with `code`, **bold** and *soft*")
        let title = try font(storage, at: "Title")
        let body = try font(storage, at: "body")
        XCTAssertGreaterThan(title.pointSize, body.pointSize, "an H1 must be larger than body text")
        XCTAssertTrue(title.fontDescriptor.symbolicTraits.contains(.bold), "headings are heavier than body")
        let code = try font(storage, at: "code")
        XCTAssertTrue(code.isFixedPitch, "inline code must use a monospaced font")
        XCTAssertTrue(try font(storage, at: "bold").fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(try font(storage, at: "soft").fontDescriptor.symbolicTraits.contains(.italic))
        let codeLocation = (storage.string as NSString).range(of: "code").location
        XCTAssertNotNil(
            storage.attribute(AgentLinkedInlineTextRepresentable.inlineCodePillKey, at: codeLocation, effectiveRange: nil),
            "inline code is marked for the rounded pill background"
        )
    }

    func test_quotesListsTasksAndStrikethroughCarryTheirStyling() throws {
        let blocks = AgentMessageMarkdown.blocks(from: "> quoted\n\n- item\n- [x] done\n\n~~gone~~")
        let prose = AgentMessageMarkdown.selectableProse(from: blocks, compact: false, cache: false)
        let text = AgentLinkedInlineTextRepresentable.makeNSAttributedString(
            attributed: prose, font: .systemFont(ofSize: 13), textColor: DS.NS.text, lineSpacing: 5
        )
        let string = text.string as NSString
        let quote = string.range(of: "quoted").location
        XCTAssertEqual(
            (text.attribute(AgentMarkdownLayoutManager.quoteDepthKey, at: quote, effectiveRange: nil) as? NSNumber)?.intValue, 1,
            "the layout manager draws a bar for every quoted paragraph"
        )
        let quoteStyle = try XCTUnwrap(text.attribute(.paragraphStyle, at: quote, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThanOrEqual(quoteStyle.headIndent, AgentMessageMarkdown.quoteIndentStep, "quote text clears its bar")
        XCTAssertEqual(text.attribute(.foregroundColor, at: quote, effectiveRange: nil) as? NSColor, DS.NS.textSecondary)

        let item = string.range(of: "item").location
        let itemStyle = try XCTUnwrap(text.attribute(.paragraphStyle, at: item, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(itemStyle.headIndent, itemStyle.firstLineHeadIndent,
                             "wrapped lines hang under the item text, not under the bullet")
        XCTAssertNotEqual(string.range(of: "☑").location, NSNotFound, "a checked task shows a checkbox glyph")
        let gone = string.range(of: "gone").location
        XCTAssertEqual(text.attribute(.strikethroughStyle, at: gone, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
    }

    /// WHY: a soft break inside a list item must not start a new paragraph
    /// (which would drop the hanging indent and add block spacing mid-item).
    func test_softBreakStaysInsideTheParagraph() {
        let blocks = AgentMessageMarkdown.blocks(from: "- first\n  second")
        let prose = AgentMessageMarkdown.selectableProse(from: blocks, compact: false, cache: false)
        XCTAssertFalse(String(prose.characters).contains("\n"))
        XCTAssertTrue(String(prose.characters).contains("first\u{2028}second"))
    }

    /// WHY: rules, tables and code are not prose; a rule must be its own
    /// hairline view, not a "---" text line.
    func test_ruleTableAndCodeAreIsolatedGroups() {
        let groups = AgentMessageMarkdown.selectionGroups(from: AgentMessageMarkdown.blocks(
            from: "a\n\n---\n\n| x |\n|---|\n| 1 |\n\n```\nc\n```\n\nb"
        ))
        XCTAssertEqual(groups.map(\.count), [1, 1, 1, 1, 1])
        XCTAssertEqual(groups[1].first?.kind, .rule)
    }

    /// WHY: a wide table must keep readable columns (and scroll) instead of
    /// being crushed to the column width; alignment comes from the delimiter row.
    func test_tableLayoutKeepsNaturalWidthAndAlignment() throws {
        let headers = (0..<12).map { "Column header \($0)" }
        let built = AgentMarkdownTableLayout.build(
            headers: headers,
            rows: [headers.map { "value for \($0)" }],
            alignments: Array(repeating: .right, count: 12)
        )
        XCTAssertGreaterThan(built.width, 1_000, "twelve readable columns are wider than a chat column")
        let style = try XCTUnwrap(built.text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.alignment, .right)
        XCTAssertTrue(style.textBlocks.first is NSTextTableBlock)
    }

    /// WHY: the table's scroll view has no intrinsic height; if SwiftUI does
    /// not use our `sizeThatFits`, the table collapses to zero height.
    func test_mountedTableHasRealHeightAndHugsNarrowContent() {
        let host = NSHostingView(rootView: AgentMarkdownTableView(headers: ["A", "B"], rows: [["1", "2"]], alignments: [.none, .none])
            .frame(width: 400))
        host.layoutSubtreeIfNeeded()
        let oneRow = host.fittingSize.height
        XCTAssertGreaterThan(oneRow, 40, "header + one row must have height")
        let twoRows = NSHostingView(rootView: AgentMarkdownTableView(headers: ["A", "B"], rows: [["1", "2"], ["3", "4"]], alignments: [.none, .none])
            .frame(width: 400))
        twoRows.layoutSubtreeIfNeeded()
        XCTAssertEqual(twoRows.fittingSize.height - oneRow, oneRow / 2, accuracy: 2,
                       "each row adds one row height: no empty extra line under the table")
    }

    func test_codeBlockKeepsLanguageForItsLabel() {
        XCTAssertEqual(
            AgentMessageMarkdown.blocks(from: "```swift title=x\nlet a = 1\n```").first?.kind,
            .code(language: "swift")
        )
    }
}
