import XCTest
import CoreModel
import Darwin
@testable import AgentRuntime

/// `~/.grok/logs/unified.jsonl` is scanned on every 60 s account-usage tick
/// whenever the Grok credits API misses. These tests pin what the scan
/// returns as the log grows, scrolls and gets rewritten, so skipping the work
/// on an unchanged log can never return a different answer than a full scan.
final class GrokBillingLogScanTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-grok-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func billingLine(_ percent: Double) -> String {
        #"{"msg":"billing: fetched credits config","ctx":{"config":{"creditUsagePercent":"# + "\(percent)"
            + #","billingPeriodEnd":"2099-07-22T20:46:41.975270+00:00"}}}"# + "\n"
    }

    private let noiseLine = #"{"ts":"2026-10-13T15:41:00.000Z","msg":"tool_result","ctx":{"output":"ok"}}"# + "\n"

    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    private func percent(_ url: URL, maxBytes: Int = 4 * 1024 * 1024) -> Double? {
        AssistantAccountUsageParser.grokFromBillingLogFile(at: url, maxBytes: maxBytes)?.weeklyUsedPercent
    }

    /// WHY: the log is append-only while Grok runs. A new billing snapshot
    /// must win over the one seen a minute earlier, and noise appended after
    /// it must not hide it.
    func test_appendedBillingLinesWinAndSurviveLaterNoise() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        try String(repeating: noiseLine, count: 50).write(to: log, atomically: true, encoding: .utf8)
        XCTAssertNil(percent(log))
        XCTAssertNil(percent(log), "an unchanged log without billing lines stays nil")

        try append(billingLine(31), to: log)
        XCTAssertEqual(percent(log), 31)
        try append(String(repeating: noiseLine, count: 20), to: log)
        XCTAssertEqual(percent(log), 31)
        try append(billingLine(44) + noiseLine, to: log)
        XCTAssertEqual(percent(log), 44, "the newest billing line must win")
        XCTAssertEqual(percent(log), 44)
    }

    /// WHY: Grok can be mid-write when the timer fires. A half-written last
    /// line is not a billing line yet; once the writer finishes it, it is.
    func test_halfWrittenLastLineIsReadOnceComplete() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        let line = billingLine(52)
        let cut = line.index(line.startIndex, offsetBy: 40)
        try (noiseLine + String(line[..<cut])).write(to: log, atomically: true, encoding: .utf8)
        XCTAssertNil(percent(log))

        try append(String(line[cut...]), to: log)
        XCTAssertEqual(percent(log), 52)
    }

    /// WHY: the scan window is the last `maxBytes`. A billing line that
    /// scrolled out of it must stop counting, exactly as a full scan would.
    func test_billingLineThatScrollsOutOfTheWindowIsDropped() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        try (billingLine(18) + noiseLine).write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(percent(log, maxBytes: 4_096), 18)

        try append(String(repeating: noiseLine, count: 80), to: log)
        XCTAssertNil(percent(log, maxBytes: 4_096),
                     "a billing line older than the scan window must not be returned")
    }

    /// WHY: when the window starts exactly on a line boundary the scan still
    /// discards the first line, because it cannot know the line is whole.
    func test_lineStartingExactlyAtTheWindowStartIsDiscarded() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        let billing = billingLine(27)
        let tail = String(repeating: noiseLine, count: 3)
        try (noiseLine + billing + tail).write(to: log, atomically: true, encoding: .utf8)
        let window = billing.utf8.count + tail.utf8.count
        XCTAssertNil(percent(log, maxBytes: window))
        XCTAssertEqual(percent(log, maxBytes: window + 1), 27)
    }

    /// WHY: `grokBillingJSON` also accepts a bare credits `config` with no
    /// "billing"/"credits" text in `msg`; a byte prefilter must not skip it.
    func test_configWithoutBillingMessageIsStillFound() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        try (noiseLine + #"{"msg":"usage","ctx":{"config":{"used":5,"monthlyLimit":10}}}"# + "\n" + noiseLine)
            .write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(percent(log), 50)
    }

    /// WHY: rotation or a rewrite replaces the bytes a previous scan saw. The
    /// answer must come from the new contents, even at the same size.
    func test_rewrittenLogIsRescanned() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        try (noiseLine + billingLine(61)).write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(percent(log), 61)

        try (noiseLine + billingLine(62)).write(to: log, atomically: true, encoding: .utf8)
        XCTAssertEqual(percent(log), 62, "a same-size rewrite must not return the old answer")

        let handle = try FileHandle(forWritingTo: log)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((billingLine(9) + String(repeating: noiseLine, count: 5)).utf8))
        try handle.close()
        XCTAssertEqual(percent(log), 9, "a truncated and regrown log must be read from scratch")
    }

    /// WHY: the live log sat unchanged for ~13 h while every 60 s tick re-read
    /// and JSON-parsed all 3.4 MB of it. An unchanged log must not be read, and
    /// a grown one must be read only from where the last scan stopped.
    func test_unchangedLogIsNotReadAndGrownLogReadsOnlyNewBytes() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        let body = String(repeating: noiseLine, count: 2_000)
        try body.write(to: log, atomically: true, encoding: .utf8)
        func bytesRead(_ body: () -> Void) -> Int {
            let before = AssistantAccountUsageParser.grokBillingLogBytesReadForTesting
            body()
            return AssistantAccountUsageParser.grokBillingLogBytesReadForTesting - before
        }

        XCTAssertEqual(bytesRead { XCTAssertNil(percent(log)) }, body.utf8.count)
        XCTAssertEqual(bytesRead { XCTAssertNil(percent(log)) }, 0, "an unchanged log must not be read again")

        let appended = billingLine(37)
        try append(appended, to: log)
        let anchor = 32
        XCTAssertEqual(bytesRead { XCTAssertEqual(percent(log), 37) }, anchor + appended.utf8.count,
                       "a grown log is read from the last scanned line, plus a short anchor")
        XCTAssertEqual(bytesRead { XCTAssertEqual(percent(log), 37) }, 0)
    }

    /// Measures one periodic Grok fallback on a log shaped like the live one
    /// (3,474,048 bytes, 12,356 lines, no billing line): an unchanged tick and
    /// a tick after Grok appended one line.
    func test_microbench_periodicScanOfAnUnchangedLargeLog() throws {
        let log = directory.appendingPathComponent("unified.jsonl")
        let lineCount = 12_356
        let pad = String(repeating: "x", count: 3_474_048 / lineCount - noiseLine.utf8.count)
        let line = #"{"ts":"2026-10-13T15:41:00.000Z","msg":"tool_result","ctx":{"output":""# + pad + #""}}"# + "\n"
        try String(repeating: line, count: lineCount).write(to: log, atomically: true, encoding: .utf8)

        func milliseconds(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        for _ in 0..<2 { XCTAssertNil(percent(log)) }
        var unchanged: [Double] = []
        var appended: [Double] = []
        for _ in 0..<7 {
            unchanged.append(milliseconds { XCTAssertNil(percent(log)) })
            try append(line, to: log)
            appended.append(milliseconds { XCTAssertNil(percent(log)) })
        }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        print("[perf-proof] grokBillingLogScan bytes=\(try FileManager.default.attributesOfItem(atPath: log.path)[.size] ?? 0) unchanged_ms=\(unchanged) appended_ms=\(appended) median_unchanged_ms=\(median(unchanged)) median_appended_ms=\(median(appended))")
    }
}
