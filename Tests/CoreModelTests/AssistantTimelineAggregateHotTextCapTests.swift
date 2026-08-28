import Dispatch
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

    /// Under-limit repeats (and small watermarked growth) must not re-walk the
    /// whole timeline. Over-limit must still take the exact eviction path.
    func test_enforceAggregateHotTextBudget_underLimitRepeatsSkipWalkAndPreserveSemantics() {
        AssistantTimelineState.aggregateHotTextExactWalksForTesting = 0
        var state = AssistantTimelineState()
        for i in 0..<24 {
            let turnId = "t-\(i)"
            state.apply(.turnStarted(turnId: turnId))
            state.apply(.itemStarted(item: AssistantItem(
                id: "i-\(i)",
                turnId: turnId,
                type: .assistantMessage,
                state: .completed,
                body: String(repeating: "b", count: 400),
                startedAtMs: Int64(i)
            )))
        }
        let underLimit = 2_000_000
        XCTAssertLessThan(state.aggregateHotTextByteCount, underLimit)

        state.enforceAggregateHotTextBudget(byteLimit: underLimit)
        XCTAssertEqual(
            AssistantTimelineState.aggregateHotTextExactWalksForTesting,
            1,
            "first enforce must take the exact walk to seed lastMeasured"
        )

        for _ in 0..<64 {
            state.enforceAggregateHotTextBudget(byteLimit: underLimit)
        }
        XCTAssertEqual(
            AssistantTimelineState.aggregateHotTextExactWalksForTesting,
            1,
            "under-limit repeats with no growth must stay O(1) and skip the walk"
        )

        state.apply(.itemDelta(
            itemId: "i-23",
            bodyAppend: "tok",
            outputAppend: nil,
            summary: nil
        ))
        state.enforceAggregateHotTextBudget(byteLimit: underLimit)
        XCTAssertEqual(
            AssistantTimelineState.aggregateHotTextExactWalksForTesting,
            1,
            "small under-watermark growth must not force another exact walk"
        )
        XCTAssertLessThan(state.aggregateHotTextByteCount, underLimit)

        let tightLimit = 8_000
        XCTAssertGreaterThan(state.aggregateHotTextByteCount, tightLimit)
        state.enforceAggregateHotTextBudget(byteLimit: tightLimit)
        XCTAssertEqual(
            AssistantTimelineState.aggregateHotTextExactWalksForTesting,
            2,
            "crossing the limit must take the exact eviction path"
        )
        XCTAssertLessThanOrEqual(state.aggregateHotTextByteCount, tightLimit)
    }

    func test_enforceAggregateHotTextBudget_underLimitRepeatsStayCheap() {
        var state = AssistantTimelineState()
        for i in 0..<80 {
            let turnId = "turn-\(i)"
            state.apply(.turnStarted(turnId: turnId))
            state.apply(.itemStarted(item: AssistantItem(
                id: "item-\(i)",
                turnId: turnId,
                type: .assistantMessage,
                state: .completed,
                body: String(repeating: "B", count: 1_024),
                startedAtMs: Int64(i)
            )))
        }
        let limit = 8_000_000
        XCTAssertLessThan(state.aggregateHotTextByteCount, limit)
        state.enforceAggregateHotTextBudget(byteLimit: limit)

        func timeMs(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }

        let repeats = 400
        var walkSink = 0
        let walkMs = timeMs {
            for _ in 0..<repeats {
                walkSink &+= state.aggregateHotTextByteCount
            }
        }
        var enforceSink = 0
        let enforceMs = timeMs {
            for _ in 0..<repeats {
                state.enforceAggregateHotTextBudget(byteLimit: limit)
                enforceSink &+= 1
            }
        }
        XCTAssertGreaterThan(walkSink, 0)
        XCTAssertEqual(enforceSink, repeats)
        XCTAssertLessThan(
            enforceMs,
            walkMs * 0.5,
            "cached under-limit enforce must beat a full walk (walk=\(walkMs)ms enforce=\(enforceMs)ms)"
        )
    }
}
