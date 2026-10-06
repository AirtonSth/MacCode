import XCTest
@testable import AgentRuntime
@testable import CoreModel
@testable import Persistence

/// WHY: a failed Codex resume must reconstruct prior turns once on the fresh
/// destination. Seeding a successful resume, an empty snapshot, or a retry
/// would either duplicate provider-native history or invent a second conversation.
final class ConversationContextSeedRuntimeTests: XCTestCase {
    func test_successfulResumeDoesNotSeedOrDuplicateHistory() async throws {
        // WHY: provider-native resume already has the conversation. Host seed
        // would replay history into a live session.
        let snapshot = try XCTUnwrap(makeSnapshot(user: "prior user", assistant: "prior assistant"))
        let client = ContextSeedMockClient()
        let adapter = CodexAppServerAdapter(clientFactory: { _, notificationHandler, _ in
            client.notificationHandler = notificationHandler
            return client
        })
        var request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "continue",
            providerThreadId: "live-thread"
        )
        request.contextSnapshot = snapshot
        _ = try await adapter.sendTurn(request) { _ in }
        XCTAssertNil(client.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(client.startedTurns.first?.request.prompt, "continue")
        XCTAssertEqual(client.openedRequests.compactMap(\.providerThreadId), ["live-thread"])
    }

    func test_freshFallbackWithNoPriorContextSendsNoEmptySeed() async throws {
        // WHY: an empty RCSEED1 document would be a fake history. Cold fallback
        // with no prior rows must send only the current prompt.
        let (adapter, destClient) = fallbackAdapter()
        var request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "first prompt",
            providerThreadId: "missing-thread"
        )
        request.contextSnapshot = nil
        _ = try await adapter.sendTurn(request) { _ in }
        XCTAssertNil(destClient.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(destClient.startedTurns.first?.request.prompt, "first prompt")
    }

