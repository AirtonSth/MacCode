import XCTest
import AppKit
@testable import Surfaces

/// QA-mac:27 -- view-level NSTextInputClient contract for GhosttyTerminalView.
///
/// WHY: dead-key / IME composition (~ then a -> a, ' then e -> e, CJK candidates)
/// was previously only guarded by path-selection tests in TerminalEncodeTests --
/// nothing pinned the AppKit-facing preedit state machine itself. The live
/// ghostty_surface_preedit render call still needs the gated Ghostty harness
/// (QA-mac:47), but the decision logic the methods route through -- input
/// normalization, the "insert/unmark clears the composing preedit" rule, and the
/// marked range -- is pure and is exercised here directly.
final class GhosttyIMEPreeditTests: XCTestCase {

    // MARK: input normalization (shared by setMarkedText + insertText)

    func test_plainString_extractsFromStringAndAttributedString() {
        XCTAssertEqual(GhosttyTerminalView.plainString(from: "~"), "~",
                       "a plain String must pass through unchanged")
        let attr = NSAttributedString(string: "e\u{0301}") // combining acute
        XCTAssertEqual(GhosttyTerminalView.plainString(from: attr), "e\u{0301}",
                       "an NSAttributedString must yield its backing string (IME often delivers attributed)")
    }

    func test_plainString_rejectsNonTextPayload() {
        XCTAssertNil(GhosttyTerminalView.plainString(from: 42),
                     "non-text Any must be rejected so we never send garbage to the surface")
    }

    // MARK: preedit transitions -- the dead-key fix

    func test_setMarked_showsComposingText() {
        XCTAssertEqual(GhosttyTerminalView.nextPreedit(for: .setMarked("~")), "~",
                       "setMarkedText must surface the in-progress dead key as the preedit")
        XCTAssertEqual(GhosttyTerminalView.nextPreedit(for: .setMarked(NSAttributedString(string: "\u{3042}"))), "\u{3042}",
                       "CJK composition delivered as attributed text must still render as preedit")
    }

    func test_insert_clearsPreedit_theDeadKeyFix() {
        // The regression this guards: committing a character (~ then a -> a) must
        // DROP the in-progress preedit first. If this ever returns the composing
        // text instead of "", the dead key stays rendered next to the result.
        XCTAssertEqual(GhosttyTerminalView.nextPreedit(for: .insert), "",
                       "insertText must clear the preedit before committing -- the dead-key/IME fix")
    }

    func test_unmark_clearsPreedit() {
        XCTAssertEqual(GhosttyTerminalView.nextPreedit(for: .unmark), "",
                       "unmarkText must clear the composing preedit")
    }

    func test_setMarked_nonTextPayloadClearsRatherThanCrashing() {
        XCTAssertEqual(GhosttyTerminalView.nextPreedit(for: .setMarked(99)), "",
                       "a non-text marked payload must collapse to an empty preedit, never propagate")
    }

    // MARK: markedRange

    func test_markedRange_emptyIsNotFound() {
        let r = GhosttyTerminalView.markedRange(forPreedit: "")
        XCTAssertEqual(r.location, NSNotFound,
                       "no composition -> NSNotFound so AppKit knows there is no marked text")
        XCTAssertEqual(r.length, 0)
    }

    func test_markedRange_usesNSStringLengthForMultibyte() {
        // markedRange must report UTF-16 (NSString) length, not Character count,
        // or AppKit's candidate-window placement drifts for multibyte composition.
        let emoji = "\u{1F600}" // 1 Character, 2 UTF-16 code units
        let r = GhosttyTerminalView.markedRange(forPreedit: emoji)
        XCTAssertEqual(r.location, 0)
        XCTAssertEqual(r.length, (emoji as NSString).length,
                       "marked range length must match NSString (UTF-16) length, not Character count")
        XCTAssertEqual(r.length, 2, "a single emoji is 2 UTF-16 code units")
    }
}
