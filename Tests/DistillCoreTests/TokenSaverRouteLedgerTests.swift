import XCTest
@testable import DistillCore

/// C5: BERT-first telemetry — share of requests resolved without the LLM and
/// encoder-vs-LLM average latency per traffic class.
final class TokenSaverRouteLedgerTests: XCTestCase {
    func test_resolvedWithoutLLMRateAndPerStageLatency() {
        var ledger = TokenSaverRouteLedger()
        ledger.record(.init(lane: .commandOutput, stage: .deterministic, wallClockMilliseconds: 2))
        ledger.record(.init(lane: .commandOutput, stage: .encoderBERT, wallClockMilliseconds: 40))
        ledger.record(.init(lane: .longText, stage: .encoderBERT, wallClockMilliseconds: 60))
        ledger.record(.init(lane: .wireEncode, stage: .llmMLX, wallClockMilliseconds: 1800))

        XCTAssertEqual(ledger.total, 4)
        XCTAssertEqual(ledger.resolvedWithoutLLM, 3)
        XCTAssertEqual(ledger.resolvedWithoutLLMRate, 0.75, accuracy: 0.0001)
        XCTAssertEqual(ledger.averageLatencyMillis(stage: .encoderBERT), 50, accuracy: 0.0001)
        XCTAssertEqual(ledger.averageLatencyMillis(stage: .llmMLX), 1800, accuracy: 0.0001)
        XCTAssertGreaterThan(
            ledger.averageLatencyMillis(stage: .llmMLX),
            ledger.averageLatencyMillis(stage: .encoderBERT),
            "the whole point of BERT-first: encoder is far cheaper than the LLM")
        XCTAssertEqual(ledger.resolvedWithoutLLMRate(lane: .commandOutput), 1.0, accuracy: 0.0001)
        XCTAssertEqual(ledger.resolvedWithoutLLMRate(lane: .wireEncode), 0.0, accuracy: 0.0001)
    }

    func test_emptyLedgerIsZeroNotNaN() {
        let ledger = TokenSaverRouteLedger()
        XCTAssertEqual(ledger.resolvedWithoutLLMRate, 0)
        XCTAssertEqual(ledger.averageLatencyMillis(stage: .encoderBERT), 0)
    }

    func test_externalAPIHasDistinctLedgerStageAndCountsAsGenerative() {
        var ledger = TokenSaverRouteLedger()
        ledger.record(.init(lane: .naturalLanguage, stage: .apiExternal, wallClockMilliseconds: 125))

        XCTAssertEqual(ledger.total, 1)
        XCTAssertEqual(ledger.resolvedWithoutLLM, 0)
        XCTAssertEqual(ledger.resolvedWithoutLLMRate, 0)
        XCTAssertEqual(ledger.averageLatencyMillis(stage: .apiExternal), 125)
        XCTAssertEqual(ledger.averageLatencyMillis(stage: .llmMLX), 0)
    }
}
