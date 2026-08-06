import XCTest
import Combine
@testable import Surfaces
import CoreModel
import Persistence
import AgentRuntime

/// Tests for the MED perf bundle (token-stream hot path) in AgentAppSurface.swift.
///
/// Fix A (PERF-MAC_AGENT-010): runCoordinator(_:didReceive:) batches streaming
///   events into one main-actor hop per tick instead of one Task per event.
///   WHY: Fast token streams emit thousands of events/sec; one Task per event
///   saturates the Swift concurrency scheduler. Batching drains all events in a
///   single flush while preserving order and correctness.
///
/// Fix B (PERF-MAC_AGENT-011): transcriptSignature computed once per body pass
///   via AgentAppView.buildTranscriptSignature(messages:turns:) + SignatureCache.
///   WHY: The O(turns) string concat ran twice per every SwiftUI body eval —
///   once in transcriptEntries and once in hiddenPersistedAssistantMessageIDs.
///   A single static helper is deterministic and shared through the SignatureCache.
///
/// Fix C (PERF-MAC_AGENT-009): thread->workspace membership cached in
///   threadWorkspaceCache so didChangeStatus skips the DB read per status event.
///   WHY: A multi-thread workspace generates a status event per active thread
///   per status change; each event was a threadRepo.get DB round-trip that
///   blocked the main actor.
@MainActor
final class AgentAppPerfBundleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Isolate from model choices remembered by earlier test runs via
        // AgentLastModelStore.shared (runner-level UserDefaults leak).
        UserDefaults.standard.removeObject(forKey: "agent.lastModel.byProvider.v1")
    }

    // MARK: - Helpers

    private func makeVM(provider: AgentProviderRunner? = nil) throws -> (AgentAppViewModel, AgentThreadRepository) {
        let tmp = NSTemporaryDirectory() + "rc2-perf-bundle-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(
            runRepo: runRepo, messageRepo: messageRepo, threadRepo: threadRepo,
            providers: [
                .codex: provider ?? FakeProviderRunner(provider: .codex),
                .claude: FakeProviderRunner(provider: .claude)
            ]
        )
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(
            workspaceID: workspaceID, cwd: tmp,
            coordinator: coord, threadRepo: threadRepo, messageRepo: messageRepo
        )
        vm.providerSnapshots = [
            AgentProviderSnapshotFactory.snapshot(
                provider: .codex,
                models: [AgentModelDescriptor(id: "gpt-5.5", label: "GPT-5.5", provider: .codex)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            ),
            AgentProviderSnapshotFactory.snapshot(
                provider: .claude,
                models: [AgentModelDescriptor(id: "claude-sonnet-4-6", label: "Claude Sonnet 4.6", provider: .claude)],
                binaryPath: "/usr/bin/true",
                authenticated: true
            )
        ]
        return (vm, threadRepo)
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 6, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !cond() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(cond(), "timed out waiting for: \(desc)")
    }

    // MARK: - Fix A: stream event batching

    /// Sends N streaming events synchronously then yields once.
    /// All N events must arrive at the timeline in the correct order.
    /// This proves the batch flush preserves event order — the critical
    /// correctness invariant of the batching optimization.
    func test_streamEventBatch_allEventsAppliedInOrderAfterSingleYield() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "stream")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let runId = AgentRunID()

        // Send 5 events synchronously (no yields between them) — these should
        // all land in the same batch and be flushed together.
        let turnId1 = "batch-turn-1"
        let turnId2 = "batch-turn-2"
        let itemId1 = "batch-item-1"
        let itemId2 = "batch-item-2"

        vm.runCoordinator(vm.coordinator, didReceive: .turnStarted(turnId: turnId1),
                          run: runId, threadId: tid)
        vm.runCoordinator(vm.coordinator,
                          didReceive: .itemStarted(item: AssistantItem(
                              id: itemId1, turnId: turnId1, type: .assistantMessage,
                              startedAtMs: Int64(Date().timeIntervalSince1970 * 1000))),
                          run: runId, threadId: tid)
        vm.runCoordinator(vm.coordinator,
                          didReceive: .itemDelta(itemId: itemId1, bodyAppend: "hello", outputAppend: nil, summary: nil),
                          run: runId, threadId: tid)
        vm.runCoordinator(vm.coordinator, didReceive: .turnStarted(turnId: turnId2),
                          run: runId, threadId: tid)
        vm.runCoordinator(vm.coordinator,
                          didReceive: .itemStarted(item: AssistantItem(
                              id: itemId2, turnId: turnId2, type: .assistantMessage,
                              startedAtMs: Int64(Date().timeIntervalSince1970 * 1000))),
                          run: runId, threadId: tid)

        // One yield lets the single flush Task run.
        await Task.yield()

        // Both turns must exist in the timeline — proving all 5 events were applied.
        let turnIds = vm.timeline.turns.map(\.turnId)
        XCTAssertTrue(turnIds.contains(turnId1),
                      "batched turnStarted for turn 1 must appear in timeline after flush")
        XCTAssertTrue(turnIds.contains(turnId2),
                      "batched turnStarted for turn 2 must appear in timeline after flush")

        // Item 1's body must have been updated by the delta event — proving order was preserved.
        let item1 = vm.timeline.turns
            .first(where: { $0.turnId == turnId1 })?
            .items.first(where: { $0.id == itemId1 })
        XCTAssertEqual(item1?.body, "hello",
                       "itemDelta event must be applied after itemStarted, preserving event order in the batch")
    }

    /// Verifies that an event for a non-selected thread is silently dropped
    /// by the flush, not applied to the current thread's timeline.
    func test_streamEventBatch_eventsForOtherThreadsAreDropped() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "selected")
        let selectedTid = try XCTUnwrap(vm.selectedThreadId)
        let otherTid = AgentThreadID()  // never selected
        let runId = AgentRunID()
        let otherTurnId = "other-turn-x"
        let initialTurnCount = vm.timeline.turns.count

        vm.runCoordinator(vm.coordinator, didReceive: .turnStarted(turnId: otherTurnId),
                          run: runId, threadId: otherTid)
        await Task.yield()

        XCTAssertEqual(vm.selectedThreadId, selectedTid,
                       "delivering an event for a non-selected thread must not change the selection")
        XCTAssertEqual(vm.timeline.turns.count, initialTurnCount,
                       "events for non-selected threads must not pollute the current timeline")
    }

    /// One provider token burst must publish one bounded UI invalidation burst, not
    /// one SwiftUI invalidation per token. The app already batches stream events
    /// into one main-actor hop; this guards the missing second half of that contract:
    /// applying the batch must mutate `@Published` state in bulk so a long run keeps
    /// typing/scrolling responsive instead of forcing hundreds of view rebuilds.
    func test_streamEventBatch_publishesBoundedViewInvalidationsForTokenBurst() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "stream invalidation")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        // Drain the select-time off-main history load before counting: its
        // publish lands nondeterministically inside the measured window and
        // this guard is about STREAM-batch publishes, not thread-open ones.
        await vm.waitForMessageHistoryLoad()
        let runId = AgentRunID()
        var publishCount = 0
        let cancellable = vm.objectWillChange.sink { publishCount += 1 }

        let turnId = "burst-turn"
        let itemId = "burst-answer"
        vm.runCoordinator(vm.coordinator, didReceive: .turnStarted(turnId: turnId),
                          run: runId, threadId: tid)
        vm.runCoordinator(vm.coordinator,
                          didReceive: .itemStarted(item: AssistantItem(
                              id: itemId, turnId: turnId, type: .assistantMessage,
                              startedAtMs: Int64(Date().timeIntervalSince1970 * 1000))),
                          run: runId, threadId: tid)
        for i in 0..<200 {
            vm.runCoordinator(vm.coordinator,
                              didReceive: .itemDelta(itemId: itemId, bodyAppend: "tok\(i) ", outputAppend: nil, summary: nil),
                              run: runId, threadId: tid)
        }

        await Task.yield()
        try? await Task.sleep(nanoseconds: 50_000_000)
        cancellable.cancel()

        XCTAssertEqual(vm.timeline.turns.first?.items.first?.body.hasSuffix("tok199 "), true,
                       "the bounded publish assertion must still prove every token delta was applied to the visible timeline")
        XCTAssertLessThanOrEqual(publishCount, 10,
                                 "one batched provider token burst must not publish one SwiftUI invalidation per token; that was the long-run typing/scrolling slowdown")
    }

    /// SR1 translation badges must still update after stream events are applied in
    /// bulk. This protects the user-visible "View original" affordance while the
    /// stream flush avoids publishing empty/no-op badge state on every token.
    func test_streamEventBatch_updatesSR1TranslationBadgeStateAfterBulkTimelineApply() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "sr1 translation")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let runId = AgentRunID()
        let messageId = AgentMessageID()
        let original = "S=state D=patch P=tests"

        vm.runCoordinator(
            vm.coordinator,
            didReceive: .sr1Translation(AssistantSR1Translation(
                messageId: messageId.value.uuidString,
                originalText: original,
                rewrittenText: "State, patch, tests."
            )),
            run: runId,
            threadId: tid
        )

        await Task.yield()

        XCTAssertTrue(vm.sr1TranslatedMessageIds.contains(messageId),
                      "batched stream flush must still mark SR1-translated messages so the transcript shows the translation badge")
        XCTAssertEqual(vm.sr1OriginalText(for: messageId), original,
                       "batched stream flush must preserve the original compressed text for the View original disclosure")
    }

    func test_sr1PublishedCacheDropsTranslationsEvictedByHotBudget() throws {
        let (vm, _) = try makeVM()
        var state = AssistantTimelineState()
        let text = String(repeating: "s", count: 100_000)
        for _ in 0..<50 {
            let messageID = AgentMessageID()
            state.apply(.sr1Translation(AssistantSR1Translation(
                messageId: messageID.value.uuidString,
                originalText: text,
                rewrittenText: text
            )))
        }
        vm.refreshSR1TranslationStateFromTimeline(state)
        let before = vm.sr1TranslatedMessageIds
        XCTAssertEqual(before.count, 50)

        // Production aggregateHotTextByteLimit is now 96 MiB, so this small fixture no
        // longer evicts under the default. Force eviction with an explicit sub-production
        // 8 MiB budget (mirrors test_timelineAggregateBudgetIncludesRequestsInputsPlansAndWorkLog).
        let testBudget = 8 * 1_024 * 1_024
        state.enforceAggregateHotTextBudget(byteLimit: testBudget)
        vm.refreshSR1TranslationStateFromTimeline(state)

        let retained = Set(state.sr1TranslationsByMessageId.keys.compactMap(UUID.init(uuidString:)).map(AgentMessageID.init))
        XCTAssertEqual(vm.sr1TranslatedMessageIds, retained,
                       "published badges must be an exact projection of the budgeted timeline")
        XCTAssertTrue(vm.sr1TranslatedMessageIds.isStrictSubset(of: before),
                      "translations evicted by the 8 MiB budget must not remain in a duplicate cache")
        XCTAssertEqual(Set(vm.sr1OriginalTextsByMessageId.keys), retained)
        XCTAssertLessThanOrEqual(
            vm.sr1OriginalTextsByMessageId.values.reduce(0) { $0 + $1.utf8.count },
            testBudget
        )
    }

    func test_hiddenTranscriptRevealWindowKeepsLargeHistoryRevealBounded() {
        let threadId = AgentThreadID()
        let entries = (0..<140).map { index in
            AgentAppView.TranscriptEntry.message(AgentMessage(
                threadId: threadId,
                role: .assistant,
                content: "message-\(index)",
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index))
            ))
        }
        let visible = Array(entries.suffix(30))

        let firstReveal = AgentAppView.hiddenTranscriptRevealWindow(
            allItems: entries,
            visibleWindow: visible,
            revealCount: 50
        )
        let secondReveal = AgentAppView.hiddenTranscriptRevealWindow(
            allItems: entries,
            visibleWindow: visible,
            revealCount: 100
        )

        XCTAssertEqual(firstReveal.count, 50,
                       "one tap must not render the entire older transcript for huge threads; reveal work stays bounded")
        XCTAssertEqual(firstReveal.first?.id, entries[60].id,
                       "the first reveal shows the most recent hidden entries adjacent to the visible window")
        XCTAssertEqual(secondReveal.count, 100,
                       "additional taps can reveal more history in bounded chunks without losing older transcript access")
        XCTAssertEqual(secondReveal.first?.id, entries[10].id)
    }

    // MARK: - PERF #1: bounded hot replay from a 5,000-event thread

    func test_threadOpenReplayFiveThousandEventsStaysWithinBudget() async throws {
        // Thread-open hot replay is bounded by durable stream-event retention
        // (`AgentEventRetentionPolicy.streamEventCountPerThread` = 100). A completed
        // run that emitted far more events therefore rehydrates only the latest
        // retained rows (~20 turns at 5 events/turn), with the newest assistant
        // message preserved. Emit 1,200 turns so retention engages.
        let runner = ReplayBenchmarkRunner(turns: 1_200)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "bounded replay")
        let threadId = try XCTUnwrap(vm.selectedThreadId)

        vm.prompt = "generate replay benchmark"
        await vm.send()
        await waitAsync("6,000-event run completes", timeout: 60) {
            vm.status == .completed && vm.timeline.latestAssistantMessage == "REPLAY_1199"
        }
        XCTAssertEqual(vm.timeline.turns.count, 1_200,
                       "the live run must build the full transcript before the bounded thread-open replay")

        let start = DispatchTime.now()
        vm.selectThread(threadId)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let budgetMs = 2_000.0

        print("ThreadOpenReplayBenchmark events=6001 turns=1200 elapsedMs=\(Int(elapsedMs)) budgetMs=\(Int(budgetMs))")
        // 100 retained stream events / 5 events per fixture turn = 20 turns.
        XCTAssertEqual(vm.timeline.turns.count, 20,
                       "thread-open hot replay must apply only the durable retention window, not the full 1,200-turn live history")
        XCTAssertEqual(vm.timeline.latestAssistantMessage, "REPLAY_1199",
                       "thread-open replay must preserve the newest assistant message after rebuilding the timeline")
        XCTAssertLessThanOrEqual(elapsedMs, budgetMs,
                                 "opening a large thread must stay under the CI replay budget to catch O(n^2) regressions")
    }

    // MARK: - Fix B: transcriptSignature static helper

    /// buildTranscriptSignature is deterministic: the same messages + turns
    /// must always produce the same string. This is the core correctness
    /// property that makes the SignatureCache safe to use.
    func test_buildTranscriptSignature_isDeterministicForSameInputs() {
        let threadId = AgentThreadID()
        let msgA = AgentMessage(threadId: threadId, role: .user, content: "hello")
        let msgB = AgentMessage(threadId: threadId, role: .assistant, content: "world")
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [AssistantItem(id: "i1", turnId: "t1", type: .assistantMessage,
                                  startedAtMs: 1_000)]
        )

        let sig1 = AgentAppView.buildTranscriptSignature(messages: [msgA, msgB], turns: [turn])
        let sig2 = AgentAppView.buildTranscriptSignature(messages: [msgA, msgB], turns: [turn])

        XCTAssertEqual(sig1, sig2,
                       "buildTranscriptSignature must be deterministic: identical inputs must produce identical signature strings, otherwise the SignatureCache would over-invalidate or return stale results")
    }

    /// Signature changes when a message is appended — even when turns don't change.
    /// WHY: the cache must invalidate on message list changes so new context
    /// (user sends a message) refreshes the transcript.
    func test_buildTranscriptSignature_changesWhenMessageAppended() {
        let threadId = AgentThreadID()
        let msg1 = AgentMessage(threadId: threadId, role: .user, content: "ping")
        let turn = AssistantTurnSnapshot(turnId: "t1", items: [])

        let sigBefore = AgentAppView.buildTranscriptSignature(messages: [msg1], turns: [turn])
        let msg2 = AgentMessage(threadId: threadId, role: .assistant, content: "pong")
        let sigAfter = AgentAppView.buildTranscriptSignature(messages: [msg1, msg2], turns: [turn])

        XCTAssertNotEqual(sigBefore, sigAfter,
                          "adding a message must change the signature so the transcript sort reruns and the new message appears")
    }

    /// Signature changes when a turn gains a new item — even when messages don't change.
    /// WHY: streaming deltas add items to turns; the cache must detect this so
    /// the transcript re-sorts and the new item renders.
    func test_buildTranscriptSignature_changesWhenTurnItemAdded() {
        let threadId = AgentThreadID()
        let msg = AgentMessage(threadId: threadId, role: .user, content: "hi")
        let turnBefore = AssistantTurnSnapshot(turnId: "t1", items: [])
        let sigBefore = AgentAppView.buildTranscriptSignature(messages: [msg], turns: [turnBefore])

        let turnAfter = AssistantTurnSnapshot(
            turnId: "t1",
            items: [AssistantItem(id: "i1", turnId: "t1", type: .assistantMessage, startedAtMs: 1_000)]
        )
        let sigAfter = AgentAppView.buildTranscriptSignature(messages: [msg], turns: [turnAfter])

        XCTAssertNotEqual(sigBefore, sigAfter,
                          "adding an item to a turn must change the signature so the transcript cache re-sorts and the new item is rendered")
    }

    /// Signature does NOT change when only a turn item's body text changes.
    /// WHY: body text changes on every streaming delta token; re-sorting the
    /// whole transcript on every token is the cost we're eliminating. The
    /// signature intentionally ignores body content.
    func test_buildTranscriptSignature_stableOnItemBodyChange() {
        let threadId = AgentThreadID()
        let msg = AgentMessage(threadId: threadId, role: .user, content: "hi")
        var item = AssistantItem(id: "i1", turnId: "t1", type: .assistantMessage, startedAtMs: 1_000)
        let turnBefore = AssistantTurnSnapshot(turnId: "t1", items: [item])
        let sigBefore = AgentAppView.buildTranscriptSignature(messages: [msg], turns: [turnBefore])

        item.body = "streaming text chunk"
        let turnAfter = AssistantTurnSnapshot(turnId: "t1", items: [item])
        let sigAfter = AgentAppView.buildTranscriptSignature(messages: [msg], turns: [turnAfter])

        XCTAssertEqual(sigBefore, sigAfter,
                       "streaming body updates must NOT change the signature — that is the key perf invariant: sort and dedup run only on structural changes, not on every token delta")
    }

    // MARK: - Fix C: thread workspace membership cache

    /// After createThread (which calls reloadThreads), the threadWorkspaceCache
    /// must contain the new thread's id mapped to the correct workspace.
    /// This proves the cache is populated before any status events arrive.
    func test_threadWorkspaceCache_populatedAfterReloadThreads() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "cached")
        let tid = try XCTUnwrap(vm.selectedThreadId)

        // The cache must already know this thread's workspace.
        // We prove it indirectly: a runCoordinator(_:didChangeStatus:) for
        // this thread must update vm.status without hitting the DB for the
        // workspace check (we cannot spy on DB calls directly, so we verify
        // the behavioral outcome is correct).
        let runId = AgentRunID()
        vm.runCoordinator(vm.coordinator, didChangeStatus: .running, runId: runId, threadId: tid)

        // Wait for the Task to run.
        let deadline = Date().addingTimeInterval(4)
        while vm.status != .running && Date() < deadline {
            await Task.yield()
        }

        XCTAssertEqual(vm.status, .running,
                       "didChangeStatus for a thread in this workspace must update status — proving the workspace cache correctly identifies own-workspace threads without a DB read")
    }

    /// A status event for a thread belonging to a different workspace must be
    /// silently dropped — the workspace filter must work correctly via the cache.
    func test_threadWorkspaceCache_filtersOtherWorkspaceThreads() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "own")
        let ownTid = try XCTUnwrap(vm.selectedThreadId)
        let initialStatus = vm.status

        // Create a thread in a different workspace outside this VM.
        let foreignTid = AgentThreadID()  // not in this VM's workspace

        let runId = AgentRunID()
        vm.runCoordinator(vm.coordinator, didChangeStatus: .running, runId: runId,
                          threadId: foreignTid)
        await Task.yield()

        // Status must NOT change — the foreign thread was filtered out.
        // (ownTid is selected but foreignTid's event must not affect it.)
        XCTAssertEqual(vm.selectedThreadId, ownTid,
                       "delivering a status event for a foreign thread must not change the selection")
        XCTAssertEqual(vm.status, initialStatus,
                       "status event for a thread in a different workspace must be filtered by the cache and not update this surface's status")
    }

    // MARK: - Stream quantum pure reduce

    /// WHY: production applies stream quanta off MainActor; the pure reducer must
    /// preserve order and mark runs active only when pre-resolved, without SQLite.
    func test_reduceStreamQuantum_appliesOrderedEventsAndActiveGate() {
        let tid = AgentThreadID()
        let run = AgentRunID()
        let turnId = "pure-turn"
        let itemId = "pure-item"
        let input = StreamQuantumReduceInput(
            selectedThreadId: tid,
            timeline: AssistantTimelineState(),
            suppressStaleActivePlanUpdates: false,
            newestUserMessageAt: nil,
            runStartedAt: nil,
            hasQueuedFollowUp: false,
            currentRunId: nil,
            status: .pending,
            lastErrorRecoverable: false,
            liveBackgroundShellCount: 0,
            runsAllowedToMarkActive: [run],
            entries: [
                StreamQuantumEntry(event: .turnStarted(turnId: turnId), run: run, threadId: tid),
                StreamQuantumEntry(
                    event: .itemStarted(item: AssistantItem(
                        id: itemId, turnId: turnId, type: .assistantMessage,
                        startedAtMs: 1
                    )),
                    run: run,
                    threadId: tid
                ),
                StreamQuantumEntry(
                    event: .itemDelta(itemId: itemId, bodyAppend: "hi", outputAppend: nil, summary: nil),
                    run: run,
                    threadId: tid
                ),
            ]
        )
        let reduced = AgentAppViewModel.reduceStreamQuantum(input)
        XCTAssertTrue(reduced.appliedEvent)
        XCTAssertEqual(reduced.currentRunId, run)
        XCTAssertEqual(reduced.status, .running)
        XCTAssertTrue(reduced.seedRunStartedAt)
        XCTAssertEqual(reduced.timeline.turns.first?.items.first?.body, "hi")
    }

    func test_reduceStreamQuantum_dropsOtherThreadAndRespectsActiveGate() {
        let selected = AgentThreadID()
        let other = AgentThreadID()
        let allowed = AgentRunID()
        let denied = AgentRunID()
        let input = StreamQuantumReduceInput(
            selectedThreadId: selected,
            timeline: AssistantTimelineState(),
            suppressStaleActivePlanUpdates: false,
            newestUserMessageAt: nil,
            runStartedAt: Date(),
            hasQueuedFollowUp: false,
            currentRunId: nil,
            status: .pending,
            lastErrorRecoverable: false,
            liveBackgroundShellCount: 0,
            runsAllowedToMarkActive: [allowed],
            entries: [
                StreamQuantumEntry(event: .turnStarted(turnId: "other"), run: denied, threadId: other),
                StreamQuantumEntry(event: .turnStarted(turnId: "ok"), run: denied, threadId: selected),
            ]
        )
        let reduced = AgentAppViewModel.reduceStreamQuantum(input)
        XCTAssertTrue(reduced.appliedEvent)
        XCTAssertNil(reduced.currentRunId,
                     "run not in runsAllowedToMarkActive must not latch Working")
        XCTAssertEqual(reduced.status, .pending)
        XCTAssertEqual(reduced.timeline.turns.map(\.turnId), ["ok"])
    }

    // MARK: - StreamEventBatch unit

    /// StreamEventBatch.append returns true only for the FIRST append in a batch
    /// (triggering exactly one flush Task), and false for subsequent appends.
    /// WHY: returning true on every append would re-schedule the flush Task for
    /// each event, defeating the entire batching optimization.
    func test_streamEventBatch_schedulesFlushedOncePerBatch() {
        let batch = StreamEventBatch()
        let tid = AgentThreadID()
        let runId = AgentRunID()
        let event: AssistantEvent = .turnStarted(turnId: "t1")

        let shouldScheduleFirst  = batch.append(event: event, run: runId, threadId: tid)
        let shouldScheduleSecond = batch.append(event: event, run: runId, threadId: tid)
        let shouldScheduleThird  = batch.append(event: event, run: runId, threadId: tid)

        XCTAssertTrue(shouldScheduleFirst,
                      "first append must return true so exactly one flush Task is scheduled")
        XCTAssertFalse(shouldScheduleSecond,
                       "second append must return false — no additional Task should be created")
        XCTAssertFalse(shouldScheduleThird,
                       "subsequent appends must return false — only one flush Task per batch")
    }

    /// After drain(), the batch is reset: the next append returns true again.
    /// WHY: if drain does not reset flushScheduled, the next tick's first event
    /// would not schedule a flush and events would be silently lost.
    func test_streamEventBatch_resetAfterDrain() {
        let batch = StreamEventBatch()
        let tid = AgentThreadID()
        let runId = AgentRunID()
        let event: AssistantEvent = .turnStarted(turnId: "t2")

        _ = batch.append(event: event, run: runId, threadId: tid)
        let drained = batch.drain()
        XCTAssertEqual(drained.count, 1,
                       "drain must return all buffered events")

        // After drain the batch is empty — next append should schedule again.
        let shouldScheduleAfterDrain = batch.append(event: event, run: runId, threadId: tid)
        XCTAssertTrue(shouldScheduleAfterDrain,
                      "first append after drain must return true so the next tick schedules a new flush Task")
    }

    /// drain() returns events in the order they were appended.
    /// WHY: event order is semantically critical — turnStarted must precede
    /// itemStarted must precede itemDelta; reversing them corrupts the timeline.
    func test_streamEventBatch_drainPreservesInsertionOrder() {
        let batch = StreamEventBatch()
        let tid = AgentThreadID()
        let runId = AgentRunID()

        let events: [AssistantEvent] = [
            .turnStarted(turnId: "t-order-1"),
            .turnStarted(turnId: "t-order-2"),
            .turnStarted(turnId: "t-order-3"),
        ]
        for e in events {
            _ = batch.append(event: e, run: runId, threadId: tid)
        }
        let drained = batch.drain()

        XCTAssertEqual(drained.count, 3,
                       "drain must return all 3 buffered events")
        for (idx, entry) in drained.enumerated() {
            if case .turnStarted(let id) = entry.event {
                XCTAssertEqual(id, "t-order-\(idx + 1)",
                               "drained events must be in insertion order — reordering streaming events corrupts timeline state")
            } else {
                XCTFail("unexpected event type at index \(idx)")
            }
        }
    }

    func test_streamEventBatch_enforcesHighWaterAndDrainsInYieldingQuanta() {
        let batch = StreamEventBatch(limits: .init(
            maxBufferedCount: 3,
            maxBufferedBytes: 64 * 1_024,
            drainCount: 2,
            drainBytes: 64 * 1_024
        ))
        let tid = AgentThreadID()
        let run = AgentRunID()
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "1"), run: run, threadId: tid), .scheduled)
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "2"), run: run, threadId: tid), .buffered)
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "3"), run: run, threadId: tid), .buffered)
        // Budget pressure drops the oldest UI event so the newest always admits.
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "4"), run: run, threadId: tid), .bufferedAfterEviction,
                       "a blocked MainActor must evict oldest buffered paints, not refuse the newest")

        let first = batch.drainQuantum()
        XCTAssertEqual(first.entries.count, 2,
                       "one MainActor application turn must never exceed the configured work quantum")
        XCTAssertTrue(first.hasMore)
        // After eviction the queue still holds 3 events (2,3,4) — first quantum
        // takes 2, second takes the remainder.
        let second = batch.drainQuantum()
        XCTAssertEqual(second.entries.count, 1)
        XCTAssertFalse(second.hasMore)
        if case .turnStarted(let id) = second.entries[0].event {
            XCTAssertEqual(id, "4", "newest event must survive eviction of the oldest")
        } else {
            XCTFail("expected turnStarted after eviction drain")
        }
    }

    func test_streamEventBatch_acceptsEventLargerThanDrainQuantumWithinHardCeiling() {
        // drainBytes is a paint quantum, not an admission ceiling. A single tool
        // payload larger than one quantum must still enter the queue so long-running
        // Chrome/shell turns do not abort on the first large result.
        let batch = StreamEventBatch(limits: .init(
            maxBufferedCount: 8,
            maxBufferedBytes: 64 * 1_024,
            drainCount: 8,
            drainBytes: 512
        ))
        let tid = AgentThreadID()
        let run = AgentRunID()
        let large = AssistantEvent.error(message: String(repeating: "x", count: 8_192), recoverable: true)

        XCTAssertEqual(batch.appendBounded(event: large, run: run, threadId: tid), .scheduled,
                       "an event larger than drainBytes but within maxBufferedBytes must be admitted")
        let quantum = batch.drainQuantum()
        XCTAssertEqual(quantum.entries.count, 1,
                       "drainQuantum must emit a single oversized head event even when it exceeds drainBytes")
        XCTAssertFalse(quantum.hasMore)
    }

    func test_streamEventBatch_rejectsEventAboveHardCeilingAndLatchesOneEpisode() {
        let batch = StreamEventBatch(limits: .init(
            maxBufferedCount: 8,
            maxBufferedBytes: 512,
            drainCount: 8,
            drainBytes: 512
        ))
        let tid = AgentThreadID()
        let run = AgentRunID()
        let oversized = AssistantEvent.error(message: String(repeating: "x", count: 8_192), recoverable: true)

        XCTAssertEqual(batch.appendBounded(event: oversized, run: run, threadId: tid), .saturated,
                       "an event larger than maxBufferedBytes must fail closed instead of exceeding the hot-queue ceiling")
        XCTAssertEqual(batch.appendBounded(event: oversized, run: run, threadId: tid), .saturationAlreadyReported,
                       "one saturation episode may report at most once while the hard ceiling holds")
        XCTAssertTrue(batch.drainQuantum().entries.isEmpty)
        XCTAssertTrue(batch.isEmpty)
    }

    func test_streamEventBatch_finishResetsSaturationForNextRun() {
        let batch = StreamEventBatch(limits: .init(
            maxBufferedCount: 8,
            maxBufferedBytes: 512,
            drainCount: 8,
            drainBytes: 512
        ))
        let thread = AgentThreadID()
        let runA = AgentRunID()
        let runB = AgentRunID()
        let oversized = AssistantEvent.error(
            message: String(repeating: "x", count: 8_192),
            recoverable: true
        )
        XCTAssertEqual(batch.appendBounded(event: oversized, run: runA, threadId: thread), .saturated)
        batch.resetSaturation(for: runA)

        XCTAssertEqual(
            batch.appendBounded(event: .turnStarted(turnId: "run-b"), run: runB, threadId: thread),
            .scheduled,
            "a cleared saturation episode must not suppress the first event of the next run"
        )
    }

    func test_timelineAggregateTextBudgetPreservesCompactActiveState() {
        var state = AssistantTimelineState()
        let plan = AssistantActivePlan(
            steps: [.init(id: "active", title: "Must survive", status: .inProgress)],
            updatedAtMs: 1
        )
        state.apply(.activePlanUpdated(plan))
        for index in 0..<40 {
            let turn = "turn-\(index)"
            state.apply(.turnStarted(turnId: turn))
            state.apply(.itemStarted(item: AssistantItem(
                id: "item-\(index)", turnId: turn, type: .assistantMessage,
                body: String(repeating: "x", count: 2_000), startedAtMs: Int64(index)
            )))
        }
        state.enforceAggregateHotTextBudget(byteLimit: 8_000)
        XCTAssertLessThanOrEqual(state.aggregateHotTextByteCount, 8_000)
        XCTAssertEqual(state.activePlan, plan, "evictable rendered text must not own correctness-critical active state")
    }

    func test_timelineAggregateBudgetIncludesRequestsInputsPlansAndWorkLog() {
        var state = AssistantTimelineState()
        state.apply(.activePlanUpdated(AssistantActivePlan(
            explanation: "active",
            steps: [.init(id: "active-step", title: "Keep status", status: .inProgress)],
            updatedAtMs: 1
        )))
        let large = String(repeating: "x", count: 20_000)
        for index in 0..<200 {
            state.apply(.requestOpened(AssistantPendingRequest(
                id: "request-\(index)", turnId: "turn", kind: .exec,
                title: large, detail: large, createdAtMs: Int64(index)
            )))
            state.apply(.userInputRequested(AssistantUserInputRequest(
                id: "input-\(index)", turnId: "turn", prompt: large,
                options: [large], createdAtMs: Int64(index)
            )))
            state.apply(.proposedPlan(AssistantProposedPlan(
                id: "plan-\(index)", turnId: "turn", markdown: large
            )))
        }

        // Use an explicit sub-production ceiling so the fixture stays small/fast
        // while still proving every hot-state class shares one budget. Production
        // aggregateHotTextByteLimit is sized for a 16 GB MacBook and would require
        // multi-hundred-MB fixtures here.
        let testBudget = 256_000
        XCTAssertGreaterThan(state.aggregateHotTextByteCount, testBudget)
        state.enforceAggregateHotTextBudget(byteLimit: testBudget)

        XCTAssertLessThanOrEqual(
            state.aggregateHotTextByteCount,
            testBudget,
            "every rendered hot-state class plus collection overhead must share one hard budget"
        )
        XCTAssertEqual(state.activePlan?.steps.first?.id, "active-step")
        XCTAssertEqual(state.activePlan?.steps.first?.status, .inProgress,
                       "memory eviction must preserve compact active-plan identity and status")
    }

    // MARK: - PERF 2026-08-05 residual hot path

    /// estimatedHotQueueBytes must be positive and never force a JSON encode.
    /// WHY: StreamEventBatch admission previously allocated JSONEncoder per token.
    func test_estimatedHotQueueBytes_coversItemDeltaAndLargeErrorWithoutEncode() {
        let small = AssistantEvent.itemDelta(
            itemId: "i", bodyAppend: "hello", outputAppend: nil, summary: nil
        )
        let large = AssistantEvent.error(
            message: String(repeating: "x", count: 50_000), recoverable: true
        )
        XCTAssertGreaterThan(small.estimatedHotQueueBytes, 0)
        XCTAssertGreaterThanOrEqual(
            large.estimatedHotQueueBytes, 50_000,
            "estimate must track payload so hard-ceiling saturation still fires"
        )
        // Estimate must be enough to admit tiny events under tiny budgets.
        let batch = StreamEventBatch(limits: .init(
            maxBufferedCount: 8,
            maxBufferedBytes: 4_096,
            drainCount: 8,
            drainBytes: 4_096
        ))
        let tid = AgentThreadID()
        let run = AgentRunID()
        XCTAssertEqual(
            batch.appendBounded(event: small, run: run, threadId: tid),
            .scheduled
        )
    }

    /// Microbench: admission sizing via estimate vs JSONEncoder (same machine, n=5).
    /// Primary metric is wall time for 20_000 itemDelta size measurements.
    func test_microbench_hotQueueSizing_estimateFasterThanJSONEncoder() throws {
        let events: [AssistantEvent] = (0..<64).map { i in
            .itemDelta(
                itemId: "item",
                bodyAppend: String(repeating: "a", count: 16 + (i % 8)),
                outputAppend: nil,
                summary: nil
            )
        }
        let iterations = 20_000
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        func timeJSON() -> Double {
            let encoder = JSONEncoder()
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for i in 0..<iterations {
                let event = events[i % events.count]
                sink &+= (try? encoder.encode(event).count) ?? 0
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0 // ms
        }

        func timeEstimate() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for i in 0..<iterations {
                sink &+= events[i % events.count].estimatedHotQueueBytes
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
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
        NSLog("[perf-proof] hotQueueSizing json_ms=%@ estimate_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 50.0,
            "estimate must be substantially faster than JSONEncoder sizing (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    // MARK: - PERF 2026-08-06 live-view cap (no full grapheme count)

    /// WHY: multi-byte graphemes can sit under the grapheme window while over the
    /// UTF-8 budget — the live cap must not over-truncate them (same F11 contract).
    func test_cappedVisibleText_preservesMultibyteUnderGraphemeLimit() {
        let multibyte = "héllo" // 5 graphemes, >5 UTF-8 bytes
        XCTAssertGreaterThan(multibyte.utf8.count, 5)
        XCTAssertEqual(
            AgentAppView.cappedVisibleText(multibyte, limit: 5),
            multibyte,
            "live head-cap must stay grapheme-based for multi-byte text under the limit"
        )
        XCTAssertEqual(
            AgentAppView.cappedVisibleTextTail(multibyte, limit: 5),
            multibyte,
            "live tail-cap must stay grapheme-based for multi-byte text under the limit"
        )
        let emoji = "😀😀😀😀"
        let head = AgentAppView.cappedVisibleText(emoji, limit: 2)
        XCTAssertTrue(head.hasPrefix("😀😀"), "emoji head-cap keeps first two graphemes")
        XCTAssertFalse(head.contains("😀😀😀"), "emoji head-cap must drop the trailing pair")
        let tail = AgentAppView.cappedVisibleTextTail(emoji, limit: 2)
        XCTAssertTrue(tail.contains("😀😀"), "emoji tail-cap keeps last two graphemes")
        XCTAssertTrue(tail.hasPrefix("..."), "over-limit tail-cap still emits the omission marker")
    }

    /// Microbench: full-body `String.count` walk vs O(limit) index live cap.
    /// Simulates streaming paint re-capping a long held tool/reasoning body.
    func test_microbench_liveVisibleCap_indexFasterThanFullGraphemeCount() throws {
        let body = String(repeating: "b", count: 80_000)
        let limit = AgentAppView.liveTurnBodyCharacterLimit // 2_000
        let iterations = 2_000
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        /// Legacy path retained only for A/B: O(n) grapheme count every paint.
        func timeLegacyCount() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                // Mirror the pre-fix cappedVisibleTextTail body.
                if body.count > limit {
                    let tail = body.suffix(limit)
                    let dropped = body.count - tail.count
                    sink &+= dropped &+ tail.count
                } else {
                    sink &+= body.count
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        func timeIndexCap() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                let capped = AgentAppView.cappedVisibleTextTail(body, limit: limit)
                sink &+= capped.utf8.count
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup { _ = timeLegacyCount(); _ = timeIndexCap() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeLegacyCount())
            after.append(timeIndexCap())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] liveVisibleCap legacy_count_ms=%@ index_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "live-view tail cap must beat full grapheme count by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
        // Functional pin: tail window still surfaces the newest bytes.
        let capped = AgentAppView.cappedVisibleTextTail(body + "LATEST", limit: limit)
        XCTAssertTrue(capped.contains("LATEST"))
        XCTAssertTrue(capped.hasPrefix("..."))
    }

    // MARK: - PERF 2026-08-06 assistant dedupe cache gate

    /// Microbench: warm paint path re-checks cache eligibility with grapheme
    /// `String.count` vs O(1) `utf8.count` (product residual in
    /// `normalizedAssistantText` / `compactAssistantText`).
    ///
    /// WHY: `hiddenPersistedAssistantMessageIDs` re-runs on every
    /// `timelineUpdateTick`; NSCache hits still paid a full grapheme walk per
    /// body just to decide whether the cache key path was allowed.
    func test_microbench_assistantDedupeGate_utf8FasterThanGraphemeCount() throws {
        // Under the 16_384 byte cache budget; typical completed assistant body.
        let text = String(repeating: "word ", count: 2_400) // 12_000 ASCII bytes
        let limit = 16_384
        XCTAssertLessThanOrEqual(text.utf8.count, limit)
        let iterations = 30_000
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        /// Legacy residual: O(n) grapheme count before every warm cache admission.
        func timeLegacyGraphemeGate() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                if text.count <= limit {
                    sink &+= 1
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(sink, iterations)
            return Double(end - start) / 1_000_000.0
        }

        /// Product path: O(1) UTF-8 length gate.
        func timeUTF8Gate() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                if text.utf8.count <= limit {
                    sink &+= 1
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertEqual(sink, iterations)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup { _ = timeLegacyGraphemeGate(); _ = timeUTF8Gate() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeLegacyGraphemeGate())
            after.append(timeUTF8Gate())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] assistantDedupeGate grapheme_ms=%@ utf8_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "dedupe cache gate must beat grapheme count by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )

        // Functional pin: same combined-answer hide contract as AgentAppViewModelTests.
        let threadId = AgentThreadID()
        let persisted = AgentMessage(
            threadId: threadId,
            role: .assistant,
            content: "S start. D inspect. O done."
        )
        let turn = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S start. D inspect.", startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "O done.", startedAtMs: 2)
            ],
            finished: true
        )
        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [turn]),
            [persisted.id],
            "utf8 cache gate must not change hidden-persisted dedupe semantics"
        )
    }

    // MARK: - Coalesced aggregate hot-text budget walk

    private func streamInput(
        entries: [StreamQuantumEntry],
        thread: AgentThreadID,
        run: AgentRunID,
        timeline: AssistantTimelineState = AssistantTimelineState()
    ) -> StreamQuantumReduceInput {
        StreamQuantumReduceInput(
            selectedThreadId: thread,
            timeline: timeline,
            suppressStaleActivePlanUpdates: false,
            newestUserMessageAt: nil,
            runStartedAt: nil,
            hasQueuedFollowUp: false,
            currentRunId: nil,
            status: .pending,
            lastErrorRecoverable: false,
            liveBackgroundShellCount: 0,
            runsAllowedToMarkActive: [run],
            entries: entries
        )
    }

    /// WHY: the budget walk is the only thing holding the 96 MiB aggregate hot-text
    /// ceiling. Coalescing it is safe only while pure token quanta are the sole
    /// events allowed to skip — a future event added to the skip list could grow
    /// the timeline unboundedly between walks. Pin the classification.
    func test_reduceStreamQuantum_onlyPureTokenQuantaSkipTheBudgetWalk() {
        let tid = AgentThreadID()
        let run = AgentRunID()
        let turnId = "budget-turn"
        let itemId = "budget-item"
        var seeded = AssistantTimelineState()
        seeded.apply(.turnStarted(turnId: turnId))
        seeded.apply(.itemStarted(item: AssistantItem(
            id: itemId, turnId: turnId, type: .assistantMessage, startedAtMs: 0
        )))

        let tokenOnly = AgentAppViewModel.reduceStreamQuantum(streamInput(
            entries: [
                StreamQuantumEntry(
                    event: .itemDelta(itemId: itemId, bodyAppend: "tok", outputAppend: nil, summary: nil),
                    run: run, threadId: tid
                ),
                StreamQuantumEntry(event: .itemProgress(itemId: itemId, progress: 0.5), run: run, threadId: tid),
            ],
            thread: tid, run: run, timeline: seeded
        ))
        XCTAssertTrue(tokenOnly.appliedEvent)
        XCTAssertFalse(tokenOnly.forceAggregateBudget,
                       "pure token quanta must not force the O(items) budget walk")
        XCTAssertEqual(tokenOnly.appliedEventCount, 2)

        let structural = AgentAppViewModel.reduceStreamQuantum(streamInput(
            entries: [
                StreamQuantumEntry(
                    event: .itemDelta(itemId: itemId, bodyAppend: "tok", outputAppend: nil, summary: nil),
                    run: run, threadId: tid
                ),
                StreamQuantumEntry(event: .itemCompleted(itemId: itemId, finalState: .completed),
                                   run: run, threadId: tid),
            ],
            thread: tid, run: run, timeline: seeded
        ))
        XCTAssertTrue(structural.forceAggregateBudget,
                      "a structural event must force the budget walk in the same quantum")

        // A single large delta is over the 64 KiB quantum gate even though its
        // event kind is skippable.
        let large = AgentAppViewModel.reduceStreamQuantum(streamInput(
            entries: [
                StreamQuantumEntry(
                    event: .itemDelta(itemId: itemId,
                                      bodyAppend: String(repeating: "x", count: 70_000),
                                      outputAppend: nil, summary: nil),
                    run: run, threadId: tid
                )
            ],
            thread: tid, run: run, timeline: seeded
        ))
        XCTAssertTrue(large.forceAggregateBudget,
                      "a quantum over the 64 KiB gate must force the budget walk")
    }

    /// WHY: skipping the walk is bounded ONLY by this counter. If it stopped
    /// resetting, or the threshold stopped being reached, the hot-text ceiling
    /// would never be enforced during a long pure-token stream.
    func test_aggregateBudgetDecision_coalescesTokenQuantaAndAlwaysConverges() {
        var ops = 0
        // 15 single-event token quanta skip the walk...
        for step in 1..<AgentAppViewModel.streamAggregateBudgetThreshold {
            let decision = AgentAppViewModel.aggregateBudgetDecision(
                force: false, opsSinceLastWalk: ops, appliedEventCount: 1
            )
            XCTAssertFalse(decision.runsWalk, "token quantum \(step) must skip the walk")
            XCTAssertEqual(decision.nextOps, step, "counter must accumulate applied events")
            ops = decision.nextOps
        }
        // ...and the 16th forces it and resets the counter.
        let forced = AgentAppViewModel.aggregateBudgetDecision(
            force: false, opsSinceLastWalk: ops, appliedEventCount: 1
        )
        XCTAssertTrue(forced.runsWalk, "the threshold-th applied event must force the walk")
        XCTAssertEqual(forced.nextOps, 0, "forcing the walk must reset the counter")

        // A structural quantum forces immediately and resets, regardless of count.
        let structural = AgentAppViewModel.aggregateBudgetDecision(
            force: true, opsSinceLastWalk: 0, appliedEventCount: 1
        )
        XCTAssertTrue(structural.runsWalk)
        XCTAssertEqual(structural.nextOps, 0)

        // A fat quantum reaches the threshold in one commit.
        let fat = AgentAppViewModel.aggregateBudgetDecision(
            force: false, opsSinceLastWalk: 0,
            appliedEventCount: AgentAppViewModel.streamAggregateBudgetThreshold
        )
        XCTAssertTrue(fat.runsWalk, "one quantum carrying threshold events must force the walk")

        // A quantum that applied nothing still advances the counter, so a stream
        // of empty commits cannot stall the walk forever.
        let empty = AgentAppViewModel.aggregateBudgetDecision(
            force: false, opsSinceLastWalk: 0, appliedEventCount: 0
        )
        XCTAssertFalse(empty.runsWalk)
        XCTAssertEqual(empty.nextOps, 1)
    }

    // MARK: - SR1 publish skip

    /// WHY: the skip exists to avoid rebuilding the published SR1 sets on every
    /// token. It is only safe while it is a strict superset of the cases where
    /// refreshSR1TranslationStateFromTimeline can change state — in particular the
    /// eviction path, where the timeline is already empty but the published cache
    /// still holds badges that MUST be cleared.
    func test_shouldPublishSR1State_skipsOnlyWhenRepublishIsANoOp() {
        let empty = AssistantTimelineState()
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishSR1State(
                timeline: empty, publishedIds: [], publishedOriginals: [:]
            ),
            "both sides empty is the pure-token path and must skip"
        )

        var translated = AssistantTimelineState()
        translated.apply(.sr1Translation(AssistantSR1Translation(
            messageId: UUID().uuidString, originalText: "o", rewrittenText: "r"
        )))
        XCTAssertFalse(translated.sr1TranslationsByMessageId.isEmpty)
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishSR1State(
                timeline: translated, publishedIds: [], publishedOriginals: [:]
            ),
            "a new translation must always publish"
        )

        // Eviction shape: the aggregate budget walk emptied the timeline, but the
        // published badges are still live and have to be cleared.
        let stale = AgentMessageID(UUID())
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishSR1State(
                timeline: empty, publishedIds: [stale], publishedOriginals: [:]
            ),
            "budget-evicted translations must still clear the published id set"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishSR1State(
                timeline: empty, publishedIds: [], publishedOriginals: [stale: "o"]
            ),
            "budget-evicted translations must still clear the published originals"
        )

        var itemOnly = AssistantTimelineState()
        itemOnly.apply(.sr1Translation(AssistantSR1Translation(
            itemId: "item", originalText: "o", rewrittenText: "r"
        )))
        XCTAssertFalse(itemOnly.sr1TranslationsByItemId.isEmpty)
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishSR1State(
                timeline: itemOnly, publishedIds: [], publishedOriginals: [:]
            ),
            "item-scoped translations must not be silently dropped by the guard"
        )
    }

    // MARK: - commitStreamQuantum composition (the wiring the pure units miss)

    private func reducedQuantum(
        timeline: AssistantTimelineState,
        force: Bool,
        appliedEventCount: Int = 1
    ) -> StreamQuantumReduceResult {
        StreamQuantumReduceResult(
            appliedEvent: true,
            timeline: timeline,
            currentRunId: nil,
            status: .running,
            lastErrorRecoverable: false,
            liveBackgroundShellCount: 0,
            suppressStaleActivePlanUpdates: false,
            seedRunStartedAt: false,
            runThreadBindings: [:],
            hasProposedPlan: false,
            forceAggregateBudget: force,
            appliedEventCount: appliedEventCount
        )
    }

    /// WHY: `aggregateBudgetDecision` and `shouldPublishSR1State` are pure and
    /// individually tested, but the invariant that actually protects the hot-text
    /// ceiling lives in their COMPOSITION inside `commitStreamQuantum`: the
    /// counter must be written back, and the budget walk must run BEFORE the
    /// publish guard reads the timeline. A regression that drops
    /// `streamAggregateBudgetOps = budget.nextOps`, or swaps the two blocks, would
    /// leave both unit tests green. This drives the real method.
    func test_commitStreamQuantum_coalescesWalkThenPublishesEvictedSR1State() throws {
        let (vm, _) = try makeVM()
        vm.aggregateHotTextByteLimitForTesting = 4_000

        // A timeline holding one SR1 translation, well under the lowered ceiling.
        let messageId = UUID().uuidString
        var small = AssistantTimelineState()
        small.apply(.sr1Translation(AssistantSR1Translation(
            messageId: messageId, originalText: "original", rewrittenText: "rewritten"
        )))
        vm.commitStreamQuantum(reducedQuantum(timeline: small, force: true))
        XCTAssertEqual(vm.sr1TranslatedMessageIds.count, 1,
                       "a committed translation must publish its badge")
        XCTAssertEqual(vm.streamAggregateBudgetOpsForTesting, 0,
                       "a forced walk must reset the coalescing counter")

        // Pure token quanta coalesce: the counter accumulates and never resets
        // until the threshold, which is the only thing bounding the skip window.
        for step in 1..<AgentAppViewModel.streamAggregateBudgetThreshold {
            vm.commitStreamQuantum(reducedQuantum(timeline: small, force: false))
            XCTAssertEqual(vm.streamAggregateBudgetOpsForTesting, step,
                           "token quantum \(step) must accumulate, not reset")
        }
        vm.commitStreamQuantum(reducedQuantum(timeline: small, force: false))
        XCTAssertEqual(vm.streamAggregateBudgetOpsForTesting, 0,
                       "the threshold-th applied event must run the walk and reset")

        // Now exceed the lowered ceiling. The walk must evict the translation AND
        // the publish guard must observe the post-eviction timeline, clearing the
        // badge. If the guard ran before the walk, the badge would survive.
        //
        // The oversize must live in the TRANSLATION itself: enforceAggregateHotTextBudget
        // clears item bodies first and returns as soon as it is back under the
        // ceiling, so a large item body would be freed without ever reaching the
        // sr1Translations eviction loops.
        var oversized = AssistantTimelineState()
        oversized.apply(.sr1Translation(AssistantSR1Translation(
            messageId: messageId,
            originalText: String(repeating: "o", count: 10_000),
            rewrittenText: String(repeating: "r", count: 10_000)
        )))
        XCTAssertGreaterThan(oversized.aggregateHotTextByteCount, 4_000,
                             "fixture must actually exceed the lowered ceiling")

        vm.commitStreamQuantum(reducedQuantum(timeline: oversized, force: true))
        XCTAssertTrue(vm.timeline.sr1TranslationsByMessageId.isEmpty,
                      "the budget walk must evict translations over the ceiling")
        XCTAssertTrue(vm.sr1TranslatedMessageIds.isEmpty,
                      "walk-then-publish order must clear badges evicted in the same commit")
        XCTAssertTrue(vm.sr1OriginalTextsByMessageId.isEmpty,
                      "evicted originals must not survive in the published cache")
    }

    // MARK: - Truncation marker contract (the one deliberate output change)

    /// WHY: the marker's size is a UTF-8 residual, and the differential proof that
    /// compared old vs new output normalised the number away. Without these,
    /// nothing pins either the reported quantity or the formatting convention, so
    /// a revert to a raw grapheme count, to a raw integer, or to measuring the
    /// residual before ANSI stripping would fail no test.
    ///
    /// Precision, stated honestly: `ByteCountFormatter` rounds, so these pin the
    /// residual to its formatter bucket (~±500 B at KB scale), NOT to the byte.
    /// A one-byte off-by-one would still pass. The ANSI case below is sized so the
    /// stripped and unstripped measurements land in DIFFERENT buckets, and asserts
    /// that they do — otherwise that assertion would not discriminate either.
    func test_truncationMarkers_reportFormattedUTF8Residual() {
        let limit = 64
        let body = String(repeating: "x", count: 4_096)

        let head = AgentAppView.cappedVisibleText(body, limit: limit)
        let headKept = String(body.prefix(limit))
        XCTAssertTrue(head.hasPrefix(headKept))
        XCTAssertTrue(
            head.contains(AgentTimelineItemPresentation.truncationSizeLabel(
                body.utf8.count - headKept.utf8.count
            )),
            "head cap must report the formatted UTF-8 residual it actually dropped"
        )
        XCTAssertFalse(head.contains("more characters"),
                       "the marker must not claim a character count it never computes")

        let tail = AgentAppView.cappedVisibleTextTail(body, limit: limit)
        let tailKept = String(body.suffix(limit))
        XCTAssertTrue(tail.hasSuffix(tailKept))
        XCTAssertTrue(
            tail.contains(AgentTimelineItemPresentation.truncationSizeLabel(
                body.utf8.count - tailKept.utf8.count
            )),
            "tail cap must report the formatted UTF-8 residual it actually dropped"
        )
        XCTAssertFalse(tail.contains("earlier characters"),
                       "the tail marker must not claim a character count either")

        // cappedDetail measures the residual AFTER stripping ANSI, not before.
        // Sized so stripped (999 B) and unstripped (1008 B) fall either side of a
        // formatter bucket boundary; the assertion below proves they do, so this
        // case actually discriminates instead of matching both ways.
        let ansiBody = String(repeating: "x", count: limit + 999)
        let ansi = "\u{1B}[31m" + ansiBody + "\u{1B}[0m"
        let detail = AgentTimelineItemPresentation.cappedDetail(ansi, limit: limit)
        let clean = AgentTimelineItemPresentation.stripANSI(ansi)
        let detailKept = String(clean.prefix(limit))
        let strippedLabel = AgentTimelineItemPresentation.truncationSizeLabel(
            clean.utf8.count - detailKept.utf8.count
        )
        let unstrippedLabel = AgentTimelineItemPresentation.truncationSizeLabel(
            ansi.utf8.count - detailKept.utf8.count
        )
        XCTAssertNotEqual(strippedLabel, unstrippedLabel,
                          "fixture must straddle a formatter bucket or this case proves nothing")
        XCTAssertTrue(detail.contains(strippedLabel),
                      "tool detail residual must be measured on the ANSI-stripped body")
        XCTAssertFalse(detail.contains(unstrippedLabel),
                       "tool detail residual must NOT be measured before ANSI stripping")
        XCTAssertFalse(detail.contains("more characters"))

        // Formatting convention: sizes go through ByteCountFormatter like every
        // other byte quantity the app shows, not a raw six-digit integer.
        let wide = AgentAppView.cappedVisibleText(String(repeating: "y", count: 400_000), limit: 2_000)
        XCTAssertTrue(
            wide.contains(AgentTimelineItemPresentation.truncationSizeLabel(398_000)),
            "large residuals must render through the shared size formatter"
        )
        XCTAssertFalse(
            wide.contains("398000"),
            "large residuals must not render as a raw digit wall"
        )
    }

}

private final class ReplayBenchmarkRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let turns: Int

    init(turns: Int) {
        self.turns = turns
    }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let turns = self.turns
        Task.detached {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let startedAt = Int64(Date().timeIntervalSince1970 * 1000)
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            for index in 0..<turns {
                let turnId = "replay-turn-\(index)"
                let itemId = "replay-item-\(index)"
                onEvent(.event(.turnStarted(turnId: turnId)))
                onEvent(.event(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: .assistantMessage,
                    startedAtMs: startedAt + Int64(index)
                ))))
                onEvent(.event(.itemDelta(itemId: itemId, bodyAppend: "REPLAY_\(index)", outputAppend: nil, summary: nil)))
                onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "REPLAY_\(index)")))
            }
            onEvent(.status(.completed))
            onEvent(.finished(.completed, finalMessage: "REPLAY_\(max(turns - 1, 0))", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}
