import Darwin
import XCTest
@testable import AgentRuntime
import CoreModel

final class GrokACPRetentionTests: XCTestCase {
    func test_historyRetentionPrunesAtHighWaterAndKeepsNewestOrder() {
        var history = GrokACPHistoryRetention(
            eventLimit: 3,
            byteLimit: 1_000_000,
            eventSlack: 2,
            byteSlack: 1_000_000
        )

        for index in 0..<5 {
            history.append(.turnStarted(turnId: "turn-\(index)"))
        }
        XCTAssertEqual(history.bufferedEventCount, 5,
                       "physical compaction must wait at the high-water mark")
        XCTAssertEqual(history.readableEvents.compactMap(Self.turnStartedID), ["turn-2", "turn-3", "turn-4"],
                       "the logical public window must stay exact during physical slack")

        history.append(.turnStarted(turnId: "turn-5"))

        XCTAssertEqual(history.bufferedEventCount, 3,
                       "crossing physical slack must release the discarded prefix")
        XCTAssertEqual(history.readableEvents.compactMap(Self.turnStartedID), ["turn-3", "turn-4", "turn-5"],
                       "the public history must stay exact and FIFO ordered")
    }

    /// WHY: every resident session reserved the whole 5,121-slot window up
    /// front (~750 KB of AssistantEvent storage) even for a one-message thread.
    /// Small sessions must stay small; a full window must not grow past the old
    /// reservation (plain doubling would reach 8,192 slots).
    func test_historyRetentionGrowsWithItsEventsInsteadOfPreallocatingTheWindow() {
        var history = GrokACPHistoryRetention()
        let window = AgentRunCoordinator.hotReplayEventCount + GrokACPHistoryRetention.eventPruneSlack + 1
        for index in 0..<10 {
            history.append(.turnStarted(turnId: "turn-\(index)"))
        }
        XCTAssertLessThanOrEqual(history.storageCapacityForTesting, 64, "ten events must not pin the whole window")
        var reserved: [AssistantEvent] = []
        reserved.reserveCapacity(window)
        var peakCapacity = 0
        for index in 10..<(window * 3) {
            history.append(.turnStarted(turnId: "turn-\(index)"))
            peakCapacity = max(peakCapacity, history.storageCapacityForTesting)
        }
        XCTAssertLessThanOrEqual(peakCapacity, reserved.capacity, "a full window must not outgrow the old reservation")
        XCTAssertEqual(history.readableEvents.count, AgentRunCoordinator.hotReplayEventCount)
        XCTAssertEqual(history.readableEvents.last.flatMap(Self.turnStartedID), "turn-\(window * 3 - 1)",
                       "growth must keep the newest event last")
    }

    func test_historyByteLimitKeepsRecentPartialDiagnosticAndTerminal() {
        var history = GrokACPHistoryRetention(
            eventLimit: 100,
            byteLimit: 900,
            eventSlack: 0,
            byteSlack: 0
        )
        for id in ["old", "middle", "recent"] {
            history.append(.itemDelta(
                itemId: id,
                bodyAppend: String(repeating: id.first ?? "x", count: 300),
                outputAppend: nil,
                summary: nil
            ))
        }
        history.append(.error(
            message: "partial replay: corrupt frame remains visible",
            recoverable: false
        ))
        history.append(.turnCompleted(turnId: "turn-final", finalMessage: "terminal"))

        let readable = history.readableEvents
        XCTAssertLessThanOrEqual(
            readable.reduce(into: Int64(0)) { $0 += Int64($1.estimatedHotQueueBytes) },
            900
        )
        XCTAssertLessThanOrEqual(history.bufferedEstimatedBytes, 900,
                                 "zero slack must release evicted payload bytes immediately")
        XCTAssertTrue(readable.contains {
            if case .error(let message, let recoverable) = $0 {
                return message.contains("partial replay") && !recoverable
            }
            return false
        }, "a recent partial/corruption diagnostic must not be replaced by silent truncation")
        XCTAssertTrue(readable.contains {
            if case .turnCompleted(let id, let final) = $0 {
                return id == "turn-final" && final == "terminal"
            }
            return false
        }, "the newest terminal must survive byte-budget pruning")
        XCTAssertEqual(Self.itemDeltaID(readable.first), "recent",
                       "byte pruning must preserve the newest fitting suffix in order")
    }

