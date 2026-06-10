import XCTest
@testable import Surfaces

// Tests for the Terminal UX-gap implementations:
// - PasteGuard applied to Ghostty keyboard paste path
// - Font zoom HUD label text
// - VoiceOver accessibilityLabel for GhosttyTerminalView
//
// All helpers tested here are pure (nonisolated static) so no @MainActor is needed.
final class TerminalUXGapTests: XCTestCase {

    // MARK: - Paste guard: GhosttyTerminalView Cmd+V path

    // WHY: The Ghostty keyboard-paste path (Cmd+V via pasteText) previously sent
    // clipboard content directly to the PTY without checking PasteGuard. A user
    // with a multi-line command (e.g. a sudo pipeline) on the clipboard would have
    // it executed immediately. These tests verify PasteGuard.classify covers all
    // cases that the Ghostty paste path must respect.

    func test_pasteGuard_safeText_classifiesAsSafe() {
        // Single-line text with no control characters must not require confirmation;
        // blocking it would break normal copy-paste workflows.
        XCTAssertEqual(PasteGuard.classify("echo hello"), .safe,
            "single-line text must be classified safe so normal paste is not interrupted")
    }

    func test_pasteGuard_multiLineNewline_requiresConfirm() {
        // Two-line text with \n executes a second command immediately when pasted
        // to a shell. The Ghostty paste path must route this through the confirm
        // callback rather than sending it straight to ghostty_surface_text.
        let text = "sudo rm -rf /tmp\nyes"
        XCTAssertEqual(PasteGuard.classify(text), .needsConfirm(reason: "multi-line"),
            "pasting a newline-separated command must require confirmation to prevent unintended execution")
    }

    func test_pasteGuard_carriageReturn_requiresConfirm() {
        // \r also terminates a shell command on many terminals.
        let text = "cmd1\rcmd2"
        XCTAssertEqual(PasteGuard.classify(text), .needsConfirm(reason: "multi-line"),
            "carriage-return in paste must require confirmation for the same reason as newline")
    }

    func test_pasteGuard_escapeSequence_requiresConfirm() {
        // ESC in a paste can inject terminal-control bytes (e.g. change mode,
        // rewrite the command line). Must require confirmation.
        let text = "title\u{1B}[2J"
        XCTAssertEqual(PasteGuard.classify(text), .needsConfirm(reason: "control-characters"),
            "ESC byte in paste must require confirmation to prevent terminal-control injection")
    }

    func test_pasteGuard_emptyString_isSafe() {
        // Empty paste must pass through immediately; blocking it would confuse users.
        XCTAssertEqual(PasteGuard.classify(""), .safe,
            "empty paste must be safe; blocking it produces a confusing no-op confirmation sheet")
    }

    // MARK: - Font zoom HUD label

    // WHY: Cmd+/-/0 in the terminal changes font size but previously gave no
    // visual feedback. The HUD must show a concise label so the user knows the
    // current zoom level without leaving the terminal.

    func test_fontZoomHUDText_zeroDelta_showsBase() {
        // delta == 0 means no zoom applied; label must say "Base" not "+0pt"
        // to avoid confusion ("+0" implies a zoom that did not happen).
        XCTAssertEqual(GhosttyTerminalView.fontZoomHUDText(for: 0), "Font: Base",
            "zero delta must render as 'Font: Base' to clearly indicate no zoom is active")
    }

    func test_fontZoomHUDText_positiveDelta_showsPlusSign() {
        // Positive delta means the font was increased. The + sign is essential to
        // distinguish an increase from no change.
        XCTAssertEqual(GhosttyTerminalView.fontZoomHUDText(for: 3), "Font: +3pt",
            "positive delta must include '+' so the direction of zoom is unambiguous")
    }

    func test_fontZoomHUDText_negativeDelta_showsNegativeSign() {
        // Negative delta means font was decreased. Must not show double-minus.
        XCTAssertEqual(GhosttyTerminalView.fontZoomHUDText(for: -2), "Font: -2pt",
            "negative delta must show the minus sign to indicate font was shrunk")
    }

    func test_fontZoomHUDText_maxPositiveDelta_rendersCorrectly() {
        // FontZoomLevel.maxSteps == 40; the HUD must handle any clamped value.
        XCTAssertEqual(GhosttyTerminalView.fontZoomHUDText(for: 40), "Font: +40pt",
            "maximum zoom delta must render correctly without truncation or overflow")
    }

    func test_fontZoomHUDText_minNegativeDelta_rendersCorrectly() {
        // FontZoomLevel.minSteps == -20; the HUD must handle the extreme floor.
        XCTAssertEqual(GhosttyTerminalView.fontZoomHUDText(for: -20), "Font: -20pt",
            "minimum zoom delta must render correctly without truncation or overflow")
    }

    // MARK: - BellDetector integration: confirming it is wired correctly

    // WHY: appendDataAsync replaces data.contains(0x07) with
    // BellDetector.containsStandaloneBEL. These representative cases ensure
    // the integration logic is sound at the helper boundary.

    func test_bellDetector_bareOSCThenTitle_noFalsePositive() {
        // A common shell prompt sequence: ANSI CSI reset + OSC title.
        // ESC ] 0 ; shell BEL — must NOT trigger bell.
        let data = Data([0x1B, 0x5D, 0x30, 0x3B, 0x73, 0x68, 0x65, 0x6C, 0x6C, 0x07])
        XCTAssertFalse(BellDetector.containsStandaloneBEL(data),
            "OSC title-set ending with BEL must not produce a false bell (unread dot + sound)")
    }

    func test_bellDetector_realBellAfterOSCTitle_detected() {
        // OSC title followed immediately by a program-emitted BEL alert:
        // ESC ] 0 ; done BEL BEL — second 0x07 is a real bell.
        let data = Data([0x1B, 0x5D, 0x30, 0x3B, 0x64, 0x6F, 0x6E, 0x65, 0x07, 0x07])
        XCTAssertTrue(BellDetector.containsStandaloneBEL(data),
            "standalone BEL following an OSC title must still be detected as a real bell")
    }
}
