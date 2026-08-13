import XCTest
@testable import AgentRuntime

/// Regression: the runners used to decode each raw pipe chunk and split
/// it by "\n" with no cross-read buffering. A JSON line (or a UTF-8
/// sequence) split across two reads was silently dropped, so a large
/// agent answer lost its terminal agent_message/turn.completed and the
/// run hung "running". LineBuffer must reassemble across chunk
/// boundaries and only ever yield whole lines.
final class LineBufferTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    func test_jsonLineSplitAcrossTwoReads_isReassembled() {
        let b = LineBuffer()
        XCTAssertEqual(b.take(d("{\"type\":\"turn.")), [],
                       "an unterminated fragment must NOT be emitted")
        XCTAssertEqual(b.take(d("completed\"}\n")),
                       ["{\"type\":\"turn.completed\"}"],
                       "the line completes only once its newline arrives")
    }

    func test_multipleLinesAndBlankLines() {
        let b = LineBuffer()
        XCTAssertEqual(b.take(d("a\n\n  \nb\nc")), ["a", "b"],
                       "blank/whitespace-only lines are skipped; 'c' is still buffered")
        XCTAssertEqual(b.flush(), ["c"], "flush emits the final unterminated line")
    }

    func test_crlfStripped() {
        let b = LineBuffer()
        XCTAssertEqual(b.take(d("hello\r\nworld\r\n")), ["hello", "world"])
    }

    func test_utf8MultibyteSplitAcrossReads_notCorrupted() {
        // "é" = 0xC3 0xA9. Old code did String(data:encoding:.utf8) on the
        // raw chunk → nil when the 2 bytes landed in different reads → the
        // whole chunk (and answer) vanished.
        let b = LineBuffer()
        XCTAssertEqual(b.take(Data([0xC3])), [], "half a codepoint is not a line")
        XCTAssertEqual(b.take(Data([0xA9]) + d("\n")), ["é"],
                       "the split multi-byte char must round-trip intact")
    }

    func test_flushEmptyIsNoop() {
        XCTAssertEqual(LineBuffer().flush(), [])
    }

    /// PERF R7: a single NDJSON fragment without newline must not pin multi-MB Data.
    /// Oversize partials are dropped entirely (retained count → 0) until `\n`.
    func test_unterminatedFragment_isDroppedWhenOverDefaultMaxBytes() {
        let b = LineBuffer()
        let oversize = LineBuffer.defaultMaxBytes + (256 * 1_024)
        let chunk = Data(repeating: 0x41, count: oversize)
        XCTAssertEqual(b.take(chunk), [], "unterminated fragment must not emit a line")
        XCTAssertEqual(
            b.retainedByteCount,
            0,
            "oversize partial must be discarded so peak retained stays at 0 after clamp"
        )
        XCTAssertEqual(LineBuffer.defaultMaxBytes, 512 * 1_024)
    }

    /// Under the cap, split-line reassembly remains lossless.
    func test_underCap_splitLineStillReassembled() {
        let b = LineBuffer(maxBytes: 64)
        XCTAssertEqual(b.take(d("{\"ok\":")), [])
        XCTAssertEqual(b.take(d("true}\n")), ["{\"ok\":true}"])
        XCTAssertEqual(b.retainedByteCount, 0)
    }

    /// After overflow, a later newline must NOT emit a truncated prefix (fail open:
    /// drop the bad line entirely).
    func test_oversizeThenNewline_emitsNothing() {
        let cap = 16
        let b = LineBuffer(maxBytes: cap)
        _ = b.take(Data(repeating: 0x42, count: 64)) // 'B' * 64 → oversize drop
        XCTAssertEqual(b.retainedByteCount, 0)
        XCTAssertEqual(b.take(d("\n")), [], "oversize line is discarded, not emitted")
        XCTAssertEqual(b.retainedByteCount, 0)
    }

    /// After overflow, a suffix before newline must not splice onto a discarded
    /// prefix and invent corrupted JSON.
    func test_oversizeThenSuffixBeforeNewline_doesNotSplice() {
        let cap = 16
        let b = LineBuffer(maxBytes: cap)
        _ = b.take(Data(repeating: 0x41, count: 64)) // oversize → drop + discard mode
        XCTAssertEqual(b.retainedByteCount, 0)
        // Suffix that would look like valid JSON if spliced onto a retained prefix.
        XCTAssertEqual(b.take(d("{\"ok\":true}\n")), [], "must not splice suffix after discard")
        // Next full line under the cap still works.
        XCTAssertEqual(b.take(d("{\"next\":1}\n")), ["{\"next\":1}"])
    }
}
