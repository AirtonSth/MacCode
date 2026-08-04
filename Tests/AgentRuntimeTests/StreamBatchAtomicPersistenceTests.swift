import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class StreamBatchAtomicPersistenceTests: XCTestCase {
    func test_partialBatchFailureRollsBackAndRetryPersistsEveryEventExactlyOnce() async throws {
        let fixture = try await makeFixture(name: "partial")
        defer { fixture.cleanup() }

        try fixture.db.execute("""
            CREATE TRIGGER fail_third_stream_event
            BEFORE INSERT ON agent_stream_events
            WHEN NEW.seq = 3
            BEGIN
                SELECT RAISE(ABORT, 'forced partial batch failure');
            END;
            """)

        fixture.runner.emitItemStarts(count: 16)

        XCTAssertEqual(
            try persistedSequences(db: fixture.db, runId: fixture.runId),
            [],
            "a failed stream batch must roll back earlier rows instead of exposing a durable prefix"
        )

        try fixture.db.execute("DROP TRIGGER fail_third_stream_event;")
        let replay = try fixture.coordinator.withMirrorEventSnapshot(threadId: fixture.thread.id) { $0 }

        XCTAssertEqual(itemStartIDs(replay), (1...16).map { "item-\($0)" })
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), Array(1...16))

        _ = try fixture.coordinator.withMirrorEventSnapshot(threadId: fixture.thread.id) { $0 }
        XCTAssertEqual(
            try persistedSequences(db: fixture.db, runId: fixture.runId),
            Array(1...16),
            "retrying the durability barrier must not duplicate an already committed batch"
        )
    }

    func test_sqliteBusyBeyondTimeoutRetainsBatchForOrderedExactlyOnceRetry() async throws {
        let fixture = try await makeFixture(name: "busy")
        defer { fixture.cleanup() }
        let locker = try SQLiteDB(path: fixture.databasePath)
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let writerLock = Task.detached {
            try locker.transaction {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 1), .success)

        let emit = Task.detached {
            fixture.runner.emitItemStarts(count: 16)
        }
        await emit.value

        XCTAssertEqual(
            try persistedSequences(db: fixture.db, runId: fixture.runId),
            [],
            "a writer lock held beyond SQLite's busy timeout must leave the complete batch pending"
        )

        releaseLock.signal()
        try await writerLock.value
        let replay = try fixture.coordinator.withMirrorEventSnapshot(threadId: fixture.thread.id) { $0 }

        XCTAssertEqual(itemStartIDs(replay), (1...16).map { "item-\($0)" })
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), Array(1...16))

        _ = try fixture.coordinator.withMirrorEventSnapshot(threadId: fixture.thread.id) { $0 }
        XCTAssertEqual(
            try persistedSequences(db: fixture.db, runId: fixture.runId),
            Array(1...16),
            "a successful retry after SQLITE_BUSY must persist each sequence exactly once"
        )
    }

    func test_providerTerminalWaitsForBusyRetryAndCommitsEventsAndTerminalStateTogether() async throws {
        let fixture = try await makeFixture(name: "busy-terminal")
        defer { fixture.cleanup() }
        fixture.runner.emitItemStarts(count: 1)
        let locker = try SQLiteDB(path: fixture.databasePath)
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let writerLock = Task.detached {
            try locker.transaction {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 1), .success)

        let finishReturned = DispatchSemaphore(value: 0)
        let finish = Task.detached {
            fixture.runner.finishCompleted()
            finishReturned.signal()
        }
        try await Task.sleep(nanoseconds: 5_200_000_000)
        XCTAssertEqual(finishReturned.wait(timeout: .now() + 0.1), .timedOut,
                       "provider completion must not publish terminal state after the first SQLITE_BUSY timeout while its event batch is still pending")

        releaseLock.signal()
        try await writerLock.value
        await finish.value

        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), [1],
                       "the retrying terminal barrier must commit the buffered provider event exactly once")
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.completed.rawValue)
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.completed.rawValue)
    }

    func test_providerTerminalRemainsPendingWhenWriterLockOutlivesEveryImmediateRetry() async throws {
        let fixture = try await makeFixture(name: "busy-terminal-long")
        defer { fixture.cleanup() }
        try fixture.db.execute("PRAGMA busy_timeout=50;")
        fixture.runner.emitItemStarts(count: 1)
        let finishBox = TerminalFinishBox()
        fixture.coordinator.onRunFinished = { _, _, _ in finishBox.record() }

        let locker = try SQLiteDB(path: fixture.databasePath)
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let writerLock = Task.detached {
            try locker.transaction {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 1), .success)

        fixture.runner.finishCompleted()
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(finishBox.count, 0,
                       "terminal publication must remain pending after every immediate SQLITE_BUSY retry while the stream batch is uncommitted")
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.running.rawValue)
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), [])

        releaseLock.signal()
        try await writerLock.value
        let deadline = Date().addingTimeInterval(3)
        while finishBox.count == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(finishBox.count, 1,
                       "the retained terminal event must publish exactly once after the durability barrier commits")
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), [1])
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.completed.rawValue)
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.completed.rawValue)
    }

    func test_stopCannotOvertakeTerminalWaitingForDurabilityBarrier() async throws {
        let fixture = try await makeFixture(name: "busy-terminal-stop")
        defer { fixture.cleanup() }
        try fixture.db.execute("PRAGMA busy_timeout=50;")
        fixture.runner.emitItemStarts(count: 1)
        let finishBox = TerminalFinishBox()
        fixture.coordinator.onRunFinished = { _, _, status in finishBox.record(status) }

        let locker = try SQLiteDB(path: fixture.databasePath)
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let writerLock = Task.detached {
            try locker.transaction {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 1), .success)

        fixture.runner.finishCompleted()
        try await Task.sleep(nanoseconds: 300_000_000)
        fixture.coordinator.stopRun(threadId: fixture.thread.id)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(finishBox.statuses, [],
                       "Stop must not publish cancellation while the provider terminal waits for its stream commit")
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.running.rawValue)
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.running.rawValue)
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), [])

        releaseLock.signal()
        try await writerLock.value
        let deadline = Date().addingTimeInterval(3)
        while finishBox.statuses.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(finishBox.statuses, [.completed],
                       "the original provider terminal must win exactly once after the stream commit")
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), [1])
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.completed.rawValue)
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.completed.rawValue)
    }

    func test_failedStopFlushDoesNotReuseSeq1ForLateProviderRuntimeAndAllowsNextStart() async throws {
        // WHY: stop used to clear seq[runId] even when flushPendingStreamWrites
        // failed and the pending batch was retained. A late Grok ACP notification
        // (prompt_complete after servers_updated) then reissued seq 1 with a
        // different kind. persistStreamEventIdempotently rejected the conflict and
        // the user's next message failed with "Failed to start".
        let fixture = try await makeFixture(name: "seq-reuse-after-stop")
        defer { fixture.cleanup() }
        try fixture.db.execute("PRAGMA busy_timeout=50;")

        fixture.runner.emitProviderRuntime(method: "_x.ai/mcp/servers_updated")

        let locker = try SQLiteDB(path: fixture.databasePath)
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let writerLock = Task.detached {
            try locker.transaction {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 1), .success)

        fixture.coordinator.stopRun(threadId: fixture.thread.id)
        // Late provider notification after stop ownership was torn down but while
        // the failed flush still owns a retryable batch for the same runId.
        fixture.runner.emitProviderRuntime(method: "_x.ai/session/prompt_complete")
        try await Task.sleep(nanoseconds: 150_000_000)

        releaseLock.signal()
        try await writerLock.value

        let deadline = Date().addingTimeInterval(3)
        var sequences: [Int] = []
        while Date() < deadline {
            sequences = try persistedSequences(db: fixture.db, runId: fixture.runId)
            if sequences.count >= 2 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            sequences,
            [1, 2],
            "late post-stop events must continue the stream sequence instead of colliding on seq 1"
        )
        let kinds = try persistedKinds(db: fixture.db, runId: fixture.runId)
        XCTAssertEqual(kinds.count, 2)
        XCTAssertNotEqual(kinds[0], kinds[1], "seq 1 and seq 2 must retain distinct event identities")

        // The next user turn must not be blocked by a conflicting prior batch.
        let secondRunId = try await fixture.coordinator.startRun(AgentRunRequest(
            threadId: fixture.thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: fixture.root.path,
            prompt: "second user message after stream conflict regression"
        ))
        XCTAssertNotEqual(secondRunId, fixture.runId)
        fixture.runner.finishCompleted()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(
            try persistedStatus(db: fixture.db, table: "agent_runs", id: secondRunId.value.uuidString),
            AgentRunStatus.completed.rawValue,
            "second start must complete after the prior run's stream identities stayed consistent"
        )
    }

    func test_lateTurnStartedAfterFinishDoesNotCollideWithServersUpdatedAtSeq1() async throws {
        // WHY: Grok often persists `_x.ai/mcp/servers_updated` as seq 1 before
        // turnStarted. After a successful finish cleared seq[runId], a spurious
        // post-finish turnStarted reallocated seq 1 and hit:
        // Conflicting stream event identity (... existing servers_updated, retry turnStarted).
        let fixture = try await makeFixture(name: "seq-reuse-after-finish-turnstarted")
        defer { fixture.cleanup() }
        let finishBox = TerminalFinishBox()
        let issueBox = PersistenceIssueBox()
        fixture.coordinator.onRunFinished = { _, _, status in finishBox.record(status) }
        fixture.coordinator.onPersistenceIssue = { message, _, _ in issueBox.record(message) }

        fixture.runner.emitProviderRuntime(method: "_x.ai/mcp/servers_updated")
        fixture.runner.emitTurnStarted(turnId: "turn-live")
        // Force batch commit before finish so seq 1 is durable (time/count cadence alone may not fire).
        _ = try fixture.coordinator.withMirrorEventSnapshot(threadId: fixture.thread.id) { $0 }

        let kindsBeforeFinish = try persistedKinds(db: fixture.db, runId: fixture.runId)
        XCTAssertTrue(kindsBeforeFinish.contains { $0.contains("servers_updated") },
                      "precondition: servers_updated must occupy an early durable seq")
        XCTAssertTrue(kindsBeforeFinish.contains { $0.hasPrefix("turnStarted") },
                      "precondition: live turnStarted must also be durable")
        let seq1Before = try persistedKind(db: fixture.db, runId: fixture.runId, seq: 1)
        XCTAssertTrue(seq1Before?.contains("servers_updated") == true,
                      "precondition: seq 1 must be servers_updated for this regression (got \(seq1Before ?? "nil"))")

        fixture.runner.finishCompleted()
        await waitForTerminal(finishBox)
        XCTAssertEqual(finishBox.statuses, [.completed])

        // Simulate a post-finish ensureTurn reopen / late mapper event on the same run.
        fixture.runner.emitTurnStarted(turnId: "turn-spurious-after-finish")
        // Force the durability barrier so a buffered late event is committed or rejected.
        _ = try fixture.coordinator.withMirrorEventSnapshot(threadId: fixture.thread.id) { $0 }

        let issues = issueBox.messages
        XCTAssertFalse(
            issues.contains { $0.contains("Conflicting stream event identity") },
            "late turnStarted after finish must not collide with durable seq 1: \(issues)"
        )
        let seq1After = try persistedKind(db: fixture.db, runId: fixture.runId, seq: 1)
        XCTAssertEqual(
            seq1After, seq1Before,
            "seq 1 identity must stay exactly as committed before finish (no late turnStarted steal)"
        )
        let sequences = try persistedSequences(db: fixture.db, runId: fixture.runId)
        XCTAssertEqual(sequences, Array(1...sequences.count),
                       "stream sequences must remain contiguous without holes from a failed conflict")
    }

    func test_stopFirstWaitsForDurabilityBarrierAndPublishesCancellationExactlyOnce() async throws {
        let fixture = try await makeFixture(name: "busy-stop-first")
        defer { fixture.cleanup() }
        try fixture.db.execute("PRAGMA busy_timeout=50;")
        fixture.runner.emitItemStarts(count: 1)
        let finishBox = TerminalFinishBox()
        fixture.coordinator.onRunFinished = { _, _, status in finishBox.record(status) }

        let locker = try SQLiteDB(path: fixture.databasePath)
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let writerLock = Task.detached {
            try locker.transaction {
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 1), .success)

        fixture.coordinator.stopRun(threadId: fixture.thread.id)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(finishBox.statuses, [],
                       "a user Stop must not publish cancellation before its buffered provider events are durable")
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.running.rawValue)
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.running.rawValue)
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), [])

        releaseLock.signal()
        try await writerLock.value
        let deadline = Date().addingTimeInterval(3)
        while finishBox.statuses.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(finishBox.statuses, [.cancelled],
                       "the retained Stop terminal must publish exactly once after its stream tail commits")
        XCTAssertEqual(try persistedSequences(db: fixture.db, runId: fixture.runId), [1])
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.cancelled.rawValue)
        XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.cancelled.rawValue)
    }

    func test_terminalGraphFailureAtEveryRequiredWriteRollsBackAndRetriesExactlyOnce() async throws {
        let faultStages: [(name: String, operation: String, table: String, condition: String)] = [
            ("assistant", "INSERT", "agent_messages", "NEW.role = 'assistant'"),
            ("run", "UPDATE", "agent_runs", "NEW.status = 'completed'"),
            ("thread", "UPDATE", "agent_threads", "NEW.status = 'completed'"),
            ("session", "UPDATE", "provider_session_runtime", "NEW.status = 'completed'")
        ]

        for stage in faultStages {
            let fixture = try await makeFixture(name: "terminal-graph-\(stage.name)")
            defer { fixture.cleanup() }
            let finishBox = TerminalFinishBox()
            let messageBox = AppendedMessageBox()
            fixture.coordinator.onRunFinished = { _, _, status in finishBox.record(status) }
            fixture.coordinator.onMessageAppended = { message in messageBox.record(message) }

            try fixture.db.execute("""
                CREATE TRIGGER fail_terminal_\(stage.name)
                BEFORE \(stage.operation) ON \(stage.table)
                WHEN \(stage.condition)
                BEGIN
                    SELECT RAISE(ABORT, 'forced terminal \(stage.name) failure');
                END;
            """)

            fixture.runner.finishCompleted()
            try await Task.sleep(nanoseconds: 150_000_000)

            XCTAssertEqual(finishBox.count, 0,
                           "\(stage.name): terminal fanout must wait for the complete graph")
            XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.running.rawValue)
            XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.running.rawValue)
            XCTAssertEqual(try fixture.sessionRepo.get(threadId: fixture.thread.id)?.status, .running)
            XCTAssertTrue(try fixture.messageRepo.list(threadId: fixture.thread.id).filter { $0.role == .assistant }.isEmpty,
                          "\(stage.name): no assistant row may escape a rolled-back terminal graph")
            XCTAssertEqual(messageBox.assistantMessages.count, 0,
                           "\(stage.name): an uncommitted assistant must not publish")

            try fixture.db.execute("DROP TRIGGER fail_terminal_\(stage.name);")
            await waitForTerminal(finishBox)

            XCTAssertEqual(finishBox.statuses, [.completed],
                           "\(stage.name): the retained terminal must fan out once after retry")
            XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_runs", id: fixture.runId.value.uuidString), AgentRunStatus.completed.rawValue)
            XCTAssertEqual(try persistedStatus(db: fixture.db, table: "agent_threads", id: fixture.thread.id.value.uuidString), AgentRunStatus.completed.rawValue)
            XCTAssertEqual(try fixture.sessionRepo.get(threadId: fixture.thread.id)?.status, .completed)
            XCTAssertEqual(try fixture.messageRepo.list(threadId: fixture.thread.id).filter { $0.role == .assistant && $0.content == "done" }.count, 1,
                           "\(stage.name): retry must persist the final assistant exactly once")
            XCTAssertEqual(messageBox.assistantMessages.filter { $0.content == "done" }.count, 1)
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(finishBox.count, 1,
                           "\(stage.name): a stale retry must not duplicate terminal fanout")
        }
    }

    func test_identicalFinalRepliesFromDistinctRunsRemainDistinctMessages() async throws {
        let fixture = try await makeFixture(name: "terminal-identical-replies")
        defer { fixture.cleanup() }
        let finishBox = TerminalFinishBox()
        fixture.coordinator.onRunFinished = { _, _, status in finishBox.record(status) }

        fixture.runner.finishCompleted()
        await waitForTerminal(finishBox)

        _ = try await fixture.coordinator.startRun(AgentRunRequest(
            threadId: fixture.thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: fixture.root.path,
            prompt: "return the same final reply again"
        ))
        fixture.runner.finishCompleted()
        let deadline = Date().addingTimeInterval(3)
        while finishBox.count < 2, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        let replies = try fixture.messageRepo.list(threadId: fixture.thread.id)
            .filter { $0.role == .assistant && $0.content == "done" }
        XCTAssertEqual(replies.count, 2,
                       "content equality across distinct runs is legitimate and must not be deduplicated")
        XCTAssertEqual(Set(replies.map(\.id)).count, 2,
                       "each run intent owns a distinct deterministic assistant identity")
        XCTAssertEqual(finishBox.statuses, [.completed, .completed])
    }

    func test_failedTurnCompletedAssistantAppendDoesNotPoisonTerminalRetryMemo() async throws {
        let fixture = try await makeFixture(name: "terminal-assistant-memo")
        defer { fixture.cleanup() }
        let finishBox = TerminalFinishBox()
        let messageBox = AppendedMessageBox()
        fixture.coordinator.onRunFinished = { _, _, status in finishBox.record(status) }
        fixture.coordinator.onMessageAppended = { message in messageBox.record(message) }

        try fixture.db.execute("""
            CREATE TRIGGER fail_turn_completed_assistant
            BEFORE INSERT ON agent_messages
            WHEN NEW.role = 'assistant'
            BEGIN
                SELECT RAISE(ABORT, 'forced turn-completed assistant failure');
            END;
        """)
        fixture.runner.emitTurnCompleted(finalMessage: "done")

        XCTAssertTrue(try fixture.messageRepo.list(threadId: fixture.thread.id).filter { $0.role == .assistant }.isEmpty)
        XCTAssertTrue(messageBox.assistantMessages.isEmpty,
                      "an assistant append that did not commit must not publish or seed successful dedup state")

        try fixture.db.execute("DROP TRIGGER fail_turn_completed_assistant;")
        fixture.runner.finishCompleted()
        await waitForTerminal(finishBox)

        XCTAssertEqual(try fixture.messageRepo.list(threadId: fixture.thread.id).filter { $0.role == .assistant && $0.content == "done" }.count, 1,
                       "terminal commit must retry the same final text after the earlier append failure")
        XCTAssertEqual(messageBox.assistantMessages.filter { $0.content == "done" }.count, 1)
        XCTAssertEqual(finishBox.statuses, [.completed])
    }

    func test_startFailureGraphFailureAtEveryWriteRetriesBeforeOneLedgeredPresentation() async throws {
        let faultStages: [(name: String, operation: String, table: String, condition: String)] = [
            ("run", "UPDATE", "agent_runs", "NEW.status = 'failed'"),
            ("thread", "UPDATE", "agent_threads", "NEW.status = 'failed'"),
            ("session", "UPDATE", "provider_session_runtime", "NEW.status = 'failed'"),
            ("event", "INSERT", "agent_stream_events", "NEW.event_kind LIKE 'error%'")
        ]

        for stage in faultStages {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("rc-start-failure-graph-\(stage.name)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let db = try SQLiteDB(path: root.appendingPathComponent("remotecode.sqlite").path)
            try Schema.migrate(db)
            let threadRepo = AgentThreadRepository(db: db)
            let messageRepo = AgentMessageRepository(db: db)
            let runRepo = AgentRunRepository(db: db)
            let sessionRepo = ProviderSessionRuntimeRepository(db: db)
            let thread = AgentThread(title: "start failure graph", provider: .codex, model: "fake-model")
            try threadRepo.upsert(thread)
            let ledger = TerminalTransitionLedger(
                directory: root.appendingPathComponent("diagnostics")
            )
            let runner = FailingStreamBatchStartRunner()
            let coordinator = AgentRunCoordinator(
                runRepo: runRepo,
                messageRepo: messageRepo,
                threadRepo: threadRepo,
                providerSessionRepo: sessionRepo,
                providers: [.codex: runner],
                terminalTransitionLedger: ledger
            )
            let finishBox = TerminalFinishBox()
            let eventBox = AssistantEventBox()
            let presentationBox = StartFailurePresentationBox()
            coordinator.onRunFinished = { _, _, status in
                presentationBox.record("finish", ledgerRecordCount: (try? ledger.allRecords().count) ?? -1)
                finishBox.record(status)
            }
            coordinator.onAssistantEvent = { event, _, _ in
                presentationBox.record("event", ledgerRecordCount: (try? ledger.allRecords().count) ?? -1)
                eventBox.record(event)
            }
            let runId = AgentRunID()

            try db.execute("""
                CREATE TRIGGER fail_start_\(stage.name)
                BEFORE \(stage.operation) ON \(stage.table)
                WHEN \(stage.condition)
                BEGIN
                    SELECT RAISE(ABORT, 'forced start \(stage.name) failure');
                END;
            """)

            do {
                _ = try await coordinator.startRun(AgentRunRequest(
                    runId: runId,
                    threadId: thread.id,
                    provider: .codex,
                    model: "fake-model",
                    cwd: root.path,
                    prompt: "fail before accepting the turn"
                ))
                XCTFail("the provider must reject start")
            } catch {
                // Expected provider rejection. The durable transition retries below.
            }
            // The trigger remains active across three 100 ms retry slots.
            try await Task.sleep(nanoseconds: 350_000_000)

            XCTAssertEqual(finishBox.count, 0,
                           "\(stage.name): failed start must not drain/fan out before commit")
            XCTAssertEqual(eventBox.errorCount, 0,
                           "\(stage.name): failed start error must not publish before its snapshot row commits")
            XCTAssertEqual(try runRepo.get(id: runId)?.status, .pending,
                           "provider rejection before a handle exists must retain the pre-start state")
            XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .pending)
            XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.status, .pending)
            XCTAssertEqual(try runRepo.countStreamEvents(threadId: thread.id), 0)
            XCTAssertTrue(
                try ledger.records(forRunId: runId.value.uuidString).isEmpty,
                "\(stage.name): failed start retries must not append a ledger row before the graph commits"
            )
            do {
                _ = try await coordinator.startRun(AgentRunRequest(
                    threadId: thread.id,
                    provider: .codex,
                    model: "fake-model",
                    cwd: root.path,
                    prompt: "must not overtake retained failure"
                ))
                XCTFail("a second provider start must remain gated by the retained terminal intent")
            } catch {
                // Expected durability gate. The provider must not be called again.
            }
            XCTAssertEqual(runner.startCount, 1,
                           "\(stage.name): no second provider start/queue drain may overtake the uncommitted failure graph")

            try db.execute("DROP TRIGGER fail_start_\(stage.name);")
            await waitForTerminal(finishBox)

            XCTAssertEqual(finishBox.statuses, [.failed])
            XCTAssertEqual(eventBox.errorCount, 1)
            XCTAssertEqual(try runRepo.get(id: runId)?.status, .failed)
            XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .failed)
            XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.status, .failed)
            XCTAssertEqual(try runRepo.countStreamEvents(threadId: thread.id), 1)
            let records = try ledger.records(forRunId: runId.value.uuidString)
            XCTAssertEqual(records.count, 1)
            let record = try XCTUnwrap(records.first)
            let commitTime = try XCTUnwrap(record.commitTime)
            let presentTime = try XCTUnwrap(record.presentTime)
            XCTAssertEqual(record.reason, .providerStartFailure)
            XCTAssertEqual(record.initiator, .providerStartFailure)
            XCTAssertEqual(record.requestedStatus, AgentRunStatus.failed.rawValue)
            XCTAssertLessThanOrEqual(record.eventTime, commitTime)
            XCTAssertLessThanOrEqual(commitTime, presentTime)
            XCTAssertEqual(
                presentationBox.observations,
                [
                    StartFailurePresentationBox.Observation(phase: "event", ledgerRecordCount: 1),
                    StartFailurePresentationBox.Observation(phase: "finish", ledgerRecordCount: 1)
                ],
                "\(stage.name): the committed ledger row must exist before each first presentation callback"
            )
            try await Task.sleep(nanoseconds: 250_000_000)
            XCTAssertEqual(finishBox.count, 1,
                           "\(stage.name): a committed start failure must not fan out twice")
            XCTAssertEqual(eventBox.errorCount, 1)
            XCTAssertEqual(try ledger.records(forRunId: runId.value.uuidString).count, 1,
                           "\(stage.name): later retry turns must not append a duplicate ledger row")
        }
    }

    private func waitForTerminal(_ box: TerminalFinishBox, timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while box.count == 0, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeFixture(name: String) async throws -> Fixture {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-stream-batch-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databasePath = root.appendingPathComponent("remotecode.sqlite").path
        let db = try SQLiteDB(path: databasePath)
        try Schema.migrate(db)
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let thread = AgentThread(title: "atomic stream", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = ControlledStreamBatchRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: root.path,
            prompt: "exercise atomic stream persistence"
        ))
        return Fixture(
            root: root,
            databasePath: databasePath,
            db: db,
            thread: thread,
            runId: runId,
            messageRepo: messageRepo,
            sessionRepo: sessionRepo,
            runner: runner,
            coordinator: coordinator
        )
    }

    private func persistedSequences(db: SQLiteDB, runId: AgentRunID) throws -> [Int] {
        let statement = try db.prepare("SELECT seq FROM agent_stream_events WHERE run_id = ? ORDER BY seq ASC;")
        try statement.bind(1, runId.value.uuidString)
        var values: [Int] = []
        while try statement.step() {
            values.append(Int(statement.columnInt64(0)))
        }
        return values
    }

    private func persistedKinds(db: SQLiteDB, runId: AgentRunID) throws -> [String] {
        let statement = try db.prepare(
            "SELECT event_kind FROM agent_stream_events WHERE run_id = ? ORDER BY seq ASC;"
        )
        try statement.bind(1, runId.value.uuidString)
        var values: [String] = []
        while try statement.step() {
            if let kind = statement.columnText(0) {
                values.append(kind)
            }
        }
        return values
    }

    private func persistedKind(db: SQLiteDB, runId: AgentRunID, seq: Int) throws -> String? {
        let statement = try db.prepare(
            "SELECT event_kind FROM agent_stream_events WHERE run_id = ? AND seq = ? LIMIT 1;"
        )
        try statement.bind(1, runId.value.uuidString)
        try statement.bind(2, Int64(seq))
        guard try statement.step() else { return nil }
        return statement.columnText(0)
    }

    private func persistedStatus(db: SQLiteDB, table: String, id: String) throws -> String? {
        let statement = try db.prepare("SELECT status FROM \(table) WHERE id = ?;")
        try statement.bind(1, id)
        guard try statement.step() else { return nil }
        return statement.columnText(0)
    }

    private func itemStartIDs(_ events: [AssistantEvent]) -> [String] {
        events.compactMap { event in
            guard case .itemStarted(let item) = event else { return nil }
            return item.id
        }
    }
}

