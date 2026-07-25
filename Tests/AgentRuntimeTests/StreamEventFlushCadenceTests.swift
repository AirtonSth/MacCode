import XCTest
@testable import AgentRuntime
import CoreModel

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

    func test_atByteThreshold_flushesBeforeCountThreshold() {
        let decision = AgentRunCoordinator.shouldFlushStreamBatch(
            pendingCount: 2,
            pendingBytes: 512 * 1_024,
            sinceLastFlushMs: 0,
            countThreshold: 16,
            byteThreshold: 512 * 1_024,
            timeThresholdMs: 250
        )
        XCTAssertTrue(decision,
                      "two oversized provider frames must flush by encoded bytes instead of waiting for sixteen rows")
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

        XCTAssertGreaterThan(buffer.encodedByteCount, 0,
                             "retry high-water accounting must include encoded payload and kind bytes")

        let drained = buffer.drain()

        XCTAssertEqual(drained.map(\.seq), [1, 2, 3], "drain must preserve append (seq) order")
        XCTAssertEqual(drained.map(\.kind), ["a", "b", "c"])
        XCTAssertTrue(buffer.isEmpty, "drain must empty the buffer so items are not re-persisted on the next flush")
        XCTAssertTrue(buffer.drain().isEmpty, "a second drain of an emptied buffer must yield nothing")
    }

    func test_boundedRuntimeIdentifiers_keepsNewestWithinCountAndBytes() {
        var ids: [String] = []
        for index in 0..<20 {
            ids = AgentRunCoordinator.boundedRuntimeIdentifiers(
                existing: ids,
                adding: "request-\(index)",
                countLimit: 4,
                byteLimit: 36
            )
        }
        XCTAssertLessThanOrEqual(ids.count, 4)
        XCTAssertLessThanOrEqual(ids.reduce(0) { $0 + $1.utf8.count }, 36)
        XCTAssertEqual(ids.last, "request-19",
                       "the newest pending interaction must survive compact-state pressure")
    }

    func test_activePlanCompactBudget_rejectsOversizedRecoveryState() {
        let small = AssistantActivePlan(
            steps: [.init(id: "1", title: "bounded", status: .pending)],
            updatedAtMs: 1
        )
        XCTAssertTrue(AgentRunCoordinator.activePlanFitsCompactBudget(small, stepLimit: 2, byteLimit: 1_024))

        let tooMany = AssistantActivePlan(
            steps: (0..<3).map { .init(id: "\($0)", title: "step", status: .pending) },
            updatedAtMs: 1
        )
        XCTAssertFalse(AgentRunCoordinator.activePlanFitsCompactBudget(tooMany, stepLimit: 2, byteLimit: 1_024),
                       "correctness state must stop explicitly instead of growing a non-evictable step array")

        let tooLarge = AssistantActivePlan(
            explanation: String(repeating: "x", count: 2_048),
            steps: [],
            updatedAtMs: 1
        )
        XCTAssertFalse(AgentRunCoordinator.activePlanFitsCompactBudget(tooLarge, stepLimit: 2, byteLimit: 256))
    }

    func test_boundedHotReplay_keepsNewestFIFOAndNeverRetainsOversizedEvent() {
        let events = (0..<20).map {
            AssistantEvent.turnStarted(turnId: "turn-\($0)-" + String(repeating: "x", count: 64))
        }
        let replay = AgentRunCoordinator.boundedHotReplay(events, countLimit: 4, byteLimit: 10_000)
        XCTAssertEqual(replay.count, 4)
        XCTAssertEqual(replay.compactMap { event -> String? in
            if case .turnStarted(let id) = event { return id }
            return nil
        }.map { String($0.prefix(7)) }, ["turn-16", "turn-17", "turn-18", "turn-19"])

        let oversized = AssistantEvent.error(message: String(repeating: "z", count: 10_000), recoverable: true)
        XCTAssertTrue(
            AgentRunCoordinator.boundedHotReplay([events[0], oversized], countLimit: 4, byteLimit: 1).isEmpty,
            "frames larger than the whole hot-replay window are skipped (newest-first eviction), never retained above the ceiling"
        )
        // A normal newest event must still admit when an older oversized one is skipped.
        let normal = AssistantEvent.turnStarted(turnId: "keep-me")
        let mixed = AgentRunCoordinator.boundedHotReplay(
            [oversized, normal],
            countLimit: 4,
            byteLimit: 2_000
        )
        XCTAssertEqual(mixed.count, 1)
        if case .turnStarted(let id) = mixed[0] {
            XCTAssertEqual(id, "keep-me", "newest-fit event must survive after skipping a pathological older frame")
        } else {
            XCTFail("expected turnStarted after oversized skip")
        }
    }

    func test_persistedPayloadBoundingSoftTruncatesWithoutRecoverableError() throws {
        // Ordinary large frames (e.g. ~746 KiB Chrome dumps) must admit fully under
        // the 16 MB ceiling — no "omitted from local history" recoverable banner.
        let largeButAdmissible = String(repeating: "z", count: 700 * 1_024)
        let admitted = AgentRunCoordinator.boundedPersistedStreamPayload(largeButAdmissible)
        XCTAssertEqual(admitted, largeButAdmissible,
                       "frames under the per-event ceiling must persist verbatim")

        let pathological = String(repeating: "z", count: AgentRunCoordinator.maximumBufferedEventBytes + 50_000)
        let bounded = AgentRunCoordinator.boundedPersistedStreamPayload(pathological)
        XCTAssertLessThanOrEqual(bounded.utf8.count, AgentRunCoordinator.maximumBufferedEventBytes)
        XCTAssertNotEqual(bounded, pathological)
        XCTAssertTrue(bounded.contains("truncated"),
                      "only pathological frames soft-truncate; no recoverable error marker")
        XCTAssertFalse(bounded.contains("omitted from local history"),
                       "size pressure must never surface a user-facing omit/Retry error")

        let runtime = ProviderRuntimeEvent(
            id: "oversized", provider: .codex, source: "test", method: "event",
            payloadJSON: pathological, receivedAtMs: 1
        )
        let boundedRuntime = AgentRunCoordinator.boundedProviderRuntimeEvent(runtime)
        XCTAssertLessThanOrEqual(boundedRuntime.payloadJSON.utf8.count, AgentRunCoordinator.maximumBufferedEventBytes)
        XCTAssertTrue(boundedRuntime.payloadJSON.contains("truncated"))
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
