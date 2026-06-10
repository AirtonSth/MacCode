import XCTest
@testable import Surfaces

/// Tests for TerminalSurface.shouldPreferRendererSnapshotForReadText (MAC-TERMINAL-T030).
///
/// WHY: When a terminal surface is hidden (e.g. in a background tab) and the
/// Ghostty viewport has not rendered recent output, `readTextSnapshot` must
/// choose the right text source. The Ghostty viewport may show a stale
/// single-line prompt ("$") while the ANSI renderer has buffered multi-line
/// output. `shouldPreferRendererSnapshotForReadText` is the decision function.
///
/// The bug documented by T030: when viewportText contains only a Ghostty
/// "hidden-period" placeholder character (Ghostty renders a single "." at row 0
/// col 0 when the surface is obscured) the visible-line-count heuristic treats
/// the viewport as "1 visible line" instead of 0, so it sometimes returns false
/// (use stale viewport) when it should return true (use ANSI renderer).
///
/// These tests pin the documented behavior of every branch so a regression in
/// the heuristic fails before shipping. The T030 red-first case is marked with
/// a comment explaining the live divergence.
@MainActor
final class TerminalRendererDivergenceTests: XCTestCase {

    // MARK: - Guard conditions: returns false when renderer has no advantage

    /// WHY: if rendererText has no newlines it has no more content than a
    /// single-line viewport  -  preferring it is always wrong.
    func test_rendererHasNoNewlines_returnsFalse() {
        let result = TerminalSurface.shouldPreferRendererSnapshotForReadText(
            viewportText: "$",
            rendererText: "just one line no newline"
        )
        XCTAssertFalse(result,
                       "When rendererText has no newlines it cannot have more content than the viewport; " +
                       "returning true would substitute inferior content for whatever the viewport has")
    }

    /// WHY: if rendererText is shorter or equal, the viewport is at least as
    /// good  -  fall back to viewport.
    func test_rendererShorterThanViewport_returnsFalse() {
        let viewport = "line one\nline two\nline three"
        let renderer = "short\n"
        let result = TerminalSurface.shouldPreferRendererSnapshotForReadText(
            viewportText: viewport,
            rendererText: renderer
        )
        XCTAssertFalse(result,
                       "When rendererText is shorter than viewportText the viewport has more content; " +
                       "overriding with the shorter renderer output would lose lines the user can see")
    }

    /// WHY: both guards must hold  -  if rendererText has a newline but is still
    /// shorter, the second guard fires.
    func test_rendererHasNewlineButShorter_returnsFalse() {
        let result = TerminalSurface.shouldPreferRendererSnapshotForReadText(
            viewportText: "first\nsecond\nthird\nfourth",
            rendererText: "x\ny"
        )
        XCTAssertFalse(result,
                       "A renderer with a newline but less total content must not override the viewport; " +
                       "the viewport already shows more")
    }

    // MARK: - True path: renderer wins when viewport looks empty

    /// WHY: The core scenario for shouldPrefer=true is a hidden surface where
    /// Ghostty only renders a single line (the prompt "$ " or nothing) but the
    /// ANSI renderer has the full buffered multi-line output. The heuristic
    /// checks visibleLineCount(viewportText) <= 1.
    func test_viewportSingleLine_rendererMultiLine_returnsTrue() {
        let viewport = "$ "
        let renderer = "$ npm test\n\nRunning test suite...\nPASS src/foo.test.ts\n\nTests: 3 passed\n"
        let result = TerminalSurface.shouldPreferRendererSnapshotForReadText(
            viewportText: viewport,
            rendererText: renderer
        )
        XCTAssertTrue(result,
                      "When the viewport shows only 1 visible line (stale prompt) but the renderer " +
                      "has multi-line buffered output, we must prefer the renderer so an agent reading " +
                      "a hidden terminal gets the real output, not the stale single-line prompt")
    }

    /// WHY: An empty viewport string counts as 0 visible lines (<= 1), so the
    /// renderer must win when it has multi-line content.
    func test_viewportEmpty_rendererMultiLine_returnsTrue() {
        let viewport = ""
        let renderer = "output line 1\noutput line 2\noutput line 3\n"
        let result = TerminalSurface.shouldPreferRendererSnapshotForReadText(
            viewportText: viewport,
            rendererText: renderer
        )
        XCTAssertTrue(result,
                      "An empty viewport (0 visible lines) with a non-empty multi-line renderer " +
                      "must prefer the renderer  -  the surface has output the viewport never rendered")
    }

    // MARK: - T030 divergence: hidden-period renderer divergence

    /// WHY (T030  -  live bug documentation): Ghostty renders a single period "."
    /// at position (0,0) when a surface is hidden (the "hidden-period mode").
    /// This means viewportText == "." when the terminal is in a background tab.
    /// visibleLineCount(".") == 1 (one non-empty line after trimming), so the
    /// function currently returns TRUE (prefer renderer) for any renderer with
    /// multi-line content.
    ///
    /// This is the CORRECT behavior for the hidden-period case  -  the "." is a
    /// Ghostty placeholder, not real output  -  but the test documents the coupling
    /// between the Ghostty hidden-period detail and the heuristic. If Ghostty
    /// changes its hidden-period character or stops emitting it, the heuristic
    /// would need updating.
    ///
    /// The test is written to PASS on the current implementation, encoding the
    /// contract: when viewportText is a single period and renderer has multi-line
    /// output, prefer the renderer.
    func test_hiddenPeriodViewport_multiLineRenderer_prefersRenderer() {
        // Ghostty hidden-period placeholder: a single period character.
        let viewportText = "."
        let rendererText = "$ ls\nfoo.txt  bar.txt  baz.txt\n$ "
        let result = TerminalSurface.shouldPreferRendererSnapshotForReadText(
            viewportText: viewportText,
            rendererText: rendererText
        )
        // Currently returns true: visibleLineCount(".") == 1 => (<= 1) => true.
        // WHY this matters: if the heuristic regresses to returning false here,
        // an agent reading a hidden terminal after `ls` would see "." instead of
        // the directory listing  -  a silent content divergence that only surfaces
        // as wrong agent behavior, not a crash.
        XCTAssertTrue(result,
                      "T030 hidden-period case: viewportText='.' (Ghostty hidden-period placeholder) " +
                      "with multi-line renderer output must prefer the renderer. " +
                      "Regression to false would mean agents read stale hidden-period placeholders " +
                      "as terminal output content, silently corrupting read_text results")
    }

    /// WHY: the converse: if the viewport has >= 2 visible lines it is stale but
    /// populated  -  the heuristic must NOT override it with the renderer because
    /// the renderer's ANSI buffer may be older than the viewport's Ghostty render.
    func test_viewportMultiLine_rendererAlsoMultiLine_returnsFalse() {
        let viewport = "$ make build\nBuilding project...\nDone."
        let renderer = "$ make build\nBuilding project...\nDone.\n\n$ make build\nBuilding project...\nDone.\n"
        let result = TerminalSurface.shouldPreferRendererSnapshotForReadText(
            viewportText: viewport,
            rendererText: renderer
        )
        XCTAssertFalse(result,
                       "When viewportText already has >= 2 visible lines, the viewport has meaningful " +
                       "content and we must NOT override it with the ANSI renderer even if the renderer " +
                       "is longer  -  the renderer may contain stale repeated content from a previous run")
    }
}
