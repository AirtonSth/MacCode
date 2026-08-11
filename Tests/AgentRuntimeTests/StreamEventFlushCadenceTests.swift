import XCTest
@testable import AgentRuntime
import CoreModel
@testable import Persistence

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

    /// R5-A: cheap estimate must be ≥ true JSON size so compact recovery never
    /// admits a plan that would exceed the wire-byte ceiling.
    func test_activePlanEstimatedCompactJSONBytes_isUpperBoundOfEncoder() throws {
        // Control-only payload: every byte becomes `\u00XX` (6) on the wire.
        let controlOnly = String(repeating: "\u{0001}", count: 100)
        let fixtures: [AssistantActivePlan] = [
            AssistantActivePlan(steps: [], updatedAtMs: 0),
            AssistantActivePlan(
                explanation: "short",
                steps: [.init(id: "a", title: "t", status: .pending)],
                updatedAtMs: 42
            ),
            AssistantActivePlan(
                explanation: String(repeating: "plan ", count: 200),
                steps: (0..<20).map {
                    .init(id: "s\($0)", title: "Step \($0) with \"quotes\" and\nnewlines", status: .inProgress)
                },
                updatedAtMs: 1_700_000_000_000
            ),
            AssistantActivePlan(
                explanation: "ctrl:\u{0001}\u{0008}\t",
                steps: [.init(id: "x", title: "done", status: .completed)],
                updatedAtMs: 9
            ),
            AssistantActivePlan(
                explanation: controlOnly,
                steps: [.init(id: controlOnly, title: controlOnly, status: .pending)],
                updatedAtMs: 1
            ),
            AssistantActivePlan(
                explanation: String(repeating: "\\\"", count: 80),
                steps: [.init(id: "q", title: String(repeating: "\\", count: 40), status: .completed)],
                updatedAtMs: 99
            ),
        ]
        let encoder = JSONEncoder()
        for plan in fixtures {
            let encoded = try encoder.encode(plan)
            XCTAssertGreaterThanOrEqual(
                plan.estimatedCompactJSONBytes,
                encoded.count,
                "estimate must upper-bound JSON size (estimate=\(plan.estimatedCompactJSONBytes) encoded=\(encoded.count))"
            )
        }
    }

    func test_activePlanCompactBudget_microbench_estimateVsJSONEncoder() {
        let plan = AssistantActivePlan(
            explanation: String(repeating: "detail ", count: 80),
            steps: (0..<40).map {
                .init(id: "step-\($0)", title: "Title for step \($0) with more text", status: .pending)
            },
            updatedAtMs: 1_700_000_000_000
        )
        let iterations = 8_000
        let warmup = 2
        let samples = 5
        let encoder = JSONEncoder()
        let lock = NSLock()

        func timeJSON() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var accepted = 0
            for _ in 0..<iterations {
                lock.lock()
                let bytes = (try? encoder.encode(plan))?.count ?? Int.max
                lock.unlock()
                if bytes <= 256 * 1_024 { accepted &+= 1 }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(accepted, iterations)
            return Double(end - start) / 1_000_000.0
        }
        func timeEstimate() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var accepted = 0
            for _ in 0..<iterations {
                if plan.estimatedCompactJSONBytes <= 256 * 1_024 { accepted &+= 1 }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(accepted, iterations)
            return Double(end - start) / 1_000_000.0
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        for _ in 0..<warmup { _ = timeJSON(); _ = timeEstimate() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeJSON())
            after.append(timeEstimate())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] activePlan budget encode_ms=%@ estimate_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "estimate-based plan budget must beat JSONEncoder by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
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

    // MARK: - Soft truncate (UTF-8 index, Character-safe)

    func test_softTruncateUTF8Payload_underLimitIsIdentity() {
        let small = String(repeating: "a", count: 100)
        XCTAssertEqual(
            AgentRunCoordinator.softTruncateUTF8Payload(small, byteLimit: 1_000),
            small
        )
    }

    func test_softTruncateUTF8Payload_preservesTrailerAndNeverSplitsMultibyte() {
        // "é" is 2 UTF-8 bytes; head budget must not land mid-scalar.
        let payload = String(repeating: "é", count: 50_000)
        let limit = 1_024
        let bounded = AgentRunCoordinator.softTruncateUTF8Payload(payload, byteLimit: limit)
        XCTAssertLessThanOrEqual(bounded.utf8.count, limit)
        XCTAssertTrue(bounded.contains("truncated"), "trailer must report original→limit")
        XCTAssertTrue(bounded.hasPrefix("é") || bounded.hasPrefix("…"),
                      "head must start on a Character boundary")
        // No broken UTF-8: re-roundtrip via Data.
        XCTAssertEqual(String(data: Data(bounded.utf8), encoding: .utf8), bounded)

        let emojiPayload = String(repeating: "😀", count: 10_000)
        let emojiBounded = AgentRunCoordinator.softTruncateUTF8Payload(emojiPayload, byteLimit: 2_048)
        XCTAssertLessThanOrEqual(emojiBounded.utf8.count, 2_048)
        XCTAssertEqual(String(data: Data(emojiBounded.utf8), encoding: .utf8), emojiBounded)
        XCTAssertTrue(emojiBounded.contains("truncated"))
    }

    func test_softTruncateUTF8Payload_repoMatchesCoordinatorSemantics() {
        let payload = String(repeating: "x", count: 10_000) + "ééé"
        let limit = 4_096
        let a = AgentRunCoordinator.softTruncateUTF8Payload(payload, byteLimit: limit)
        let b = try! AgentRunRepository.softTruncateUTF8Payload(payload, byteLimit: limit, reversibleStore: nil)
        XCTAssertEqual(a, b, "persist + buffer must share one truncation policy")
        XCTAssertLessThanOrEqual(a.utf8.count, limit)
    }

    /// Microbench: Character-index walk vs UTF-8 index soft-truncate.
    /// Named metric: wall time for N truncations of a payload over the limit.
    func test_microbench_softTruncate_utf8FasterThanCharacterWalk() {
        // ~2 MiB ASCII body slightly over a 1 MiB limit — Character walk pays
        // grapheme-index overhead on the admitted head; UTF-8 index does not.
        let payload = String(repeating: "x", count: 2 * 1_024 * 1_024)
        let limit = 1 * 1_024 * 1_024
        let iterations = 8
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        /// Legacy Character walk retained only for A/B (mirrors pre-fix body).
        func legacyCharacterWalk(_ payloadJSON: String, byteLimit: Int) -> String {
            let limit = max(1, byteLimit)
            let originalBytes = payloadJSON.utf8.count
            guard originalBytes > limit else { return payloadJSON }
            let trailer = "…[truncated \(originalBytes)→\(limit) bytes]"
            let headBudget = max(0, limit - trailer.utf8.count)
            var consumed = 0
            var end = payloadJSON.startIndex
            for index in payloadJSON.indices {
                let step = String(payloadJSON[index]).utf8.count
                if consumed + step > headBudget { break }
                consumed += step
                end = payloadJSON.index(after: index)
            }
            return String(payloadJSON[..<end]) + trailer
        }

        func timeLegacy() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                sink &+= legacyCharacterWalk(payload, byteLimit: limit).utf8.count
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        func timeUTF8() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                sink &+= AgentRunCoordinator.softTruncateUTF8Payload(payload, byteLimit: limit).utf8.count
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup { _ = timeLegacy(); _ = timeUTF8() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeLegacy())
            after.append(timeUTF8())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] softTruncate character_ms=%@ utf8_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "softTruncate UTF-8 path must beat Character walk by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
        // Functional pin: product path still under the limit with trailer.
        let sample = AgentRunCoordinator.softTruncateUTF8Payload(payload, byteLimit: limit)
        XCTAssertLessThanOrEqual(sample.utf8.count, limit)
        XCTAssertTrue(sample.contains("truncated"))
    }

    // MARK: - StreamWriteBatch running encodedByteCount (R3)

    func test_streamWriteBatch_encodedByteCountTracksAppendAcknowledgeDrain() {
        var batch = AgentRunCoordinator.StreamWriteBatch()
        XCTAssertEqual(batch.encodedByteCount, 0)

        let a = AgentRunCoordinator.StreamWriteItem(
            seq: 1, kind: "a", payloadJSON: "{\"i\":1}", providerEvent: nil
        )
        let b = AgentRunCoordinator.StreamWriteItem(
            seq: 2, kind: "b", payloadJSON: "{\"i\":22}", providerEvent: nil
        )
        batch.append(a)
        XCTAssertEqual(batch.encodedByteCount, a.encodedByteCount)
        batch.append(b)
        XCTAssertEqual(batch.encodedByteCount, a.encodedByteCount + b.encodedByteCount,
                       "running total must match sum without re-reduce")

        XCTAssertTrue(batch.acknowledge([a]))
        XCTAssertEqual(batch.encodedByteCount, b.encodedByteCount)
        XCTAssertEqual(batch.count, 1)

        _ = batch.drain()
        XCTAssertEqual(batch.encodedByteCount, 0)
        XCTAssertTrue(batch.isEmpty)
    }
}
