import XCTest
import AppKit
@testable import Surfaces

/// IMP-010: verifies the testable seam for the code-block copy button.
///
/// The copy button in AgentMessageMarkdownView delegates the actual pasteboard
/// write to `AgentMessageMarkdown.copyCodeToPasteboard(_:)` so the action can
/// be exercised in tests without instantiating a SwiftUI view.
///
/// Assertions encode *why*: a user clicking "Copy" on a code block must receive
/// exactly the fenced code text on their pasteboard — not empty, not truncated,
/// not mixed with other content. If the helper ever stops writing to the general
/// pasteboard, or writes the wrong string, these tests catch the regression.
@MainActor
final class AgentMessageMarkdownCopyTests: XCTestCase {

    // Clear the pasteboard before each test so state from previous tests or
    // other running processes cannot produce false positives.
    override func setUp() {
        super.setUp()
        NSPasteboard.general.clearContents()
    }

    func test_copyCodeToPasteboard_writesCodeStringToGeneralPasteboard() {
        let code = "let x = 42\nprint(x)"

        AgentMessageMarkdown.copyCodeToPasteboard(code)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            code,
            "copyCodeToPasteboard must write the exact code text to NSPasteboard.general so the user gets what they see in the block"
        )
    }

    func test_copyCodeToPasteboard_replacesAnyPreviousContent() {
        // A prior copy action (or another app) already placed something on the pasteboard.
        NSPasteboard.general.setString("old content", forType: .string)

        let newCode = "func greet() { print(\"hello\") }"
        AgentMessageMarkdown.copyCodeToPasteboard(newCode)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            newCode,
            "copyCodeToPasteboard must replace pre-existing pasteboard content so the user always gets the most recently copied block"
        )
    }

    func test_copyCodeToPasteboard_handlesEmptyString() {
        // An empty code fence (``` ```) should still produce a valid pasteboard write
        // rather than crashing or silently failing; the resulting string is empty.
        AgentMessageMarkdown.copyCodeToPasteboard("")

        // NSPasteboard.setString("", …) may return nil for the string read-back on
        // some macOS versions; accept either empty string or nil as valid outcomes —
        // the key invariant is that calling the function on an empty string does not crash.
        let result = NSPasteboard.general.string(forType: .string)
        // nil or "" are both acceptable; anything else is wrong.
        XCTAssertTrue(
            result == nil || result == "",
            "copyCodeToPasteboard with empty input must not leave unexpected content on the pasteboard; got: \(result ?? "nil")"
        )
    }

    /// WHY: wrapping AgentMessageMarkdownView in SwiftUI `.textSelection`
    /// installs SelectionOverlay (NSTextField) on every Text child. The
    /// 2026-08-12 hang sample spent the entire main-thread quantum in
    /// SelectionOverlay.updateNSView → setFont → invalidateIntrinsicContentSize.
    func test_assistantProseDoesNotWrapMarkdownInSwiftUITextSelection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func assistantProse("))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "private func assistantCopyBar"))
        let prose = String(tail[..<end.lowerBound])
        XCTAssertTrue(prose.contains("AgentMessageMarkdownView("))
        XCTAssertFalse(
            prose.contains(".textSelection(.enabled)"),
            "selection belongs on AgentLinkedInlineText NSTextView, not a SwiftUI overlay around the markdown stack"
        )
    }

    func test_reasoningAndToolHotPathsAvoidSwiftUITextSelection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )

        let reasoningStart = try XCTUnwrap(source.range(of: "if expanded, !text.isEmpty {"))
        let reasoningTail = source[reasoningStart.lowerBound...]
        let reasoningEnd = try XCTUnwrap(reasoningTail.range(of: "accessibilityIdentifier(\"agent.reasoning."))
        let reasoning = String(reasoningTail[..<reasoningEnd.lowerBound])
        XCTAssertTrue(reasoning.contains("AgentSelectablePlainText("))
        XCTAssertFalse(
            reasoning.contains(".textSelection(.enabled)"),
            "streaming Thought must not install SelectionOverlay; it is always expanded while streaming"
        )

        let summaryStart = try XCTUnwrap(source.range(of: "if let summary = commandSummary, !summary.isEmpty {"))
        let summaryTail = source[summaryStart.lowerBound...]
        let summaryEnd = try XCTUnwrap(summaryTail.range(of: "if let activityHint {"))
        let summary = String(summaryTail[..<summaryEnd.lowerBound])
        XCTAssertFalse(
            summary.contains(".textSelection(.enabled)"),
            "always-visible tool summaries must not create a SelectionOverlay per live work row"
        )
    }

    func test_applyExternalTextDefersCursorPublish() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "func applyExternalText(_ value: String, to textView: NSTextView)"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "func recalculateHeight()"))
        let apply = String(tail[..<end.lowerBound])
        let asyncRange = try XCTUnwrap(apply.range(of: "DispatchQueue.main.async"))
        let cursorRange = try XCTUnwrap(apply.range(of: "onCursorMoved(endOffset)"))
        XCTAssertLessThan(
            asyncRange.lowerBound,
            cursorRange.lowerBound,
            "cursor publish from applyExternalText must run on a later turn than updateNSView"
        )
    }

    func test_markdownCodeBlockDoesNotUseSwiftUITextSelection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Surfaces/AgentMessageMarkdown.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "case .code:"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "private func headingSize"))
        let codeBlock = String(tail[..<end.lowerBound])
        XCTAssertTrue(
            codeBlock.contains("AgentLinkedInlineText("),
            "code fences must use the NSTextView path so parent refreshes can no-op"
        )
        XCTAssertFalse(
            codeBlock.contains(".textSelection(.enabled)"),
            "SwiftUI textSelection on fenced code is the SelectionOverlay that froze the transcript"
        )
    }

    func test_fileEditDiffCardDoesNotWrapLinesInSwiftUITextSelection() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/Surfaces/AgentMessageMarkdown.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "struct AgentFileEditDiffCard: View {"))
        let tail = source[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "private func diffLineRow"))
        let card = String(tail[..<end.lowerBound])
        XCTAssertFalse(
            card.contains(".textSelection(.enabled)"),
            "a parent SelectionOverlay over N diff lines is the same setFont loop as assistant markdown"
        )
    }

    func test_copyCodeToPasteboard_preservesMultilineCode() {
        let multiline = """
        import Foundation

        struct Foo {
            var bar: String
        }
        """

        AgentMessageMarkdown.copyCodeToPasteboard(multiline)

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            multiline,
            "copyCodeToPasteboard must preserve newlines in multi-line code blocks exactly as rendered"
        )
    }
}
