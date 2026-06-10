import XCTest
@testable import AgentRuntime

// PERF-MAC_AGENT-007: fast provider streaming was issuing 2-3 synchronous SQLite
// writes per stream event (appendStreamEvent + appendProviderEventLog +
// updateDiagnostics), each its own transaction/fsync. The coordinator now buffers
// those writes and flushes them on a cadence. This pins the PURE cadence decision
// (count/time thresholds -> shouldFlush) and the buffer drain semantics, since a
// regression here would either re-introduce the per-event write storm (flush too
// eagerly) or silently delay/lose persisted stream events (flush too lazily).
final class StreamEventFlushCadenceTests: XCTestCase {

    // Within both thresholds -> do NOT flush. WHY: the whole point of batching is
    // to coalesce; a flush while still under count AND under time would defeat it
    // and bring back the per-event write storm.
    func test_belowBothThresholds_doesNotFlush() {
        let decision = AgentRunCoordinator.shouldFlushStreamBatch(
            pendingCount: 3,
            sinceLastFlushMs: 50,
            countThreshold: 16,
            timeThresholdMs: 250
        )
        XCTAssertFalse(decision)
    }

    // Pending count at the threshold -> flush. WHY: the count cap bounds the
    // in-memory buffer + the lock-held replay size; crossing it must drain.
    func test_atCountThreshold_flushes() {
        let decision = AgentRunCoordinator.shouldFlushStreamBatch(
            pendingCount: 16,
            sinceLastFlushMs: 0,
            countThreshold: 16,
            timeThresholdMs: 250
        )
        XCTAssertTrue(decision, "reaching the count cap must flush so the buffer cannot grow unbounded")
    }

    // Just under the count threshold and under time -> hold. WHY: off-by-one at
    // the boundary would either flush one event early (storm) or one event late.
    func test_justBelowCountThreshold_doesNotFlush() {
        let decision = AgentRunCoordinator.shouldFlushStreamBatch(
            pendingCount: 15,
            sinceLastFlushMs: 10,
            countThreshold: 16,
            timeThresholdMs: 250
        )
        XCTAssertFalse(decision)
    }

    // Time threshold elapsed even with a small buffer -> flush. WHY: a slow trickle
    // of events must still reach the DB within a bounded latency so a crash or a
    // reload does not lose the tail; count alone would strand them.
    func test_atTimeThreshold_flushesEvenWithSmallCount() {
        let decision = AgentRunCoordinator.shouldFlushStreamBatch(
            pendingCount: 1,
            sinceLastFlushMs: 250,
            countThreshold: 16,
            timeThresholdMs: 250
        )
        XCTAssertTrue(decision, "an elapsed time budget must flush the tail even below the count cap")
    }

    // Time elapsed but buffer empty -> nothing to flush. WHY: shouldFlush must be
    // a no-op when there is no pending work; flushing an empty batch would issue a
    // pointless diagnostics write every tick and re-create write pressure.
    func test_emptyBuffer_neverFlushes() {
        let decision = AgentRunCoordinator.shouldFlushStreamBatch(
            pendingCount: 0,
            sinceLastFlushMs: 10_000,
            countThreshold: 16,
            timeThresholdMs: 250
        )
        XCTAssertFalse(decision, "an empty buffer must never trigger a flush regardless of elapsed time")
    }

    // Drain returns the buffered items in order and leaves the buffer empty. WHY:
    // persisted stream-event ORDER (seq) must be preserved exactly, and a drain
    // that did not clear the buffer would re-persist (duplicate) on the next flush.
    func test_drain_returnsItemsInOrder_andEmptiesBuffer() {
        var buffer = AgentRunCoordinator.StreamWriteBatch()
        buffer.append(.init(seq: 1, kind: "a", payloadJSON: "{\"i\":1}", providerEvent: nil))
        buffer.append(.init(seq: 2, kind: "b", payloadJSON: "{\"i\":2}", providerEvent: nil))
        buffer.append(.init(seq: 3, kind: "c", payloadJSON: "{\"i\":3}", providerEvent: nil))

        let drained = buffer.drain()

        XCTAssertEqual(drained.map(\.seq), [1, 2, 3], "drain must preserve append (seq) order")
        XCTAssertEqual(drained.map(\.kind), ["a", "b", "c"])
        XCTAssertTrue(buffer.isEmpty, "drain must empty the buffer so items are not re-persisted on the next flush")
        XCTAssertTrue(buffer.drain().isEmpty, "a second drain of an emptied buffer must yield nothing")
    }

    // The last kind in the batch is the one diagnostics should report. WHY: the
    // coordinator coalesces N per-event updateDiagnostics writes into ONE per flush
    // using the last event's kind; that must equal the final buffered kind so the
    // session's lastEventKind matches the pre-batch behavior at the flush boundary.
    func test_drain_lastKind_isFinalBufferedKind() {
        var buffer = AgentRunCoordinator.StreamWriteBatch()
        buffer.append(.init(seq: 10, kind: "first", payloadJSON: "{}", providerEvent: nil))
        buffer.append(.init(seq: 11, kind: "last", payloadJSON: "{}", providerEvent: nil))

        let drained = buffer.drain()
        XCTAssertEqual(drained.last?.kind, "last",
                       "coalesced diagnostics must use the most recent event kind in the flushed batch")
    }
}
