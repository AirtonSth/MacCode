import XCTest
import AppKit
import Darwin
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

// UX-XPLAT-DELETE-UNDO: thread delete stays immediate + final (the existing
// contract in AgentAppViewModelTests is unchanged). These tests pin the ADDITIVE
// undo layer: a transient in-memory snapshot lets the user recover an accidental
// delete for a short window without deferring the actual DELETE.
@MainActor
final class AgentThreadDeletionUndoTests: XCTestCase {

    private struct RelationalFingerprint: Equatable {
        var messageIds: [String]
        var runId: String?
        var streamEventKinds: [String]
        var sessionCursor: String?
        var callbackStates: [String]
        var planIds: [String]
        var checkpointIds: [String]
        var queueRows: [String]
        var providerLogIds: [String]
        var draft: String?
    }

    private final class DeletionRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        let finishDelayNanoseconds: UInt64?

        init(finishDelayNanoseconds: UInt64?) {
            self.finishDelayNanoseconds = finishDelayNanoseconds
        }

        func listModels() async -> [AgentModelDescriptor] { [] }

        func startRun(
            _ request: AgentRunRequest,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) async throws -> AgentRunHandle {
            onEvent(.status(.running))
            return AgentRunHandle(runId: request.runId, process: nil) { [finishDelayNanoseconds] in
                guard let finishDelayNanoseconds else { return }
                Task.detached {
                    try? await Task.sleep(nanoseconds: finishDelayNanoseconds)
                    onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: "deletion-runner"))
                }
            }
        }
    }

    private final class RealProcessTreeDeletionRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        private let lock = NSLock()
        private var process: Process?
        private var terminalEmitted = false

        var processTreePIDs: [pid_t] {
            lock.withLock {
                guard let process else { return [] }
                return ProcessTerminator.processTreePIDs(root: process.processIdentifier)
            }
        }

        func listModels() async -> [AgentModelDescriptor] { [] }

        func startRun(
            _ request: AgentRunRequest,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) async throws -> AgentRunHandle {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do sleep 30; done' & wait"
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            lock.withLock { self.process = process }

            let spawnDeadline = Date().addingTimeInterval(2)
            while ProcessTerminator.processTreePIDs(root: process.processIdentifier).count < 2,
                  Date() < spawnDeadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            onEvent(.status(.running))
            return AgentRunHandle(runId: request.runId, process: process) { [weak self] in
                guard let self else { return }
                let shouldEmit = self.lock.withLock { () -> Bool in
                    guard !self.terminalEmitted else { return false }
                    self.terminalEmitted = true
                    return true
                }
                if shouldEmit {
                    onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: "real-process-tree"))
                }
            }
        }

        func forceCleanup() {
            let process = lock.withLock { self.process }
            if let process, process.isRunning {
                ProcessTerminator.terminateTree(process, grace: 0)
            }
        }
    }

    private func makeVM(runner: AgentProviderRunner? = nil) throws -> AgentAppViewModel {
        let tmp = NSTemporaryDirectory() + "rc2-vm-undo-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coord = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                        threadRepo: threadRepo,
                                        providers: [.codex: runner ?? FakeProviderRunner(provider: .codex),
                                                    .claude: FakeProviderRunner(provider: .claude)])
        return AgentAppViewModel(workspaceID: WorkspaceID(), cwd: tmp,
                                 coordinator: coord, threadRepo: threadRepo,
                                 messageRepo: messageRepo,
                                 promptHistoryStore: PromptHistoryStore(db: db))
    }

    // WHY: deleting a thread must remain instant and persisted — but an accidental
    // delete is destructive, so the snapshot must be available to undo. This proves
    // BOTH at once: the row is gone from the store immediately, AND an undo handle exists.
    func test_deleteThread_removesImmediatelyButOffersUndo() async throws {
        let vm = try makeVM()
        vm.createThread(title: "keep")
        let keep = vm.selectedThreadId!
        vm.createThread(title: "doomed")
        let doomed = vm.selectedThreadId!
        let msg = AgentMessage(threadId: doomed, role: .user, content: "important work")
        try vm.messageRepo.append(msg)

        await vm.deleteThread(doomed)

        // Immediate-delete contract: gone from store and from the list right away.
        XCTAssertNil(try vm.threadRepo.get(id: doomed),
                     "delete must remove the row immediately; undo is a separate snapshot, not a deferred delete")
        XCTAssertFalse(vm.threads.contains { $0.id == doomed })
        XCTAssertEqual(vm.selectedThreadId, keep, "selection must fall back to a remaining thread")
        // Additive undo affordance is armed.
        XCTAssertEqual(vm.pendingThreadDeletionUndo?.count, 1,
                       "an accidental delete must leave a recoverable snapshot")
    }

    // WHY: the whole point of undo is data recovery. Restoring must bring back the
    // thread AND its messages (FK-safe: thread row first, then messages).
    func test_undoLastThreadDeletion_restoresThreadAndMessagesWithinWindow() async throws {
        let vm = try makeVM()
        vm.createThread(title: "doomed")
        let doomed = vm.selectedThreadId!
        let m1 = AgentMessage(threadId: doomed, role: .user, content: "first", createdAt: Date(timeIntervalSince1970: 1))
        let m2 = AgentMessage(threadId: doomed, role: .assistant, content: "second", createdAt: Date(timeIntervalSince1970: 2))
        try vm.messageRepo.append(m1)
        try vm.messageRepo.append(m2)

        await vm.deleteThread(doomed)
        XCTAssertNil(try vm.threadRepo.get(id: doomed))
        XCTAssertTrue(((try? vm.messageRepo.list(threadId: doomed)) ?? []).isEmpty,
                      "messages CASCADE-delete with the thread, so undo must re-insert them")

        let restored = vm.undoLastThreadDeletion()

        XCTAssertTrue(restored, "undo within the window must succeed")
        XCTAssertEqual(try vm.threadRepo.get(id: doomed)?.title, "doomed",
                       "the deleted thread row must come back intact")
        let rows = try vm.messageRepo.list(threadId: doomed)
        XCTAssertEqual(rows.map(\.content), ["first", "second"],
                       "all messages must be restored in their original order")
        XCTAssertNil(vm.pendingThreadDeletionUndo, "the snapshot is consumed once undone")
        XCTAssertEqual(vm.selectedThreadId, doomed, "undo must reselect the restored thread")
    }

    func test_deleteAndUndoIncludesTerminalForkIntentWithoutRetainingDeletedTranscript() async throws {
        // WHY: a completed fork intent contains a copy of the source transcript.
        // Deleting that source must remove the copy too, while the existing
        // short undo window must still restore the exact relational graph.
        let vm = try makeVM()
        vm.createThread(title: "fork source")
        let sourceId = try XCTUnwrap(vm.selectedThreadId)
        try vm.messageRepo.append(AgentMessage(
            threadId: sourceId,
            role: .user,
            content: "private source transcript"
        ))
        let source = try XCTUnwrap(vm.threadRepo.get(id: sourceId))
        var child = AgentThread(
            workspaceId: source.workspaceId,
            title: "fork child",
            provider: .codex,
            model: source.model
        )
        let key = "delete-undo-fork-\(child.id.value.uuidString)"
        _ = try vm.threadRepo.prepareForkIntent(
            sourceThreadId: sourceId,
            childThread: child,
            idempotencyKey: key
        )
        _ = try vm.threadRepo.recordForkProviderCreated(
            childThreadId: child.id,
            providerChildThreadId: "provider-child"
        )
        child.providerThreadId = "provider-child"
        child.status = .completed
        try vm.threadRepo.persistForkedChildGraph(
            sourceThreadId: sourceId,
            childThread: child,
            providerSession: nil,
            forkIntentChildThreadId: child.id
        )

        let deleted = await vm.deleteThread(sourceId)
        XCTAssertTrue(deleted)
        XCTAssertNil(try vm.threadRepo.getForkIntent(childThreadId: child.id),
                     "deleted source content must not survive in a detached terminal intent")
        XCTAssertTrue(vm.undoLastThreadDeletion())
        let restored = try XCTUnwrap(vm.threadRepo.getForkIntent(childThreadId: child.id))
        XCTAssertEqual(restored.state, .localCommitted)
        XCTAssertEqual(restored.sourceMessages.map(\.content), ["private source transcript"])
    }

    func test_deleteFailsClosedWhileForkRecoveryNeedsSourceTranscript() async throws {
        // WHY: prepared/provider-created intents are crash-recovery evidence. A
        // delete must not erase them and risk leaking an untracked provider child.
        let vm = try makeVM()
        vm.createThread(title: "fork source")
        let sourceId = try XCTUnwrap(vm.selectedThreadId)
        let source = try XCTUnwrap(vm.threadRepo.get(id: sourceId))
        let child = AgentThread(
            workspaceId: source.workspaceId,
            title: "pending fork child",
            provider: .codex,
            model: source.model
        )
        _ = try vm.threadRepo.prepareForkIntent(
            sourceThreadId: sourceId,
            childThread: child,
            idempotencyKey: "pending-delete-fork-\(child.id.value.uuidString)"
        )

        let deleted = await vm.deleteThread(sourceId)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(try vm.threadRepo.get(id: sourceId))
        XCTAssertEqual(try vm.threadRepo.getForkIntent(childThreadId: child.id)?.state, .prepared)
        XCTAssertNil(vm.pendingThreadDeletionUndo)
    }

    // WHY: undo is a brief safety net, not permanent. After the window lapses the
    // snapshot is dropped and the delete is final — undo must NOT resurrect it.
    func test_undoLastThreadDeletion_isNoOpAfterWindowLapses() async throws {
        let vm = try makeVM()
        var now = Date(timeIntervalSince1970: 1000)
        vm.setClockForTests { now }
        vm.createThread(title: "doomed")
        let doomed = vm.selectedThreadId!

        await vm.deleteThread(doomed)
        XCTAssertNotNil(vm.pendingThreadDeletionUndo)

        // Advance past the 10s window.
        now = now.addingTimeInterval(AgentAppViewModel.threadDeletionUndoWindow + 1)
        let restored = vm.undoLastThreadDeletion()

        XCTAssertFalse(restored, "undo after the window must do nothing")
        XCTAssertNil(try vm.threadRepo.get(id: doomed),
                     "a delete is permanent once the undo window lapses")
        XCTAssertNil(vm.pendingThreadDeletionUndo, "the stale snapshot must be dropped")
    }

    // WHY: bulk delete must be recoverable as a unit — count drives the toast copy
    // and every deleted thread must come back.
    func test_undoLastThreadDeletion_restoresAllThreadsFromBulkDelete() async throws {
        let vm = try makeVM()
        vm.createThread(title: "a")
        let a = vm.selectedThreadId!
        vm.createThread(title: "b")
        let b = vm.selectedThreadId!

        await vm.deleteThreads([a, b])
        XCTAssertEqual(vm.pendingThreadDeletionUndo?.count, 2,
                       "the toast count must reflect every deleted thread")
        XCTAssertNil(try vm.threadRepo.get(id: a))
        XCTAssertNil(try vm.threadRepo.get(id: b))

        XCTAssertTrue(vm.undoLastThreadDeletion())
        XCTAssertNotNil(try vm.threadRepo.get(id: a), "bulk undo must restore every thread")
        XCTAssertNotNil(try vm.threadRepo.get(id: b), "bulk undo must restore every thread")
    }

    // AG-051: a rejected reorder must not change either durable or visible
    // ordering, and mirrors must not receive a success event.
    func test_reorderThread_sqliteFailureRollsBackVisualStateAndLifecycleEvent() throws {
        let vm = try makeVM()
        vm.createThread(title: "first")
        vm.createThread(title: "second")
        let originalOrder = vm.threads.map(\.id)
        let moved = try XCTUnwrap(originalOrder.last)
        let target = try XCTUnwrap(originalOrder.first)
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }
        try vm.threadRepo.db.execute("""
            CREATE TRIGGER reject_thread_reorder
            BEFORE UPDATE ON agent_threads
            BEGIN SELECT RAISE(ABORT, 'simulated read only database'); END;
        """)

        vm.reorderThread(moved, before: target)

        XCTAssertEqual(try vm.threadRepo.list(workspaceId: vm.workspaceID).map(\.id), originalOrder,
                       "a rejected reorder transaction must preserve durable ordering")
        XCTAssertEqual(vm.threads.map(\.id), originalOrder,
                       "a rejected reorder must preserve the visible rail ordering")
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rejected reorder must not publish a phantom reordered event")
        XCTAssertTrue(vm.statusMessage.contains("Could not reorder threads"),
                      "the rejected reorder must fail loud in the visible status channel")
    }

    // AG-051: deletion is destructive, so a failed DELETE must leave the row,
    // selection, and UI caches intact and must not arm a fake Undo.
    func test_deleteThread_sqliteFailureRollsBackVisualStateAndLifecycleEvent() async throws {
        let vm = try makeVM()
        vm.createThread(title: "must survive")
        let id = try XCTUnwrap(vm.selectedThreadId)
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }
        try vm.threadRepo.db.execute("""
            CREATE TRIGGER reject_thread_delete
            BEFORE DELETE ON agent_threads
            BEGIN SELECT RAISE(ABORT, 'simulated disk full'); END;
        """)

        let deleted = await vm.deleteThread(id)
        XCTAssertFalse(deleted)

        XCTAssertNotNil(try vm.threadRepo.get(id: id),
                        "a rejected DELETE must preserve the durable thread graph")
        XCTAssertTrue(vm.threads.contains(where: { $0.id == id }),
                      "a rejected DELETE must keep the thread visible")
        XCTAssertEqual(vm.selectedThreadId, id,
                       "a rejected DELETE must not move selection")
        XCTAssertNil(vm.pendingThreadDeletionUndo,
                     "a failed delete must not offer Undo for a mutation that never happened")
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rejected DELETE must not publish a phantom deleted event")
        XCTAssertTrue(vm.statusMessage.contains("Could not delete thread data"),
                      "the rejected DELETE must fail loud in the visible status channel")
    }

    // AG-051: restore is atomic. If the thread INSERT fails, no partial graph or
    // success event may appear and the still-valid Undo handle must remain.
    func test_undoThreadDeletion_sqliteFailureRollsBackVisualStateAndLifecycleEvent() async throws {
        let vm = try makeVM()
        vm.createThread(title: "restore me")
        let id = try XCTUnwrap(vm.selectedThreadId)
        let deleted = await vm.deleteThread(id)
        XCTAssertTrue(deleted)
        var lifecycleEvents: [AgentThreadLifecycleEvent] = []
        vm.onThreadLifecycle = { lifecycleEvents.append($0) }
        try vm.threadRepo.db.execute("""
            CREATE TRIGGER reject_thread_restore
            BEFORE INSERT ON agent_threads
            BEGIN SELECT RAISE(ABORT, 'simulated read only database'); END;
        """)

        XCTAssertFalse(vm.undoLastThreadDeletion())

        XCTAssertNil(try vm.threadRepo.get(id: id),
                     "a rejected restore transaction must not leave a partial durable graph")
        XCTAssertFalse(vm.threads.contains(where: { $0.id == id }),
                       "a rejected restore must not create a phantom visible thread")
        XCTAssertNotNil(vm.pendingThreadDeletionUndo,
                        "a failed restore must retain the valid Undo handle for a later retry")
        XCTAssertTrue(lifecycleEvents.isEmpty,
                      "a rejected restore must not publish a phantom created event")
        XCTAssertTrue(vm.statusMessage.contains("Could not restore deleted thread data"),
                      "the rejected restore must fail loud in the visible status channel")
    }

    // WHY: delete owns a provider teardown barrier. Cascading the thread row while
    // cancel is still pending loses the only durable handle to that provider work.
    func test_deleteRunningThread_removesDataOnlyAfterTerminationConfirmation() async throws {
        let vm = try makeVM(runner: DeletionRunner(finishDelayNanoseconds: 150_000_000))
        vm.createThread(title: "running")
        let id = vm.selectedThreadId!
        _ = try await vm.coordinator.startRun(AgentRunRequest(
            threadId: id,
            provider: .codex,
            model: "fake-model",
            cwd: NSTemporaryDirectory(),
            prompt: "long task"
        ))

        let deletion = Task { await vm.deleteThread(id) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(try vm.threadRepo.get(id: id),
                        "thread data must remain while provider termination is still pending")

        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        XCTAssertNil(try vm.threadRepo.get(id: id),
                     "thread data may disappear only after the termination barrier succeeds")
    }

    func test_deleteRunningThreadWaitsForRealRootAndChildDeathBeforeCascade() async throws {
        let runner = RealProcessTreeDeletionRunner()
        defer { runner.forceCleanup() }
        let vm = try makeVM(runner: runner)
        vm.coordinator.gracefulStopTimeout = 0.08
        vm.coordinator.hardStopTimeout = 2
        vm.createThread(title: "real process tree")
        let id = try XCTUnwrap(vm.selectedThreadId)
        _ = try await vm.coordinator.startRun(AgentRunRequest(
            threadId: id,
            provider: .codex,
            model: "fake-model",
            cwd: NSTemporaryDirectory(),
            prompt: "spawn real child"
        ))
        let ownedPIDs = runner.processTreePIDs
        XCTAssertGreaterThanOrEqual(ownedPIDs.count, 2,
                                    "sanity: the provider handle must own a real root and descendant")

        let deletion = Task { await vm.deleteThread(id) }
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertNotNil(try vm.threadRepo.get(id: id),
                        "an early provider terminal callback must not cascade data while an owned PID is alive")
        XCTAssertTrue(ownedPIDs.contains { Darwin.kill($0, 0) == 0 },
                      "sanity: at least one owned process must still be alive before hard escalation")

        let deleted = await deletion.value
        XCTAssertTrue(deleted)
        let deathDeadline = Date().addingTimeInterval(2)
        while ownedPIDs.contains(where: { Darwin.kill($0, 0) == 0 }), Date() < deathDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(ownedPIDs.allSatisfy { Darwin.kill($0, 0) != 0 && errno == ESRCH },
                      "delete may return only after the provider root and every captured descendant are dead")
        XCTAssertNil(try vm.threadRepo.get(id: id),
                     "the cascade may commit after the real process tree is gone")
    }

    // WHY: a hard-timeout is not permission to orphan provider work. The row and
    // caches remain intact so the user can retry and sees a recoverable error.
    func test_deleteRunningThread_whenTerminationTimesOut_preservesDataAndShowsError() async throws {
        let vm = try makeVM(runner: DeletionRunner(finishDelayNanoseconds: nil))
        vm.coordinator.gracefulStopTimeout = 0.05
        vm.coordinator.hardStopTimeout = 0.15
        vm.createThread(title: "stuck")
        let id = vm.selectedThreadId!
        _ = try await vm.coordinator.startRun(AgentRunRequest(
            threadId: id,
            provider: .codex,
            model: "fake-model",
            cwd: NSTemporaryDirectory(),
            prompt: "never exits"
        ))

        let deleted = await vm.deleteThread(id)
        XCTAssertFalse(deleted)
        XCTAssertNotNil(try vm.threadRepo.get(id: id),
                        "failed termination must preserve the thread and its cascaded data")
        XCTAssertTrue(vm.timeline.error?.contains("provider is still running") == true,
                      "the failed delete must surface a visible retryable error")
    }

    // AG-045: undo must restore the entire thread-owned relational graph. A
    // messages-only snapshot silently loses replay, provider resume state,
    // callbacks, plans, checkpoints, queued work, diagnostics, and drafts.
    func test_deleteUndo_roundTripsCompleteThreadRelationalGraphAtomically() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-undo-graph-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let attachmentRoot = URL(fileURLWithPath: tmp)
            .appendingPathComponent("agent-attachments", isDirectory: true)
        let attachmentStore = AgentAttachmentStore(root: attachmentRoot)
        let attachmentSource = URL(fileURLWithPath: tmp).appendingPathComponent("undo-attachment.txt")
        try Data("keep-attachment".utf8).write(to: attachmentSource)
        let attachment = try attachmentStore.stage(path: attachmentSource.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: attachment.path
        )
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let callbackRepo = ProviderPendingCallbackRepository(db: db)
        let planRepo = AgentProposedPlanRepository(db: db)
        let checkpointRepo = AgentTurnCheckpointRepository(db: db)
        let queueRepo = AgentQueuedMessageRepository(db: db)
        let draftRepo = AgentThreadDraftRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            checkpointRepo: checkpointRepo,
            providers: [.codex: FakeProviderRunner(provider: .codex)]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: tmp,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: draftRepo,
            queuedMessageRepo: queueRepo,
            pendingCallbackRepo: callbackRepo,
            proposedPlanRepo: planRepo,
            checkpointRepo: checkpointRepo
        )

        var thread = AgentThread(title: "graph", provider: .codex, model: "gpt-5.5")
        thread.status = .completed
        try threadRepo.upsert(thread)
        let message = AgentMessage(
            threadId: thread.id,
            role: .user,
            content: "keep-message",
            attachments: [attachment]
        )
        try messageRepo.append(message)
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "gpt-5.5", status: .completed)
        try runRepo.upsert(run)
        let streamEvent = AssistantEvent.error(message: "keep-stream", recoverable: true)
        let streamJSON = String(decoding: try JSONEncoder().encode(streamEvent), as: UTF8.self)
        try runRepo.appendStreamEvent(runId: run.id, seq: 7, kind: streamEvent.debugDescription, payloadJSON: streamJSON)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .completed,
            resumeCursor: "resume-cursor"
        ))
        try callbackRepo.record(threadId: thread.id, request: AssistantPendingRequest(
            id: "approval-graph",
            turnId: "turn-graph",
            kind: .commandExecution,
            title: "Keep callback",
            state: .stale,
            createdAtMs: 1
        ))
        try planRepo.upsert(
            threadId: thread.id,
            plan: AssistantProposedPlan(id: "plan-graph", turnId: "turn-graph", markdown: "Keep plan")
        )
        try checkpointRepo.upsert(AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: run.id,
            turnId: "turn-graph",
            checkpointTurnCount: 1,
            checkpointRef: "checkpoint-graph",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "Keep.swift", kind: "modified", additions: 1, deletions: 0)]
        ))
        let queued = try queueRepo.enqueue(
            threadId: thread.id,
            text: "keep-queue",
            attachments: [],
            interactionMode: .plan
        )
        let providerEvent = ProviderRuntimeEvent(
            id: "provider-log-graph",
            provider: .codex,
            source: "codex.app-server",
            method: "item/completed",
            providerTurnId: "turn-graph",
            payloadJSON: #"{"keep":true}"#,
            receivedAtMs: 2
        )
        try runRepo.appendProviderEventLog(threadId: thread.id, runId: run.id, event: providerEvent)
        try draftRepo.upsert(AgentThreadDraft(
            threadId: thread.id,
            providerInstanceId: "codex",
            text: "keep-draft",
            interactionMode: .plan
        ))

        func fingerprint() throws -> RelationalFingerprint {
            let callback = try callbackRepo.get(threadId: thread.id, requestId: "approval-graph", kind: .approval)
            return RelationalFingerprint(
                messageIds: try messageRepo.list(threadId: thread.id).map { $0.id.value.uuidString },
                runId: try runRepo.get(id: run.id)?.id.value.uuidString,
                streamEventKinds: try runRepo.listLatestStreamEvents(threadId: thread.id, strictDecoding: true).map(\.debugDescription),
                sessionCursor: try sessionRepo.get(threadId: thread.id)?.resumeCursor,
                callbackStates: callback.map { ["\($0.requestId):\($0.state.rawValue)"] } ?? [],
                planIds: try planRepo.list(threadId: thread.id).map { $0.plan.id },
                checkpointIds: try checkpointRepo.list(threadId: thread.id).map(\.checkpointRef),
                queueRows: try queueRepo.list(threadId: thread.id).map { "\($0.id.value.uuidString):\($0.position):\($0.text)" },
                providerLogIds: try runRepo.listLatestProviderEventLogs(threadId: thread.id).map(\.id),
                draft: try draftRepo.get(threadId: thread.id)?.text
            )
        }

        vm.reloadThreads()
        vm.selectThread(thread.id)
        let before = try fingerprint()
        let deleted = await vm.deleteThread(thread.id)
        XCTAssertTrue(deleted)
        XCTAssertNil(try threadRepo.get(id: thread.id), "deleted thread must disappear from live repository reads")
        let cleanup = try LocalStorageBudgetManager(
            db: db,
            attachmentRoot: attachmentRoot
        ).cleanupExpired(now: Date(), compact: false)
        XCTAssertEqual(cleanup.removedRows[.attachmentBlobs], 0,
                       "the durable undo pin must keep deleted-message attachments visible to GC")
        XCTAssertNoThrow(try attachmentStore.validatedForRetry(attachment),
                         "cleanup inside the undo window must preserve the recoverable attachment")
        XCTAssertTrue(vm.undoLastThreadDeletion())

        XCTAssertEqual(try fingerprint(), before,
                       "undo must restore every thread-owned relation with original ids, ordering, cursor, and payloads")
        XCTAssertNoThrow(try attachmentStore.validatedForRetry(attachment),
                         "the restored message must retain its managed attachment")
        XCTAssertEqual(try queueRepo.list(threadId: thread.id).first?.id, queued.id,
                       "queued message identity must survive delete+undo")
    }

    // MARK: pure seam

    // WHY: the expiry predicate is the contract for "how long can I undo" and must
    // be exact at the boundary so the window is neither too short nor unbounded.
    func test_isWithinUndoWindow_boundaryIsExclusive() {
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(AgentAppViewModel.ThreadDeletionUndo.isWithinUndoWindow(
            capturedAt: t0, now: t0, window: 10), "the instant of delete is inside the window")
        XCTAssertTrue(AgentAppViewModel.ThreadDeletionUndo.isWithinUndoWindow(
            capturedAt: t0, now: t0.addingTimeInterval(9.999), window: 10))
        XCTAssertFalse(AgentAppViewModel.ThreadDeletionUndo.isWithinUndoWindow(
            capturedAt: t0, now: t0.addingTimeInterval(10), window: 10),
            "at exactly the window the snapshot has expired")
    }

    // WHY: agent_messages has a thread_id FK with ON DELETE CASCADE under
    // foreign_keys=ON. Re-inserting a message before its parent thread row would
    // violate the FK, so the restore plan must order the thread first and messages
    // oldest→newest. This test guards against the historical FK-breakage regression.
    func test_restorePlan_ordersMessagesOldestFirstForFKSafeReinsert() {
        let threadId = AgentThreadID()
        let thread = AgentThread(id: threadId, workspaceId: WorkspaceID(), title: "t", provider: .codex, model: "gpt-5.5")
        let older = AgentMessage(threadId: threadId, role: .user, content: "older", createdAt: Date(timeIntervalSince1970: 1))
        let newer = AgentMessage(threadId: threadId, role: .assistant, content: "newer", createdAt: Date(timeIntervalSince1970: 5))
        let snapshot = AgentAppViewModel.ThreadDeletionUndo.ThreadSnapshot(thread: thread, messages: [newer, older])

        let plan = AgentAppViewModel.ThreadDeletionUndo.restorePlan(for: snapshot)

        XCTAssertEqual(plan.thread.id, threadId, "the parent thread must be the restore anchor")
        XCTAssertEqual(plan.messagesInAppendOrder.map(\.content), ["older", "newer"],
                       "messages must re-append oldest→newest so FK + display order survive")
    }
}
