import XCTest
@testable import Surfaces

/// Equivalence tests for the lazy mirror-renderer feeding seam (PERF-136).
///
/// WHY these tests exist:
/// On the VISIBLE hot path, TerminalSurface no longer feeds its mirror
/// ANSIRenderer byte-by-byte for every output chunk. Instead it RECORDS each
/// feed/resize as a `PendingRendererEvent` and replays the recorded sequence
/// into the renderer only when a snapshot is read (ensureRendererCurrent ->
/// `TerminalSurface.replay`). The whole optimization is only correct if the
/// deferral is UNOBSERVABLE: the renderer's snapshot after a deferred-then-
/// replayed sequence must be BYTE-IDENTICAL to the snapshot after eagerly
/// feeding the same sequence in the same order. The mirror is consumed by
/// remote clients, which corrupt on any mismatch.
///
/// These tests drive the renderer two ways and assert byte-identical snapshots:
///  - EAGER: feed each chunk / apply each resize immediately, interleaved.
///  - LAZY:  record the SAME sequence as PendingRendererEvent values, then
///           replay them via the production static seam `TerminalSurface.replay`.
///
/// Because LAZY uses the exact same `replay` code the production flush uses,
/// a passing test proves the production deferral is unobservable.
@MainActor
final class LazyMirrorRendererEquivalenceTests: XCTestCase {

    // MARK: - Harness

    private func makeRenderer(rows: Int = 24, cols: Int = 80) -> ANSIRenderer {
        ANSIRenderer(rows: rows, cols: cols)
    }

    /// Builds an eager renderer by applying `events` immediately, and a lazy
    /// renderer by recording then replaying them. Returns both for comparison.
    private func eagerAndLazy(
        rows: Int,
        cols: Int,
        events: [TerminalSurface.PendingRendererEvent]
    ) -> (eager: ANSIRenderer, lazy: ANSIRenderer) {
        let eager = makeRenderer(rows: rows, cols: cols)
        for event in events {
            switch event {
            case .bytes(let data):
                eager.feed(data)
            case .resize(let r, let c):
                eager.resize(rows: r, cols: c)
            }
        }
        let lazy = makeRenderer(rows: rows, cols: cols)
        TerminalSurface.replay(events, into: lazy)
        return (eager, lazy)
    }

