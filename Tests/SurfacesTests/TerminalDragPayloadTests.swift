import XCTest
import AppKit
@testable import Surfaces

// TerminalDragPayload and GhosttyTerminalView.canAcceptDrag are pure,
// nonisolated helpers; no @MainActor annotation is needed.
//
// WHY these tests matter: before this feature, dragging plain text onto the
// terminal was silently rejected by the drag-operation handlers, which only
// checked for file-URL drops. These tests prove the helper correctly resolves
// the three drag-payload cases (plain string, file URL, empty/unsupported)
// and that the PasteGuard semantics gate unsafe content consistently with
// keyboard paste — so a multi-line script dragged from a text editor cannot
// execute shell commands without the user's explicit confirmation.
final class TerminalDragPayloadTests: XCTestCase {

    // MARK: - TerminalDragPayload.plainText(from:)

    func test_plainText_returnsStringWhenPasteboardCarriesStringType() {
        // Plain-text drag (e.g. selected text dragged from a browser/editor) must
        // resolve to the same text so the user sees exactly what they dragged in
        // the terminal input.
        let pasteboard = makePasteboard()
        pasteboard.setString("echo hello", forType: .string)

        XCTAssertEqual(TerminalDragPayload.plainText(from: pasteboard), "echo hello",
            "plain-text drag payload must return the dragged string unchanged so it arrives in the terminal verbatim")
    }

    func test_plainText_returnsNilWhenPasteboardHasNoStringType() {
        // A pasteboard that carries only non-text content (e.g. an image) must
        // produce nil so the caller knows there is no usable text to send.
        let pasteboard = makePasteboard()

        XCTAssertNil(TerminalDragPayload.plainText(from: pasteboard),
            "a pasteboard with no .string type must return nil so the caller can fall back to other drag types")
    }

    func test_plainText_returnsFileURLPathWhenStringTypeContainsFileURL() {
        // When a pasteboard carries a file:// URL as a plain string (e.g. dragged
        // from some file managers that write the URL as a string type), plainText
        // returns it as-is; callers that need path resolution use DroppedFilePaths.
        let pasteboard = makePasteboard()
        pasteboard.setString("file:///tmp/readme.txt", forType: .string)

        XCTAssertEqual(TerminalDragPayload.plainText(from: pasteboard), "file:///tmp/readme.txt",
            "file:// URL stored as .string must be returned verbatim; path extraction is the caller's responsibility")
    }

    // MARK: - TerminalDragPayload.safeTextToSend(_:)

    func test_safeTextToSend_returnsTextForSingleLinePlainString() {
        // A single-line command with no control characters must be forwarded
        // immediately without blocking; this is the common drag-from-snippet case.
        XCTAssertEqual(TerminalDragPayload.safeTextToSend("ls -la"), "ls -la",
            "safe single-line text must be returned unchanged so it arrives in the PTY without extra confirmation")
    }

    func test_safeTextToSend_returnsTextForEmptyString() {
        // An empty drag payload is safe and must not trigger confirmation; sending
        // nothing is harmless.
        XCTAssertEqual(TerminalDragPayload.safeTextToSend(""), "",
            "empty drag payload must be classified as safe so no spurious confirm sheet appears")
    }

    func test_safeTextToSend_returnsNilForMultiLineDrag() {
        // Dragging a multi-line script onto the terminal must NOT send immediately
        // because each newline would execute a command in the shell. The nil return
        // value signals the caller to request confirmation before sending, matching
        // the same guard applied on Cmd+V keyboard paste.
        XCTAssertNil(TerminalDragPayload.safeTextToSend("echo a\necho b"),
            "multi-line drag must return nil to require confirmation, preventing silent execution of multiple commands")
    }

    func test_safeTextToSend_returnsNilForCarriageReturnDrag() {
        // CR-terminated content (Windows line endings) is also multi-line and must
        // be guarded; some code editors write CRLF content to the drag pasteboard.
        XCTAssertNil(TerminalDragPayload.safeTextToSend("cmd\r"),
            "CR-terminated drag must return nil so a Windows-line-ending script is not silently executed")
    }

