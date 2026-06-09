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
