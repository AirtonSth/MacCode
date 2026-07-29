import XCTest
@testable import Surfaces
import CoreModel

/// Context gauge must show true per-request occupancy, never a % from
/// session-cumulative billing totals (the 999% bug).
final class AgentContextStatusPresentationTests: XCTestCase {

    /// Exact cumulative live-bug row: uncached 322 + creation 98777 + read 2757231
    /// + output 24243 = 2880573 total against a 200000 window. Must not render
    /// "999%" or any percentage over 100.
    func test_cumulativeBillingWithoutContextTokens_doesNotRenderInflatedPercentage() {
        let usage = AssistantTokenUsage(
            inputTokens: 2_856_330,
            outputTokens: 24_243,
            totalTokens: 2_880_573,
            contextWindow: 200_000,
            uncachedInputTokens: 322,
            cacheCreationInputTokens: 98_777,
            cacheReadInputTokens: 2_757_231,
            contextTokens: nil
        )
        let message = AgentContextStatusPresentation.message(
            usage: usage,
            compactionSummary: nil
        )
        let text = try! XCTUnwrap(message)
        XCTAssertFalse(text.contains("999%"),
                       "must never show the pre-fix 999% from cumulative totalTokens")
        XCTAssertFalse(text.contains("%"),
                       "without contextTokens, do not derive any percentage from totalTokens")
        XCTAssertTrue(text.contains("Session"),
                      "session-billing totals use clearly different wording from Context %")
        XCTAssertTrue(text.contains("2880573"),
                      "session token count remains visible for diagnostics")
        XCTAssertTrue(text.contains("200000"))
    }

    /// Exact per-request sample (fact 4): 8+504+98273+1 = 98786 ≈ 49% of 200000.
    func test_perRequestContextTokens_rendersOccupancyPercentAndNumerator() {
        let usage = AssistantTokenUsage(
            inputTokens: 8,
            outputTokens: 1,
            totalTokens: 9,
            contextWindow: 200_000,
            contextTokens: 98_786
        )
        let message = AgentContextStatusPresentation.message(
            usage: usage,
            compactionSummary: nil
        )
        XCTAssertEqual(message, "Context 49% · 98786 / 200000 tokens",
                       "gauge must show true occupancy from contextTokens, not billing totalTokens")
    }

    func test_contextTokensAboveWindow_clampsPercentTo100() {
        let usage = AssistantTokenUsage(
            totalTokens: 50,
            contextWindow: 100,
            contextTokens: 250
        )
        let message = AgentContextStatusPresentation.message(
            usage: usage,
            compactionSummary: nil
        )
        let text = try! XCTUnwrap(message)
        XCTAssertTrue(text.hasPrefix("Context 100%"),
                      "safety clamp must keep occupancy percent in 0...100")
        XCTAssertFalse(text.contains("999%"))
        XCTAssertTrue(text.contains("250 / 100"))
    }
}
