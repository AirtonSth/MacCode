import XCTest
import AppKit
@testable import Surfaces

// WHY (todo-QA line 104): a crafted or accidentally malformed byte stream must
// never crash ANSIRenderer and must never cause oscBuffer, utf8Buf, or
// scrollback to grow without bound. The original bug reference is
// ANSIRenderer.swift:237 (unbounded oscBuffer before the cap was added).
// These tests encode the regression contract so any future change that removes
// or widens the bounds is caught immediately.
//
// RNG: a seeded 32-bit LCG (Park-Miller variant) is used throughout so every
// run produces the exact same byte sequence. Math.random / Date.now / arc4random
// are not used — reproducibility is a hard requirement for CI.

final class ANSIRendererFuzzTests: XCTestCase {

    // MARK: - Seeded deterministic LCG

    /// 32-bit Park-Miller LCG. Seed must be non-zero.
    /// Period 2^31 - 1; each call advances state and returns a value in 0..<256.
    private struct LCG {
        private var state: UInt32

        init(seed: UInt32) {
            // Ensure seed is non-zero (LCG would lock at 0 otherwise).
            self.state = seed == 0 ? 1 : seed
        }

        mutating func nextByte() -> UInt8 {
            // Multiplier from Park-Miller (1988): a=16807, m=2^31-1.
            state = UInt32(UInt64(state) * 16807 % 2_147_483_647)
            return UInt8(state & 0xFF)
        }

        mutating func nextBytes(_ count: Int) -> Data {
            var d = Data(capacity: count)
            for _ in 0..<count { d.append(nextByte()) }
            return d
        }
    }

    // MARK: - Fuzz: random-byte corpus

    /// WHY: any 256-byte random chunk fed to the renderer must not crash it,
    /// because real terminal streams can carry arbitrary control bytes from
    /// untrusted remote processes. Each iteration also verifies the three
    /// bounded-buffer invariants that the original bug would have violated.
    func test_randomBytes_noCrashAndBuffersBounded() {
        var rng = LCG(seed: 0xDEAD_BEEF)
        let r = ANSIRenderer(
            rows: 24,
            cols: 80,
            scrollbackLimit: ANSIRenderer.defaultScrollbackLimit
        )

        for _ in 0..<2_048 {
            let chunk = rng.nextBytes(256)
            r.feed(chunk)

            // oscBuffer must never exceed the documented cap.
            XCTAssertLessThanOrEqual(
                r.oscBufferCount,
                ANSIRenderer.oscBufferCap,
                "oscBuffer grew beyond cap after random-byte input"
            )
            // utf8Buf accumulates at most 3 bytes before being flushed or
            // discarded (max valid UTF-8 continuation sequence is 4 bytes
            // total; the renderer drops after 4).
            XCTAssertLessThanOrEqual(
                r.utf8BufCount,
                4,
                "utf8Buf exceeded maximum UTF-8 sequence length after random-byte input"
            )
            // Scrollback must respect the configured limit.
            XCTAssertLessThanOrEqual(
                r.scrollback.count,
                ANSIRenderer.defaultScrollbackLimit,
                "scrollback exceeded scrollbackLimit after random-byte input"
            )
        }
    }

    /// WHY: random bytes with explicit scrollbackLimit=0 must still not crash;
    /// the guard in appendScrollback must hold even under adversarial input.
    func test_randomBytes_zeroScrollbackLimit_noCrash() {
        var rng = LCG(seed: 0xCAFE_BABE)
        let r = ANSIRenderer(rows: 4, cols: 20, scrollbackLimit: 0)
        for _ in 0..<512 {
            r.feed(rng.nextBytes(128))
        }
        XCTAssertEqual(r.scrollback.count, 0,
                       "scrollbackLimit=0 must keep scrollback empty under any input")
    }

    // MARK: - Known escape-sequence fixtures

    /// WHY: a raw ESC byte with no following byte must not crash the parser or
    /// leave it stuck in the .esc state permanently (regression: subsequent
    /// plain text must still be placed in the grid).
    func test_bareESC_doesNotStickParser() {
        let r = ANSIRenderer(rows: 2, cols: 10)
        r.feed(Data([0x1B]))           // lone ESC
        // ESC + 'A' is a complete 2-byte escape (ESC selector 'A'), so 'A' is
        // consumed by the escape, not printed -- correct VT behavior in a
        // timeout-less parser. The "does not stick" contract is that the parser
        // returns to ground afterward: the NEXT printable must reach the grid.
        r.feed("A".data(using: .utf8)!) // consumed as the escape selector
        r.feed("B".data(using: .utf8)!) // must print at col 0 (parser recovered)
        XCTAssertEqual(r.grid[0][0].ch, "B",
                       "after a bare ESC + selector, the parser must return to ground so the next printable reaches the grid")
    }

