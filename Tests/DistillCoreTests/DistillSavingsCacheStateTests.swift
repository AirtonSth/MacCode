import XCTest
@testable import DistillCore

final class DistillSavingsCacheStateTests: XCTestCase {
    private func record(for mode: DistillMode) -> DistillSavingsRecord? {
        let request = DistillRequest(mode: mode, input: "some representative input here", provider: "claude", recordSavings: true)
        let response = DistillResponse(requestID: request.id, output: "compressed", inputCharacters: 30, inputTokens: 10, outputTokens: 2)
        return DistillSavingsCalculator.record(for: request, response: response)
    }

    func test_cacheStateTaggedByMode() {
        // G3: tool output via the CLI is cache-neutral (consumed once); the prompt path
        // is cache-relevant; response modes are tagged distinctly so the headline can
        // keep only honest rows.
        XCTAssertEqual(record(for: .commandOutput)?.cacheState, "tool_output_oneshot")
        XCTAssertEqual(record(for: .longText)?.cacheState, "prompt")
        XCTAssertEqual(record(for: .watchSummary)?.cacheState, "watch")
        XCTAssertEqual(record(for: .sr1Humanize)?.cacheState, "sr1_humanize")
    }

    func test_defaultCacheStateIsUnknown() {
        XCTAssertEqual(DistillSavingsRecord(provider: "x", mode: "m", inputTokens: 1, outputTokens: 0, savedTokens: 1).cacheState, "unknown")
    }
}
