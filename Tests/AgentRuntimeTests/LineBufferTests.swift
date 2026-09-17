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

    /// Pre-cap behaviour: one 8 MiB record with no newline pinned the whole
    /// blob in `buffer` until EOF. Kept as the before/uncapped replica so the
    /// cap's retained-byte savings stay measurable.
    private final class UncappedLineBuffer {
        private var buffer = Data()

        var retainedByteCount: Int { buffer.count }

        func take(_ data: Data) -> [String] {
            buffer.append(data)
            var lines: [String] = []
            var lineStart = buffer.startIndex
            var searchStart = buffer.startIndex
            while searchStart < buffer.endIndex,
                  let nl = buffer[searchStart...].firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: lineStart..<nl)
                let decoded = String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !decoded.isEmpty { lines.append(decoded) }
                searchStart = buffer.index(after: nl)
                lineStart = searchStart
            }
            if lineStart != buffer.startIndex {
                buffer.removeSubrange(buffer.startIndex..<lineStart)
            }
            return lines
        }

        func flush() -> [String] {
            guard !buffer.isEmpty else { return [] }
            let rest = String(decoding: buffer, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            return rest.isEmpty ? [] : [rest]
        }
    }

    func test_maxPartialBytes_is2MiB() {
        XCTAssertEqual(LineBuffer.maxPartialBytes, 2 * 1024 * 1024,
                       "partial NDJSON cap must stay in the 1–4 MiB band")
    }

    func test_eightMiBNoNewline_uncappedPinsWholeBlob_cappedRetainsAtMostCap() {
        let fixtureBytes = 8 * 1024 * 1024
        let blob = Data(repeating: 0x41, count: fixtureBytes)

        let uncapped = UncappedLineBuffer()
        XCTAssertEqual(uncapped.take(blob), [],
                       "an unterminated 8 MiB record must not emit a line")
        let before = uncapped.retainedByteCount
        XCTAssertEqual(before, fixtureBytes,
                       "BEFORE: uncapped LineBuffer pins the whole 8 MiB partial")

        let capped = LineBuffer()
        XCTAssertEqual(capped.take(blob), [],
                       "the oversized partial is held, not emitted, until newline/flush")
        let after = capped.retainedByteCountForTesting
        XCTAssertLessThanOrEqual(after, LineBuffer.maxPartialBytes,
                                 "AFTER: retained partial must not exceed the cap")
        XCTAssertTrue(capped.truncatedPartialForTesting,
                      "overflow must be visible so callers can surface a truncation marker")
        let reduction = Double(before - after) / Double(before)
        XCTAssertGreaterThanOrEqual(
            reduction, 0.50,
            "8 MiB fixture must retain ≥50% fewer bytes than uncapped (before=\(before) after=\(after))"
        )
        XCTAssertGreaterThanOrEqual(
            reduction, 0.75,
            "2 MiB cap on an 8 MiB blob should save ~75% (before=\(before) after=\(after) reduction=\(reduction))"
        )
        NSLog(
            "[perf-proof] lineBuffer eightMiB before=%d after=%d cap=%d reduction_pct=%.2f",
            before, after, LineBuffer.maxPartialBytes, reduction * 100
        )
    }

    func test_eightMiBNoNewline_completingNewlineYieldsTruncationMarkerThenLaterTurnCompleted() {
        let blob = Data(repeating: 0x41, count: 8 * 1024 * 1024)
        let b = LineBuffer()
        XCTAssertEqual(b.take(blob), [])

        let completed = b.take(d("\n{\"type\":\"turn.completed\"}\n"))
        XCTAssertEqual(completed.count, 2,
                       "newline must close the truncated record and still parse the next NDJSON line")
        XCTAssertTrue(
            completed[0].contains(LineBuffer.truncationMarker),
            "store-before-loss fail-open: truncated record must carry a visible [[rc:]] marker, not disappear"
        )
        let overflowObj = try? JSONSerialization.jsonObject(with: Data(completed[0].utf8)) as? [String: Any]
        XCTAssertEqual(overflowObj?["type"] as? String, "error",
                       "truncated NDJSON must become a valid JSON overflow record, not a broken JSON line")
        XCTAssertEqual(overflowObj?["recoverable"] as? Bool, true)
        XCTAssertEqual((overflowObj?["retained_bytes"] as? NSNumber)?.intValue, LineBuffer.maxPartialBytes)
        XCTAssertEqual((overflowObj?["prefix"] as? String)?.first, "A",
                       "prefix of the oversized line is retained so the record stays identifiable")
        XCTAssertEqual(completed[1], "{\"type\":\"turn.completed\"}",
                       "a later terminal frame must not be dropped when the prior line overflowed")
        XCTAssertEqual(b.retainedByteCountForTesting, 0)
        XCTAssertFalse(b.truncatedPartialForTesting)
        XCTAssertEqual(b.flush(), [])
    }

    func test_oversizedNDJSON_isNotSilentlyDropped_andTurnCompletedStillParses() {
        // WHY: appending a plain-text marker inside truncated JSON made
        // emitLine's JSONSerialization fail, so the overflow vanished.
        let blob = Data(repeating: 0x41, count: LineBuffer.maxPartialBytes + 64)
        let b = LineBuffer()
        XCTAssertEqual(b.take(blob), [])
        let completed = b.take(d("\n{\"type\":\"turn.completed\"}\n"))
        XCTAssertEqual(completed.count, 2)

        let parser = CodexParser()
        let overflow = CodexRunner.interpretStreamJSONLine(completed[0], parser: parser)
        XCTAssertNotNil(overflow.runtimeEvent, "overflow must surface as a provider runtime event")
        XCTAssertEqual(overflow.runtimeEvent?.method, "error")
        XCTAssertTrue(
            overflow.parsedEvents.contains { event in
                if case .error(let message, let recoverable) = event {
                    return recoverable && message.contains("[[rc:line-overflow]]")
                }
                return false
            },
            "CodexParser must emit a recoverable error so the oversized record is not lost"
        )

        let turn = CodexRunner.interpretStreamJSONLine(completed[1], parser: parser)
        XCTAssertTrue(
            turn.parsedEvents.contains { event in
                if case .turnCompleted = event { return true }
                return false
            },
            "turn.completed after an overflowed record must still parse"
        )
    }

    func test_flush_oversizedPartial_emitsMarkerWithoutWaitingForNewline() {
        let b = LineBuffer()
        _ = b.take(Data(repeating: 0x42, count: LineBuffer.maxPartialBytes + 16))
        let flushed = b.flush()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertTrue(flushed[0].contains(LineBuffer.truncationMarker))
        let obj = try? JSONSerialization.jsonObject(with: Data(flushed[0].utf8)) as? [String: Any]
        XCTAssertEqual(obj?["type"] as? String, "error")
        XCTAssertEqual(obj?["recoverable"] as? Bool, true)
        XCTAssertEqual(b.retainedByteCountForTesting, 0)
    }

    /// Same 8 MiB no-newline fixture, warmed n=5, so the cap's retained-byte
    /// contract is not a one-shot accident.
    func test_microbench_eightMiBNoNewline_retainedBytesStayAtCap() {
        let fixtureBytes = 8 * 1024 * 1024
        let blob = Data(repeating: 0x41, count: fixtureBytes)
        let warmup = 2
        let samples = 5
        var before: [Int] = []
        var after: [Int] = []

        func measureUncapped() -> Int {
            let parser = UncappedLineBuffer()
            _ = parser.take(blob)
            return parser.retainedByteCount
        }
        func measureCapped() -> Int {
            let parser = LineBuffer()
            _ = parser.take(blob)
            return parser.retainedByteCountForTesting
        }

        for _ in 0..<warmup {
            _ = measureUncapped()
            _ = measureCapped()
        }
        for _ in 0..<samples {
            before.append(measureUncapped())
            after.append(measureCapped())
        }
        let beforeMedian = before.sorted()[samples / 2]
        let afterMedian = after.sorted()[samples / 2]
        let reduction = Double(beforeMedian - afterMedian) / Double(beforeMedian)
        NSLog(
            "[perf-proof] lineBuffer eightMiB_microbench before_median=%d after_median=%d reduction_pct=%.2f before=%@ after=%@",
            beforeMedian, afterMedian, reduction * 100,
            String(describing: before), String(describing: after)
        )
        XCTAssertEqual(beforeMedian, fixtureBytes)
        XCTAssertLessThanOrEqual(afterMedian, LineBuffer.maxPartialBytes)
        XCTAssertGreaterThanOrEqual(reduction, 0.50)
        XCTAssertGreaterThanOrEqual(reduction, 0.75)
    }
}
