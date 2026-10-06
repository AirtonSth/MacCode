import XCTest
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// S-F4c / M-S9: a hidden Agent App tab gives up its painted caches and
/// compacts its timeline, and reveal must show exactly what the user left.
@MainActor
final class AgentAppHiddenColdReclaimTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
    }

    // MARK: - Fixture

    private struct Fixture {
        let vm: AgentAppViewModel
        let threadRepo: AgentThreadRepository
        let runRepo: AgentRunRepository
    }

    private func makeFixture() throws -> Fixture {
        let tmp = NSTemporaryDirectory() + "rc2-cold-reclaim-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(), cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo
        )
        return Fixture(vm: vm, threadRepo: threadRepo, runRepo: runRepo)
    }

    /// A finished thread whose transcript (answers plus tool output) lives in
    /// the durable stream ring, so a full open hydrates a non-trivial timeline.
    private func makeFinishedThread(
        _ fixture: Fixture,
        title: String,
        turns: Int
    ) throws -> AgentThread {
        let thread = AgentThread(
            workspaceId: fixture.vm.workspaceID,
            title: title,
            provider: .codex,
            model: "gpt-5.5",
            status: .completed
        )
        try fixture.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed)
        try fixture.runRepo.upsert(run)
        let encoder = JSONEncoder()
        var writes: [AgentRunRepository.StreamWriteIntent] = []
        for event in Self.transcriptEvents(prefix: title, turns: turns) {
            writes.append(.init(
                seq: writes.count + 1,
                kind: event.debugDescription,
                payloadJSON: String(decoding: try encoder.encode(event), as: UTF8.self),
                providerEvent: nil
            ))
        }
        try fixture.runRepo.persistStreamBatch(
            runId: run.id,
            threadId: thread.id,
            items: writes,
            shouldPruneStreamEvents: false
        )
        return thread
    }

    private static func transcriptEvents(prefix: String, turns: Int) -> [AssistantEvent] {
        var events: [AssistantEvent] = []
        for index in 0..<turns {
            let turnId = "\(prefix)-turn-\(index)"
            let tool = "\(prefix)-tool-\(index)"
            let answer = "\(prefix)-answer-\(index)"
            events.append(.turnStarted(turnId: turnId))
            events.append(.itemStarted(item: AssistantItem(
                id: tool, turnId: turnId, type: .commandExecution,
                summary: "swift build", startedAtMs: Int64(index * 10 + 1)
            )))
            events.append(.itemDelta(
                itemId: tool, bodyAppend: nil,
                outputAppend: String(repeating: "Compiling module \(index)\n", count: 200),
                summary: nil
            ))
            events.append(.itemCompleted(itemId: tool, finalState: .completed))
            events.append(.itemStarted(item: AssistantItem(
                id: answer, turnId: turnId, type: .assistantMessage,
                startedAtMs: Int64(index * 10 + 2)
            )))
            events.append(.itemDelta(
                itemId: answer, bodyAppend: "Answer \(index): the build is green. ",
                outputAppend: nil, summary: nil
            ))
            events.append(.itemCompleted(itemId: answer, finalState: .completed))
            events.append(.turnCompleted(turnId: turnId, finalMessage: "Answer \(index): the build is green. "))
        }
        return events
    }

    private func open(_ vm: AgentAppViewModel, _ thread: AgentThread) async {
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
    }

    private func pump(_ vm: AgentAppViewModel, threadId: AgentThreadID, run: AgentRunID, turnId: String) {
        vm.runCoordinator(vm.coordinator, didReceive: .turnStarted(turnId: turnId), run: run, threadId: threadId)
        vm.runCoordinator(
            vm.coordinator,
            didReceive: .itemStarted(item: AssistantItem(
                id: "\(turnId)-answer", turnId: turnId, type: .assistantMessage, startedAtMs: 9_000
            )),
            run: run,
            threadId: threadId
        )
        vm.runCoordinator(
            vm.coordinator,
            didReceive: .itemDelta(itemId: "\(turnId)-answer", bodyAppend: "follow-up", outputAppend: nil, summary: nil),
            run: run,
            threadId: threadId
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Archive

    func test_archive_roundTripsTimelineExactlyAndKeepsItLive() throws {
        // WHY: reveal must restore the timeline the user left, not a re-derived
        // approximation, and the restored tree must keep accepting stream
        // deltas exactly like the original (location maps rebuilt on decode).
        var original = AssistantTimelineState()
        for event in Self.transcriptEvents(prefix: "unit", turns: 6) { original.apply(event) }
        original.apply(.itemStarted(item: AssistantItem(
            id: "streaming", turnId: "unit-turn-5", type: .assistantMessage, startedAtMs: 99
        )))
        let encodedSize = try JSONEncoder().encode(original).count

        let archive = try AgentColdTimelineArchive.archive(original)
        var restored = try AgentColdTimelineArchive.restore(archive)

        XCTAssertEqual(restored, original)
        XCTAssertLessThan(archive.count, encodedSize / 4, "the cold form must actually be smaller than the tree")
        let delta = AssistantEvent.itemDelta(itemId: "streaming", bodyAppend: "more", outputAppend: nil, summary: nil)
        original.apply(delta)
        restored.apply(delta)
        XCTAssertEqual(restored, original, "a delta to an existing item must land the same after restore")
    }

    func test_archive_rejectsCorruptData() {
        XCTAssertThrowsError(try AgentColdTimelineArchive.restore(Data([0, 1, 2, 3])))
    }

    // MARK: - Hide → reclaim → reveal

    func test_hideReclaimReveal_restoresTimelineExactlyAndDropsInactiveCaches() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let other = try makeFinishedThread(fixture, title: "other", turns: 3)
        let selected = try makeFinishedThread(fixture, title: "selected", turns: 8)
        await open(vm, other)
        await open(vm, selected)
        let before = vm.timeline
        XCTAssertEqual(before.turns.count, 8, "fixture must hydrate a real transcript")
        XCTAssertGreaterThan(vm.paintedTimelineCountForTesting, 0, "the visited thread must be cached before hide")

        vm.setVisibility(.hidden)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .hidden)
        await vm.reclaimHiddenStateForTesting()

        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting, "a hidden idle tab must compact its timeline")
        XCTAssertEqual(vm.paintedTimelineCountForTesting, 0, "painted caches of idle threads must be released")

        vm.setVisibility(.visible)
        XCTAssertEqual(vm.timeline, before, "reveal must restore the exact timeline")
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .visible)
        XCTAssertFalse(vm.visibilitySessionForTesting.retainsCompactDirtyOnly)

        // The dropped cache falls back to the normal full open, which still
        // completes with the thread's own transcript.
        await open(vm, other)
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), (0..<3).map { "other-turn-\($0)" })
    }

    func test_scheduledReclaim_eventuallyArchivesAfterHideDelay() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "delayed", turns: 4)
        await open(vm, thread)
        let before = vm.timeline
        vm.hiddenReclaimDelayForTesting = .milliseconds(10)

        vm.setVisibility(.hidden)
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting, "hide itself must stay cheap; reclaim is deferred")
        await waitUntil { vm.hiddenTimelineIsArchivedForTesting }
        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting)

        vm.setVisibility(.visible)
        XCTAssertEqual(vm.timeline, before)
    }

    func test_revealBeforeReclaim_cancelsItAndStaleGenerationIsRejected() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "race", turns: 3)
        await open(vm, thread)
        let before = vm.timeline
        vm.hiddenReclaimDelayForTesting = .milliseconds(20)

        // Rapid hide → reveal: the armed reclaim must never land.
        vm.setVisibility(.hidden)
        let staleGeneration = vm.visibilitySessionForTesting.generation
        vm.setVisibility(.visible)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting)
        XCTAssertEqual(vm.timeline, before)

        // A second hide must not accept the first hide's reclaim.
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.setVisibility(.hidden)
        await vm.reclaimHiddenState(generation: staleGeneration)
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting, "a reclaim from an earlier hide must be rejected")
        await vm.reclaimHiddenStateForTesting()
        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting, "the current hide's reclaim still lands")
        vm.setVisibility(.visible)
        XCTAssertEqual(vm.timeline, before)
    }

    func test_repeatedHide_keepsTheArchivedTimeline() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "rehide", turns: 3)
        await open(vm, thread)
        let before = vm.timeline
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.setVisibility(.hidden)
        await vm.reclaimHiddenStateForTesting()

        vm.setVisibility(.hidden)

        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting, "a second hide must not stash the emptied timeline")
        vm.setVisibility(.visible)
        XCTAssertEqual(vm.timeline, before)
    }

    func test_runStartingWhileReclaimed_extendsTheRestoredTimeline() async throws {
        // WHY: a follow-up can start from iOS or the queue while the tab is
        // hidden. Its stream must reduce onto the restored transcript, never
        // onto an empty tree that would replace it on reveal.
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "followup", turns: 3)
        await open(vm, thread)
        let before = vm.timeline
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.hiddenTimelinePublishIntervalForTesting = 0
        vm.setVisibility(.hidden)
        await vm.reclaimHiddenStateForTesting()
        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting)

        pump(vm, threadId: thread.id, run: AgentRunID(), turnId: "followup-live")
        await waitUntil { vm.hiddenTimelinePublishCountForTesting > 0 }
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting, "a stream must thaw the archive first")

        vm.setVisibility(.visible)
        XCTAssertEqual(
            vm.timeline.turns.map(\.turnId),
            before.turns.map(\.turnId) + ["followup-live"]
        )
        XCTAssertEqual(Array(vm.timeline.turns.prefix(before.turns.count)), before.turns)
    }

    func test_liveRun_isNotArchivedAndKeepsReducing() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "live", turns: 2)
        await open(vm, thread)
        // The durable running row is what lets the surface bind the run as live.
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .running)
        try fixture.runRepo.upsert(run)
        pump(vm, threadId: thread.id, run: run.id, turnId: "live-now")
        await waitUntil { vm.timeline.turns.contains { $0.turnId == "live-now" } }
        let before = vm.timeline
        XCTAssertTrue(before.turns.contains { $0.turnId == "live-now" })
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)

        vm.setVisibility(.hidden)
        await vm.reclaimHiddenStateForTesting()

        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting, "a thread still streaming must keep its live tree")
        vm.setVisibility(.visible)
        XCTAssertEqual(vm.timeline, before)
    }

    func test_corruptArchive_revealsTheDurableReplayInsteadOfAnEmptyConversation() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "corrupt", turns: 3)
        await open(vm, thread)
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.setVisibility(.hidden)
        vm.setHiddenTimelineArchiveForTesting(Data([0, 1, 2, 3]))

        vm.setVisibility(.visible)

        // The durable replay is the honest fallback, not an exact restore: turn
        // start times are re-stamped on replay, which is why the archive exists.
        let durable = AgentAppViewModel.timelineByReplaying(vm.coordinator.latestStreamEvents(threadId: thread.id))
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), (0..<3).map { "corrupt-turn-\($0)" })
        XCTAssertEqual(vm.timeline.turns.map(\.items), durable.turns.map(\.items))
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting)
    }
}
