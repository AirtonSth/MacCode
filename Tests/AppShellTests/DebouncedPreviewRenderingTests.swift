import XCTest
@testable import AppShell

/// Tests for the two pure helpers that gate debounced preview renders and carry scroll-restore
/// tokens across WKWebView reloads (P2: debounced preview rendering with scroll-position
/// preservation).
///
/// WHY these tests matter:
///  - `PreviewDebounceGate.shouldRender` determines whether split-mode typing triggers an
///    immediate WKWebView reload or waits for the debounce window. A bug here either
///    spikes CPU (always true) or silently drops renders (always false).
///  - `PreviewScrollToken.restoreScript` is injected verbatim into a live WKWebView after
///    each reload; incorrect JS syntax or a wrong scrollY value would reset the user's
///    viewport to the top on every keystroke.
final class DebouncedPreviewRenderingTests: XCTestCase {

    // MARK: - PreviewDebounceGate

    func test_gate_firstRender_returnsTrue() {
        // With no previous render, any keystroke must trigger an immediate render so the
        // preview is not blank indefinitely.
        let gate = PreviewDebounceGate(interval: 0.2)
        XCTAssertTrue(
            gate.shouldRender(lastRenderAt: nil, now: 1000),
            "first render (lastRenderAt=nil) must always be allowed"
        )
    }

    func test_gate_withinInterval_returnsFalse() {
        // A second render arriving 50ms after the first must be suppressed; firing per-keystroke
        // would cause a full WKWebView reflow on every character typed.
        let gate = PreviewDebounceGate(interval: 0.2)
        let last: TimeInterval = 1000.0
        let now: TimeInterval = 1000.05  // 50 ms later, inside the 200 ms window
        XCTAssertFalse(
            gate.shouldRender(lastRenderAt: last, now: now),
            "render inside the debounce window (50ms < 200ms) must be suppressed"
        )
    }

    func test_gate_exactlyAtInterval_returnsTrue() {
        // A render at exactly the interval boundary must be allowed; off-by-one here would
        // silently extend the debounce window and produce a laggy preview.
        let gate = PreviewDebounceGate(interval: 0.2)
        let last: TimeInterval = 1000.0
        let now: TimeInterval = 1000.2   // exactly 200 ms
        XCTAssertTrue(
            gate.shouldRender(lastRenderAt: last, now: now),
            "render exactly at the interval boundary must be allowed"
        )
    }

    func test_gate_pastInterval_returnsTrue() {
        // A render well past the interval must always be allowed; failing this would freeze
        // the preview even after the user stops typing.
        let gate = PreviewDebounceGate(interval: 0.2)
        let last: TimeInterval = 1000.0
        let now: TimeInterval = 1000.5   // 500 ms later, past the 200 ms window
        XCTAssertTrue(
            gate.shouldRender(lastRenderAt: last, now: now),
            "render past the debounce window (500ms > 200ms) must be allowed"
        )
    }

    func test_gate_differentIntervals_respectTheirOwnThreshold() {
        // The interval is configurable; a 1-second gate must still block renders at 500 ms.
        let gate = PreviewDebounceGate(interval: 1.0)
        let last: TimeInterval = 0.0
        XCTAssertFalse(
            gate.shouldRender(lastRenderAt: last, now: 0.5),
            "500ms must be inside a 1-second debounce window"
        )
        XCTAssertTrue(
            gate.shouldRender(lastRenderAt: last, now: 1.0),
            "exactly 1 second must be allowed by a 1-second gate"
        )
    }

    // MARK: - PreviewScrollToken

    func test_scrollToken_restoreScript_encodesScrollY() {
        // The JS injected into WKWebView must call `window.scrollTo` with the captured pixel
        // offset. If the offset is wrong, the viewport jumps to the wrong position.
        let token = PreviewScrollToken(scrollY: 342.5)
        XCTAssertEqual(
            token.restoreScript,
            "window.scrollTo(0, 342.5);",
            "restoreScript must encode scrollY as the second argument to window.scrollTo"
        )
    }

    func test_scrollToken_none_hasZeroScrollY() {
        // The sentinel `.none` value must have scrollY == 0 so the caller's guard
        // (`if pendingScrollToken.scrollY > 0`) correctly skips injection on the first load.
        XCTAssertEqual(
            PreviewScrollToken.none.scrollY, 0,
            "PreviewScrollToken.none.scrollY must be 0"
        )
    }

    func test_scrollToken_equality_comparesScrollY() {
        // Two tokens with the same scrollY must be equal so the coordinator can detect
        // no-op scroll changes without injecting JS unnecessarily.
        let a = PreviewScrollToken(scrollY: 100)
        let b = PreviewScrollToken(scrollY: 100)
        let c = PreviewScrollToken(scrollY: 200)
        XCTAssertEqual(a, b, "tokens with the same scrollY must be equal")
        XCTAssertNotEqual(a, c, "tokens with different scrollY must not be equal")
    }

    func test_scrollToken_zeroScrollY_restoreScriptIsValid() {
        // Even scrollY=0 must produce syntactically valid JS; a syntax error would throw a
        // WKWebView JS exception and silently break the restore path.
        let token = PreviewScrollToken(scrollY: 0)
        XCTAssertEqual(
            token.restoreScript,
            "window.scrollTo(0, 0.0);",
            "scrollY=0 must produce valid JS (window.scrollTo(0, 0.0))"
        )
    }
}
