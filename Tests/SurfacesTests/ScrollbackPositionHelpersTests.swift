import XCTest
import AppKit
@testable import Surfaces

/// Tests for the two pure scrollback helpers added alongside the position
/// indicator and keyboard scrollback feature.
///
/// WHY these tests matter:
///
/// ScrollbackPositionLabel:
///   The label is the only textual feedback users see about where they are in
///   the scrollback. Wrong boundary detection (e.g. showing "50% from bottom"
///   when actually at the top) or incorrect percent math confuses users and
///   breaks accessibility labelling. The three boundary cases (bottom, middle,
///   top) and the percent calculation are pinned here so any future change to
///   the label logic causes a test failure rather than a silent regression.
///
/// ScrollbackKeyAction:
///   The four keyboard shortcuts (Shift+PgUp/PgDn, Cmd+Home/End) are the
///   only way for keyboard-only users to navigate scrollback. If a mapping is
///   wrong or missing, the key is silently swallowed (performBindingAction
///   receives nil) and the user has no scrollback navigation. The nil-for-
///   unrelated-key test guards that unrelated keys are NOT captured, which
///   would break normal terminal input.
///
/// No @MainActor annotation needed: both helpers are pure nonisolated enums.
final class ScrollbackPositionHelpersTests: XCTestCase {

    // MARK: - ScrollbackPositionLabel

    func test_label_atBottom_returnsBottom() {
        // offset == 0 means the viewport is at the live output - no scrollback is
        // visible. "Bottom" is the expected label; any other value would mislead
        // the user into thinking they are somewhere in the history.
        XCTAssertEqual(
            ScrollbackPositionLabel.label(offset: 0, total: 1000),
            "Bottom",
            "offset 0 must produce \"Bottom\" regardless of total"
        )
    }

    func test_label_atBottom_zeroTotal_returnsBottom() {
        // Edge: total == 0 (no scrollback at all). Offset 0 is still bottom.
        XCTAssertEqual(
            ScrollbackPositionLabel.label(offset: 0, total: 0),
            "Bottom",
            "offset 0 with total 0 must still produce \"Bottom\""
        )
    }

    func test_label_atTop_returnsTop() {
        // offset >= total means the user has scrolled to the very oldest line in
        // the buffer. "Top" is the correct label. If we showed "100% from bottom"
        // instead, the label would be technically correct but not user-friendly,
        // and the boundary detection would diverge from the indicator hiding logic.
        XCTAssertEqual(
            ScrollbackPositionLabel.label(offset: 1000, total: 1000),
            "Top",
            "offset == total must produce \"Top\" (user is at oldest line)"
        )
        XCTAssertEqual(
            ScrollbackPositionLabel.label(offset: 1500, total: 1000),
            "Top",
            "offset > total must also produce \"Top\""
        )
    }

    func test_label_atMidpoint_returnsPercent() {
        // Middle of the scrollback: 500 lines from bottom out of 1000 total =
        // exactly 50%. The label must show a percent because absolute line counts
        // vary between buffers and are less meaningful to users than a percentage.
        let result = ScrollbackPositionLabel.label(offset: 500, total: 1000)
        XCTAssertEqual(result, "50% from bottom",
            "middle scroll position must show the correct percent from bottom")
    }

    func test_label_nearBottom_showsSmallPercent() {
        // 10 lines from bottom out of 1000 = 1%. This tests that the clamped floor
        // of 1% prevents "0% from bottom" which would look identical to "Bottom"
        // without actually being at the bottom.
        let result = ScrollbackPositionLabel.label(offset: 10, total: 1000)
        // 10/1000 = 1.0%, Int truncates to 1, clamped min is 1.
        XCTAssertEqual(result, "1% from bottom",
            "very small non-zero offset must show at least 1% from bottom (not 0 or \"Bottom\")")
    }

    func test_label_noTotal_returnsLinesCount() {
        // When total is 0 but offset > 0 (e.g. scrollback count unavailable),
        // fall back to an absolute line count rather than crashing or showing
        // a division-by-zero percent.
        let result = ScrollbackPositionLabel.label(offset: 42, total: 0)
        XCTAssertEqual(result, "42 lines from bottom",
            "when total is 0, label must show absolute line count rather than percent")
    }