private final class TerminalFinishBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRunStatus] = []

    var count: Int { lock.withLock { values.count } }
    var statuses: [AgentRunStatus] { lock.withLock { values } }
    func record(_ status: AgentRunStatus = .completed) { lock.withLock { values.append(status) } }
}

private final class PersistenceIssueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    var messages: [String] { lock.withLock { values } }
    func record(_ message: String) { lock.withLock { values.append(message) } }
}

private final class AppendedMessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentMessage] = []

    var assistantMessages: [AgentMessage] { lock.withLock { values.filter { $0.role == .assistant } } }
    func record(_ message: AgentMessage) { lock.withLock { values.append(message) } }
}

private final class AssistantEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AssistantEvent] = []

    var errorCount: Int {
        lock.withLock { values.filter { if case .error = $0 { return true }; return false }.count }
    }
    func record(_ event: AssistantEvent) { lock.withLock { values.append(event) } }
}

private final class StartFailurePresentationBox: @unchecked Sendable {
    struct Observation: Equatable {
        let phase: String
        let ledgerRecordCount: Int
    }

    private let lock = NSLock()
    private var values: [Observation] = []

    var observations: [Observation] { lock.withLock { values } }

    func record(_ phase: String, ledgerRecordCount: Int) {
        lock.withLock { values.append(Observation(phase: phase, ledgerRecordCount: ledgerRecordCount)) }
    }
}