    /// Same-process A/B of the exact pre-checkpoint unbounded collections and
    /// the production bounded windows. Primary gate is retained bytes/count;
    /// wall and process CPU are captured to quantify hot-path overhead.
    func test_microbench_50kEventsBoundsHistoryAndDedupe() {
        let eventCount = 50_000
        let events: [AssistantEvent] = (0..<eventCount).map { index in
            .itemDelta(
                itemId: "item-\(index)",
                bodyAppend: "representative Grok ACP stream delta \(index) "
                    + String(repeating: "x", count: 96),
                outputAppend: nil,
                summary: nil
            )
        }
        let eventIDs = (0..<eventCount).map { "event-\($0)" }

        func runLegacy() -> GrokRetentionPerfSample {
            var history: [AssistantEvent] = []
            var seenEventIDs = Set<String>()
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = Self.processCPUNanoseconds()
            for index in events.indices where seenEventIDs.insert(eventIDs[index]).inserted {
                history.append(events[index])
            }
            let cpuEnd = Self.processCPUNanoseconds()
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            return GrokRetentionPerfSample(
                wallMs: Double(wallEnd - wallStart) / 1_000_000,
                cpuMs: Double(cpuEnd - cpuStart) / 1_000_000,
                retainedEventCount: history.count,
                retainedIDCount: seenEventIDs.count,
                retainedEventBytes: history.reduce(into: Int64(0)) {
                    $0 += Int64($1.estimatedHotQueueBytes)
                },
                peakCollectionCount: history.count + seenEventIDs.count,
                readableEventCount: history.count
            )
        }

        func runBounded() -> GrokRetentionPerfSample {
            var history = GrokACPHistoryRetention()
            var seenEventIDs = GrokACPRecentEventIDs()
            var peakCollectionCount = 0
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let cpuStart = Self.processCPUNanoseconds()
            for index in events.indices where seenEventIDs.insert(eventIDs[index]) {
                history.append(events[index])
                peakCollectionCount = max(
                    peakCollectionCount,
                    history.bufferedEventCount + seenEventIDs.bufferedCount
                )
            }
            let cpuEnd = Self.processCPUNanoseconds()
            let wallEnd = DispatchTime.now().uptimeNanoseconds
            return GrokRetentionPerfSample(
                wallMs: Double(wallEnd - wallStart) / 1_000_000,
                cpuMs: Double(cpuEnd - cpuStart) / 1_000_000,
                retainedEventCount: history.bufferedEventCount,
                retainedIDCount: seenEventIDs.bufferedCount,
                retainedEventBytes: history.bufferedEstimatedBytes,
                peakCollectionCount: peakCollectionCount,
                readableEventCount: history.readableEvents.count
            )
        }

        for _ in 0..<2 {
            _ = runLegacy()
            _ = runBounded()
        }

        var before: [GrokRetentionPerfSample] = []
        var after: [GrokRetentionPerfSample] = []
        for sample in 0..<5 {
            if sample.isMultiple(of: 2) {
                before.append(runLegacy())
                after.append(runBounded())
            } else {
                after.append(runBounded())
                before.append(runLegacy())
            }
        }

        let beforeWall = Self.median(before.map(\.wallMs))
        let afterWall = Self.median(after.map(\.wallMs))
        let beforeCPU = Self.median(before.map(\.cpuMs))
        let afterCPU = Self.median(after.map(\.cpuMs))
        let retainedCountBefore = before[0].retainedEventCount + before[0].retainedIDCount
        let retainedCountAfter = after[0].retainedEventCount + after[0].retainedIDCount
        let retainedCountReduction = Double(retainedCountBefore - retainedCountAfter)
            / Double(retainedCountBefore) * 100
        let retainedByteReduction = Double(before[0].retainedEventBytes - after[0].retainedEventBytes)
            / Double(before[0].retainedEventBytes) * 100

        NSLog(
            "[perf-proof] grokRetention50k wall_before_ms=%@ wall_after_ms=%@ cpu_before_ms=%@ cpu_after_ms=%@ retained_count_before=%d retained_count_after=%d retained_count_reduction_pct=%.2f retained_event_bytes_before=%lld retained_event_bytes_after=%lld retained_byte_reduction_pct=%.2f peak_after=%d wall_raw_before=%@ wall_raw_after=%@ cpu_raw_before=%@ cpu_raw_after=%@",
            String(beforeWall), String(afterWall), String(beforeCPU), String(afterCPU),
            retainedCountBefore, retainedCountAfter, retainedCountReduction,
            before[0].retainedEventBytes, after[0].retainedEventBytes, retainedByteReduction,
            after.map(\.peakCollectionCount).max() ?? 0,
            String(describing: before.map(\.wallMs)), String(describing: after.map(\.wallMs)),
            String(describing: before.map(\.cpuMs)), String(describing: after.map(\.cpuMs))
        )

        XCTAssertGreaterThan(retainedCountReduction, 5,
                             "bounded history+dedupe must reduce retained collection entries by >5%")
        XCTAssertGreaterThan(retainedByteReduction, 5,
                             "bounded history must reduce retained event-byte proxy by >5%")
        XCTAssertEqual(after[0].readableEventCount, AgentRunCoordinator.hotReplayEventCount)
        XCTAssertLessThanOrEqual(
            after.map(\.peakCollectionCount).max() ?? .max,
            2 * (AgentRunCoordinator.hotReplayEventCount + GrokACPHistoryRetention.eventPruneSlack)
        )
    }

    private static func processCPUNanoseconds() -> UInt64 {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return UInt64(value.tv_sec) * 1_000_000_000 + UInt64(value.tv_nsec)
    }

    private static func median(_ values: [Double]) -> Double {
        values.sorted()[values.count / 2]
    }

    private static func turnStartedID(_ event: AssistantEvent) -> String? {
        guard case .turnStarted(let id) = event else { return nil }
        return id
    }

    private static func itemDeltaID(_ event: AssistantEvent?) -> String? {
        guard let event, case .itemDelta(let id, _, _, _) = event else { return nil }
        return id
    }
}

private struct GrokRetentionPerfSample {
    let wallMs: Double
    let cpuMs: Double
    let retainedEventCount: Int
    let retainedIDCount: Int
    let retainedEventBytes: Int64
    let peakCollectionCount: Int
    let readableEventCount: Int
}
