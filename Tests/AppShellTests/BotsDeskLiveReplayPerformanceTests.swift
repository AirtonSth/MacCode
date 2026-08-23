import XCTest
import CoreModel
@testable import AgentRuntime
@testable import AppShell
@testable import Persistence
import Surfaces

@MainActor
final class BotsDeskLiveReplayPerformanceTests: XCTestCase {
    private struct TimedSample {
        let wallNanoseconds: UInt64
        let fullReplays: Int
        let decodedPayloadBytes: Int64
    }

    private final class Harness {
        let root: URL
        let context: AppContext
        let viewModel: BotsViewModel
        let thread: AgentThread
        let run: AgentRun
        var nextSequence: Int
        var windowPayloadBytes: [Int64]

        init(
            root: URL,
            context: AppContext,
            viewModel: BotsViewModel,
            thread: AgentThread,
            run: AgentRun,
            nextSequence: Int,
            windowPayloadBytes: [Int64]
        ) {
            self.root = root
            self.context = context
            self.viewModel = viewModel
            self.thread = thread
            self.run = run
            self.nextSequence = nextSequence
            self.windowPayloadBytes = windowPayloadBytes
        }
    }

    func test_benchmarkObserverWatermarkBeatsFullReplayByMoreThanFivePercent() throws {
        guard ProcessInfo.processInfo.environment["RC2_BOTS_REPLAY_BENCHMARK"] == "1" else {
            throw XCTSkip("Set RC2_BOTS_REPLAY_BENCHMARK=1 to run the Bots Desk replay A/B benchmark.")
        }

        let fixtureEventCount = 4_096
        let eventsPerSample = 32
        let warmupCount = 2
        let measuredCount = 5
        let legacy = try makeHarness(label: "legacy", fixtureEventCount: fixtureEventCount)
        let candidate = try makeHarness(label: "candidate", fixtureEventCount: fixtureEventCount)
        defer {
            try? FileManager.default.removeItem(at: legacy.root)
            try? FileManager.default.removeItem(at: candidate.root)
        }

        for warmup in 0..<warmupCount {
            _ = try measureLegacy(legacy, sample: -warmup - 1, eventCount: eventsPerSample)
            _ = try measureCandidate(candidate, sample: -warmup - 1, eventCount: eventsPerSample)
        }

        var legacySamples: [TimedSample] = []
        var candidateSamples: [TimedSample] = []
        for sample in 0..<measuredCount {
            if sample.isMultiple(of: 2) {
                legacySamples.append(try measureLegacy(legacy, sample: sample, eventCount: eventsPerSample))
                candidateSamples.append(try measureCandidate(candidate, sample: sample, eventCount: eventsPerSample))
            } else {
                candidateSamples.append(try measureCandidate(candidate, sample: sample, eventCount: eventsPerSample))
                legacySamples.append(try measureLegacy(legacy, sample: sample, eventCount: eventsPerSample))
            }
        }

        let legacyWall = legacySamples.map(\.wallNanoseconds)
        let candidateWall = candidateSamples.map(\.wallNanoseconds)
        let legacyMedian = median(legacyWall)
        let candidateMedian = median(candidateWall)
        let improvementPercent = 100 * (Double(legacyMedian) - Double(candidateMedian))
            / Double(legacyMedian)
        let legacyReplays = legacySamples.reduce(0) { $0 + $1.fullReplays }
        let candidateReplays = candidateSamples.reduce(0) { $0 + $1.fullReplays }
        let measuredEvents = measuredCount * eventsPerSample
        let legacyReplaysPerThousand = Double(legacyReplays) * 1_000 / Double(measuredEvents)
        let candidateReplaysPerThousand = Double(candidateReplays) * 1_000 / Double(measuredEvents)
        let legacyDecodedBytes = legacySamples.reduce(Int64(0)) { $0 + $1.decodedPayloadBytes }
        let candidateDecodedBytes = candidateSamples.reduce(Int64(0)) { $0 + $1.decodedPayloadBytes }

        print("BOTS_DESK_REPLAY_BENCHMARK fixture_events=\(fixtureEventCount) stream_events_per_second=\(eventsPerSample) warmups=\(warmupCount) n=\(measuredCount)")
        print("BOTS_DESK_REPLAY_BENCHMARK legacy_mainactor_wall_ns=\(legacyWall)")
        print("BOTS_DESK_REPLAY_BENCHMARK candidate_mainactor_wall_ns=\(candidateWall)")
        print("BOTS_DESK_REPLAY_BENCHMARK legacy_median_ns=\(legacyMedian) candidate_median_ns=\(candidateMedian) improvement_percent=\(improvementPercent)")
        print("BOTS_DESK_REPLAY_BENCHMARK legacy_full_replays_per_1k=\(legacyReplaysPerThousand) candidate_full_replays_per_1k=\(candidateReplaysPerThousand)")
        print("BOTS_DESK_REPLAY_BENCHMARK legacy_decoded_payload_bytes=\(legacyDecodedBytes) candidate_decoded_payload_bytes=\(candidateDecodedBytes)")

        XCTAssertGreaterThan(improvementPercent, 5,
            "observer-watermark reconciliation must improve median MainActor wall time by more than 5%")
        XCTAssertLessThanOrEqual(candidateReplaysPerThousand, 5,
            "steady observed streaming must not keep replaying the full 4,096-event window")
        XCTAssertLessThan(candidateDecodedBytes, legacyDecodedBytes,
            "the candidate must decode fewer persisted payload bytes than full replay")
    }