    func test_freshFallbackSendsOneSeedAndCurrentPromptOnce() async throws {
        let snapshot = try XCTUnwrap(makeSnapshot(user: "ask", assistant: "answer"))
        let (adapter, destClient) = fallbackAdapter()
        var request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "next",
            providerThreadId: "gone"
        )
        request.contextSnapshot = snapshot
        _ = try await adapter.sendTurn(request) { _ in }
        let seed = try XCTUnwrap(destClient.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(seed.document.items.map(\.payload), ["ask", "answer"])
        XCTAssertEqual(destClient.startedTurns.map { $0.request.prompt }, ["next"])
        let params = CodexAppServerClient.turnStartParams(
            providerThreadId: destClient.startedTurns[0].providerThreadId,
            for: destClient.startedTurns[0].request
        )
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["text"] as? String, seed.encoded)
        XCTAssertEqual(input[1]["text"] as? String, "next")
    }

    func test_duplicateCallbackDoesNotSeedTwice() async throws {
        let snapshot = try XCTUnwrap(makeSnapshot(user: "u", assistant: "a"))
        let (adapter, destClient) = fallbackAdapter()
        let store = try makeReceiptStore()
        adapter.contextSeedReceipts = store.repo
        let threadId = store.thread.id
        var request = AgentRunRequest(
            runId: store.run.id,
            threadId: threadId,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "p1",
            providerThreadId: "gone"
        )
        request.contextSnapshot = snapshot
        _ = try await adapter.sendTurn(request) { _ in }
        try adapter.stopSession(threadId: threadId)
        _ = try await adapter.sendTurn(request) { _ in }
        XCTAssertEqual(destClient.startedTurns.filter { $0.request.preparedContextSeed != nil }.count, 1)
        XCTAssertEqual(try store.repo.list(runId: request.runId).filter { $0.winner.lifecycle == .delivered }.count, 2)
    }

    func test_providerRejectionLeavesNoDeliveredReceipt() async throws {
        // WHY: Codex never accepted the seeded turn. A delivered row would
        // block a later honest retry and claim a send that did not happen.
        let snapshot = try XCTUnwrap(makeSnapshot(user: "u", assistant: "a"))
        let timedOut = ContextSeedMockClient(
            openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
        )
        let rejected = ContextSeedMockClient(
            startTurnError: CodexAppServerError.rpcError(code: 1, message: "rejected")
        )
        let factoryCalls = ContextSeedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = factoryCalls.value <= 2 ? timedOut : rejected
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
        let store = try makeReceiptStore()
        adapter.contextSeedReceipts = store.repo
        var request = AgentRunRequest(
            runId: store.run.id,
            threadId: store.thread.id,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "now",
            providerThreadId: "gone"
        )
        request.contextSnapshot = snapshot
        do {
            _ = try await adapter.sendTurn(request) { _ in }
            XCTFail("provider rejection must surface")
        } catch {
            let records = try store.repo.list(runId: request.runId)
            XCTAssertFalse(records.contains { $0.winner.lifecycle == .delivered })
            XCTAssertTrue(records.allSatisfy { $0.winner.lifecycle == .notDelivered || $0.winner.lifecycle == .provisional })
        }
    }

    func test_rejectedFreshFallbackDoesNotPublishDestinationOrDeliverReceipt() async throws {
        // WHY: publishing D1 before turn/start is accepted makes the next resume
        // treat an empty dest as live history. Prior context is then skipped.
        let dest = ContextSeedMockClient(
            startTurnError: CodexAppServerError.rpcError(code: 1, message: "rejected"),
            freshThreadId: "fresh-dest-d1"
        )
        let (adapter, _) = fallbackAdapter(dest: dest)
        let store = try makeReceiptStore()
        adapter.contextSeedReceipts = store.repo
        var thread = store.thread
        thread.providerThreadId = "old-thread"
        try AgentThreadRepository(db: store.db).upsert(thread)
        let sessionRepo = ProviderSessionRuntimeRepository(db: store.db)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "old-thread",
            cwd: "/tmp/context-seed",
            model: "gpt-test",
            lastRunId: store.run.id
        ))
        try AgentMessageRepository(db: store.db).append(
            AgentMessage(threadId: thread.id, role: .user, content: "prior user")
        )
        try AgentMessageRepository(db: store.db).append(
            AgentMessage(threadId: thread.id, role: .assistant, content: "prior assistant")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: store.db),
            messageRepo: AgentMessageRepository(db: store.db),
            threadRepo: AgentThreadRepository(db: store.db),
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let publishedDests = ContextSeedCounter()
        coordinator.onAssistantEvent = { event, _, _ in
            if case .threadStarted(_, let providerThreadId) = event, providerThreadId == "fresh-dest-d1" {
                publishedDests.increment()
            }
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "gpt-test",
                cwd: "/tmp/context-seed",
                prompt: "current after reject"
            ))
            XCTFail("seeded startTurn rejection must surface")
        } catch {
            XCTAssertEqual(publishedDests.value, 0)
            XCTAssertEqual(try AgentThreadRepository(db: store.db).get(id: thread.id)?.providerThreadId, "old-thread")
            XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.resumeCursor, "old-thread")
            if let startedRunId = dest.startedTurns.first?.request.runId {
                XCTAssertFalse(try store.repo.list(runId: startedRunId).contains { $0.winner.lifecycle == .delivered })
            }
            XCTAssertEqual(dest.startedTurns.count, 1)
            XCTAssertNotNil(dest.startedTurns.first?.request.preparedContextSeed)
            XCTAssertEqual(dest.startedTurns.first?.request.prompt, "current after reject")
        }
    }

    func test_retryFromOriginalCursorSeedsOnceAndPublishesOnlyAfterAccept() async throws {
        // WHY: after a rejected fallback dest the durable cursor must stay the
        // original one so retry falls back again and reconstructs history once.
        let snapshot = try XCTUnwrap(makeSnapshot(user: "ask", assistant: "answer"))
        let rejected = ContextSeedMockClient(
            startTurnError: CodexAppServerError.rpcError(code: 1, message: "rejected"),
            freshThreadId: "fresh-dest-d1"
        )
        let accepted = ContextSeedMockClient(freshThreadId: "fresh-dest-d2")
        let factoryCalls = ContextSeedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client: ContextSeedMockClient
                switch factoryCalls.value {
                case 1, 2, 4, 5:
                    client = ContextSeedMockClient(
                        openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
                    )
                case 3:
                    client = rejected
                default:
                    client = accepted
                }
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
        let store = try makeReceiptStore()
        adapter.contextSeedReceipts = store.repo
        var request = AgentRunRequest(
            runId: store.run.id,
            threadId: store.thread.id,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "next",
            providerThreadId: "old-thread"
        )
        request.contextSnapshot = snapshot
        let firstEvents = ContextSeedEventLog()
        do {
            _ = try await adapter.sendTurn(request) { firstEvents.append($0) }
            XCTFail("first seeded startTurn must reject")
        } catch {
            XCTAssertFalse(firstEvents.threadStartedIds.contains("fresh-dest-d1"))
            XCTAssertFalse(try store.repo.list(runId: request.runId).contains { $0.winner.lifecycle == .delivered })
        }

        let retryEvents = ContextSeedEventLog()
        accepted.onStartTurn = { retryEvents.markStartTurn() }
        _ = try await adapter.sendTurn(request) { retryEvents.append($0) }
        XCTAssertEqual(accepted.startedTurns.count, 1)
        XCTAssertNotNil(accepted.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(accepted.startedTurns.first?.request.prompt, "next")
        XCTAssertEqual(accepted.startedTurns.first?.request.preparedContextSeed?.document.items.map(\.payload), ["ask", "answer"])
        XCTAssertEqual(rejected.startedTurns.count, 1)
        XCTAssertFalse(retryEvents.threadStartedIds.contains("fresh-dest-d1"))
        XCTAssertEqual(retryEvents.threadStartedIds, ["fresh-dest-d2"])
        XCTAssertTrue(retryEvents.threadStartedFollowsFirstStartTurn)
        XCTAssertTrue(try store.repo.list(runId: request.runId).contains { $0.winner.lifecycle == .delivered })
    }

    func test_recoverSessionFallbackDoesNotPublishEmptyDestinationBeforeSeed() async throws {
        // WHY: recoverSession used to emit threadStarted for the empty dest. A
        // relaunch then resumed that dest with shouldSeed=false and dropped history.
        let snapshot = try XCTUnwrap(makeSnapshot(user: "keep", assistant: "this"))
        let recoverDest = ContextSeedMockClient(freshThreadId: "recover-empty-d1")
        let (recoverAdapter, _) = fallbackAdapter(dest: recoverDest)
        let recoverEvents = ContextSeedEventLog()
        let threadId = AgentThreadID()
        try await recoverAdapter.recoverSession(AgentRunRequest(
            threadId: threadId,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "",
            providerThreadId: "old-thread"
        )) { recoverEvents.append($0) }
        XCTAssertFalse(recoverEvents.threadStartedIds.contains("recover-empty-d1"))
        XCTAssertNil(recoverAdapter.listSessions().first?.providerThreadId)

        let retryDest = ContextSeedMockClient(freshThreadId: "recover-retry-d2")
        let (retryAdapter, _) = fallbackAdapter(dest: retryDest)
        let store = try makeReceiptStore()
        retryAdapter.contextSeedReceipts = store.repo
        var request = AgentRunRequest(
            runId: store.run.id,
            threadId: store.thread.id,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "after relaunch",
            providerThreadId: "old-thread"
        )
        request.contextSnapshot = snapshot
        let retryEvents = ContextSeedEventLog()
        _ = try await retryAdapter.sendTurn(request) { retryEvents.append($0) }
        XCTAssertEqual(retryDest.startedTurns.count, 1)
        XCTAssertNotNil(retryDest.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(retryEvents.threadStartedIds, ["recover-retry-d2"])
        XCTAssertTrue(try store.repo.list(runId: request.runId).allSatisfy { $0.winner.lifecycle == .delivered })
    }

    func test_successfulResumeAndColdStartKeepExistingEventOrderAndDoNotSeed() async throws {
        // WHY: delaying publish is only for resume-fallback dests. Successful
        // resume and ordinary cold starts must keep today's event order.
        let snapshot = try XCTUnwrap(makeSnapshot(user: "prior user", assistant: "prior assistant"))
        let live = ContextSeedMockClient(freshThreadId: "live-thread")
        let resumeAdapter = CodexAppServerAdapter(clientFactory: { _, notificationHandler, _ in
            live.notificationHandler = notificationHandler
            return live
        })
        var resumeRequest = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "continue",
            providerThreadId: "live-thread"
        )
        resumeRequest.contextSnapshot = snapshot
        let resumeEvents = ContextSeedEventLog()
        _ = try await resumeAdapter.sendTurn(resumeRequest) { resumeEvents.append($0) }
        XCTAssertNil(live.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(resumeEvents.threadStartedIds, ["live-thread"])
        XCTAssertEqual(resumeEvents.lifecycleNames, ["running", "threadStarted", "turnStarted"])

        let cold = ContextSeedMockClient(freshThreadId: "cold-thread")
        let coldAdapter = CodexAppServerAdapter(clientFactory: { _, notificationHandler, _ in
            cold.notificationHandler = notificationHandler
            return cold
        })
        let coldEvents = ContextSeedEventLog()
        _ = try await coldAdapter.sendTurn(AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "first prompt"
        )) { coldEvents.append($0) }
        XCTAssertNil(cold.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(cold.startedTurns.first?.request.prompt, "first prompt")
        XCTAssertEqual(coldEvents.threadStartedIds, ["cold-thread"])
        XCTAssertEqual(coldEvents.lifecycleNames, ["running", "threadStarted", "turnStarted"])
    }

    func test_threadStartedNotificationDuringSeedAwaitKeepsOldCursorAndRetriesOnce() async throws {
        // WHY: checked-in Codex corpus emits thread/started after thread/start.
        // After recordSession that notification used to persist empty D1 before
        // seeded startTurn was accepted, so retry resumed D1 with shouldSeed=false.
        let rejected = ContextSeedMockClient(
            startTurnError: CodexAppServerError.rpcError(code: 1, message: "rejected"),
            freshThreadId: "fresh-dest-d1"
        )
        rejected.emitThreadStartedNotification = true
        let accepted = ContextSeedMockClient(freshThreadId: "fresh-dest-d2")
        accepted.emitThreadStartedNotification = true
        let factoryCalls = ContextSeedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client: ContextSeedMockClient
                switch factoryCalls.value {
                case 1, 2, 4, 5:
                    client = ContextSeedMockClient(
                        openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
                    )
                case 3:
                    client = rejected
                default:
                    client = accepted
                }
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
        let store = try makeReceiptStore()
        adapter.contextSeedReceipts = store.repo
        var thread = store.thread
        thread.providerThreadId = "old-thread"
        try AgentThreadRepository(db: store.db).upsert(thread)
        let sessionRepo = ProviderSessionRuntimeRepository(db: store.db)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "old-thread",
            cwd: "/tmp/context-seed",
            model: "gpt-test",
            lastRunId: store.run.id
        ))
        try AgentMessageRepository(db: store.db).append(
            AgentMessage(threadId: thread.id, role: .user, content: "prior user")
        )
        try AgentMessageRepository(db: store.db).append(
            AgentMessage(threadId: thread.id, role: .assistant, content: "prior assistant")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: store.db),
            messageRepo: AgentMessageRepository(db: store.db),
            threadRepo: AgentThreadRepository(db: store.db),
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let publishedDests = ContextSeedPublishedDests()
        coordinator.onAssistantEvent = { event, _, _ in
            if case .threadStarted(_, let providerThreadId) = event {
                publishedDests.append(providerThreadId)
            }
        }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "gpt-test",
                cwd: "/tmp/context-seed",
                prompt: "after notify reject"
            ))
            XCTFail("seeded startTurn rejection must surface")
        } catch {
            XCTAssertFalse(publishedDests.ids.contains("fresh-dest-d1"))
            XCTAssertEqual(try AgentThreadRepository(db: store.db).get(id: thread.id)?.providerThreadId, "old-thread")
            XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.resumeCursor, "old-thread")
            XCTAssertEqual(rejected.startedTurns.count, 1)
            XCTAssertNotNil(rejected.startedTurns.first?.request.preparedContextSeed)
            XCTAssertEqual(rejected.startedTurns.first?.request.prompt, "after notify reject")
            if let startedRunId = rejected.startedTurns.first?.request.runId {
                XCTAssertFalse(try store.repo.list(runId: startedRunId).contains { $0.winner.lifecycle == .delivered })
            }
        }

        let durableThreadId = thread.id
        accepted.onStartTurn = { publishedDests.markStartTurn() }
        accepted.onAfterThreadStartedNotification = {
            XCTAssertEqual(try? AgentThreadRepository(db: store.db).get(id: durableThreadId)?.providerThreadId, "old-thread")
            XCTAssertEqual(try? sessionRepo.get(threadId: durableThreadId)?.resumeCursor, "old-thread")
            XCTAssertFalse(publishedDests.ids.contains("fresh-dest-d2"))
        }
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "retry after notify"
        ))
        XCTAssertEqual(accepted.startedTurns.count, 1)
        XCTAssertNotNil(accepted.startedTurns.first?.request.preparedContextSeed)
        XCTAssertEqual(accepted.startedTurns.first?.request.prompt, "retry after notify")
        let retryPayloads = accepted.startedTurns.first?.request.preparedContextSeed?.document.items.map(\.payload) ?? []
        XCTAssertTrue(retryPayloads.contains("prior user"))
        XCTAssertTrue(retryPayloads.contains("prior assistant"))
        XCTAssertEqual(rejected.startedTurns.count, 1)
        XCTAssertFalse(publishedDests.ids.contains("fresh-dest-d1"))
        XCTAssertEqual(publishedDests.ids, ["fresh-dest-d2"])
        XCTAssertTrue(publishedDests.threadStartedFollowsFirstStartTurn)
        XCTAssertEqual(try AgentThreadRepository(db: store.db).get(id: thread.id)?.providerThreadId, "fresh-dest-d2")
        XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.resumeCursor, "fresh-dest-d2")
        if let retryRunId = accepted.startedTurns.first?.request.runId {
            XCTAssertTrue(try store.repo.list(runId: retryRunId).contains { $0.winner.lifecycle == .delivered })
        }
    }

    func test_terminationWhileAwaitingSeedDeliversTerminalWithoutPersistingDestination() async throws {
        // WHY: process loss after recordSession must still fail the turn, but
        // persistTerminalGraph must not bind the user to unpublished D1.
        let dest = ContextSeedMockClient(
            startTurnError: CodexAppServerError.processExited(stderrTail: ""),
            freshThreadId: "fresh-dest-d1"
        )
        dest.emitThreadStartedNotification = true
        dest.terminateOnStartTurn = true
        let (adapter, _) = fallbackAdapter(dest: dest)
        let store = try makeReceiptStore()
        adapter.contextSeedReceipts = store.repo
        var thread = store.thread
        thread.providerThreadId = "old-thread"
        try AgentThreadRepository(db: store.db).upsert(thread)
        let sessionRepo = ProviderSessionRuntimeRepository(db: store.db)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "old-thread",
            cwd: "/tmp/context-seed",
            model: "gpt-test",
            lastRunId: store.run.id
        ))
        try AgentMessageRepository(db: store.db).append(
            AgentMessage(threadId: thread.id, role: .user, content: "keep")
        )
        try AgentMessageRepository(db: store.db).append(
            AgentMessage(threadId: thread.id, role: .assistant, content: "this")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: store.db),
            messageRepo: AgentMessageRepository(db: store.db),
            threadRepo: AgentThreadRepository(db: store.db),
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let finishes = ContextSeedFinishLog()
        coordinator.addObserver(finishes)

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "gpt-test",
                cwd: "/tmp/context-seed",
                prompt: "die during seed"
            ))
            XCTFail("process loss while awaiting seed must surface")
        } catch {
            XCTAssertFalse(finishes.providerThreadIds.isEmpty, "terminal finished event must still be delivered")
            XCTAssertFalse(finishes.providerThreadIds.contains("fresh-dest-d1"))
            XCTAssertEqual(try AgentThreadRepository(db: store.db).get(id: thread.id)?.providerThreadId, "old-thread")
            XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.resumeCursor, "old-thread")
            XCTAssertEqual(dest.startedTurns.count, 1)
            XCTAssertNotNil(dest.startedTurns.first?.request.preparedContextSeed)
            if let startedRunId = dest.startedTurns.first?.request.runId {
                XCTAssertFalse(try store.repo.list(runId: startedRunId).contains { $0.winner.lifecycle == .delivered })
            }
        }
    }

    func test_successfulResumeAndColdStartStillPublishProviderThreadStartedNotification() async throws {
        // WHY: suppressing fallback dest publish must not swallow ordinary
        // resume or cold-start thread/started notifications.
        let snapshot = try XCTUnwrap(makeSnapshot(user: "prior user", assistant: "prior assistant"))
        let live = ContextSeedMockClient(freshThreadId: "live-thread")
        live.emitThreadStartedNotification = true
        let resumeAdapter = CodexAppServerAdapter(clientFactory: { _, notificationHandler, _ in
            live.notificationHandler = notificationHandler
            return live
        })
        var resumeRequest = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "continue",
            providerThreadId: "live-thread"
        )
        resumeRequest.contextSnapshot = snapshot
        let resumeEvents = ContextSeedEventLog()
        _ = try await resumeAdapter.sendTurn(resumeRequest) { resumeEvents.append($0) }
        XCTAssertNil(live.startedTurns.first?.request.preparedContextSeed)
        XCTAssertTrue(resumeEvents.threadStartedIds.contains("live-thread"))

        let cold = ContextSeedMockClient(freshThreadId: "cold-thread")
        cold.emitThreadStartedNotification = true
        let coldAdapter = CodexAppServerAdapter(clientFactory: { _, notificationHandler, _ in
            cold.notificationHandler = notificationHandler
            return cold
        })
        let coldEvents = ContextSeedEventLog()
        _ = try await coldAdapter.sendTurn(AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp/context-seed",
            prompt: "first prompt"
        )) { coldEvents.append($0) }
        XCTAssertNil(cold.startedTurns.first?.request.preparedContextSeed)
        XCTAssertTrue(coldEvents.threadStartedIds.contains("cold-thread"))
    }

    func test_coordinatorSnapshotsPriorHistoryAndExcludesCurrentPrompt() async throws {
        let tmp = NSTemporaryDirectory() + "rc-context-seed-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "snap", provider: .codex, model: "gpt-test")
        try threadRepo.upsert(thread)
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .user, content: "first"))
        try messageRepo.append(AgentMessage(threadId: thread.id, role: .assistant, content: "reply"))
        let adapter = SnapshotCapturingAdapter()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerAdapters: [.codex: adapter]
        )
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-test",
            cwd: tmp,
            prompt: "second"
        ))
        let snapshot = try XCTUnwrap(adapter.request?.contextSnapshot)
        XCTAssertEqual(snapshot.items.map(\.canonicalText), ["first", "reply"])
        XCTAssertFalse(snapshot.items.contains(where: { $0.canonicalText == "second" }))
    }

    func test_rcw1ArmIsNotDerivedFromRCS1OnRuntimePrepare() async throws {
        let human = String(repeating: "ABCDEFGH", count: 16)
        let snapshot = try XCTUnwrap(makeSnapshot(user: "q", assistant: human))
        let preparer = TokenSaverHumanContextSeedPreparer()
        let request = AgentRunRequest(
            threadId: AgentThreadID(),
            provider: .codex,
            model: "gpt-test",
            cwd: "/tmp",
            prompt: "now"
        )
        let preparedOptional = await preparer.prepare(
            snapshot: snapshot,
            request: request,
            destinationProviderThreadId: "dest"
        )
        let prepared = try XCTUnwrap(preparedOptional)
        let rcs1 = RemoteCodeCompactSpan.encode(human)
        XCTAssertNotEqual(prepared.document.items.last?.format, .rcw1)
        XCTAssertNotEqual(prepared.document.items.last?.payload, rcs1)
        let rcw1Arm = prepared.receipts.last?.arm(.rcw1)
        XCTAssertEqual(rcw1Arm?.eligible, false)
        XCTAssertNotEqual(rcw1Arm?.producerId, TokenSaverRequestSelectionReceipt.rcs1ProducerID)
    }

    private func makeSnapshot(user: String, assistant: String) -> TokenSaverCanonicalConversationSnapshot? {
        let thread = AgentThreadID()
        return TokenSaverCanonicalConversationSnapshot.capture(
            messages: [
                AgentMessage(threadId: thread, role: .user, content: user),
                AgentMessage(threadId: thread, role: .assistant, content: assistant),
            ],
            persistedRCW1ByMessageId: [:],
            excludingCurrentUserText: "unused"
        )
    }

    private func fallbackAdapter(
        dest: ContextSeedMockClient = ContextSeedMockClient()
    ) -> (CodexAppServerAdapter, ContextSeedMockClient) {
        let timedOut = ContextSeedMockClient(
            openThreadError: CodexAppServerError.requestTimedOut(method: "thread/resume", timeout: 30)
        )
        let factoryCalls = ContextSeedCounter()
        let adapter = CodexAppServerAdapter(
            clientFactory: { _, notificationHandler, _ in
                factoryCalls.increment()
                let client = factoryCalls.value <= 2 ? timedOut : dest
                client.notificationHandler = notificationHandler
                return client
            },
            threadResumeRetryPolicy: CodexThreadResumeRetryPolicy(
                maxAttempts: 2,
                backoffNanoseconds: [],
                perAttemptTimeoutHint: 30
            )
        )
        return (adapter, dest)
    }

    private func makeReceiptStore() throws -> (
        db: SQLiteDB,
        repo: TokenSaverContextSelectionReceiptRepository,
        thread: AgentThread,
        run: AgentRun
    ) {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let thread = AgentThread(title: "context-seed", provider: .codex, model: "gpt-test")
        try AgentThreadRepository(db: db).upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-test", status: .pending)
        try AgentRunRepository(db: db).upsert(run)
        return (db, TokenSaverContextSelectionReceiptRepository(db: db), thread, run)
    }
}

