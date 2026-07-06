import XCTest
@testable import CoreModel

/// F39: `pendingItemDeltas` buffers deltas that arrive before their
/// `itemStarted` so out-of-order streams still render. But orphan ids never
/// pair: the codex adapter mints a FRESH UUID-fallback id per outputDelta line
/// when the handle is missing, and items evicted mid-run by trimTurnItems turn
/// their later deltas into orphans too. Unlike every other timeline collection
/// (turns, items, requests, activities — all capped) this dict had no bound and
/// no clear, so a long-lived run grew main-actor memory monotonically until the
/// thread was switched. The buffer must be capped oldest-first and dropped at
/// turn completion — while the legitimate delta-before-itemStarted pairing keeps
/// working.
final class AssistantEventsPendingItemDeltaTests: XCTestCase {

    private func orphanDelta(_ id: String, output: String = "x") -> AssistantEvent {
        .itemDelta(itemId: id, bodyAppend: nil, outputAppend: output, summary: nil)
    }

    func test_legitimateEarlyDelta_stillPairsWithItsLateItemStarted() {
        // Regression guard: the whole reason the buffer exists.
        var state = AssistantTimelineState()
        state.apply(.turnStarted(turnId: "t1"))
        state.apply(.itemDelta(itemId: "i1", bodyAppend: "hello ", outputAppend: nil, summary: nil))
        state.apply(.itemDelta(itemId: "i1", bodyAppend: "world", outputAppend: nil, summary: nil))
        state.apply(.itemStarted(item: AssistantItem(id: "i1", turnId: "t1", type: .assistantMessage, startedAtMs: 0)))

        XCTAssertEqual(state.turns.first?.items.first?.body, "hello world",
                       "deltas that race ahead of their itemStarted must still be applied when the item lands — " +
                       "the F39 bound may not break out-of-order stream rendering")
    }

    func test_orphanDeltas_areCappedOldestFirst() {
        var state = AssistantTimelineState()
        let limit = AssistantTimelineState.pendingItemDeltaLimit
        let total = limit * 4
        // Simulate the codex UUID-fallback flood: every delta line is a distinct,
        // permanently-orphaned key holding output text.
        for i in 0..<total {
            state.apply(orphanDelta("orphan-\(i)", output: String(repeating: "x", count: 64)))
        }
        #if DEBUG
        XCTAssertEqual(state.pendingItemDeltaCountForTesting, limit,
                       "orphan delta ids must be bounded — an uncapped buffer grows main-actor memory " +
                       "monotonically for the life of a long run (up to 120KB of text per orphan key)")
        #endif

        // Eviction must be oldest-first: the newest orphan is the only kind that
        // can still legitimately pair (a delta racing its itemStarted), so it must
        // survive while the oldest is gone.
        state.apply(.turnStarted(turnId: "t1"))
        state.apply(.itemStarted(item: AssistantItem(id: "orphan-0", turnId: "t1", type: .tool, startedAtMs: 0)))
        state.apply(.itemStarted(item: AssistantItem(id: "orphan-\(total - 1)", turnId: "t1", type: .tool, startedAtMs: 0)))
        let items = state.turns.first?.items ?? []
        XCTAssertNil(items.first(where: { $0.id == "orphan-0" })?.output,
                     "the OLDEST buffered delta must have been evicted once the cap was exceeded")
        XCTAssertEqual(items.first(where: { $0.id == "orphan-\(total - 1)" })?.output,
                       String(repeating: "x", count: 64),
                       "the NEWEST buffered delta must survive the cap so a real early-arriving delta still pairs")
    }

    func test_turnCompleted_dropsUnmatchedDeltas() {
        var state = AssistantTimelineState()
        state.apply(.turnStarted(turnId: "t1"))
        state.apply(orphanDelta("stale-item", output: "stale output"))
        state.apply(.turnCompleted(turnId: "t1", finalMessage: "done"))

        #if DEBUG
        XCTAssertEqual(state.pendingItemDeltaCountForTesting, 0,
                       "deltas still unmatched at turn end can never pair with a live item (items open with " +
                       "their turn) — retaining them is a pure leak")
        #endif
        // A later item that happens to reuse the id must not inherit the stale
        // cross-turn text.
        state.apply(.turnStarted(turnId: "t2"))
        state.apply(.itemStarted(item: AssistantItem(id: "stale-item", turnId: "t2", type: .tool, startedAtMs: 0)))
        XCTAssertNil(state.turns.last?.items.first?.output,
                     "an item started in a LATER turn must not absorb a previous turn's orphaned delta text")
    }
}