    private func makeHarness(label: String, fixtureEventCount: Int) throws -> Harness {
        let fallback = FileManager.default.temporaryDirectory
        let appSupport = ProcessInfo.processInfo.environment["RC2_SANDBOX_APP_SUPPORT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? fallback
        let root = appSupport
            .appendingPathComponent("BotsDeskLiveReplayPerformanceTests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let context = try AppContext(channel: .debug, appSupportOverride: root.path)
        let viewModel = BotsViewModel(context: context)
        let bot = try viewModel.create(name: "Piper", title: "Replay benchmark", provider: .claude)
        let thread = AgentThread(title: "Replay benchmark", provider: .claude, model: "opus")
        let run = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .completed,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try context.threadRepo.upsert(thread)
        try context.runRepo.upsert(run)

        let events = fixtureEvents()
        XCTAssertEqual(events.count, fixtureEventCount)
        let encoded = try events.enumerated().map { offset, event -> AgentRunRepository.StreamWriteIntent in
            let data = try JSONEncoder().encode(event)
            return AgentRunRepository.StreamWriteIntent(
                seq: offset + 1,
                kind: event.debugDescription,
                payloadJSON: String(decoding: data, as: UTF8.self),
                providerEvent: nil
            )
        }
        try context.runRepo.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: encoded,
            shouldPruneStreamEvents: false
        )
        try context.botStore.upsertConversation(
            BotConversation(botID: bot.id, title: "Replay benchmark", linkedAgentThreadID: thread.id)
        )
        viewModel.openDesk(bot)
        XCTAssertEqual(context.coordinator.latestStreamEvents(threadId: thread.id).count, fixtureEventCount)

        return Harness(
            root: root,
            context: context,
            viewModel: viewModel,
            thread: thread,
            run: run,
            nextSequence: fixtureEventCount + 1,
            windowPayloadBytes: encoded.map { Int64($0.payloadJSON.utf8.count) }
        )
    }

    private func fixtureEvents() -> [AssistantEvent] {
        var events: [AssistantEvent] = [.turnStarted(turnId: "t-benchmark")]
        events.reserveCapacity(4_096)
        for itemIndex in 0..<63 {
            let itemID = "item-\(itemIndex)"
            events.append(.itemStarted(item: AssistantItem(
                id: itemID,
                turnId: "t-benchmark",
                type: .reasoning,
                state: .streaming,
                body: "seed-\(itemIndex)",
                startedAtMs: Int64(itemIndex + 1)
            )))
            for deltaIndex in 0..<64 {
                events.append(.itemDelta(
                    itemId: itemID,
                    bodyAppend: " chunk-\(deltaIndex)",
                    outputAppend: nil,
                    summary: nil
                ))
            }
        }
        return events
    }

    private func streamEvent(sample: Int, index: Int) -> AssistantEvent {
        .itemDelta(
            itemId: "item-62",
            bodyAppend: " sample-\(sample)-event-\(index)",
            outputAppend: nil,
            summary: nil
        )
    }

    private func persist(_ event: AssistantEvent, in harness: Harness) throws {
        let data = try JSONEncoder().encode(event)
        let json = String(decoding: data, as: UTF8.self)
        try harness.context.runRepo.persistStreamBatch(
            runId: harness.run.id,
            threadId: harness.thread.id,
            items: [.init(
                seq: harness.nextSequence,
                kind: event.debugDescription,
                payloadJSON: json,
                providerEvent: nil
            )],
            shouldPruneStreamEvents: false
        )
        harness.nextSequence += 1
        harness.windowPayloadBytes.removeFirst()
        harness.windowPayloadBytes.append(Int64(json.utf8.count))
    }

    private func measureLegacy(_ harness: Harness, sample: Int, eventCount: Int) throws -> TimedSample {
        var decodedPayloadBytes: Int64 = 0
        var checksum = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<eventCount {
            let event = streamEvent(sample: sample, index: index)
            try persist(event, in: harness)
            let replay = harness.context.coordinator.latestStreamEvents(threadId: harness.thread.id)
            decodedPayloadBytes += harness.windowPayloadBytes.reduce(0, +)
            let timeline = AgentChatLiveTurnChrome.timelineByReplaying(replay)
            checksum ^= timeline.aggregateHotTextByteCount
        }
        let finished = DispatchTime.now().uptimeNanoseconds
        XCTAssertNotEqual(checksum, Int.min)
        return TimedSample(
            wallNanoseconds: finished - started,
            fullReplays: eventCount,
            decodedPayloadBytes: decodedPayloadBytes
        )
    }

    private func measureCandidate(_ harness: Harness, sample: Int, eventCount: Int) throws -> TimedSample {
        var decodedPayloadBytes: Int64 = 0
        var fullReplays = 0
        let started = DispatchTime.now().uptimeNanoseconds
        for index in 0..<eventCount {
            let event = streamEvent(sample: sample, index: index)
            harness.viewModel.applyDeskLiveEventForTesting(event, threadId: harness.thread.id)
            try persist(event, in: harness)
            let before = harness.viewModel.deskLiveReplayFetchCountForTesting
            let incrementalBytesBefore = harness.viewModel.deskLiveIncrementalDecodeBytesForTesting
            harness.viewModel.refreshDeskLiveTurn()
            let replayDelta = harness.viewModel.deskLiveReplayFetchCountForTesting - before
            decodedPayloadBytes += harness.viewModel.deskLiveIncrementalDecodeBytesForTesting
                - incrementalBytesBefore
            if replayDelta > 0 {
                fullReplays += replayDelta
                decodedPayloadBytes += Int64(replayDelta) * harness.windowPayloadBytes.reduce(0, +)
            }
        }
        let finished = DispatchTime.now().uptimeNanoseconds
        XCTAssertTrue(harness.viewModel.deskPaintsLiveTurnChrome)
        return TimedSample(
            wallNanoseconds: finished - started,
            fullReplays: fullReplays,
            decodedPayloadBytes: decodedPayloadBytes
        )
    }

    private func median(_ values: [UInt64]) -> UInt64 {
        values.sorted()[values.count / 2]
    }
}
