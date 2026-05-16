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
}
