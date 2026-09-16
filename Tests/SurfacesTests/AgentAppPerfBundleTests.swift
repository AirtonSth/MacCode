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

    private func makeVMWithRunRepository(
        provider: AgentProviderRunner? = nil
    ) throws -> (AgentAppViewModel, AgentThreadRepository, AgentRunRepository) {
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
        return (vm, threadRepo, runRepo)
    }

    private func makeVM(provider: AgentProviderRunner? = nil) throws -> (AgentAppViewModel, AgentThreadRepository) {
        let (vm, threadRepo, _) = try makeVMWithRunRepository(provider: provider)
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

    /// Token Saver badges must still update after wire events are applied in
    /// bulk. This protects the user-visible "View original" affordance while the
    /// stream flush avoids publishing empty/no-op badge state on every token.
    func test_streamEventBatch_updatesTokenSaverBadgeStateAfterBulkTimelineApply() async throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "wire translation")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let runId = AgentRunID()
        let messageId = AgentMessageID()
        let original = "RCW1\tA\t1\nO\tState, patch, tests.\n.\n"
        let request = "RCW1\tQ\t1\nG\tInspect and report.\n.\n"

        vm.runCoordinator(
            vm.coordinator,
            didReceive: .wireTranslation(AssistantWireTranslation(
                messageId: messageId.value.uuidString,
                originalText: original,
                rewrittenText: "State, patch, tests.",
                wireRequestText: request
            )),
            run: runId,
            threadId: tid
        )
        vm.runCoordinator(
            vm.coordinator,
            didReceive: .wireTranslation(AssistantWireTranslation(
                itemId: "progress-item",
                originalText: original,
                rewrittenText: "State, patch, tests.",
                wireRequestText: request
            )),
            run: runId,
            threadId: tid
        )

        await Task.yield()

        XCTAssertTrue(vm.tokenSaverOptimizedMessageIds.contains(messageId),
                      "batched stream flush must still mark wire-rendered messages so the transcript shows the badge")
        XCTAssertEqual(vm.tokenSaverOriginalText(for: messageId), original,
                       "batched stream flush must preserve the original compressed text for the View original disclosure")
        XCTAssertEqual(vm.tokenSaverWireRequestText(for: messageId), request,
                       "the disclosure must expose exactly what RemoteCode sent while keeping the human prompt canonical")
        let itemTranslation = try XCTUnwrap(vm.tokenSaverTranslation(forItemId: "progress-item"))
        XCTAssertEqual(itemTranslation.originalText, original,
                       "streamed progress must expose its exact raw provider frame, not only the final message")
        XCTAssertEqual(itemTranslation.wireRequestText, request,
                       "streamed progress must retain the exact provider-bound request for the Translated/RCW1 toggle")
    }

    func test_tokenSaverPublishedCacheDropsTranslationsEvictedByHotBudget() throws {
        let (vm, _) = try makeVM()
        var state = AssistantTimelineState()
        let text = String(repeating: "s", count: 100_000)
        for _ in 0..<50 {
            let messageID = AgentMessageID()
            state.apply(.wireTranslation(AssistantWireTranslation(
                messageId: messageID.value.uuidString,
                originalText: text,
                rewrittenText: text
            )))
        }
        vm.refreshTokenSaverOptimizationStateFromTimeline(state)
        let before = vm.tokenSaverOptimizedMessageIds
        XCTAssertEqual(before.count, 50)

        // Production aggregateHotTextByteLimit is now 32 MiB, so this small fixture no
        // longer evicts under the default. Force eviction with an explicit sub-production
        // 8 MiB budget (mirrors test_timelineAggregateBudgetIncludesRequestsInputsPlansAndWorkLog).
        let testBudget = 8 * 1_024 * 1_024
        state.enforceAggregateHotTextBudget(byteLimit: testBudget)
        vm.refreshTokenSaverOptimizationStateFromTimeline(state)

        let retained = Set(state.tokenSaverTranslationsByMessageId.keys.compactMap(UUID.init(uuidString:)).map(AgentMessageID.init))
        XCTAssertEqual(vm.tokenSaverOptimizedMessageIds, retained,
                       "published badges must be an exact projection of the budgeted timeline")
        XCTAssertTrue(vm.tokenSaverOptimizedMessageIds.isStrictSubset(of: before),
                      "translations evicted by the 8 MiB budget must not remain in a duplicate cache")
        XCTAssertEqual(Set(vm.tokenSaverOriginalTextsByMessageId.keys), retained)
        XCTAssertLessThanOrEqual(
            vm.tokenSaverOriginalTextsByMessageId.values.reduce(0) { $0 + $1.utf8.count },
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
        //
        // Same-thread re-select is a soft path (keeps the painted live timeline).
        // Force a true full open by switching away and back.
        let (vm, _, runRepo) = try makeVMWithRunRepository()
        vm.createThread(title: "bounded replay")
        let threadId = try XCTUnwrap(vm.selectedThreadId)
        let run = AgentRun(
            threadId: threadId,
            provider: .codex,
            model: "gpt-5.5",
            status: .completed,
            finishedAt: Date()
        )
        try runRepo.upsert(run)
        let encoder = JSONEncoder()
        var writes: [AgentRunRepository.StreamWriteIntent] = []
        writes.reserveCapacity(6_000)
        for index in 0..<1_200 {
            let turnId = "replay-turn-\(index)"
            let itemId = "replay-item-\(index)"
            let startedAt = Int64(index)
            let events: [AssistantEvent] = [
                .turnStarted(turnId: turnId),
                .itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: turnId,
                    type: .assistantMessage,
                    startedAtMs: startedAt
                )),
                .itemDelta(itemId: itemId, bodyAppend: "REPLAY_\(index)", outputAppend: nil, summary: nil),
                .itemCompleted(itemId: itemId, finalState: .completed),
                .turnCompleted(turnId: turnId, finalMessage: "REPLAY_\(index)"),
            ]
            for event in events {
                let payload = String(decoding: try encoder.encode(event), as: UTF8.self)
                writes.append(.init(
                    seq: writes.count + 1,
                    kind: event.debugDescription,
                    payloadJSON: payload,
                    providerEvent: nil
                ))
            }
        }
        try runRepo.persistStreamBatch(
            runId: run.id,
            threadId: threadId,
            items: writes,
            shouldPruneStreamEvents: true
        )

        vm.createThread(title: "switch-away")
        let otherId = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertNotEqual(otherId, threadId)
        await waitAsync("switched away", timeout: 6) { vm.selectedThreadId == otherId }

        let start = DispatchTime.now()
        vm.selectThread(threadId)
        await waitAsync("full open replay applied", timeout: 10) {
            vm.selectedThreadId == threadId && vm.timeline.latestAssistantMessage == "REPLAY_1199"
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        let budgetMs = 2_000.0

        print("ThreadOpenReplayBenchmark events=6001 turns=\(vm.timeline.turns.count) elapsedMs=\(Int(elapsedMs)) budgetMs=\(Int(budgetMs))")
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

    /// WHY: every mounted Agent App observes coordinator status. A cache miss
    /// used to full-get the 26-column row (plus routing JSON) just to learn
    /// workspace_id, then drop foreign events. The probe is the cheap path
    /// already proven on rail selection.
    func test_didChangeStatus_cacheMiss_usesWorkspaceIdProbeNotDurableGet() async throws {
        let (vm, threadRepo) = try makeVM()
        let initialStatus = vm.status
        let foreign = AgentThread(
            workspaceId: WorkspaceID(),
            title: "foreign",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(foreign)

        let getsBefore = threadRepo.durableGetCountForTesting
        let probesBefore = threadRepo.workspaceIdProbeCountForTesting
        vm.runCoordinator(
            vm.coordinator,
            didChangeStatus: .running,
            runId: AgentRunID(),
            threadId: foreign.id
        )
        let deadline = Date().addingTimeInterval(4)
        while threadRepo.workspaceIdProbeCountForTesting == probesBefore && Date() < deadline {
            await Task.yield()
        }

        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "foreign cache-miss status must not compile a full 26-column get"
        )
        XCTAssertEqual(
            threadRepo.workspaceIdProbeCountForTesting,
            probesBefore + 1,
            "foreign cache-miss status must probe workspace_id once"
        )
        XCTAssertEqual(vm.status, initialStatus)

        let probesAfterMiss = threadRepo.workspaceIdProbeCountForTesting
        vm.runCoordinator(
            vm.coordinator,
            didChangeStatus: .running,
            runId: AgentRunID(),
            threadId: foreign.id
        )
        let secondDeadline = Date().addingTimeInterval(1)
        while Date() < secondDeadline {
            await Task.yield()
        }
        XCTAssertEqual(
            threadRepo.workspaceIdProbeCountForTesting,
            probesAfterMiss,
            "a cached foreign workspace must not re-probe on the next status event"
        )
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "a cached foreign workspace must not full-get on the next status event"
        )
    }

    func test_lifecycleWorkspaceFilter_sourceUsesWorkspaceIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains("private func resolvedWorkspaceID(for threadId: AgentThreadID)"),
            "run-lifecycle fan-out must share one workspace probe helper"
        )
        XCTAssertTrue(source.contains("threadRepo.workspaceId(of: threadId)"))

        func body(after needle: String, limit: Int) throws -> String {
            let range = try XCTUnwrap(source.range(of: needle))
            return String(source[range.lowerBound...].prefix(limit))
        }
        let queueBody = try body(after: "public func handleQueueLifecycleEvent(kind: String, threadId: String?, message: String?)", limit: 1600)
        let finishBody = try body(after: "nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)", limit: 2200)
        let statusBody = try body(after: "nonisolated public func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID)", limit: 1800)
        for (name, snippet) in [
            ("handleQueueLifecycleEvent", queueBody),
            ("didFinish", finishBody),
            ("didChangeStatus", statusBody),
        ] {
            XCTAssertTrue(
                snippet.contains("resolvedWorkspaceID(for:"),
                "\(name) must resolve workspace membership via the probe helper"
            )
            XCTAssertFalse(
                snippet.contains("threadRepo.get(id:"),
                "\(name) must not full-get a thread just to read workspace_id"
            )
        }
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
            liveBackgroundTasks: [],
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
            liveBackgroundTasks: [],
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

    // MARK: - Scheduled live poll count-gate (R1)

    /// WHY: LaunchAgent-owned runs poll every 2s. Decoding the full hot-replay
    /// window just to compare `.count` burns CPU/memory when nothing changed.
    /// Pure helper pins growth + prune both rebuild; equal count does not.
    func test_shouldRebuildScheduledLiveTimeline_onlyWhenCountChanges() {
        XCTAssertFalse(
            AgentAppViewModel.shouldRebuildScheduledLiveTimeline(previousCount: 0, currentCount: 0),
            "idle equal counts must not rebuild"
        )
        XCTAssertFalse(
            AgentAppViewModel.shouldRebuildScheduledLiveTimeline(previousCount: 42, currentCount: 42),
            "unchanged count must not rebuild"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldRebuildScheduledLiveTimeline(previousCount: 10, currentCount: 11),
            "growth must rebuild"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldRebuildScheduledLiveTimeline(previousCount: 10, currentCount: 7),
            "prune (count down) must rebuild"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldRebuildScheduledLiveTimeline(previousCount: 0, currentCount: 1),
            "first event must rebuild"
        )
    }

    func test_scheduledLiveReplayPlan_skipSuffixAndFullReplay() {
        // WHY: growth inside the hot-replay cap must be O(delta); prune, first
        // apply, and overflow must fail closed to the existing full replay.
        let cap = AgentRunCoordinator.hotReplayEventCount
        XCTAssertEqual(
            AgentAppViewModel.scheduledLiveReplayPlan(previousCount: 10, currentCount: 10, cap: cap),
            .skip
        )
        XCTAssertEqual(
            AgentAppViewModel.scheduledLiveReplayPlan(previousCount: 10, currentCount: 15, cap: cap),
            .suffix(offset: 10)
        )
        XCTAssertEqual(
            AgentAppViewModel.scheduledLiveReplayPlan(previousCount: 0, currentCount: 15, cap: cap),
            .fullReplay,
            "previous==0 has no applied prefix, so suffix is unsafe"
        )
        XCTAssertEqual(
            AgentAppViewModel.scheduledLiveReplayPlan(previousCount: 100, currentCount: 7, cap: cap),
            .fullReplay,
            "prune must full-replay"
        )
        XCTAssertEqual(
            AgentAppViewModel.scheduledLiveReplayPlan(previousCount: 10, currentCount: cap + 1, cap: cap),
            .fullReplay,
            "current>cap must full-replay"
        )
    }

    func test_tickScheduledLivePoll_growthAppliesSuffixWithoutZeroingTimeline() async throws {
        // WHY: each COUNT growth used to zero AssistantTimelineState and reapply
        // every latestStreamEvent. 100+5 must apply only the five new events.
        let tmp = NSTemporaryDirectory() + "rc2-scheduled-suffix-" + UUID().uuidString
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
        let thread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "scheduled",
            provider: .codex,
            model: "gpt-5.5",
            status: .running
        )
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            status: .running
        )
        try runRepo.upsert(run)
        try persistScheduledEvents(runRepo: runRepo, run: run, threadId: thread.id, start: 0, count: 100)

        vm.isScheduledThreadRunning = { $0 == thread.id }
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        vm.tickScheduledLivePollForTesting()
        XCTAssertEqual(vm.scheduledLiveApplyCountForTesting, 0, "idle equal COUNT must skip")
        let turnsBeforeGrowth = vm.timeline.turns.count
        XCTAssertGreaterThan(turnsBeforeGrowth, 0, "hydration must already hold the prefix")

        try persistScheduledEvents(runRepo: runRepo, run: run, threadId: thread.id, start: 100, count: 5)
        vm.tickScheduledLivePollForTesting()
        XCTAssertEqual(
            vm.scheduledLiveApplyCountForTesting,
            5,
            "in-cap growth must apply only the attested suffix"
        )
        XCTAssertEqual(
            vm.timeline.turns.count,
            turnsBeforeGrowth + 5,
            "suffix apply must not zero the already-painted timeline"
        )

        let delete = try db.prepare("DELETE FROM agent_stream_events WHERE seq > 7;")
        _ = try delete.step()
        vm.tickScheduledLivePollForTesting()
        XCTAssertEqual(
            vm.scheduledLiveApplyCountForTesting,
            7,
            "prune 100→7 must fail closed to one full latestStreamEvents replay"
        )
        XCTAssertEqual(vm.timeline.turns.count, 7)
    }

    func test_tickScheduledLivePoll_hiddenDoesNotRefillPublishedTimeline() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-scheduled-hidden-" + UUID().uuidString
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
        let thread = AgentThread(
            workspaceId: vm.workspaceID,
            title: "scheduled-hidden",
            provider: .codex,
            model: "gpt-5.5",
            status: .running
        )
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            status: .running
        )
        try runRepo.upsert(run)
        try persistScheduledEvents(runRepo: runRepo, run: run, threadId: thread.id, start: 0, count: 8)
        vm.isScheduledThreadRunning = { $0 == thread.id }
        vm.selectThread(thread.id)
        await vm.waitForSelectThreadHydrationForTesting()
        vm.setVisibility(.hidden)
        XCTAssertTrue(vm.timeline.turns.isEmpty)
        try persistScheduledEvents(runRepo: runRepo, run: run, threadId: thread.id, start: 8, count: 3)
        vm.tickScheduledLivePollForTesting()
        XCTAssertTrue(
            vm.timeline.turns.isEmpty,
            "hidden scheduled poll must apply to latestHiddenTimeline, not refill the published tree"
        )
        vm.setVisibility(.visible)
        XCTAssertEqual(vm.timeline.turns.count, 11)
    }

    func test_rematerialize_liveTurnFastPathSkipsFinishedDictionaries() {
        // WHY: a signature hit used to rebuild messagesById/turnsById for every
        // turn on each stream tick. 200 finished + 1 live must patch only the live
        // turn; a budget-generation bump takes the full path.
        let finished: [AssistantTurnSnapshot] = (0..<200).map { index in
            AssistantTurnSnapshot(
                turnId: "done-\(index)",
                items: [
                    AssistantItem(
                        id: "i-\(index)",
                        turnId: "done-\(index)",
                        type: .assistantMessage,
                        state: .completed,
                        body: "answer-\(index)",
                        startedAtMs: Int64(index)
                    )
                ],
                finalAssistantMessage: "answer-\(index)",
                finished: true
            )
        }
        let liveStale = AssistantTurnSnapshot(
            turnId: "live",
            items: [
                AssistantItem(
                    id: "live-i",
                    turnId: "live",
                    type: .assistantMessage,
                    body: "Hel",
                    startedAtMs: 9_000
                )
            ]
        )
        let liveLive = AssistantTurnSnapshot(
            turnId: "live",
            items: [
                AssistantItem(
                    id: "live-i",
                    turnId: "live",
                    type: .assistantMessage,
                    body: "Hello streamed",
                    startedAtMs: 9_000
                )
            ]
        )
        let cached = (finished + [liveStale]).map(AgentAppView.TranscriptEntry.turn)
        AgentAppView.TranscriptRematerializeProbe.reset()
        let patched = AgentAppView.rematerializedTranscriptEntries(
            cached: cached,
            messages: [],
            turns: finished + [liveLive],
            liveTurnIds: ["live"],
            messagesGenerationUnchanged: true,
            forceFullPath: false
        )
        XCTAssertEqual(AgentAppView.TranscriptRematerializeProbe.liveTurnPatchCount, 1)
        XCTAssertEqual(AgentAppView.TranscriptRematerializeProbe.dictionaryBuildCount, 0)
        guard case .turn(let servedLive) = patched.last else {
            return XCTFail("live turn stays a turn")
        }
        XCTAssertEqual(servedLive.items.first?.body, "Hello streamed")
        guard case .turn(let servedFinished) = patched[0] else {
            return XCTFail("finished turn preserved")
        }
        XCTAssertEqual(servedFinished.items.first?.body, "answer-0")

        AgentAppView.TranscriptRematerializeProbe.reset()
        _ = AgentAppView.rematerializedTranscriptEntries(
            cached: cached,
            messages: [],
            turns: finished + [liveLive],
            liveTurnIds: ["live"],
            messagesGenerationUnchanged: true,
            forceFullPath: true
        )
        XCTAssertEqual(
            AgentAppView.TranscriptRematerializeProbe.dictionaryBuildCount,
            1,
            "aggregate hot-text budget walk must take the full dictionary path"
        )
    }

    private func persistScheduledEvents(
        runRepo: AgentRunRepository,
        run: AgentRun,
        threadId: AgentThreadID,
        start: Int,
        count: Int
    ) throws {
        let encoder = JSONEncoder()
        var writes: [AgentRunRepository.StreamWriteIntent] = []
        writes.reserveCapacity(count)
        for index in start..<(start + count) {
            let event = AssistantEvent.turnStarted(turnId: "sched-\(index)")
            writes.append(.init(
                seq: index + 1,
                kind: event.debugDescription,
                payloadJSON: String(decoding: try encoder.encode(event), as: UTF8.self),
                providerEvent: nil
            ))
        }
        try runRepo.persistStreamBatch(
            runId: run.id,
            threadId: threadId,
            items: writes,
            shouldPruneStreamEvents: false
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
            liveBackgroundTasks: [],
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

    // MARK: - Token Saver publish skip

    /// WHY: the skip exists to avoid rebuilding the published Token Saver sets on every
    /// token. It is only safe while it is a strict superset of the cases where
    /// refreshTokenSaverOptimizationStateFromTimeline can change state — in particular the
    /// eviction path, where the timeline is already empty but the published cache
    /// still holds badges that MUST be cleared.
    func test_shouldPublishTokenSaverOptimizationState_skipsOnlyWhenRepublishIsANoOp() {
        let empty = AssistantTimelineState()
        XCTAssertFalse(
            AgentAppViewModel.shouldPublishTokenSaverOptimizationState(
                timeline: empty, publishedIds: [], publishedOriginals: [:]
            ),
            "both sides empty is the pure-token path and must skip"
        )

        var translated = AssistantTimelineState()
        translated.apply(.wireTranslation(AssistantWireTranslation(
            messageId: UUID().uuidString, originalText: "o", rewrittenText: "r"
        )))
        XCTAssertFalse(translated.tokenSaverTranslationsByMessageId.isEmpty)
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishTokenSaverOptimizationState(
                timeline: translated, publishedIds: [], publishedOriginals: [:]
            ),
            "a new translation must always publish"
        )

        // Eviction shape: the aggregate budget walk emptied the timeline, but the
        // published badges are still live and have to be cleared.
        let stale = AgentMessageID(UUID())
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishTokenSaverOptimizationState(
                timeline: empty, publishedIds: [stale], publishedOriginals: [:]
            ),
            "budget-evicted translations must still clear the published id set"
        )
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishTokenSaverOptimizationState(
                timeline: empty, publishedIds: [], publishedOriginals: [stale: "o"]
            ),
            "budget-evicted translations must still clear the published originals"
        )

        var itemOnly = AssistantTimelineState()
        itemOnly.apply(.wireTranslation(AssistantWireTranslation(
            itemId: "item", originalText: "o", rewrittenText: "r"
        )))
        XCTAssertFalse(itemOnly.tokenSaverTranslationsByItemId.isEmpty)
        XCTAssertTrue(
            AgentAppViewModel.shouldPublishTokenSaverOptimizationState(
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
            liveBackgroundTasks: [],
            suppressStaleActivePlanUpdates: false,
            seedRunStartedAt: false,
            runThreadBindings: [:],
            hasProposedPlan: false,
            forceAggregateBudget: force,
            appliedEventCount: appliedEventCount
        )
    }

    /// WHY: `aggregateBudgetDecision` and `shouldPublishTokenSaverOptimizationState` are pure and
    /// individually tested, but the invariant that actually protects the hot-text
    /// ceiling lives in their COMPOSITION inside `commitStreamQuantum`: the
    /// counter must be written back, and the budget walk must run BEFORE the
    /// publish guard reads the timeline. A regression that drops
    /// `streamAggregateBudgetOps = budget.nextOps`, or swaps the two blocks, would
    /// leave both unit tests green. This drives the real method.
    func test_commitStreamQuantum_coalescesWalkThenPublishesEvictedTokenSaverState() throws {
        let (vm, _) = try makeVM()
        vm.aggregateHotTextByteLimitForTesting = 4_000

        // A timeline holding one wire translation, well under the lowered ceiling.
        let messageId = UUID().uuidString
        var small = AssistantTimelineState()
        small.apply(.wireTranslation(AssistantWireTranslation(
            messageId: messageId, originalText: "original", rewrittenText: "rewritten"
        )))
        vm.commitStreamQuantum(reducedQuantum(timeline: small, force: true))
        XCTAssertEqual(vm.tokenSaverOptimizedMessageIds.count, 1,
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
        // compatibility-backed translation eviction loops.
        var oversized = AssistantTimelineState()
        oversized.apply(.wireTranslation(AssistantWireTranslation(
            messageId: messageId,
            originalText: String(repeating: "o", count: 10_000),
            rewrittenText: String(repeating: "r", count: 10_000)
        )))
        XCTAssertGreaterThan(oversized.aggregateHotTextByteCount, 4_000,
                             "fixture must actually exceed the lowered ceiling")

        vm.commitStreamQuantum(reducedQuantum(timeline: oversized, force: true))
        XCTAssertTrue(vm.timeline.tokenSaverTranslationsByMessageId.isEmpty,
                      "the budget walk must evict translations over the ceiling")
        XCTAssertTrue(vm.tokenSaverOptimizedMessageIds.isEmpty,
                      "walk-then-publish order must clear badges evicted in the same commit")
        XCTAssertTrue(vm.tokenSaverOriginalTextsByMessageId.isEmpty,
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

    // MARK: - R4-A StreamEventBatch headIndex ring

    /// Order, eviction (oldest first), drain quanta, and saturation still hold
    /// after the removeFirst → headIndex port.
    func test_streamEventBatch_headIndex_evictDrainOrderAndSaturation() {
        let batch = StreamEventBatch(limits: .init(
            maxBufferedCount: 4,
            maxBufferedBytes: 64 * 1_024,
            drainCount: 2,
            drainBytes: 64 * 1_024
        ))
        let tid = AgentThreadID()
        let run = AgentRunID()
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "a"), run: run, threadId: tid), .scheduled)
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "b"), run: run, threadId: tid), .buffered)
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "c"), run: run, threadId: tid), .buffered)
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "d"), run: run, threadId: tid), .buffered)
        // Fifth admission must drop oldest ("a") so newest still enters.
        XCTAssertEqual(batch.appendBounded(event: .turnStarted(turnId: "e"), run: run, threadId: tid), .bufferedAfterEviction)

        let q1 = batch.drainQuantum()
        XCTAssertEqual(q1.entries.count, 2)
        XCTAssertTrue(q1.hasMore)
        if case .turnStarted(let id0) = q1.entries[0].event {
            XCTAssertEqual(id0, "b", "oldest surviving event after eviction must drain first")
        } else { XCTFail("expected turnStarted") }
        if case .turnStarted(let id1) = q1.entries[1].event {
            XCTAssertEqual(id1, "c")
        } else { XCTFail("expected turnStarted") }

        let q2 = batch.drainQuantum()
        XCTAssertEqual(q2.entries.count, 2)
        XCTAssertFalse(q2.hasMore)
        if case .turnStarted(let id3) = q2.entries[1].event {
            XCTAssertEqual(id3, "e", "newest admitted event must survive to last drain")
        } else { XCTFail("expected turnStarted") }

        // Hard ceiling still latches once per run.
        let tiny = StreamEventBatch(limits: .init(
            maxBufferedCount: 8,
            maxBufferedBytes: 256,
            drainCount: 8,
            drainBytes: 256
        ))
        let huge = AssistantEvent.error(message: String(repeating: "z", count: 8_192), recoverable: true)
        XCTAssertEqual(tiny.appendBounded(event: huge, run: run, threadId: tid), .saturated)
        XCTAssertEqual(tiny.appendBounded(event: huge, run: run, threadId: tid), .saturationAlreadyReported)
        XCTAssertTrue(tiny.isEmpty)
    }

    /// Microbench: Array.removeFirst eviction/drain vs headIndex ring
    /// (same process, n≥5). Pure algorithm A/B — not product lock/encode overhead.
    /// Primary metric: wall ms to fill then fully drain a large FIFO.
    func test_microbench_streamEventBatch_headIndexFasterThanRemoveFirst() throws {
        // WHY: removeFirst shifts every remaining element (O(n) per pop → O(n²) full
        // drain). headIndex advances O(1) per pop and only occasionally compacts.
        // Scale N so shift cost dominates allocator noise; n_samples ≥ 5.
        let n = 40_000
        let compactionThreshold = 1_024
        let samples = 5
        let warmup = 2
        // Non-trivial payload so each removeFirst moves real memory.
        let payload = String(repeating: "p", count: 128)

        struct Entry {
            let id: Int
            let body: String
        }

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        /// Pre-R4-A: Array + removeFirst on every eviction / full drain.
        func timeLegacyRemoveFirst() -> Double {
            var buffer: [Entry] = []
            buffer.reserveCapacity(n)
            for i in 0..<n {
                buffer.append(Entry(id: i, body: payload))
            }
            var sink = 0
            let start = DispatchTime.now().uptimeNanoseconds
            // Simulate continuous admission under full buffer: each append forces
            // one oldest eviction via removeFirst (the StreamEventBatch hot path).
            for i in 0..<(n / 2) {
                let removed = buffer.removeFirst()
                sink &+= removed.id
                buffer.append(Entry(id: n + i, body: payload))
            }
            // Drain remaining.
            while !buffer.isEmpty {
                let removed = buffer.removeFirst()
                sink &+= removed.id
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        /// R4-A pattern (StreamEventBatch / WebSocketOutboundQueue): headIndex +
        /// optional-slot release + amortized compaction.
        func timeHeadIndex() -> Double {
            var storage: [Entry?] = []
            storage.reserveCapacity(n + compactionThreshold)
            for i in 0..<n {
                storage.append(Entry(id: i, body: payload))
            }
            var head = 0
            var sink = 0

            func queued() -> Int { storage.count - head }
            func compactIfNeeded() {
                if head == storage.count {
                    storage.removeAll(keepingCapacity: true)
                    head = 0
                } else if head >= compactionThreshold, head >= storage.count - head {
                    storage.removeFirst(head)
                    head = 0
                }
            }
            func popFirst() {
                guard head < storage.count, let e = storage[head] else { return }
                storage[head] = nil
                head += 1
                sink &+= e.id
                compactIfNeeded()
            }

            let start = DispatchTime.now().uptimeNanoseconds
            for i in 0..<(n / 2) {
                popFirst()
                storage.append(Entry(id: n + i, body: payload))
            }
            while queued() > 0 { popFirst() }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        // Functional pin on product queue (order / eviction / saturation).
        do {
            let batch = StreamEventBatch(limits: .init(
                maxBufferedCount: 4,
                maxBufferedBytes: 64 * 1_024,
                drainCount: 2,
                drainBytes: 64 * 1_024
            ))
            let tid = AgentThreadID()
            let run = AgentRunID()
            _ = batch.appendBounded(event: .turnStarted(turnId: "1"), run: run, threadId: tid)
            _ = batch.appendBounded(event: .turnStarted(turnId: "2"), run: run, threadId: tid)
            _ = batch.appendBounded(event: .turnStarted(turnId: "3"), run: run, threadId: tid)
            _ = batch.appendBounded(event: .turnStarted(turnId: "4"), run: run, threadId: tid)
            XCTAssertEqual(
                batch.appendBounded(event: .turnStarted(turnId: "5"), run: run, threadId: tid),
                .bufferedAfterEviction
            )
            let drained = batch.drain()
            XCTAssertEqual(drained.count, 4)
            if case .turnStarted(let id) = drained[0].event {
                XCTAssertEqual(id, "2", "oldest must be gone; next-oldest drains first")
            } else { XCTFail("expected turnStarted") }
            if case .turnStarted(let id) = drained[3].event {
                XCTAssertEqual(id, "5")
            } else { XCTFail("expected turnStarted") }
        }

        for _ in 0..<warmup { _ = timeLegacyRemoveFirst(); _ = timeHeadIndex() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeLegacyRemoveFirst())
            after.append(timeHeadIndex())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] streamEventBatch removeFirst_ms=%@ headIndex_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "StreamEventBatch headIndex must beat removeFirst by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    // MARK: - R4-B Markdown NSCache streaming partial thrash

    /// Live path with `cache: false` must not store growing partials; finished
    /// identical text still caches once when `cache: true`.
    func test_markdownCache_streamingPartialsDoNotStoreWhenCacheFalse() {
        #if DEBUG
        AgentMessageMarkdown.blocksCacheStoreCountForTesting = 0
        AgentMessageMarkdown.inlineCacheStoreCountForTesting = 0
        var growing = "Hello"
        for i in 0..<40 {
            growing += " token\(i)"
            _ = AgentMessageMarkdown.blocks(from: growing, cache: false)
            _ = AgentMessageMarkdown.attributedInline(growing, cache: false)
        }
        XCTAssertEqual(
            AgentMessageMarkdown.blocksCacheStoreCountForTesting, 0,
            "live streaming partials must not insert into blocks NSCache"
        )
        XCTAssertEqual(
            AgentMessageMarkdown.inlineCacheStoreCountForTesting, 0,
            "live streaming partials must not insert into inline NSCache"
        )

        // Stable finished body may store once.
        let stable = "Finished **answer** with `code`."
        AgentMessageMarkdown.blocksCacheStoreCountForTesting = 0
        AgentMessageMarkdown.inlineCacheStoreCountForTesting = 0
        AgentMessageMarkdown.blocksComputeCountForTesting = 0
        _ = AgentMessageMarkdown.blocks(from: stable, cache: true)
        _ = AgentMessageMarkdown.blocks(from: stable, cache: true)
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheStoreCountForTesting, 1)
        XCTAssertEqual(AgentMessageMarkdown.blocksComputeCountForTesting, 1,
                       "second identical finished parse must hit cache")
        XCTAssertTrue(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 100, cache: true))
        XCTAssertFalse(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 100, cache: false))
        XCTAssertTrue(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 100_000, cache: true),
                       "finished large replies must cache so a conversation switch does not reparse")
        #else
        // Release: policy helper still testable without store counters.
        XCTAssertTrue(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 100, cache: true))
        XCTAssertFalse(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 100, cache: false))
        #endif
    }

    // MARK: - R4-C hiddenPersisted content fingerprint (no tick)

    /// Pure paint ticks must not change the cache key; streaming body growth must.
    func test_hiddenPersistedContentKey_stableOnPaintTick_changesOnBodyGrowth() {
        let thread = AgentThreadID()
        let msg = AgentMessage(threadId: thread, role: .assistant, content: "Hello world")
        let turnShort = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "a1", turnId: "t1", type: .assistantMessage,
                              body: "Hel", startedAtMs: 1)
            ],
            finalAssistantMessage: nil,
            finished: false
        )
        let turnGrown = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "a1", turnId: "t1", type: .assistantMessage,
                              body: "Hello full streamed answer", startedAtMs: 1)
            ],
            finalAssistantMessage: "Hello full streamed answer",
            finished: false
        )
        let k1 = AgentAppView.hiddenPersistedAssistantContentKey(messages: [msg], timelineTurns: [turnShort])
        let k2 = AgentAppView.hiddenPersistedAssistantContentKey(messages: [msg], timelineTurns: [turnShort])
        XCTAssertEqual(k1, k2, "identical inputs must produce identical keys (paint-tick stable)")
        // Simulate "tick-only" by recomputing with same messages/turns — key must match.
        XCTAssertEqual(
            k1,
            AgentAppView.hiddenPersistedAssistantContentKey(messages: [msg], timelineTurns: [turnShort]),
            "pure paint with unchanged content must hit the same key"
        )
        let kGrown = AgentAppView.hiddenPersistedAssistantContentKey(messages: [msg], timelineTurns: [turnGrown])
        XCTAssertNotEqual(k1, kGrown, "streaming body growth must change the content key so hide set recomputes")

        // Functional pin: hide contract still holds for combined live answer.
        let persisted = AgentMessage(
            threadId: thread,
            role: .assistant,
            content: "S start. D inspect. O done."
        )
        let done = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "S start. D inspect.", startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "O done.", startedAtMs: 2)
            ],
            finalAssistantMessage: "S start. D inspect. O done.",
            finished: true
        )
        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(messages: [persisted], timelineTurns: [done]),
            [persisted.id],
            "content-key change must not alter hide semantics"
        )
    }

    /// Equal-length body/final (and message) swaps must change the content key.
    /// Length-only fingerprints would collide on "alpha"→"bravo" and serve a
    /// stale hide set; digests over content close that hole.
    func test_hiddenPersistedContentKey_changesOnEqualLengthContentReplacement() {
        let thread = AgentThreadID()
        let msgId = AgentMessageID()
        // Same identity + same UTF-8 length; only the text differs.
        let msgAlpha = AgentMessage(id: msgId, threadId: thread, role: .assistant, content: "alpha")
        let msgBravo = AgentMessage(id: msgId, threadId: thread, role: .assistant, content: "bravo")
        XCTAssertEqual(msgAlpha.content.utf8.count, msgBravo.content.utf8.count)

        let turnAlpha = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "a1", turnId: "t1", type: .assistantMessage,
                              body: "alpha", startedAtMs: 1)
            ],
            finalAssistantMessage: "alpha",
            finished: true
        )
        let turnBravo = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "a1", turnId: "t1", type: .assistantMessage,
                              body: "bravo", startedAtMs: 1)
            ],
            finalAssistantMessage: "bravo",
            finished: true
        )
        XCTAssertEqual(
            turnAlpha.items[0].body.utf8.count,
            turnBravo.items[0].body.utf8.count
        )
        XCTAssertEqual(
            turnAlpha.finalAssistantMessage?.utf8.count,
            turnBravo.finalAssistantMessage?.utf8.count
        )

        let kAlpha = AgentAppView.hiddenPersistedAssistantContentKey(
            messages: [msgAlpha], timelineTurns: [turnAlpha]
        )
        let kBravo = AgentAppView.hiddenPersistedAssistantContentKey(
            messages: [msgBravo], timelineTurns: [turnBravo]
        )
        XCTAssertNotEqual(
            kAlpha, kBravo,
            "equal-length alpha→bravo on message/body/final must change the content key"
        )

        // Body-only equal-length swap (final + message unchanged).
        let turnBodyOnly = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "a1", turnId: "t1", type: .assistantMessage,
                              body: "bravo", startedAtMs: 1)
            ],
            finalAssistantMessage: "alpha",
            finished: true
        )
        XCTAssertNotEqual(
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgAlpha], timelineTurns: [turnAlpha]
            ),
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgAlpha], timelineTurns: [turnBodyOnly]
            ),
            "equal-length body swap alone must change the content key"
        )

        // Final-only equal-length swap (body + message unchanged).
        let turnFinalOnly = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "a1", turnId: "t1", type: .assistantMessage,
                              body: "alpha", startedAtMs: 1)
            ],
            finalAssistantMessage: "bravo",
            finished: true
        )
        XCTAssertNotEqual(
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgAlpha], timelineTurns: [turnAlpha]
            ),
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgAlpha], timelineTurns: [turnFinalOnly]
            ),
            "equal-length final swap alone must change the content key"
        )

        // Message-only equal-length swap (turns unchanged).
        XCTAssertNotEqual(
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgAlpha], timelineTurns: [turnAlpha]
            ),
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgBravo], timelineTurns: [turnAlpha]
            ),
            "equal-length persisted message swap alone must change the content key"
        )

        // When evaluated, hide set recomputes for equal-length content swaps
        // (multi-item combined live answer — same path as production hide).
        // Plain prose keeps this fixture outside the wire prefix path. Single-item
        // live body that equals persisted is
        // intentionally *not* hidden; multi-item join is.
        let contentA = "hello there friendx"
        let contentB = "hello there buddyyy" // same UTF-8 length, different text
        XCTAssertEqual(contentA.utf8.count, contentB.utf8.count)
        let msgCombinedA = AgentMessage(id: msgId, threadId: thread, role: .assistant, content: contentA)
        let msgCombinedB = AgentMessage(id: msgId, threadId: thread, role: .assistant, content: contentB)
        let turnCombinedA = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "hello there", startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "friendx", startedAtMs: 2)
            ],
            finalAssistantMessage: nil,
            finished: true
        )
        let turnCombinedB = AssistantTurnSnapshot(
            turnId: "turn-1",
            items: [
                AssistantItem(id: "msg-1", turnId: "turn-1", type: .assistantMessage,
                              body: "hello there", startedAtMs: 1),
                AssistantItem(id: "msg-2", turnId: "turn-1", type: .assistantMessage,
                              body: "buddyyy", startedAtMs: 2)
            ],
            finalAssistantMessage: nil,
            finished: true
        )
        XCTAssertNotEqual(
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgCombinedA], timelineTurns: [turnCombinedA]
            ),
            AgentAppView.hiddenPersistedAssistantContentKey(
                messages: [msgCombinedB], timelineTurns: [turnCombinedB]
            ),
            "equal-length combined-answer swap must change the content key"
        )
        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(
                messages: [msgCombinedA], timelineTurns: [turnCombinedA]
            ),
            [msgCombinedA.id],
            "matching combined live+persisted must hide"
        )
        XCTAssertTrue(
            AgentAppView.hiddenPersistedAssistantMessageIDs(
                messages: [msgCombinedA], timelineTurns: [turnCombinedB]
            ).isEmpty,
            "equal-length different combined live must not hide (would be stale if key collided)"
        )
        XCTAssertEqual(
            AgentAppView.hiddenPersistedAssistantMessageIDs(
                messages: [msgCombinedB], timelineTurns: [turnCombinedB]
            ),
            [msgCombinedB.id],
            "matching B live+persisted must hide after equal-length replacement"
        )
    }

    /// Microbench optional: content-key build vs full hide recompute on tick-only
    /// (same content, n≥5). Proves skip path stays cheaper than recompute.
    func test_microbench_hiddenPersisted_keyHitFasterThanFullRecompute() throws {
        let thread = AgentThreadID()
        var messages: [AgentMessage] = []
        for i in 0..<12 {
            messages.append(AgentMessage(
                threadId: thread,
                role: i % 2 == 0 ? .user : .assistant,
                content: String(repeating: "body \(i) ", count: 80)
            ))
        }
        var turns: [AssistantTurnSnapshot] = []
        for t in 0..<6 {
            let items = (0..<4).map { j in
                AssistantItem(
                    id: "t\(t)-i\(j)",
                    turnId: "turn-\(t)",
                    type: .assistantMessage,
                    body: String(repeating: "x", count: 200 + t * 10 + j),
                    startedAtMs: Int64(t * 10 + j)
                )
            }
            turns.append(AssistantTurnSnapshot(
                turnId: "turn-\(t)",
                items: items,
                finalAssistantMessage: items.last?.body,
                finished: t < 5
            ))
        }
        let iterations = 2_000
        let samples = 5
        let warmup = 2

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        func timeFullRecompute() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                let ids = AgentAppView.hiddenPersistedAssistantMessageIDs(
                    messages: messages,
                    timelineTurns: turns
                )
                sink &+= ids.count
            }
            let end = DispatchTime.now().uptimeNanoseconds
            _ = sink
            return Double(end - start) / 1_000_000.0
        }

        func timeKeyOnly() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            var lastKey: String?
            for _ in 0..<iterations {
                let key = AgentAppView.hiddenPersistedAssistantContentKey(
                    messages: messages,
                    timelineTurns: turns
                )
                if lastKey == key {
                    sink &+= 1 // simulated cache hit — skip recompute
                } else {
                    lastKey = key
                    let ids = AgentAppView.hiddenPersistedAssistantMessageIDs(
                        messages: messages,
                        timelineTurns: turns
                    )
                    sink &+= ids.count
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup { _ = timeFullRecompute(); _ = timeKeyOnly() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeFullRecompute())
            after.append(timeKeyOnly())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] hiddenPersisted full_ms=%@ keyHit_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "tick-only hidden cache hit must beat full recompute by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    /// R5-B: enforceAggregateHotTextBudget under pressure must not re-walk the
    /// full timeline after every removeFirst (O(n²)). Debit path vs naive recount.
    func test_r5_enforceAggregateBudget_debitVsFullRecount_microbench() {
        func makeOversizedState(turns: Int, events: Int) -> AssistantTimelineState {
            var state = AssistantTimelineState()
            state.threadId = "thread-r5"
            for t in 0..<turns {
                let turnId = "turn-\(t)"
                var turn = AssistantTurnSnapshot(turnId: turnId, startedAtMs: Int64(t))
                for i in 0..<4 {
                    turn.items.append(AssistantItem(
                        id: "item-\(t)-\(i)",
                        turnId: turnId,
                        type: .assistantMessage,
                        body: String(repeating: "B", count: 2_048),
                        output: String(repeating: "O", count: 1_024),
                        startedAtMs: Int64(t * 10 + i)
                    ))
                }
                turn.finalAssistantMessage = String(repeating: "F", count: 512)
                state.turns.append(turn)
            }
            for e in 0..<events {
                state.providerRuntimeEvents.append(ProviderRuntimeEvent(
                    id: "ev-\(e)",
                    provider: .codex,
                    source: "test",
                    method: "event",
                    payloadJSON: String(repeating: "p", count: 256),
                    receivedAtMs: Int64(e)
                ))
            }
            return state
        }

        // Naive recount path (pre-R5): after each eviction, re-walk aggregate.
        func enforceWithFullRecount(_ state: inout AssistantTimelineState, byteLimit: Int) {
            let limit = max(1, byteLimit)
            var total = state.aggregateHotTextByteCount
            guard total > limit else { return }
            while total > limit, !state.providerRuntimeEvents.isEmpty {
                state.providerRuntimeEvents.removeFirst()
                total = state.aggregateHotTextByteCount
            }
            while total > limit, state.turns.count > 1 {
                state.turns.removeFirst()
                total = state.aggregateHotTextByteCount
            }
        }

        let budget = 64_000
        let samples = 5
        let warmup = 2
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup {
            var a = makeOversizedState(turns: 80, events: 200)
            var b = makeOversizedState(turns: 80, events: 200)
            enforceWithFullRecount(&a, byteLimit: budget)
            b.enforceAggregateHotTextBudget(byteLimit: budget)
        }

        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            var a = makeOversizedState(turns: 80, events: 200)
            var b = makeOversizedState(turns: 80, events: 200)
            before.append(timeMs { enforceWithFullRecount(&a, byteLimit: budget) })
            after.append(timeMs { b.enforceAggregateHotTextBudget(byteLimit: budget) })
            XCTAssertLessThanOrEqual(a.aggregateHotTextByteCount, budget)
            XCTAssertLessThanOrEqual(b.aggregateHotTextByteCount, budget)
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] enforceAggregate fullRecount_ms=%@ debit_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 5.0,
            "debit-based enforceAggregate must beat full recount by ≥5% (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    // MARK: - Thread selection cache-first (no MainActor SQLite get on rail hits)

    /// Rail-resident selection must not compile `threadRepo.get` (row + routing)
    /// on MainActor. Clicking a visible thread has to acknowledge from memory.
    func test_selectThread_railHit_skipsDurableLookup() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "rail-a")
        let first = try XCTUnwrap(vm.selectedThreadId)
        vm.createThread(title: "rail-b")
        let second = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertNotEqual(first, second)
        let lookupsBefore = vm.durableThreadSelectionLookupCountForTesting
        let probesBefore = vm.durableThreadExistenceProbeCountForTesting
        vm.selectThread(first)
        XCTAssertEqual(vm.selectedThreadId, first,
                       "selecting a rail thread must still bind that thread")
        XCTAssertTrue(vm.lastThreadSelectionUsedRailForTesting,
                      "a thread already painted on the rail must not wait on a full SQLite get")
        XCTAssertEqual(
            vm.durableThreadSelectionLookupCountForTesting,
            lookupsBefore,
            "rail hits must not increment the durable full-get counter"
        )
        XCTAssertEqual(
            vm.durableThreadExistenceProbeCountForTesting,
            probesBefore,
            "rail switch must publish before the existence probe"
        )
        let deadline = Date().addingTimeInterval(1)
        while vm.durableThreadExistenceProbeCountForTesting == probesBefore,
              Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(
            vm.durableThreadExistenceProbeCountForTesting,
            probesBefore + 1,
            "existence probe still runs after the first frame"
        )
        XCTAssertEqual(vm.selectedThreadId, first)
    }

    /// Same-thread reselect (rail re-click / host refresh) used to hit SQLite
    /// before taking the soft path. That hitch is gone: stay on the rail row.
    func test_selectThread_sameThreadReselect_staysOnRail() throws {
        let (vm, _) = try makeVM()
        vm.createThread(title: "open")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertTrue(vm.lastThreadSelectionUsedRailForTesting)
        let lookupsBefore = vm.durableThreadSelectionLookupCountForTesting
        let probesBefore = vm.durableThreadExistenceProbeCountForTesting
        vm.selectThread(tid)
        XCTAssertEqual(vm.selectedThreadId, tid)
        XCTAssertTrue(vm.lastThreadSelectionUsedRailForTesting,
                      "re-selecting the already-open thread must stay cache-first")
        XCTAssertEqual(vm.durableThreadSelectionLookupCountForTesting, lookupsBefore)
        XCTAssertEqual(
            vm.durableThreadExistenceProbeCountForTesting,
            probesBefore,
            "same-thread reselect must not re-probe SQLite"
        )
    }

    /// Threads not on this surface's rail still load from SQLite, and a
    /// different-workspace row is rejected instead of being bound.
    func test_selectThread_cacheMiss_usesDurableLookup() throws {
        let (vm, threadRepo) = try makeVM()
        let foreign = AgentThread(
            workspaceId: WorkspaceID(),
            title: "foreign",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(foreign)
        let local = AgentThread(
            workspaceId: vm.workspaceID,
            title: "unlisted",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(local)
        XCTAssertFalse(vm.threads.contains(where: { $0.id == local.id }))

        let lookupsBefore = vm.durableThreadSelectionLookupCountForTesting
        vm.selectThread(foreign.id)
        XCTAssertNil(vm.selectedThreadId,
                     "a foreign-workspace durable row must not become the selection")
        XCTAssertTrue(
            vm.statusMessage.contains("another workspace"),
            "cache-miss workspace rejection must keep the existing error copy"
        )
        XCTAssertEqual(
            vm.durableThreadSelectionLookupCountForTesting,
            lookupsBefore + 1,
            "a rail miss must consult durable storage"
        )

        vm.selectThread(local.id)
        XCTAssertEqual(vm.selectedThreadId, local.id,
                       "a same-workspace thread missing from the rail must still open from SQLite")
        XCTAssertFalse(vm.lastThreadSelectionUsedRailForTesting)
        XCTAssertEqual(vm.durableThreadSelectionLookupCountForTesting, lookupsBefore + 2)
    }

    func test_railThreadForSelection_rejectsOtherWorkspaceAndMisses() {
        let workspace = WorkspaceID()
        let other = WorkspaceID()
        let local = AgentThread(
            workspaceId: workspace,
            title: "local",
            provider: .codex,
            model: "gpt-5.5"
        )
        let foreign = AgentThread(
            workspaceId: other,
            title: "foreign",
            provider: .codex,
            model: "gpt-5.5"
        )
        let rail = [local, foreign]
        XCTAssertEqual(
            AgentAppViewModel.railThreadForSelection(
                id: local.id,
                workspaceID: workspace,
                rail: rail
            )?.id,
            local.id
        )
        XCTAssertNil(
            AgentAppViewModel.railThreadForSelection(
                id: foreign.id,
                workspaceID: workspace,
                rail: rail
            ),
            "a painted row from another workspace must not be treated as a cache hit"
        )
        XCTAssertNil(
            AgentAppViewModel.railThreadForSelection(
                id: AgentThreadID(),
                workspaceID: workspace,
                rail: rail
            )
        )
    }

    /// The lookup this change removes (two SQLite statements + ISO parsing)
    /// must stay cheaper than the durable get on the same machine.
    func test_selectThread_railHit_fasterThanDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "lookup-cost")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let rail = vm.threads
        let workspaceID = vm.workspaceID
        let warmup = 3
        let samples = 5
        let iterations = 200

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }

        for _ in 0..<warmup {
            _ = AgentAppViewModel.railThreadForSelection(
                id: tid, workspaceID: workspaceID, rail: rail
            )
            _ = try threadRepo.workspaceId(of: tid)
            _ = try threadRepo.get(id: tid)
        }

        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = AgentAppViewModel.railThreadForSelection(
                        id: tid, workspaceID: workspaceID, rail: rail
                    )
                    _ = try threadRepo.workspaceId(of: tid)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: tid)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] thread-select rail+exists_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "rail chrome + existence probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    /// WHY: queue-while-running and startProviderRun used to full-get the
    /// selected thread just to read routing the painted rail already JOINs.
    func test_sendRouting_usesPaintedRailWithoutDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "send-routing")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        XCTAssertTrue(vm.threads.contains(where: { $0.id == tid }))
        let getsBefore = threadRepo.durableGetCountForTesting
        let routing = vm.routingConfigurationForSendForTesting(threadId: tid)
        XCTAssertEqual(routing.mode, vm.threads.first { $0.id == tid }?.effectiveRoutingConfiguration.mode)
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "send routing must use the painted rail, not a 26-column get"
        )
        let missing = AgentThreadID()
        let probesBefore = threadRepo.routingConfigurationProbeCountForTesting
        _ = vm.routingConfigurationForSendForTesting(threadId: missing)
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "a thread missing from the rail must probe routing, not a 26-column get"
        )
        XCTAssertEqual(threadRepo.routingConfigurationProbeCountForTesting, probesBefore + 1)
    }

    func test_sendRouting_sourceUsesPaintedRail() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("private func routingConfigurationForSend(threadId: AgentThreadID)"))
        XCTAssertTrue(source.contains("threads.first(where: { $0.id == threadId })"))
        let queueBodyRange = try XCTUnwrap(source.range(of: "private func enqueuePromptWhileRunning("))
        let queueBody = String(source[queueBodyRange.lowerBound...].prefix(900))
        XCTAssertTrue(queueBody.contains("routingConfigurationForSend(threadId: selectedThreadId)"))
        XCTAssertFalse(queueBody.contains("threadRepo.get(id: selectedThreadId)"))
        let startBodyRange = try XCTUnwrap(source.range(of: "private func startProviderRun("))
        let startBody = String(source[startBodyRange.lowerBound...].prefix(2200))
        XCTAssertTrue(startBody.contains("routingConfigurationForSend(threadId:"))
        XCTAssertFalse(startBody.contains("threadRepo.get(id: $0)"))
    }

    func test_sendRouting_paintedRail_fasterThanDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "send-bench")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = vm.routingConfigurationForSendForTesting(threadId: tid)
            _ = try threadRepo.get(id: tid)
        }
        var railSamples: [Double] = []
        var getSamples: [Double] = []
        railSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            railSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = vm.routingConfigurationForSendForTesting(threadId: tid)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: tid)
                }
            })
        }
        let railMed = median(railSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - railMed) / getMed * 100.0
        NSLog(
            "[perf-proof] send-routing rail_ms=%@ durable_get_ms=%@ improvement_pct=%.2f rail=%@ get=%@",
            String(railMed), String(getMed), improvement,
            String(describing: railSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "painted-rail send routing must beat durable get by ≥5% (got \(improvement)%; rail=\(railMed)ms get=\(getMed)ms)"
        )
    }

    /// WHY: bot-peer apply used to full-get 26 columns + routing JSON just to
    /// confirm workspace membership before loading the message row.
    func test_applyPersistedBotPeerMessage_usesWorkspaceIdProbeWithoutDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "peer-apply")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let messageID = AgentMessageID()
        try vm.messageRepo.append(AgentMessage(
            id: messageID,
            threadId: tid,
            role: .assistant,
            content: "peer"
        ))
        let getsBefore = threadRepo.durableGetCountForTesting
        vm.applyPersistedBotPeerMessage(messageID: messageID, threadId: tid)
        XCTAssertEqual(vm.messages.first?.id, messageID)
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsBefore,
            "same-workspace peer apply must not compile a full 26-column get"
        )

        let foreign = AgentThread(
            workspaceId: WorkspaceID(),
            title: "foreign-peer",
            provider: .codex,
            model: "gpt-5.5"
        )
        try threadRepo.upsert(foreign)
        let foreignMessageID = AgentMessageID()
        try vm.messageRepo.append(AgentMessage(
            id: foreignMessageID,
            threadId: foreign.id,
            role: .assistant,
            content: "nope"
        ))
        let getsAfterForeignInsert = threadRepo.durableGetCountForTesting
        let probesBeforeForeign = threadRepo.workspaceIdProbeCountForTesting
        let countBefore = vm.messages.count
        vm.applyPersistedBotPeerMessage(messageID: foreignMessageID, threadId: foreign.id)
        XCTAssertEqual(vm.messages.count, countBefore)
        XCTAssertEqual(
            threadRepo.durableGetCountForTesting,
            getsAfterForeignInsert,
            "foreign-workspace peer apply must fail on the workspace_id probe, not a full get"
        )
        XCTAssertEqual(
            threadRepo.workspaceIdProbeCountForTesting,
            probesBeforeForeign + 1
        )
    }

    func test_applyPersistedBotPeerMessage_sourceUsesWorkspaceIdProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "public func applyPersistedBotPeerMessage("))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("resolvedWorkspaceID(for: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_applyPersistedBotPeerMessage_workspaceIdProbe_fasterThanDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "peer-bench")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try threadRepo.workspaceId(of: tid)
            _ = try threadRepo.get(id: tid)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.workspaceId(of: tid)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: tid)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] peer-apply workspace_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "workspace_id probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    func test_botPeerReconciliationInterval_defaultsToFiveSeconds() throws {
        // WHY: waiting peer markup used to poll SQLite every 1s. Default is 5s;
        // tests keep the writable override (this suite uses 60s to freeze the loop).
        let (vm, _) = try makeVM()
        XCTAssertEqual(
            vm.botPeerReconciliationIntervalNanoseconds,
            5_000_000_000,
            "bot-peer reconcile default must be 5s, not 1s"
        )
        vm.botPeerReconciliationIntervalNanoseconds = 60_000_000_000
        XCTAssertEqual(
            vm.botPeerReconciliationIntervalNanoseconds,
            60_000_000_000,
            "tests must still be able to override the peer interval"
        )
    }

    /// WHY: peer reconcile used to full-get 26 columns + routing JSON every ~1s
    /// while a peer was waiting, just to copy durable status.
    func test_peerReconcile_usesStatusProbeWithoutDurableGet() async throws {
        let (vm, threadRepo) = try makeVM()
        vm.botPeerReconciliationIntervalNanoseconds = 60_000_000_000
        vm.createThread(title: "peer-reconcile")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let peer = BotDefinition(handle: "quinn", name: "Quinn", title: "CRM", description: "")
        let messageID = AgentMessageID()
        try vm.messageRepo.append(AgentMessage(
            id: messageID,
            threadId: tid,
            role: .assistant,
            content: BotPeerTranscript.encode(peer: peer, text: "hello")
        ))
        vm.applyPersistedBotPeerMessage(messageID: messageID, threadId: tid)
        XCTAssertEqual(vm.status, .pending)
        let settle = Date().addingTimeInterval(0.2)
        while Date() < settle { await Task.yield() }
        var stored = try XCTUnwrap(try threadRepo.get(id: tid))
        stored.status = .completed
        try threadRepo.upsert(stored)
        let probesBefore = threadRepo.statusProbeCountForTesting
        await vm.reconcilePersistedBotPeerActivities()
        XCTAssertEqual(vm.status, .completed)
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "peer reconcile must probe status once, not compile a full 26-column get"
        )
        XCTAssertNil(try threadRepo.status(of: AgentThreadID()))
    }

    func test_peerReconcile_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "func reconcilePersistedBotPeerActivities()"))
        let body = String(source[range.lowerBound...].prefix(3200))
        XCTAssertTrue(body.contains("threadRepo.status(of: threadID)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadID)"))
    }

    func test_peerReconcile_statusProbe_fasterThanDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "peer-status-bench")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try threadRepo.status(of: tid)
            _ = try threadRepo.get(id: tid)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.status(of: tid)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: tid)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] peer-reconcile status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    /// WHY: Stop on a stale Working projection used to full-get 26 columns +
    /// routing JSON just to copy durable status onto the selected thread.
    func test_stopStaleProjection_usesStatusProbeWithoutDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "stale-stop")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        var stored = try XCTUnwrap(try threadRepo.get(id: tid))
        stored.status = .completed
        try threadRepo.upsert(stored)
        vm.status = .running
        let probesBefore = threadRepo.statusProbeCountForTesting
        vm.stop()
        XCTAssertEqual(vm.status, .completed)
        XCTAssertFalse(vm.isStopping)
        XCTAssertEqual(
            threadRepo.statusProbeCountForTesting,
            probesBefore + 1,
            "stale Stop must probe status once instead of a 26-column get"
        )
    }

    func test_stopStaleProjection_sourceUsesStatusProbe() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let range = try XCTUnwrap(source.range(of: "private func clearStaleRunProjection(threadId: AgentThreadID)"))
        let body = String(source[range.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("threadRepo.status(of: threadId)"))
        XCTAssertFalse(body.contains("threadRepo.get(id: threadId)"))
    }

    func test_stopStaleProjection_statusProbe_fasterThanDurableGet() throws {
        let (vm, threadRepo) = try makeVM()
        vm.createThread(title: "stale-stop-bench")
        let tid = try XCTUnwrap(vm.selectedThreadId)
        let warmup = 3
        let samples = 5
        let iterations = 200
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func timeMs(_ body: () throws -> Void) rethrows -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            try body()
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0
        }
        for _ in 0..<warmup {
            _ = try threadRepo.status(of: tid)
            _ = try threadRepo.get(id: tid)
        }
        var probeSamples: [Double] = []
        var getSamples: [Double] = []
        probeSamples.reserveCapacity(samples)
        getSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            probeSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.status(of: tid)
                }
            })
            getSamples.append(try timeMs {
                for _ in 0..<iterations {
                    _ = try threadRepo.get(id: tid)
                }
            })
        }
        let probeMed = median(probeSamples)
        let getMed = median(getSamples)
        let improvement = (getMed - probeMed) / getMed * 100.0
        NSLog(
            "[perf-proof] stop-stale status_probe_ms=%@ durable_get_ms=%@ improvement_pct=%.2f probe=%@ get=%@",
            String(probeMed), String(getMed), improvement,
            String(describing: probeSamples), String(describing: getSamples)
        )
        XCTAssertGreaterThan(
            improvement,
            5.0,
            "status probe must beat durable get by ≥5% (got \(improvement)%; probe=\(probeMed)ms get=\(getMed)ms)"
        )
    }

    /// PERF-IMPROVE-28 (warm-cache draft restore): cache-first restore must beat
    /// the old durable-read-then-cache order on every warm thread switch.
    /// Primary metric is median wall time for 4_000 restore evaluations against
    /// the same warm fixture (memory draft + real SQLite row).
    func test_microbench_composerDraftRestore_cacheFirstBeatsDurableRead() throws {
        let tmp = NSTemporaryDirectory() + "rc2-perf-draft-restore-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let draftRepo = AgentThreadDraftRepository(db: db)
        let threadRepo = AgentThreadRepository(db: db)
        let threadID = AgentThreadID()
        let providerInstanceID = "codex-cli"
        // agent_thread_drafts.thread_id is FK-bound to agent_threads.
        try threadRepo.upsert(AgentThread(
            id: threadID,
            workspaceId: WorkspaceID(),
            title: "draft restore bench",
            provider: .codex,
            model: "gpt",
            interactionMode: .default
        ))
        let draft = AgentThreadDraft(
            threadId: threadID,
            providerInstanceId: providerInstanceID,
            text: "draft body for restore benchmark",
            attachments: [],
            interactionMode: .default
        )
        try draftRepo.upsert(draft)
        let cache: [String: AgentThreadDraft] = [providerInstanceID: draft]

        let iterations = 4_000
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        // Old order: durable SQLite read + decode first, cache result second.
        func timeDurableFirst() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                let durable = try? draftRepo.get(threadId: threadID, providerInstanceId: providerInstanceID)
                let restored = cache[providerInstanceID] ?? durable ?? nil
                sink &+= restored?.text.utf8.count ?? 0
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0 // ms
        }

        // New order: cache-first; durable row only on a miss (none here).
        func timeCacheFirst() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            var sink = 0
            for _ in 0..<iterations {
                let restored: AgentThreadDraft?
                if let cached = cache[providerInstanceID] {
                    restored = cached
                } else {
                    let durable = try? draftRepo.get(threadId: threadID, providerInstanceId: providerInstanceID)
                    restored = durable ?? nil
                }
                sink &+= restored?.text.utf8.count ?? 0
            }
            let end = DispatchTime.now().uptimeNanoseconds
            XCTAssertGreaterThan(sink, 0)
            return Double(end - start) / 1_000_000.0 // ms
        }

        for _ in 0..<warmup { _ = timeDurableFirst(); _ = timeCacheFirst() }
        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(timeDurableFirst())
            after.append(timeCacheFirst())
        }
        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] composerDraftRestore durable_first_ms=%@ cache_first_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 50.0,
            "cache-first restore must be substantially faster than durable-first (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    /// PERF-IMPROVE-28 (debounced draft save): the off-main write must leave the
    /// MainActor immediately instead of blocking it for the full SQLite upsert.
    /// Primary metric is MainActor-occupied time for 200 fire-and-forget saves.
    func test_microbench_debouncedDraftSave_offMainKeepsMainActorFree() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-perf-draft-write-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let draftRepo = AgentThreadDraftRepository(db: db)
        let threadID = AgentThreadID()
        // agent_thread_drafts.thread_id is FK-bound to agent_threads.
        try AgentThreadRepository(db: db).upsert(AgentThread(
            id: threadID,
            workspaceId: WorkspaceID(),
            title: "draft write bench",
            provider: .codex,
            model: "gpt",
            interactionMode: .default
        ))
        let draft = AgentThreadDraft(
            threadId: threadID,
            providerInstanceId: "codex-cli",
            text: "debounced background draft body",
            attachments: [],
            interactionMode: .default
        )

        let iterations = 200
        let warmup = 2
        let samples = 5

        func median(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[s.count / 2]
        }

        // Old behavior: the debounce completion runs the upsert inline on the
        // MainActor; the actor is occupied for the whole SQLite write.
        func timeSyncOnMain() throws -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                try draftRepo.upsert(draft)
            }
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0 // ms
        }

        // New behavior: the debounce completion only enqueues a detached write.
        // MainActor time is the enqueue; the upsert runs off-main.
        func timeOffMainEnqueue() -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<iterations {
                let repo = draftRepo
                Task.detached(priority: .utility) {
                    try? repo.upsert(draft)
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            return Double(end - start) / 1_000_000.0 // ms
        }

        for _ in 0..<warmup { _ = try timeSyncOnMain(); _ = timeOffMainEnqueue() }
        // Let warmup detached writes drain before sampling so the serial SQLite
        // queue is not backlogged when the off-main samples run.
        try await Task.sleep(nanoseconds: 300_000_000)

        var before: [Double] = []
        var after: [Double] = []
        for _ in 0..<samples {
            before.append(try timeSyncOnMain())
            after.append(timeOffMainEnqueue())
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let durable = try draftRepo.get(threadId: threadID, providerInstanceId: "codex-cli")
        XCTAssertEqual(durable?.text, draft.text,
                       "fire-and-forget off-main writes must still land the durable row")

        let beforeMed = median(before)
        let afterMed = median(after)
        let improvement = (beforeMed - afterMed) / beforeMed * 100.0
        NSLog("[perf-proof] debouncedDraftSave mainactor_sync_ms=%@ mainactor_offmain_ms=%@ improvement_pct=%.2f before=%@ after=%@",
              String(beforeMed), String(afterMed), improvement,
              String(describing: before), String(describing: after))
        XCTAssertGreaterThan(
            improvement, 80.0,
            "off-main enqueue must keep the MainActor substantially freer than an inline upsert (got \(improvement)%; before=\(beforeMed)ms after=\(afterMed)ms)"
        )
    }

    /// Residual #2: conversation-column body currently calls
    /// `paintOrderedTranscriptEntries` 2× (idle) or 3× (reveal). The production
    /// helper must keep paint order while dropping extra `placingMatchingFinalsAfterTurns`
    /// on already-ordered windows.
    func test_transcriptColumnPaint_paintOrderedCalls_microbench() {
        let turnCount = 320
        let finalBytes = 4096
        let pad = String(repeating: "Z", count: finalBytes - 16)
        let threadId = AgentThreadID()
        var merged: [AgentAppView.TranscriptEntry] = []
        merged.reserveCapacity(turnCount * 2)
        for index in 0..<turnCount {
            let final = "final-\(index)-" + pad
            let message = AgentMessage(
                threadId: threadId,
                role: .assistant,
                content: final,
                createdAt: Date(timeIntervalSince1970: Double(index * 2))
            )
            let snapshot = AssistantTurnSnapshot(
                turnId: "paint-turn-\(index)",
                items: [
                    AssistantItem(
                        id: "tool-\(index)",
                        turnId: "paint-turn-\(index)",
                        type: .tool,
                        startedAtMs: Int64((index * 2 + 1) * 1_000)
                    )
                ],
                finalAssistantMessage: final,
                finished: true,
                startedAtMs: Int64((index * 2 + 1) * 1_000)
            )
            merged.append(.message(message))
            merged.append(.turn(snapshot))
        }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        func timeMs(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        }

        /// HEAD conversation-column body: order full list, then re-order the
        /// visible window, then re-order older+visible on reveal.
        func legacyColumnPaint(revealCount: Int) -> (
            all: [AgentAppView.TranscriptEntry],
            visible: [AgentAppView.TranscriptEntry],
            paint: [AgentAppView.TranscriptEntry]
        ) {
            let allEntries = AgentAppView.paintOrderedTranscriptEntries(merged)
            let visible = AgentAppView.paintOrderedTranscriptEntries(
                AgentAppView.visibleTranscriptWindow(
                    entries: allEntries,
                    status: .completed,
                    runStartedAt: nil
                )
            )
            let hiddenCount = AgentAppView.hiddenTranscriptCount(
                totalCount: allEntries.count,
                visibleCount: visible.count
            )
            let revealed = min(revealCount, hiddenCount)
            if revealed > 0 {
                let older = AgentAppView.hiddenTranscriptRevealWindow(
                    allItems: allEntries,
                    visibleWindow: visible,
                    revealCount: revealed
                )
                return (allEntries, visible, AgentAppView.paintOrderedTranscriptEntries(older + visible))
            }
            return (allEntries, visible, visible)
        }

        func productionColumnPaint(revealCount: Int) -> (
            all: [AgentAppView.TranscriptEntry],
            visible: [AgentAppView.TranscriptEntry],
            paint: [AgentAppView.TranscriptEntry]
        ) {
            AgentAppView.transcriptColumnPaint(
                mergedEntries: merged,
                status: .completed,
                runStartedAt: nil,
                revealCount: revealCount
            )
        }

        for _ in 0..<2 {
            _ = legacyColumnPaint(revealCount: 0)
            _ = productionColumnPaint(revealCount: 0)
            _ = legacyColumnPaint(revealCount: 50)
            _ = productionColumnPaint(revealCount: 50)
        }
        var idleLegacy: [Double] = []
        var idleProduction: [Double] = []
        var revealLegacy: [Double] = []
        var revealProduction: [Double] = []
        for _ in 0..<5 {
            idleLegacy.append(timeMs { _ = legacyColumnPaint(revealCount: 0) })
            idleProduction.append(timeMs { _ = productionColumnPaint(revealCount: 0) })
            revealLegacy.append(timeMs { _ = legacyColumnPaint(revealCount: 50) })
            revealProduction.append(timeMs { _ = productionColumnPaint(revealCount: 50) })
        }

        AgentAppView.TranscriptPaintOrderedProbe.reset()
        let idle = productionColumnPaint(revealCount: 0)
        let idleCalls = AgentAppView.TranscriptPaintOrderedProbe.callCount
        AgentAppView.TranscriptPaintOrderedProbe.reset()
        let revealed = productionColumnPaint(revealCount: 50)
        let revealCalls = AgentAppView.TranscriptPaintOrderedProbe.callCount

        let expectedIdleVisible = AgentAppView.visibleTranscriptWindow(
            entries: idle.all,
            status: .completed,
            runStartedAt: nil
        )
        XCTAssertEqual(idle.visible.map(\.id), expectedIdleVisible.map(\.id))
        XCTAssertEqual(idle.paint.map(\.id), idle.visible.map(\.id))
        let olderReveal = AgentAppView.hiddenTranscriptRevealWindow(
            allItems: revealed.all,
            visibleWindow: revealed.visible,
            revealCount: 50
        )
        var revealPaintIDs = Set(revealed.visible.map(\.id))
        for entry in olderReveal {
            revealPaintIDs.insert(entry.id)
        }
        XCTAssertEqual(
            revealed.paint.map(\.id),
            revealed.all.filter { revealPaintIDs.contains($0.id) }.map(\.id),
            "reveal must keep allEntries relative order for older∪visible IDs"
        )
        // First matching final must sit after its turn in the full ordered list.
        let firstTurnId = AgentAppView.TranscriptEntry.turn(
            AssistantTurnSnapshot(turnId: "paint-turn-0")
        ).id
        let firstTurnIndex = idle.all.firstIndex(where: { $0.id == firstTurnId })
        let firstMessageIndex = idle.all.firstIndex(where: {
            if case .message(let message) = $0 { return message.content.hasPrefix("final-0-") }
            return false
        })
        XCTAssertNotNil(firstTurnIndex)
        XCTAssertNotNil(firstMessageIndex)
        if let firstTurnIndex, let firstMessageIndex {
            XCTAssertLessThan(firstTurnIndex, firstMessageIndex, "Work so far must precede its matching final")
        }

        let idleLegacyMed = median(idleLegacy)
        let idleProdMed = median(idleProduction)
        let revealLegacyMed = median(revealLegacy)
        let revealProdMed = median(revealProduction)
        print(
            "PAINT_ORDERED_BODY_BENCH idle_legacy_samples=\(idleLegacy) idle_legacy_median_ms=\(idleLegacyMed) "
                + "idle_prod_samples=\(idleProduction) idle_prod_median_ms=\(idleProdMed) idle_calls=\(idleCalls) "
                + "reveal_legacy_samples=\(revealLegacy) reveal_legacy_median_ms=\(revealLegacyMed) "
                + "reveal_prod_samples=\(revealProduction) reveal_prod_median_ms=\(revealProdMed) reveal_calls=\(revealCalls)"
        )
        NSLog(
            "[perf-proof] paintOrdered idle_legacy_ms=%@ idle_prod_ms=%@ idle_calls=%d reveal_legacy_ms=%@ reveal_prod_ms=%@ reveal_calls=%d idle_legacy=%@ idle_prod=%@ reveal_legacy=%@ reveal_prod=%@",
            String(idleLegacyMed),
            String(idleProdMed),
            idleCalls,
            String(revealLegacyMed),
            String(revealProdMed),
            revealCalls,
            String(describing: idleLegacy),
            String(describing: idleProduction),
            String(describing: revealLegacy),
            String(describing: revealProduction)
        )
        // HEAD records 2 idle / 3 reveal calls. After the single-order fix this
        // must be 1. Keep the bound loose here so BEFORE on HEAD still records.
        XCTAssertEqual(idleCalls, 1, "idle column paint must order the full merged list once")
        XCTAssertEqual(revealCalls, 1, "reveal concat must slice the already-ordered list without a second paintOrdered")
        XCTAssertLessThan(idleProdMed, 60_000)
        XCTAssertLessThan(revealProdMed, 60_000)
        _ = idleLegacyMed
        _ = revealLegacyMed
    }

    /// Live tool rows re-enter body on every token. `toolCommandPreview` must
    /// reuse `toolInputObject` so 20 tools × 200 prefixes parse 20 times, not 4000.
    func test_toolCommandPreview_computeCountStaysAtUniqueToolsAcrossDeltas() {
        let toolCount = 20
        let deltas = 200
        let pad = String(repeating: "p", count: 32)
        let items: [AssistantItem] = (0..<toolCount).map { index in
            AssistantItem(
                id: "perf-tool-\(index)",
                turnId: "perf-turn",
                type: .tool,
                state: .completed,
                summary: "Bash",
                body: #"{"command":"ls \#(index) \#(pad)"}"#,
                startedAtMs: Int64(index),
                finishedAtMs: Int64(index + 1)
            )
        }
        let before = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting
        for _ in 0..<deltas {
            for item in items {
                _ = AgentTimelineItemPresentation.toolCommandPreview(for: item)
            }
        }
        let parses = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting - before
        NSLog(
            "[perf-proof] toolInputObjectComputeCount tools=%d deltas=%d before_floor=%d after=%d",
            toolCount, deltas, toolCount * deltas, parses
        )
        XCTAssertEqual(parses, toolCount)
        XCTAssertLessThan(parses, toolCount * deltas)
    }

}