private struct Fixture {
    let root: URL
    let databasePath: String
    let db: SQLiteDB
    let thread: AgentThread
    let runId: AgentRunID
    let messageRepo: AgentMessageRepository
    let sessionRepo: ProviderSessionRuntimeRepository
    let runner: ControlledStreamBatchRunner
    let coordinator: AgentRunCoordinator

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class ControlledStreamBatchRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var callback: (@Sendable (AgentRunEvent) -> Void)?

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock {
            callback = onEvent
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func emitItemStarts(count: Int) {
        lock.lock()
        let callback = callback
        lock.unlock()
        for index in 1...count {
            callback?(.event(.itemStarted(item: AssistantItem(
                id: "item-\(index)",
                turnId: "turn-1",
                type: .assistantMessage,
                state: .streaming,
                body: "",
                startedAtMs: Int64(index)
            ))))
        }
    }

    func emitProviderRuntime(method: String) {
        lock.lock()
        let callback = callback
        lock.unlock()
        callback?(.event(.providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "grok.acp",
            method: method,
            payloadJSON: #"{"method":"\#(method)"}"#,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))))
    }

    func emitTurnStarted(turnId: String) {
        lock.lock()
        let callback = callback
        lock.unlock()
        callback?(.event(.turnStarted(turnId: turnId)))
    }

    func finishCompleted() {
        lock.withLock { callback }?(.finished(.completed, finalMessage: "done", providerThreadId: "provider-thread"))
    }

    func emitTurnCompleted(finalMessage: String) {
        lock.withLock { callback }?(.event(.turnCompleted(turnId: "turn-1", finalMessage: finalMessage)))
    }
}

private struct ForcedStreamBatchStartFailure: Error, CustomStringConvertible {
    var description: String { "forced provider start failure" }
}

private final class FailingStreamBatchStartRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var starts = 0
    var startCount: Int { lock.withLock { starts } }
    func listModels() async -> [AgentModelDescriptor] { [] }
    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { starts += 1 }
        throw ForcedStreamBatchStartFailure()
    }
}