private final class SnapshotCapturingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var _request: AgentRunRequest?
    var request: AgentRunRequest? { lock.withLock { _request } }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        if let permit = request.acceptancePermit {
            try permit.withAcceptance { lock.withLock { _request = request } }
        } else {
            lock.withLock { _request = request }
        }
        onEvent(.status(.running))
        onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: "t"))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {}
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { false }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}

private final class ContextSeedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private final class ContextSeedPublishedDests: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    private var _startTurnCount = 0
    private var _threadStartedAfterStartTurn: [Bool] = []

    func append(_ providerThreadId: String?) {
        lock.lock()
        _threadStartedAfterStartTurn.append(_startTurnCount > 0)
        if let providerThreadId {
            _ids.append(providerThreadId)
        }
        lock.unlock()
    }

    func markStartTurn() {
        lock.lock()
        _startTurnCount += 1
        lock.unlock()
    }

    var ids: [String] { lock.withLock { _ids } }
    var threadStartedFollowsFirstStartTurn: Bool {
        lock.withLock { _threadStartedAfterStartTurn.contains(true) }
    }
}

private final class ContextSeedFinishLog: AgentRunObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _providerThreadIds: [String?] = []

    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {}
    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {}
    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
        lock.lock()
        _providerThreadIds.append(providerThreadId)
        lock.unlock()
    }

    var providerThreadIds: [String?] { lock.withLock { _providerThreadIds } }
}