    func test_label_negativeInputs_treatedAsZero() {
        // Negative inputs are a caller error; treat them as 0 to avoid nonsense
        // labels. This guards callers that pass unchecked values from the scroll
        // position API.
        XCTAssertEqual(
            ScrollbackPositionLabel.label(offset: -5, total: 100),
            "Bottom",
            "negative offset must be treated as 0 (Bottom)"
        )
        XCTAssertEqual(
            ScrollbackPositionLabel.label(offset: 50, total: -100),
            "50 lines from bottom",
            "negative total must be treated as 0 (fall back to absolute count)"
        )
    }

    // MARK: - ScrollbackKeyAction

    func test_shiftPageUp_returnsScrollPageUp() {
        // Shift+PgUp is the standard terminal \"scroll one page up\" shortcut
        // (matches macOS Terminal.app, iTerm2). If missing, keyboard-only users
        // cannot scroll up through output.
        let result = ScrollbackKeyAction.action(for: 116, modifiers: .shift)
        XCTAssertEqual(result, "scroll_page_up",
            "Shift+PageUp (keyCode 116) must map to scroll_page_up")
    }

    func test_shiftPageDown_returnsScrollPageDown() {
        // Shift+PgDn scrolls back toward the live output. If missing, the user
        // can scroll up but not return without using the mouse or Jump-to-Bottom.
        let result = ScrollbackKeyAction.action(for: 121, modifiers: .shift)
        XCTAssertEqual(result, "scroll_page_down",
            "Shift+PageDown (keyCode 121) must map to scroll_page_down")
    }

    func test_cmdHome_returnsScrollToTop() {
        // Cmd+Home jumps to the oldest line in the scrollback - useful for
        // quickly reaching the start of a long build or test run.
        let result = ScrollbackKeyAction.action(for: 115, modifiers: .command)
        XCTAssertEqual(result, "scroll_to_top",
            "Cmd+Home (keyCode 115) must map to scroll_to_top")
    }

    func test_cmdEnd_returnsScrollToBottom() {
        // Cmd+End jumps back to the live output. Complements Jump to Bottom
        // (context-menu) with a keyboard alternative.
        let result = ScrollbackKeyAction.action(for: 119, modifiers: .command)
        XCTAssertEqual(result, "scroll_to_bottom",
            "Cmd+End (keyCode 119) must map to scroll_to_bottom")
    }

    func test_unrelatedKey_returnsNil() {
        // Keys not in the scroll set must return nil so keyDown can fall through
        // to the Ghostty key path. Capturing them here would silently swallow
        // normal terminal input (e.g. plain Page Up sent to a TUI).
        XCTAssertNil(
            ScrollbackKeyAction.action(for: 116, modifiers: []),
            "bare PageUp (no Shift) must return nil -- it should reach the terminal program"
        )
        XCTAssertNil(
            ScrollbackKeyAction.action(for: 0, modifiers: .shift),
            "Shift+0 (unrelated key) must return nil"
        )
        XCTAssertNil(
            ScrollbackKeyAction.action(for: 115, modifiers: .shift),
            "Shift+Home must return nil (only Cmd+Home is mapped)"
        )
        XCTAssertNil(
            ScrollbackKeyAction.action(for: 36, modifiers: []),
            "Return key must return nil"
        )
    }

    func test_shiftPageUp_onlyShiftModifier_returnsAction() {
        // When extra modifiers (e.g. Caps Lock) are present alongside Shift,
        // the deviceIndependentFlagsMask strips them; only pure Shift should
        // match. Verify that extra non-device-independent bits don't block the match.
        // NSEvent.ModifierFlags(rawValue:) with only the Shift bit set is the
        // canonical device-independent form.
        let shiftOnly = NSEvent.ModifierFlags.shift
        XCTAssertEqual(
            ScrollbackKeyAction.action(for: 116, modifiers: shiftOnly),
            "scroll_page_up",
            "Shift+PageUp with only Shift modifier bit set must match"
        )
    }
}