    private func assertSnapshotsIdentical(
        _ a: ANSIRenderer,
        _ b: ANSIRenderer,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            a.snapshot().string, b.snapshot().string,
            "text snapshot must be byte-identical: \(message)",
            file: file, line: line
        )
        XCTAssertEqual(
            a.ansiSnapshot(includeScrollback: true),
            b.ansiSnapshot(includeScrollback: true),
            "ansi snapshot must be byte-identical: \(message)",
            file: file, line: line
        )
    }

    private func data(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - (a) plain bytes

    func testPlainBytesEquivalent() {
        // WHY: the simplest case — deferring a single feed must not change output.
        let events: [TerminalSurface.PendingRendererEvent] = [
            .bytes(data("hello world\r\nsecond line\r\n"))
        ]
        let (eager, lazy) = eagerAndLazy(rows: 24, cols: 80, events: events)
        assertSnapshotsIdentical(eager, lazy, "plain bytes")
    }

    // MARK: - (b) many small chunks vs one big chunk

    func testChunkingDoesNotAffectReplay() {
        // WHY: the reader delivers output in arbitrary-sized chunks. Whether the
        // same total byte stream arrives as one chunk or many tiny chunks, the
        // replayed renderer state must be identical (feeding is order-preserving
        // and chunk-boundary-agnostic).
        let full = "\u{1b}[1;32mPASS\u{1b}[0m build #1234 ok\r\n" +
                   String(repeating: "x", count: 200) + "\r\n" +
                   "\u{1b}[31merror:\u{1b}[0m none\r\n"

        // One big chunk.
        let bigEvents: [TerminalSurface.PendingRendererEvent] = [.bytes(data(full))]
        // Many small chunks (split per byte).
        let smallEvents: [TerminalSurface.PendingRendererEvent] =
            Array(full.utf8).map { .bytes(Data([$0])) }

        let big = makeRenderer()
        TerminalSurface.replay(bigEvents, into: big)
        let small = makeRenderer()
        TerminalSurface.replay(smallEvents, into: small)

        assertSnapshotsIdentical(big, small, "one big chunk vs many small chunks")
    }

    // MARK: - (c) resize interleaved mid-stream  (the critical case)

    func testResizeInterleavedPreservesOrder() {
        // WHY: this is the byte-equivalence breaker. If a resize is applied while
        // bytes that PRECEDE it are still pending, those bytes reflow at the wrong
        // dimensions. The ordered pending-event buffer fixes this: eager
        // feed-then-resize-then-feed MUST equal record-all-then-replay-in-order.
        let events: [TerminalSurface.PendingRendererEvent] = [
            .bytes(data("line before resize: " + String(repeating: "A", count: 120) + "\r\n")),
            .resize(rows: 10, cols: 40),
            .bytes(data("line after resize: " + String(repeating: "B", count: 120) + "\r\n")),
            .resize(rows: 30, cols: 100),
            .bytes(data("final line " + String(repeating: "C", count: 90) + "\r\n"))
        ]
        let (eager, lazy) = eagerAndLazy(rows: 24, cols: 80, events: events)
        assertSnapshotsIdentical(eager, lazy, "resize interleaved mid-stream")
    }

    // MARK: - (d) scrollback overflow

    func testScrollbackOverflowEquivalent() {
        // WHY: deferral must not change which lines spill into scrollback or their
        // content. Feed far more lines than the viewport height so the scrollback
        // ring is exercised, then assert the full ansi snapshot (with scrollback)
        // is identical between eager and lazy.
        var lines = ""
        for i in 0..<500 {
            lines += "scrollback line \(i) " + String(repeating: "z", count: 30) + "\r\n"
        }
        let events: [TerminalSurface.PendingRendererEvent] = [.bytes(data(lines))]
        let (eager, lazy) = eagerAndLazy(rows: 24, cols: 80, events: events)
        assertSnapshotsIdentical(eager, lazy, "scrollback overflow")
    }

    // MARK: - (e) force-flush-on-cap mid-stream

    func testForceFlushOnCapEquivalent() {
        // WHY: when pending bytes exceed the cap, production force-flushes mid-
        // stream (ensureRendererCurrent) instead of dropping bytes. A mid-stream
        // flush splits the replay into two replay() calls against the SAME
        // renderer; the post-cap snapshot must still equal the fully-eager
        // snapshot (flush, never drop -> visible snapshot stays complete).
        let part1 = "before cap " + String(repeating: "P", count: 300) + "\r\n"
        let part2 = "after cap " + String(repeating: "Q", count: 300) + "\r\n"
        let events1: [TerminalSurface.PendingRendererEvent] = [.bytes(data(part1))]
        let events2: [TerminalSurface.PendingRendererEvent] = [.bytes(data(part2))]

        // Eager: feed both immediately.
        let eager = makeRenderer()
        eager.feed(data(part1))
        eager.feed(data(part2))

        // Lazy with a mid-stream force-flush: replay part1 (the "cap" flush), then
        // replay part2, both into the same renderer — mimicking the buffer being
        // drained mid-stream and refilled.
        let lazy = makeRenderer()
        TerminalSurface.replay(events1, into: lazy)
        TerminalSurface.replay(events2, into: lazy)

        assertSnapshotsIdentical(eager, lazy, "force-flush on cap mid-stream")
    }

    // MARK: - resize + force-flush combined ordering

    func testResizeThenCapFlushOrdering() {
        // WHY: guards the interaction of (c) and (e) — a resize recorded between
        // two byte runs, with a flush boundary, must still equal full-eager.
        let eager = makeRenderer(rows: 24, cols: 80)
        eager.feed(data("aaa " + String(repeating: "a", count: 100) + "\r\n"))
        eager.resize(rows: 12, cols: 50)
        eager.feed(data("bbb " + String(repeating: "b", count: 100) + "\r\n"))

        let lazy = makeRenderer(rows: 24, cols: 80)
        // Flush boundary after the first byte run (simulating cap force-flush).
        TerminalSurface.replay([.bytes(data("aaa " + String(repeating: "a", count: 100) + "\r\n"))], into: lazy)
        // Remaining events replayed on the next read.
        TerminalSurface.replay([
            .resize(rows: 12, cols: 50),
            .bytes(data("bbb " + String(repeating: "b", count: 100) + "\r\n"))
        ], into: lazy)

        assertSnapshotsIdentical(eager, lazy, "resize then cap-flush ordering")
    }
}