    /// WHY: a CSI sequence with an extremely long parameter string must not
    /// crash the parser. Real terminals truncate or ignore params; we only
    /// require no crash and bounded buffers.
    func test_longCSIParam_noCrash() {
        let r = ANSIRenderer(rows: 2, cols: 10)
        var d = Data([0x1B, 0x5B]) // ESC [
        d += Data(repeating: UInt8(ascii: "1"), count: 4_096)
        d += Data([UInt8(ascii: "m")]) // final byte -> SGR
        r.feed(d)
        // Must still accept subsequent text.
        r.feed("B".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "B",
                       "CSI with overlong param must not crash or leave parser stuck")
    }

    /// WHY: an OSC sequence that EXCEEDS oscBufferCap must abort to ground and
    /// clear the buffer, preventing unbounded memory growth (the guard fires when
    /// the buffer would grow past the cap). The buffer must never exceed the cap
    /// and must be cleared on overflow; the parser must then recover.
    func test_oscOverCap_clearsBufferAndRecovers() {
        let r = ANSIRenderer(rows: 2, cols: 10)
        var over = Data([0x1B, 0x5D]) // ESC ]
        over += Data(repeating: UInt8(ascii: "X"), count: ANSIRenderer.oscBufferCap + 16) // exceed cap
        r.feed(over)

        // BOUNDED: the buffer must never exceed the cap (unbounded growth = DoS).
        XCTAssertLessThanOrEqual(r.oscBufferCount, ANSIRenderer.oscBufferCap,
                       "oscBuffer must never exceed oscBufferCap under adversarial OSC input")
        // CLEARED: exceeding the cap aborts the OSC and clears the buffer.
        XCTAssertEqual(r.oscBufferCount, 0,
                       "oscBuffer must be cleared once the cap is exceeded (abort to ground)")
        // RECOVERED: the parser is back in ground; a fresh printable renders.
        r.feed("C".data(using: .utf8)!)
        XCTAssertTrue(r.grid.flatMap { $0 }.contains { $0.ch == "C" },
                       "after OSC overflow the parser must return to ground so new text renders")
    }

    /// WHY: incomplete UTF-8 sequences (1, 2, or 3 leading bytes with no
    /// valid continuation) must not crash and must not leave utf8Buf growing
    /// without bound. The renderer drops after 4 accumulated bytes.
    func test_incompleteUTF8_bounded() {
        let r = ANSIRenderer(rows: 2, cols: 10)
        // Two-byte leader (0xC2) with no continuation — repeated.
        for _ in 0..<1_024 {
            r.feed(Data([0xC2]))
        }
        XCTAssertLessThanOrEqual(r.utf8BufCount, 4,
                                  "utf8Buf must not grow beyond 4 under repeated incomplete sequences")

        // Four-byte leader (0xF0) with no continuation — repeated.
        let r2 = ANSIRenderer(rows: 2, cols: 10)
        for _ in 0..<1_024 {
            r2.feed(Data([0xF0]))
        }
        XCTAssertLessThanOrEqual(r2.utf8BufCount, 4,
                                  "utf8Buf must not grow beyond 4 under repeated 4-byte leaders")
    }

    /// WHY: valid multibyte UTF-8 chars (3- and 4-byte) must be placed in the
    /// grid correctly and not leave stale bytes in utf8Buf.
    func test_validMultibyteUTF8_placedAndBufClear() {
        let r = ANSIRenderer(rows: 2, cols: 20)
        // U+00E9 LATIN SMALL LETTER E WITH ACUTE (2-byte: 0xC3 0xA9)
        r.feed(Data([0xC3, 0xA9]))
        XCTAssertEqual(r.grid[0][0].ch, "\u{00E9}",
                       "2-byte UTF-8 char must be placed in grid cell")
        XCTAssertEqual(r.utf8BufCount, 0,
                       "utf8Buf must be empty after complete UTF-8 sequence")

        // U+1F600 GRINNING FACE (4-byte: 0xF0 0x9F 0x98 0x80)
        let r2 = ANSIRenderer(rows: 2, cols: 20)
        r2.feed(Data([0xF0, 0x9F, 0x98, 0x80]))
        XCTAssertEqual(r2.grid[0][0].ch, "\u{1F600}",
                       "4-byte UTF-8 char must be placed in grid cell")
        XCTAssertEqual(r2.utf8BufCount, 0,
                       "utf8Buf must be empty after complete 4-byte UTF-8 sequence")
    }

