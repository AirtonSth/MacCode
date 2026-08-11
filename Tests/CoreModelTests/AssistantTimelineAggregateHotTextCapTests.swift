import XCTest
@testable import CoreModel

/// Aggregate live-timeline text ceiling (memory R6 residual).
///
/// WHY: Per-item liveTextLimit / liveOutputLimit still leave multi-turn tool
/// storms able to pin multi-hundred-MB of rendered text on one selected thread.
/// `enforceAggregateHotTextBudget` is the only whole-timeline backstop; keep it
/// aligned with the durable hot-replay payload ceiling (32 MiB).
final class AssistantTimelineAggregateHotTextCapTests: XCTestCase {

    func test_aggregateHotTextByteLimit_is32MiB() {
        XCTAssertEqual(AssistantTimelineState.aggregateHotTextByteLimit, 32 * 1_024 * 1_024)
        // Prior production ceiling was 96 MiB.
        XCTAssertLessThan(
            AssistantTimelineState.aggregateHotTextByteLimit,
            96 * 1_024 * 1_024
        )
    }

    func test_retentionEstimate_96MiBTo32MiB() {
        let prior = 96 * 1_024 * 1_024
        let limit = AssistantTimelineState.aggregateHotTextByteLimit
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertEqual(reduction, 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(limit, 32 * 1_024 * 1_024)
    }

    func test_enforceAggregateHotTextBudget_respectsLimit() {
        let limit = 8_000
        var state = AssistantTimelineState()
        let body = String(repeating: "b", count: 3_000)
        for i in 0..<10 {
            let turnId = "t-\(i)"
            state.apply(.turnStarted(turnId: turnId))
            state.apply(.itemStarted(item: AssistantItem(
                id: "i-\(i)",
                turnId: turnId,
                type: .assistantMessage,
                state: .completed,
                body: body,
                startedAtMs: Int64(i)
            )))
        }
        XCTAssertGreaterThan(state.aggregateHotTextByteCount, limit)
        state.enforceAggregateHotTextBudget(byteLimit: limit)
        XCTAssertLessThanOrEqual(state.aggregateHotTextByteCount, limit)
    }
}
