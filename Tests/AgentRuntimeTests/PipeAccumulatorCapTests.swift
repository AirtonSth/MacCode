import XCTest
@testable import AgentRuntime

/// ProviderCLIProbe PipeAccumulator bounded retention (memory R6 residual).
///
/// WHY: probe paths only need the start of `--version` / auth JSON. Uncapped
/// accumulation let chatty provider output pin multi-MB Data; 128 KiB retains
/// the useful probe prefix or update diagnostic suffix while still draining to EOF
/// (no pipe deadlock).
final class PipeAccumulatorCapTests: XCTestCase {
    func test_defaultMaxBytes_is128KiB() {
        XCTAssertEqual(PipeAccumulator.defaultMaxBytes, 128 * 1_024)
    }

    func test_append_truncatesPastCap() {
        var acc = PipeAccumulator(maxBytes: 32)
        acc.append(Data(repeating: 0x41, count: 64))
        XCTAssertEqual(acc.data.count, 32)
        XCTAssertTrue(acc.truncated)
        XCTAssertTrue(acc.isFull)
    }

    func test_suffixRetentionKeepsNewestDiagnosticAndMarksTruncation() {
        var acc = PipeAccumulator(maxBytes: 4, retention: .suffix)
        acc.append(Data("abcdefghij".utf8))

        XCTAssertEqual(acc.string, "ghij",
                       "update diagnostics must retain the terminal tail rather than only an unhelpful prefix")
        XCTAssertTrue(acc.truncated,
                      "the caller must be able to make bounded-tail loss visible to the user")
        XCTAssertTrue(acc.renderedString.hasPrefix("[RemoteCode] provider update output truncated"),
                      "rendered update output must identify suffix truncation before the retained diagnostic")
    }

    func test_retainedPrefix_matchesAppendPolicy() {
        let data = Data(repeating: 0x42, count: 100)
        XCTAssertEqual(PipeAccumulator.retainedPrefix(data, maxBytes: 16).count, 16)
        XCTAssertEqual(PipeAccumulator.retainedPrefix(data, maxBytes: 200), data)
    }

    func test_retentionEstimate_unboundedTo128KiB() {
        let uncapped = 5 * 1_024 * 1_024
        let limit = PipeAccumulator.defaultMaxBytes
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.97)
        XCTAssertEqual(limit, 128 * 1_024)
    }
}