private final class ContextSeedEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [AgentRunEvent] = []
    private var _startTurnCount = 0
    private var _threadStartedAfterStartTurn: [Bool] = []

    func append(_ event: AgentRunEvent) {
        lock.lock()
        if case .event(.threadStarted) = event {
            _threadStartedAfterStartTurn.append(_startTurnCount > 0)
        }
        _events.append(event)
        lock.unlock()
    }

    func markStartTurn() {
        lock.lock()
        _startTurnCount += 1
        lock.unlock()
    }

    var threadStartedIds: [String] {
        lock.withLock {
            _events.compactMap { event in
                if case .event(.threadStarted(_, let providerThreadId)) = event {
                    return providerThreadId
                }
                return nil
            }
        }
    }

    var lifecycleNames: [String] {
        lock.withLock {
            _events.compactMap { event in
                switch event {
                case .status(.running): return "running"
                case .event(.threadStarted): return "threadStarted"
                case .event(.turnStarted): return "turnStarted"
                default: return nil
                }
            }
        }
    }

    var threadStartedFollowsFirstStartTurn: Bool {
        lock.withLock { _threadStartedAfterStartTurn.contains(true) }
    }
}

private final class ContextSeedMockClient: CodexAppServerControlling, @unchecked Sendable {
    struct StartedTurn {
        let providerThreadId: String
        let request: AgentRunRequest
    }

