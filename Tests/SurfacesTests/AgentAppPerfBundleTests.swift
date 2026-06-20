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

    // MARK: - PERF #1: 5,000-event thread-open replay benchmark

    func test_threadOpenReplayFiveThousandEventsStaysWithinBudget() async throws {
        let runner = ReplayBenchmarkRunner(turns: 1_000)
        let (vm, _) = try makeVM(provider: runner)
        vm.createThread(title: "5k replay")
        let threadId = try XCTUnwrap(vm.selectedThreadId)

        vm.prompt = "generate replay benchmark"
        await vm.send()
        await waitAsync("5,000-event run completes", timeout: 30) {
            vm.status == .completed && vm.timeline.latestAssistantMessage == "REPLAY_999"
        }

        let start = DispatchTime.now()
        vm.selectThread(threadId)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let budgetMs = 2_000.0

        print("ThreadOpenReplayBenchmark events=5000 turns=1000 elapsedMs=\(Int(elapsedMs)) budgetMs=\(Int(budgetMs))")
        XCTAssertEqual(vm.timeline.turns.count, 1_000,
                       "thread-open replay must restore every persisted turn from the 5,000-event run")
        XCTAssertEqual(vm.timeline.latestAssistantMessage, "REPLAY_999",
                       "thread-open replay must preserve the newest assistant message after rebuilding the timeline")
        XCTAssertLessThanOrEqual(elapsedMs, budgetMs,
                                 "opening a 5,000-event thread must stay under the CI replay budget to catch O(n^2) regressions")
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
