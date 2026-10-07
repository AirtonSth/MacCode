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
        // Fixture transcripts are small; the size gate has its own test.
        vm.hiddenArchiveMinimumHotTextBytes = 0
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

    /// Reveal acknowledges at once; the archived tree lands off-main.
    private func revealAndRestore(_ vm: AgentAppViewModel) async {
        vm.setVisibility(.visible)
        await vm.waitForColdRestoreForTesting()
    }

    private func hideAndArchive(_ vm: AgentAppViewModel) async {
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.setVisibility(.hidden)
        await vm.reclaimHiddenStateForTesting()
        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting, "precondition: the hidden tab is archived")
    }

    private func persistEvents(
        _ fixture: Fixture,
        run: AgentRun,
        threadId: AgentThreadID,
        turnIds: [String],
        firstSeq: Int
    ) throws {
        let encoder = JSONEncoder()
        var writes: [AgentRunRepository.StreamWriteIntent] = []
        for (offset, turnId) in turnIds.enumerated() {
            let event = AssistantEvent.turnStarted(turnId: turnId)
            writes.append(.init(
                seq: firstSeq + offset,
                kind: event.debugDescription,
                payloadJSON: String(decoding: try encoder.encode(event), as: UTF8.self),
                providerEvent: nil
            ))
        }
        try fixture.runRepo.persistStreamBatch(
            runId: run.id,
            threadId: threadId,
            items: writes,
            shouldPruneStreamEvents: false
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
        // Immediate path: the reveal is acknowledged on this turn and never
        // decodes on the main actor; the session stays restoring until then.
        XCTAssertFalse(vm.isHiddenFromSurface)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .restoring)
        XCTAssertTrue(vm.coldRestoreIsInFlightForTesting, "the decode must run off-main, after the reveal")
        await vm.waitForColdRestoreForTesting()
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

        await revealAndRestore(vm)
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
        await revealAndRestore(vm)
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
        await revealAndRestore(vm)
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

    func test_corruptArchive_takesTheNormalFullOpenInsteadOfAnEmptyConversation() async throws {
        // WHY: a restore failure must not reveal an empty conversation, and
        // must not replay the hot window on the main actor either: it takes
        // the same off-main full open a thread switch takes.
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "corrupt", turns: 3)
        await open(vm, thread)
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.setVisibility(.hidden)
        vm.setHiddenTimelineArchiveForTesting(Data([0, 1, 2, 3]))

        await revealAndRestore(vm)
        await vm.waitForSelectThreadHydrationForTesting()

        let durable = AgentAppViewModel.timelineByReplaying(vm.coordinator.latestStreamEvents(threadId: thread.id))
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), (0..<3).map { "corrupt-turn-\($0)" })
        XCTAssertEqual(vm.timeline.turns.map(\.items), durable.turns.map(\.items))
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .visible)
    }

    // MARK: - Review follow-ups (M-S9)

    func test_hiddenTreeWrittenDuringEncode_rejectsTheArchive() async throws {
        // WHY: the encode runs off-main on a snapshot. A stream event that
        // extends the hidden tree meanwhile must win; committing the stale
        // snapshot would silently drop the streamed turn until a full open.
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "encode", turns: 3)
        await open(vm, thread)
        let before = vm.timeline
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.hiddenTimelinePublishIntervalForTesting = 0
        vm.setVisibility(.hidden)
        // The hook runs after the detached encode returned and before the
        // commit guard: the stream commit lands inside the encode window.
        vm.beforeHiddenArchiveCommitForTesting = { [weak vm] in
            guard let vm else { return }
            vm.beforeHiddenArchiveCommitForTesting = nil
            let publishes = vm.hiddenTimelinePublishCountForTesting
            self.pump(vm, threadId: thread.id, run: AgentRunID(), turnId: "encode-race")
            await self.waitUntil { vm.hiddenTimelinePublishCountForTesting > publishes }
        }
        await vm.reclaimHiddenStateForTesting()

        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting, "a tree written during the encode must not be archived")
        vm.setVisibility(.visible)
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), before.turns.map(\.turnId) + ["encode-race"])
    }

    func test_disposeDuringReclaimEncode_leavesNoArchive() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "dispose", turns: 3)
        await open(vm, thread)
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.setVisibility(.hidden)
        vm.beforeHiddenArchiveCommitForTesting = { [weak vm] in vm?.dispose() }

        await vm.reclaimHiddenStateForTesting()

        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting, "a disposed surface must not keep an archive")
        XCTAssertFalse(vm.coldRestoreIsInFlightForTesting)
    }

    func test_smallTimeline_isNotArchivedButIdleCachesAreStillReleased() async throws {
        // WHY: below the size gate the archive saves little and every reveal
        // would still pay a restore; the painted caches still go.
        let fixture = try makeFixture()
        let vm = fixture.vm
        vm.hiddenArchiveMinimumHotTextBytes = 1 << 20
        let other = try makeFinishedThread(fixture, title: "small-other", turns: 2)
        let thread = try makeFinishedThread(fixture, title: "small", turns: 3)
        await open(vm, other)
        await open(vm, thread)
        let before = vm.timeline
        XCTAssertLessThan(before.aggregateHotTextByteCount, 1 << 20)
        vm.hiddenReclaimDelayForTesting = .seconds(3_600)
        vm.setVisibility(.hidden)

        await vm.reclaimHiddenStateForTesting()

        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting)
        XCTAssertEqual(vm.paintedTimelineCountForTesting, 0)
        vm.setVisibility(.visible)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .visible, "no restore: reveal completes on the same turn")
        XCTAssertEqual(vm.timeline, before)
    }

    func test_hideBeforeRevealRestoreLands_keepsTheTreeAndRestoresOnNextReveal() async throws {
        // WHY (A→B race): a reveal that is hidden again before its restore
        // lands must neither lose the archive nor paint onto the hidden tab.
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "flip", turns: 4)
        await open(vm, thread)
        let before = vm.timeline
        await hideAndArchive(vm)

        vm.setVisibility(.visible)
        vm.setVisibility(.hidden)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .hidden)
        await vm.waitForColdRestoreForTesting()
        XCTAssertTrue(vm.timeline.turns.isEmpty, "a hidden tab must not publish the restored tree")

        await revealAndRestore(vm)
        XCTAssertEqual(vm.timeline, before)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .visible)
    }

    func test_timelineWrittenBeforeRevealRestoreLands_isNotOverwritten() async throws {
        // WHY: the restore is stale once anything wrote the revealed timeline.
        // It must not overwrite that write; the tab takes the normal full open.
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "write", turns: 3)
        await open(vm, thread)
        await hideAndArchive(vm)

        // A newer turn that is durable and already painted on the revealed
        // stand-in before the restore lands.
        let newer = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed)
        try fixture.runRepo.upsert(newer)
        try persistEvents(fixture, run: newer, threadId: thread.id, turnIds: ["newer-write"], firstSeq: 100)
        vm.setVisibility(.visible)
        vm.timeline.apply(.turnStarted(turnId: "newer-write"))
        await vm.waitForColdRestoreForTesting()
        await vm.waitForSelectThreadHydrationForTesting()

        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting)
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .visible)
        XCTAssertEqual(
            vm.timeline.turns.map(\.turnId),
            (0..<3).map { "write-turn-\($0)" } + ["newer-write"],
            "the stale archive must not erase the newer turn"
        )
    }

    func test_streamDuringRevealRestore_extendsTheRestoredTimeline() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "reveal-stream", turns: 3)
        await open(vm, thread)
        let before = vm.timeline
        await hideAndArchive(vm)

        vm.setVisibility(.visible)
        pump(vm, threadId: thread.id, run: AgentRunID(), turnId: "reveal-stream-live")
        await vm.waitForColdRestoreForTesting()
        await waitUntil { vm.timeline.turns.contains { $0.turnId == "reveal-stream-live" } }

        XCTAssertEqual(vm.timeline.turns.map(\.turnId), before.turns.map(\.turnId) + ["reveal-stream-live"])
        XCTAssertEqual(Array(vm.timeline.turns.prefix(before.turns.count)), before.turns)
    }

    func test_hostSelectsAnotherThreadWhileArchived_revealShowsTheNewThread() async throws {
        // WHY: the archive belongs to the thread that was selected at hide. A
        // host selectThread while hidden must never reveal that old tree.
        let fixture = try makeFixture()
        let vm = fixture.vm
        let other = try makeFinishedThread(fixture, title: "next", turns: 2)
        let archived = try makeFinishedThread(fixture, title: "archived", turns: 4)
        await open(vm, archived)
        await hideAndArchive(vm)

        await open(vm, other)
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting, "a thread switch drops the old thread's archive")
        await revealAndRestore(vm)

        XCTAssertEqual(vm.timeline.turns.map(\.turnId), (0..<2).map { "next-turn-\($0)" })
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .visible)
    }

    func test_revealRestorePendingThenThreadSwitch_showsOnlyTheNewThread() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let other = try makeFinishedThread(fixture, title: "dest", turns: 2)
        let archived = try makeFinishedThread(fixture, title: "src", turns: 4)
        await open(vm, archived)
        await hideAndArchive(vm)

        vm.setVisibility(.visible)
        await open(vm, other)
        await vm.waitForColdRestoreForTesting()

        XCTAssertEqual(vm.timeline.turns.map(\.turnId), (0..<2).map { "dest-turn-\($0)" })
        XCTAssertEqual(vm.visibilitySessionForTesting.state, .visible)
        XCTAssertFalse(vm.hiddenTimelineIsArchivedForTesting)
    }

    func test_scheduledSuffixOnArchivedTab_extendsTheRestoredTimeline() async throws {
        // WHY: a LaunchAgent-owned scheduled run can start on a reclaimed tab.
        // Its suffix must extend the restored transcript, and the restore must
        // not run on the poll's main-actor turn.
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "sched", turns: 3)
        await open(vm, thread)
        let before = vm.timeline
        await hideAndArchive(vm)

        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .running)
        try fixture.runRepo.upsert(run)
        // Sequences above the finished run's keep this run the stream cursor
        // even when both runs share a started_at second.
        try persistEvents(fixture, run: run, threadId: thread.id, turnIds: ["sched-seed"], firstSeq: 101)
        vm.isScheduledThreadRunning = { $0 == thread.id }
        vm.selectThread(thread.id, markRead: false)  // host reselect binds the scheduled poll
        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting)
        try persistEvents(fixture, run: run, threadId: thread.id, turnIds: ["sched-1", "sched-2"], firstSeq: 102)

        vm.tickScheduledLivePollForTesting()
        XCTAssertEqual(vm.scheduledLiveApplyCountForTesting, 0, "the poll must not apply onto the archived stand-in")
        XCTAssertTrue(vm.coldRestoreIsInFlightForTesting)
        await vm.waitForColdRestoreForTesting()
        vm.tickScheduledLivePollForTesting()
        XCTAssertEqual(vm.scheduledLiveApplyCountForTesting, 2, "the next tick applies the same attested suffix")

        await revealAndRestore(vm)
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), before.turns.map(\.turnId) + ["sched-1", "sched-2"])
        XCTAssertEqual(Array(vm.timeline.turns.prefix(before.turns.count)), before.turns)
    }

    func test_hiddenThaw_rearmsReclaimSoTheTabCompactsAgain() async throws {
        let fixture = try makeFixture()
        let vm = fixture.vm
        let thread = try makeFinishedThread(fixture, title: "rearm", turns: 3)
        await open(vm, thread)
        let before = vm.timeline
        await hideAndArchive(vm)
        vm.hiddenTimelinePublishIntervalForTesting = 0
        vm.hiddenReclaimDelayForTesting = .milliseconds(10)

        pump(vm, threadId: thread.id, run: AgentRunID(), turnId: "rearm-live")
        await waitUntil { vm.hiddenTimelinePublishCountForTesting > 0 }
        await waitUntil { vm.hiddenTimelineIsArchivedForTesting }
        XCTAssertTrue(vm.hiddenTimelineIsArchivedForTesting, "an idle thawed tab must compact again")

        await revealAndRestore(vm)
        XCTAssertEqual(vm.timeline.turns.map(\.turnId), before.turns.map(\.turnId) + ["rearm-live"])
    }
}
