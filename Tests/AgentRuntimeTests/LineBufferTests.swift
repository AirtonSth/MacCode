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

    func test_largeBatchAndSplitTail_preserveEveryLineInOrder() {
        let b = LineBuffer()
        let expected = (0..<8_192).map { index in
            "{\"index\":\(index),\"body\":\"\(String(repeating: "x", count: 40))\"}"
        }
        let complete = expected.joined(separator: "\n") + "\npartial"

        XCTAssertEqual(b.take(d(complete)), expected,
                       "one large pipe delivery must emit every complete record exactly once and in order")
        XCTAssertEqual(b.take(d("-tail\n")), ["partial-tail"],
                       "the already-scanned partial suffix must resume without loss or duplication")
        XCTAssertEqual(b.flush(), [])
    }

    /// Same-process A/B of the production parser against its pre-checkpoint
    /// implementation. Primary metric: wall time for one representative 512 KiB
    /// provider delivery containing 8,192 compact NDJSON records (warmup=2, n=7).
    func test_microbench_largeNDJSONBatch_singlePrefixRemovalBeatsPerLineRemoval() {
        final class LegacyLineBuffer {
            private var buffer = Data()

            func take(_ data: Data) -> [String] {
                buffer.append(data)
                var lines: [String] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let decoded = String(decoding: line, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !decoded.isEmpty { lines.append(decoded) }
                }
                return lines
            }
        }

        let lineCount = 8_192
        let lines = (0..<lineCount).map { index in
            "{\"i\":\(index),\"delta\":\"\(String(repeating: "a", count: 40))\"}"
        }
        let payload = d(lines.joined(separator: "\n") + "\n")
        let warmup = 2
        let samples = 7

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }

        func timeLegacy() -> Double {
            let parser = LegacyLineBuffer()
            let start = DispatchTime.now().uptimeNanoseconds
            let output = parser.take(payload)
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(output, lines)
            return Double(end - start) / 1_000_000.0
        }

        func timeCurrent() -> Double {
            let parser = LineBuffer()
            let start = DispatchTime.now().uptimeNanoseconds
            let output = parser.take(payload)
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(output, lines)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup {
            _ = timeLegacy()
            _ = timeCurrent()
        }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeLegacy())
            after.append(timeCurrent())
        }
        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        NSLog(
            "[perf-proof] lineBuffer per_line_remove_ms=%@ single_remove_ms=%@ improvement_pct=%.2f before=%@ after=%@ bytes=%d lines=%d",
            String(beforeMedian), String(afterMedian), improvement,
            String(describing: before), String(describing: after), payload.count, lineCount
        )
        XCTAssertGreaterThan(
            improvement,
            5,
            "single-prefix removal must beat per-line Data removal by at least 5% (before=\(beforeMedian)ms after=\(afterMedian)ms)"
        )
    }
}
