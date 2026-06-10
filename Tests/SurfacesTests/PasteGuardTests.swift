import XCTest
@testable import Surfaces

// PasteGuard is a pure, non-MainActor helper; no @MainActor annotation needed.
final class PasteGuardTests: XCTestCase {

    // MARK: - .safe cases

    func test_emptyString_isSafe() {
        XCTAssertEqual(PasteGuard.classify(""), .safe,
            "empty paste must be sent immediately; blocking it would prevent clearing the field")
    }

    func test_singleLinePlainText_isSafe() {
        XCTAssertEqual(PasteGuard.classify("ls -la"), .safe,
            "ordinary single-line shell command must be sent immediately without interrupting the user")
    }

    func test_textWithOnlyTabCharacter_isSafe() {
        XCTAssertEqual(PasteGuard.classify("col1\tcol2"), .safe,
            "horizontal tab is normal shell input (path completion, TSV) and must not trigger confirmation")
    }

    func test_printableUnicodeText_isSafe() {
        XCTAssertEqual(PasteGuard.classify("echo \u{1F600}"), .safe,
            "printable emoji and unicode must be pasted immediately; they carry no shell-execution risk")
    }

    // MARK: - .needsConfirm — multi-line

    func test_textWithNewline_needsConfirm_multiLine() {
        XCTAssertEqual(PasteGuard.classify("echo hello\necho world"), .needsConfirm(reason: "multi-line"),
            "pasting newlines executes commands immediately; the user must confirm before a second command runs")
    }

    func test_textWithCarriageReturn_needsConfirm_multiLine() {
        XCTAssertEqual(PasteGuard.classify("foo\rbar"), .needsConfirm(reason: "multi-line"),
            "carriage return also terminates a shell command; the confirmation sheet must fire for CR-terminated pastes")
    }

    func test_textWithCRLF_needsConfirm_multiLine() {
        XCTAssertEqual(PasteGuard.classify("line1\r\nline2"), .needsConfirm(reason: "multi-line"),
            "Windows-style CRLF line endings must be caught so multi-line scripts from Windows clipboard are guarded")
    }

    // MARK: - .needsConfirm — control characters

    func test_textWithESC_needsConfirm_controlChars() {
        XCTAssertEqual(PasteGuard.classify("reset\u{1B}[2J"), .needsConfirm(reason: "control-characters"),
            "ESC in a paste can inject terminal escape sequences that change mode or hijack state; confirmation required")
    }

    func test_textWithNUL_needsConfirm_controlChars() {
        XCTAssertEqual(PasteGuard.classify("abc\u{00}def"), .needsConfirm(reason: "control-characters"),
            "NUL byte in paste can terminate strings or confuse PTY framing; must be confirmed before sending")
    }

    func test_textWithEmbeddedCTRLC_needsConfirm_controlChars() {
        // ETX (0x03) = Ctrl-C
        XCTAssertEqual(PasteGuard.classify("hello\u{03}world"), .needsConfirm(reason: "control-characters"),
            "ETX embedded in paste would interrupt the shell as Ctrl-C; the user must explicitly confirm")
    }

    func test_textWithDEL_needsConfirm_controlChars() {
        XCTAssertEqual(PasteGuard.classify("ab\u{7F}c"), .needsConfirm(reason: "control-characters"),
            "DEL (0x7F) in paste would erase characters in shell line editing; confirmation required")
    }

    func test_textWithBEL_needsConfirm_controlChars() {
        // BEL = 0x07
        XCTAssertEqual(PasteGuard.classify("ring\u{07}"), .needsConfirm(reason: "control-characters"),
            "BEL is a non-printable control byte that could spam audible alerts; must be confirmed")
    }

    // MARK: - precedence (newline checked before control chars)

    func test_multiLineWithControlChars_reportsMultiLineReason() {
        // When both newline and control char are present, newline is found
        // first in a left-to-right scan; reason reflects the first trigger.
        XCTAssertEqual(PasteGuard.classify("cmd\n\u{1B}[H"), .needsConfirm(reason: "multi-line"),
            "the first dangerous character found determines the confirmation reason so the user sees the most prominent risk")
    }

    // MARK: - bracketedPasteEnabled default

    func test_bracketedPasteEnabledByDefault() {
        XCTAssertTrue(PasteGuard.bracketedPasteEnabled,
            "bracketed paste must be on by default so terminals can delimit paste content from typed input")
    }
}