    func test_safeTextToSend_returnsNilForControlCharacterDrag() {
        // Text containing ESC (0x1B) or other C0 control characters dragged from
        // a terminal log or clipboard must require confirmation; the characters
        // could change terminal state or inject keystrokes.
        XCTAssertNil(TerminalDragPayload.safeTextToSend("reset\u{1B}[2J"),
            "drag payload containing ESC must return nil so injected terminal escapes require explicit user confirmation")
    }

    func test_safeTextToSend_allowsTabCharacter() {
        // Horizontal tab is normal shell input (path completion, TSV data) and must
        // not block drag — consistent with PasteGuard.classify semantics for paste.
        XCTAssertEqual(TerminalDragPayload.safeTextToSend("col1\tcol2"), "col1\tcol2",
            "tab is valid shell input and must pass through without confirmation, matching PasteGuard paste semantics")
    }

    func test_safeTextToSend_allowsUnicodeText() {
        // Printable Unicode (emoji, accented chars) must be forwarded as-is; it
        // carries no shell-execution risk.
        XCTAssertEqual(TerminalDragPayload.safeTextToSend("echo \u{1F600}"), "echo \u{1F600}",
            "printable Unicode in a drag must be sent immediately without confirmation")
    }

    // MARK: - TerminalDragPayload.plainTextDropDecision(from:confirmationAvailable:)

    func test_plainTextDropDecision_sendsSafeTextImmediately() {
        let pasteboard = makePasteboard()
        pasteboard.setString("echo hello", forType: .string)

        XCTAssertEqual(TerminalDragPayload.plainTextDropDecision(from: pasteboard, confirmationAvailable: false),
                       .send("echo hello"),
                       "safe single-line drags should still reach the terminal without a confirmation sheet")
    }

    func test_plainTextDropDecision_confirmsUnsafeTextWhenHandlerIsAvailable() {
        let pasteboard = makePasteboard()
        pasteboard.setString("echo a\necho b", forType: .string)

        XCTAssertEqual(TerminalDragPayload.plainTextDropDecision(from: pasteboard, confirmationAvailable: true),
                       .confirm("echo a\necho b"),
                       "multi-line drags must route through confirmation instead of executing immediately")
    }

    func test_plainTextDropDecision_rejectsUnsafeTextWhenNoConfirmationHandlerIsAvailable() {
        let pasteboard = makePasteboard()
        pasteboard.setString("echo a\necho b", forType: .string)

        XCTAssertEqual(TerminalDragPayload.plainTextDropDecision(from: pasteboard, confirmationAvailable: false),
                       .reject,
                       "unsafe drags must never fall back to direct execution when no confirmation UI is wired")
    }

    // MARK: - GhosttyTerminalView.canAcceptDrag(from:)

    func test_canAcceptDrag_trueWhenPasteboardHasStringType() {
        // The drag-operation handlers must accept a .string pasteboard so the
        // view returns .copy and AppKit delivers the drop to performDragOperation.
        let pasteboard = makePasteboard()
        pasteboard.setString("hello", forType: .string)

        XCTAssertTrue(GhosttyTerminalView.canAcceptDrag(from: pasteboard),
            "a .string pasteboard must be accepted so plain-text drags land in the terminal instead of being silently rejected")
    }

    func test_canAcceptDrag_trueWhenPasteboardHasFileURL() {
        // File-URL drops must still be accepted after the plain-text addition;
        // this test guards against the new .string check accidentally replacing
        // the existing file-drop acceptance.
        let pasteboard = makePasteboard()
        XCTAssertTrue(pasteboard.writeObjects([NSURL(fileURLWithPath: "/tmp/test.txt")]))

        XCTAssertTrue(GhosttyTerminalView.canAcceptDrag(from: pasteboard),
            "file-URL drops must remain accepted after adding plain-text drag support")
    }

    func test_canAcceptDrag_falseWhenPasteboardHasNoUsableType() {
        // A pasteboard that carries only non-text, non-URL content must be rejected
        // so the terminal does not flash a drop highlight for unsupported content.
        let pasteboard = makePasteboard()

        XCTAssertFalse(GhosttyTerminalView.canAcceptDrag(from: pasteboard),
            "a pasteboard with no usable type must be rejected so the drag-operation handlers return [] and AppKit shows the no-drop cursor")
    }

    // MARK: - Helpers

    private func makePasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pb.clearContents()
        return pb
    }
}