    var notificationHandler: CodexAppServerClient.NotificationHandler?
    var terminationHandler: (@Sendable (Error) -> Void)?
    var onStartTurn: (@Sendable () -> Void)?
    var onAfterThreadStartedNotification: (@Sendable () -> Void)?
    var emitThreadStartedNotification = false
    var terminateOnStartTurn = false
    let openThreadError: Error?
    let startTurnError: Error?
    let freshThreadId: String
    private let lock = NSLock()
    private var _openedRequests: [AgentRunRequest] = []
    private var _startedTurns: [StartedTurn] = []
    private var _didStop = false

    init(
        openThreadError: Error? = nil,
        startTurnError: Error? = nil,
        freshThreadId: String = "codex-thread-1"
    ) {
        self.openThreadError = openThreadError
        self.startTurnError = startTurnError
        self.freshThreadId = freshThreadId
    }

    var openedRequests: [AgentRunRequest] { lock.withLock { _openedRequests } }
    var startedTurns: [StartedTurn] { lock.withLock { _startedTurns } }

    func initialize(clientName: String, clientTitle: String, clientVersion: String) async throws -> CodexAppServerInitializeResult {
        CodexAppServerInitializeResult(userAgent: "mock", codexHome: nil, platformFamily: nil, platformOs: nil)
    }