    /// WHY: scrollback must never exceed scrollbackLimit regardless of how many
    /// lines are scrolled through. This pins the cap-enforcement in
    /// appendScrollback. A separate scrollbackLimit is used so the test
    /// completes quickly.
    func test_scrollback_neverExceedsLimit() {
        let limit = 50
        let r = ANSIRenderer(rows: 4, cols: 10, scrollbackLimit: limit)
        var rng = LCG(seed: 0xABCD_1234)
        // Feed enough newlines to push far more than `limit` rows through.
        for _ in 0..<(limit * 10) {
            // Alternate printable + LF to force scrollUp on every line.
            r.feed(Data([rng.nextByte() % 26 + UInt8(ascii: "a"), 0x0A]))
        }
        XCTAssertLessThanOrEqual(r.scrollback.count, limit,
                                  "scrollback must not exceed scrollbackLimit under sustained scroll")
    }

    /// WHY: vttest/esctest-lite fixture — cursor-movement sequence (CUP + CUU +
    /// CUD + CUF + CUB) must not crash and must leave cursor in a valid in-bounds
    /// position. Covers a class of sequences commonly sent by TUI apps.
    func test_cursorMovementFixture_noCrashAndInBounds() {
        let r = ANSIRenderer(rows: 10, cols: 20)
        // ESC[5;10H  -> position row 5 col 10
        // ESC[2A     -> up 2
        // ESC[3B     -> down 3
        // ESC[4C     -> right 4
        // ESC[5D     -> left 5
        // ESC[999;999H -> clamp to grid edges
        let seq = "\u{1B}[5;10H\u{1B}[2A\u{1B}[3B\u{1B}[4C\u{1B}[5D\u{1B}[999;999H"
        r.feed(seq.data(using: .utf8)!)
        XCTAssertGreaterThanOrEqual(r.cursorRow, 0)
        XCTAssertLessThan(r.cursorRow, r.rows)
        XCTAssertGreaterThanOrEqual(r.cursorCol, 0)
        XCTAssertLessThan(r.cursorCol, r.cols)
    }

    /// WHY: alternate-screen toggle sequences (ESC[?1049h / ESC[?1049l) interleaved
    /// with random bytes must not crash and must leave usesAlternateScreen consistent.
    func test_alternateScreenToggle_withRandomBytes_noCrash() {
        var rng = LCG(seed: 0x1234_5678)
        let r = ANSIRenderer(rows: 8, cols: 20)
        let enter = "\u{1B}[?1049h".data(using: .utf8)!
        let leave = "\u{1B}[?1049l".data(using: .utf8)!
        for i in 0..<64 {
            r.feed(rng.nextBytes(32))
            r.feed(i.isMultiple(of: 2) ? enter : leave)
        }
        // Final state must be consistent — just check no crash + in-bounds cursor.
        XCTAssertGreaterThanOrEqual(r.cursorRow, 0)
        XCTAssertLessThan(r.cursorRow, r.rows)
    }

    /// WHY: resize during active parsing must not crash and must keep grid
    /// dimensions consistent with the requested size even after random bytes.
    func test_resizeDuringFeed_consistent() {
        var rng = LCG(seed: 0xFEED_FACE)
        let r = ANSIRenderer(rows: 24, cols: 80)
        for _ in 0..<16 {
            r.feed(rng.nextBytes(128))
            r.resize(rows: 10, cols: 40)
            r.feed(rng.nextBytes(128))
            r.resize(rows: 24, cols: 80)
        }
        XCTAssertEqual(r.rows, 24)
        XCTAssertEqual(r.cols, 80)
        XCTAssertEqual(r.grid.count, 24)
        XCTAssertEqual(r.grid[0].count, 80)
        XCTAssertGreaterThanOrEqual(r.cursorRow, 0)
        XCTAssertLessThan(r.cursorRow, r.rows)
    }
}
