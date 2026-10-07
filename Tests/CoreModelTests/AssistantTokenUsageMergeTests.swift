import XCTest
@testable import CoreModel

/// Timeline tokenUsage merge must keep both per-request occupancy and
/// session-cumulative billing totals when Claude emits both shapes.
final class AssistantTokenUsageMergeTests: XCTestCase {

    /// Live-bug sequence: per-request assistant message.usage, then cumulative
    /// result modelUsage. Occupancy and billing must both survive.
    func test_timeline_perRequestThenCumulative_keepsContextTokensAndBillingTotals() {
        var state = AssistantTimelineState()

        // Exact sampled per-request payload (fact 4): occupancy 98786.
        state.apply(.tokenUsage(AssistantTokenUsage(
            inputTokens: 8,
            outputTokens: 1,
            totalTokens: 9,
            contextTokens: 98_786
        )))
        XCTAssertEqual(state.tokenUsage?.contextTokens, 98_786)

        // Exact cumulative payload (fact 2 / GAP A): 2880573 billing vs 200k window.
        state.apply(.tokenUsage(AssistantTokenUsage(
            inputTokens: 2_856_330,
            outputTokens: 24_243,
            totalTokens: 2_880_573,
            contextWindow: 200_000,
            uncachedInputTokens: 322,
            cacheCreationInputTokens: 98_777,
            cacheReadInputTokens: 2_757_231,
            contextTokens: nil
        )))

        let usage = state.tokenUsage
        XCTAssertEqual(usage?.contextTokens, 98_786,
                       "later cumulative event must not erase known contextTokens")
        XCTAssertEqual(usage?.totalTokens, 2_880_573,
                       "cumulative billing totalTokens must survive")
        XCTAssertEqual(usage?.inputTokens, 2_856_330)
        XCTAssertEqual(usage?.outputTokens, 24_243)
        XCTAssertEqual(usage?.uncachedInputTokens, 322)
        XCTAssertEqual(usage?.cacheCreationInputTokens, 98_777)
        XCTAssertEqual(usage?.cacheReadInputTokens, 2_757_231)
        XCTAssertEqual(usage?.contextWindow, 200_000)
    }

    func test_timeline_cumulativeThenPerRequest_keepsBillingAndTakesContextTokens() {
        var state = AssistantTimelineState()
        state.apply(.tokenUsage(AssistantTokenUsage(
            inputTokens: 2_856_330,
            outputTokens: 24_243,
            totalTokens: 2_880_573,
            contextWindow: 200_000,
            uncachedInputTokens: 322,
            cacheCreationInputTokens: 98_777,
            cacheReadInputTokens: 2_757_231,
            contextTokens: nil
        )))
        state.apply(.tokenUsage(AssistantTokenUsage(
            inputTokens: 8,
            outputTokens: 1,
            totalTokens: 9,
            contextTokens: 98_786
        )))

        let usage = state.tokenUsage
        XCTAssertEqual(usage?.contextTokens, 98_786,
                       "later per-request event supplies context occupancy")
        XCTAssertEqual(usage?.totalTokens, 2_880_573,
                       "smaller per-request totalTokens must not wipe cumulative billing")
        XCTAssertEqual(usage?.cacheReadInputTokens, 2_757_231)
        XCTAssertEqual(usage?.contextWindow, 200_000,
                       "context window from cumulative side must remain available for the gauge")
    }

    func test_merging_latestNonNilContextTokensWins() {
        let a = AssistantTokenUsage(totalTokens: 100, contextTokens: 40)
        let b = AssistantTokenUsage(totalTokens: 200, contextTokens: 90)
        let c = AssistantTokenUsage(totalTokens: 300, contextTokens: nil)

        XCTAssertEqual(AssistantTokenUsage.merging(a, with: b).contextTokens, 90)
        XCTAssertEqual(AssistantTokenUsage.merging(b, with: c).contextTokens, 90,
                       "nil contextTokens on later event must not clear occupancy")
    }
}