    func openThread(for request: AgentRunRequest) async throws -> CodexAppServerThreadOpenResult {
        lock.lock(); _openedRequests.append(request); lock.unlock()
        if let openThreadError { throw openThreadError }
        let providerThreadId = request.providerThreadId?.isEmpty == false ? request.providerThreadId! : freshThreadId
        return CodexAppServerThreadOpenResult(providerThreadId: providerThreadId, response: ["id": providerThreadId])
    }

    func startTurn(providerThreadId: String, for request: AgentRunRequest) async throws -> CodexAppServerClient.JSONObject {
        onStartTurn?()
        if emitThreadStartedNotification {
            notificationHandler?("thread/started", [
                "thread": [
                    "id": providerThreadId,
                    "sessionId": providerThreadId,
                    "status": ["type": "idle"],
                    "turns": [] as [Any],
                ]
            ])
            onAfterThreadStartedNotification?()
        }
        if terminateOnStartTurn {
            terminationHandler?(CodexAppServerError.processExited(stderrTail: ""))
        }
        lock.lock(); _startedTurns.append(StartedTurn(providerThreadId: providerThreadId, request: request)); lock.unlock()
        if let startTurnError { throw startTurnError }
        return ["turn": ["id": "turn-app-server-1"]]
    }

    func interruptTurn(providerThreadId: String, turnId: String) async throws {}
    func readThread(providerThreadId: String, includeTurns: Bool) async throws -> CodexAppServerClient.JSONObject {
        ["thread": ["id": providerThreadId, "turns": []]]
    }
    func forkThread(providerThreadId: String, lastTurnId: String?) async throws -> String { "child" }
    func rollbackThread(providerThreadId: String, beforeTurnId: String) async throws -> CodexAppServerClient.JSONObject {
        ["thread": ["id": providerThreadId]]
    }
    func updateThreadSettings(providerThreadId: String, permissionMode: AgentPermissionMode) async throws {}
    func stop() { lock.lock(); _didStop = true; lock.unlock() }
}
