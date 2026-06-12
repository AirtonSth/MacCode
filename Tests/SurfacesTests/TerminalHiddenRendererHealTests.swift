import XCTest
@testable import Surfaces

/// Tests for the hidden-renderer heal seam (P1 fix: TerminalSurface.swift, hidden output replay).
///
/// WHY these tests exist:
/// When a Mac terminal tab is hidden, `renderer.feed` is intentionally skipped to
/// avoid wasted GPU/CPU work. This means the ANSIRenderer snapshot is stale for the
/// entire hidden period. If iOS requests a snapshot during or just after that window,
/// it receives incomplete ANSI output, and the iOS mirror shows permanently partial
/// output even after the user reveals the tab.
///
/// The seam `hiddenRendererHealPlan(buffer:overflowed:)` is the pure decision point
/// for what must be replayed into `renderer.feed` on reveal. Testing it in isolation
/// ensures the business rule (replay iff buffer non-empty) is verifiable without
/// AppKit, Ghostty, or a live PTY.
final class TerminalHiddenRendererHealTests: XCTestCase {

    // MARK: - hiddenRendererHealPlan seam

    func test_healPlan_returnsNil_whenBufferIsEmpty() {
        // WHY: an empty buffer means no output arrived while hidden; replaying
        // nothing is correct and avoids a spurious renderer.feed call.
        let result = TerminalSurface.hiddenRendererHealPlan(buffer: Data(), overflowed: false)
        XCTAssertNil(result,
                     "heal plan must not replay an empty buffer — no hidden output means the renderer is already up to date")
    }

    func test_healPlan_returnsNil_whenBufferIsEmpty_evenIfOverflowed() {
        // WHY: overflowed=true with an empty buffer is a degenerate state
        // (cap was zero or buffer was already flushed); replay must be a no-op.
        let result = TerminalSurface.hiddenRendererHealPlan(buffer: Data(), overflowed: true)
        XCTAssertNil(result,
                     "heal plan must not replay when buffer is empty regardless of overflow flag")
    }

    func test_healPlan_returnsBuffer_whenOutputArrivedWhileHidden() {
        // WHY: this is the core contract — bytes that arrived while the renderer
        // was suppressed must be returned for replay so the ANSI snapshot
        // reflects the actual terminal state before iOS reads it.
        let hidden = Data("hello\r\n".utf8)
        let result = TerminalSurface.hiddenRendererHealPlan(buffer: hidden, overflowed: false)
        XCTAssertEqual(result, hidden,
                       "heal plan must replay the exact hidden bytes into renderer.feed so the iOS mirror snapshot is complete")
    }

    func test_healPlan_returnsBufferedBytes_evenWhenOverflowed() {
        // WHY: when the hidden buffer hit the capacity cap, the tail of the
        // hidden output is lost, but the head bytes ARE buffered and MUST be
        // replayed. Partial heal (with complete=false) is strictly better than
        // no heal at all — it advances the renderer forward from wherever it
        // last rendered.
        let partial = Data(Array(repeating: UInt8(ascii: "x"), count: 100))
        let result = TerminalSurface.hiddenRendererHealPlan(buffer: partial, overflowed: true)
        XCTAssertEqual(result, partial,
                       "heal plan must replay buffered bytes even after overflow — partial heal advances the renderer further than no-op")
    }

    func test_healPlan_returnsMultilineANSISequences() {
        // WHY: real terminal output contains ANSI escape sequences across
        // multiple lines; the replay must pass them verbatim so the renderer
        // can parse state machines (SGR, cursor moves, OSC titles) correctly.
        let ansi = Data("\u{1B}[1mBold\u{1B}[0m\r\nNext line\r\n".utf8)
        let result = TerminalSurface.hiddenRendererHealPlan(buffer: ansi, overflowed: false)
        XCTAssertEqual(result, ansi,
                       "heal plan must not strip ANSI sequences — renderer must receive them verbatim to rebuild correct cell state")
    }

    // MARK: - Double-feed guard invariant

    func test_doubleFeed_guard_bufferClearedBeforeLivePathResumes() {
        // WHY: the double-feed risk is: a byte arrives hidden -> buffered ->
        // didBecomeVisible replays it -> then the same byte is fed again via
        // the live path. The implementation guards this by:
        //   1. clearing hiddenRendererBuffer BEFORE setting readerAllowsRender=true
        //   2. the live path only feeds renderer when readerAllowsRender=true
        // This test encodes the invariant at the seam level: once the plan
        // returns a payload, that payload is the buffer's final value — the
        // caller must clear the buffer and only then allow live feeds.
        //
        // We verify the seam is idempotent: calling it twice on the same buffer
        // returns the same data both times (it has no side effects), so the
        // caller's clear+flip sequence is the only guard needed.
        let hidden = Data("output\r\n".utf8)
        let first = TerminalSurface.hiddenRendererHealPlan(buffer: hidden, overflowed: false)
        let second = TerminalSurface.hiddenRendererHealPlan(buffer: hidden, overflowed: false)
        XCTAssertEqual(first, second,
                       "heal plan seam must be pure/idempotent — caller's clear+readerAllowsRender=true sequence is the sole double-feed guard")
    }
}
