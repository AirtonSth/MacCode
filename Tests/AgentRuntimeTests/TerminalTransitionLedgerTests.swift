import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// plan-final W0/W1: terminal reason classes never masquerade as provider completed.
final class TerminalTransitionLedgerTests: XCTestCase {
    func test_classify_relaunchIsInterruptedNotCompleted() {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: .running,
            initiator: .relaunchReconcile
        )
        XCTAssertEqual(reason, .relaunchReconcile)
        XCTAssertEqual(reason.durableStatus, .interrupted)
        XCTAssertFalse(reason.mayRenderAsProviderCompleted)
        XCTAssertEqual(reason.durableErrorMessage, "Interrupted by app restart.")
    }

    func test_classify_lockSaturationNotCompleted() {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: .failed,
            initiator: .lockSaturation
        )
        XCTAssertEqual(reason, .lockSaturation)
        XCTAssertFalse(reason.mayRenderAsProviderCompleted)
    }

    func test_classify_rpcTimeoutNotCompleted() {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: .failed,
            initiator: .rpcTimeout
        )
        XCTAssertEqual(reason, .rpcTimeout)
        XCTAssertFalse(reason.mayRenderAsProviderCompleted)
    }

    func test_policy_rejectsFalseCompletedPresentation() {
        let record = TerminalTransitionRecord(
            runId: "r1",
            threadId: "t1",
            reason: .relaunchReconcile,
            initiator: .relaunchReconcile,
            requestedStatus: .completed
        )
        XCTAssertFalse(TerminalTransitionPolicy.allowsCompletedPresentation(record))
        XCTAssertEqual(
            TerminalTransitionPolicy.reconciledStatus(requested: .completed, reason: .relaunchReconcile),
            .interrupted
        )
    }

    func test_policy_allowsTrueProviderCompleted() {
        let record = TerminalTransitionRecord(
            runId: "r1",
            threadId: "t1",
            reason: .providerCompleted,
            initiator: .providerTerminal,
            requestedStatus: .completed
        )
        XCTAssertTrue(TerminalTransitionPolicy.allowsCompletedPresentation(record))
    }

    func test_ledger_appendAndReadRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-term-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = TerminalTransitionLedger(directory: dir, maxRows: 10, ttl: 3600)
        let record = TerminalTransitionRecord(
            runId: "run-1",
            threadId: "thread-1",
            reason: .processDeath,
            initiator: .processDeath,
            requestedStatus: .failed,
            providerPid: 42
        )
        let committed = try ledger.append(record)
        XCTAssertNotNil(committed.commitTime)
        let all = try ledger.allRecords()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].runId, "run-1")
        XCTAssertEqual(all[0].reason, .processDeath)
        XCTAssertEqual(try ledger.records(forRunId: "run-1").count, 1)
    }

    func test_terminalInitiator_userStop_processDeath_rpcTimeout() {
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .cancelled,
                providerTerminalAcknowledged: false
            ),
            .userStop
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .failed,
                providerTerminalAcknowledged: false
            ),
            .processDeath
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .failed,
                providerTerminalAcknowledged: true,
                errorMessage: "request timed out after 30s"
            ),
            .rpcTimeout
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .completed,
                providerTerminalAcknowledged: true
            ),
            .providerTerminal
        )
        XCTAssertEqual(
            AgentRunCoordinator.terminalInitiator(
                status: .interrupted,
                providerTerminalAcknowledged: false
            ),
            .relaunchReconcile
        )
    }

    func test_durableTerminalStatus_falseCompleted_notPersistedAsCompleted() {
        // WHY: durable run/thread rows must match presentation — never store completed
        // when provider terminal was not acknowledged (skeptic: persist used pending.status).
        let durable = AgentRunCoordinator.durableTerminalStatus(
            requested: .completed,
            providerTerminalAcknowledged: false
        )
        XCTAssertNotEqual(durable.status, .completed)
        XCTAssertEqual(durable.initiator, .processDeath)
        XCTAssertEqual(durable.status, .failed)

        let ok = AgentRunCoordinator.durableTerminalStatus(
            requested: .completed,
            providerTerminalAcknowledged: true
        )
        XCTAssertEqual(ok.status, .completed)
        XCTAssertEqual(ok.initiator, .providerTerminal)

        let relaunch = AgentRunCoordinator.durableTerminalStatus(
            requested: .interrupted,
            providerTerminalAcknowledged: false
        )
        XCTAssertEqual(relaunch.status, .interrupted)
        XCTAssertEqual(relaunch.initiator, .relaunchReconcile)
    }

    func test_recordTerminalTransition_usesPolicy_blocksFalseCompleted() throws {
        let tmp = NSTemporaryDirectory() + "rc2-term-policy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let ledger = TerminalTransitionLedger(
            directory: URL(fileURLWithPath: tmp).appendingPathComponent("diagnostics")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: AgentRunRepository(db: db),
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: AgentThreadRepository(db: db),
            providers: [:],
            terminalTransitionLedger: ledger
        )
        // Local initiator claiming completed must not present as completed.
        let presentation = coordinator.recordTerminalTransition(
            runId: AgentRunID(),
            threadId: AgentThreadID(),
            requestedStatus: .completed,
            initiator: .relaunchReconcile
        )
        XCTAssertEqual(presentation, .interrupted)
        XCTAssertFalse(
            TerminalTransitionPolicy.allowsCompletedPresentation(
                TerminalTransitionRecord(
                    runId: "x",
                    threadId: "y",
                    reason: .relaunchReconcile,
                    initiator: .relaunchReconcile,
                    requestedStatus: .completed
                )
            )
        )
        let rows = try ledger.allRecords()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].reason, .relaunchReconcile)
    }

    func test_lockSaturation_doesNotAppendTerminalLedgerUntilProviderTerminal() async throws {
        // WHY: a saturated stream retry is recoverable persistence telemetry, not a
        // provider terminal. Recording it as .failed made recovery diagnostics lie
        // about a still-running turn before the provider actually finished.
        let tmp = NSTemporaryDirectory() + "rc2-lock-saturation-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "lock saturation", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let ledger = TerminalTransitionLedger(
            directory: URL(fileURLWithPath: tmp).appendingPathComponent("diagnostics")
        )
        let runner = SaturatingStreamRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: runner],
            terminalTransitionLedger: ledger
        )
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "exercise saturated stream retry"
        ))
        let finished = expectation(description: "provider terminal commits")
        coordinator.onRunFinished = { _, finishedRunId, status in
            if finishedRunId == runId, status == .completed {
                finished.fulfill()
            }
        }

        try db.execute("""
            CREATE TRIGGER fail_saturated_stream_flush
            BEFORE INSERT ON agent_stream_events
            BEGIN
                SELECT RAISE(ABORT, 'forced saturated stream flush');
            END;
            """)
        runner.emitItemStarts(count: 16)
        runner.emitItemStarts(count: 1)

        XCTAssertTrue(
            try ledger.allRecords().isEmpty,
            "retry saturation must remain nonterminal telemetry until a provider terminal event arrives"
        )
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .running)
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .running)

        try db.execute("DROP TRIGGER fail_saturated_stream_flush;")
        runner.finishCompleted()
        await fulfillment(of: [finished], timeout: 2)

        let records = try ledger.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].reason, .providerCompleted)
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .completed)
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .completed)
    }

    func test_terminalGraphRetry_recordsOneTransitionOnlyAfterDurabilityAndBeforePresentation() async throws {
        // WHY: the terminal claim survives 100 ms durability retries. The forensic
        // row must describe its one successful graph commit, rather than every
        // failed attempt or an already-presented result.
        let tmp = NSTemporaryDirectory() + "rc2-terminal-ledger-retry-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "terminal retry", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let ledger = TerminalTransitionLedger(
            directory: URL(fileURLWithPath: tmp).appendingPathComponent("diagnostics")
        )
        let runner = SaturatingStreamRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: runner],
            terminalTransitionLedger: ledger
        )
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "exercise terminal graph retry"
        ))
        let finished = expectation(description: "terminal graph recovery presents once")
        coordinator.onRunFinished = { _, finishedRunId, status in
            if finishedRunId == runId, status == .completed {
                finished.fulfill()
            }
        }

        try db.execute("""
            CREATE TRIGGER fail_terminal_graph_retry
            BEFORE UPDATE ON agent_runs
            WHEN NEW.status = 'completed'
            BEGIN
                SELECT RAISE(ABORT, 'forced terminal graph failure');
            END;
            """)
        runner.finishCompleted()
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertTrue(
            try ledger.records(forRunId: runId.value.uuidString).isEmpty,
            "failed terminal graph retries must not write premature forensic rows"
        )
        XCTAssertNil(try runRepo.get(id: runId)?.finishedAt)

        try db.execute("DROP TRIGGER fail_terminal_graph_retry;")
        await fulfillment(of: [finished], timeout: 2)

        let records = try ledger.records(forRunId: runId.value.uuidString)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        let commitTime = try XCTUnwrap(record.commitTime)
        let presentTime = try XCTUnwrap(record.presentTime)
        XCTAssertEqual(record.reason, .providerCompleted)
        XCTAssertLessThanOrEqual(record.eventTime, commitTime)
        XCTAssertLessThanOrEqual(commitTime, presentTime)
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .completed)
    }

    func test_userStopRetry_recordsOneTransitionOnlyAfterDurabilityAndBeforePresentation() async throws {
        // WHY: Stop owns the same terminal claim as provider completion. Its
        // immediate claim and each retry must not append separate ledger rows.
        let tmp = NSTemporaryDirectory() + "rc2-terminal-ledger-stop-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "stop retry", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let ledger = TerminalTransitionLedger(
            directory: URL(fileURLWithPath: tmp).appendingPathComponent("diagnostics")
        )
        let runner = SaturatingStreamRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providers: [.codex: runner],
            terminalTransitionLedger: ledger
        )
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "exercise user stop retry"
        ))
        let finished = expectation(description: "user stop recovery presents once")
        coordinator.onRunFinished = { _, finishedRunId, status in
            if finishedRunId == runId, status == .cancelled {
                finished.fulfill()
            }
        }

        try db.execute("""
            CREATE TRIGGER fail_terminal_stop_retry
            BEFORE UPDATE ON agent_runs
            WHEN NEW.status = 'cancelled'
            BEGIN
                SELECT RAISE(ABORT, 'forced terminal stop failure');
            END;
            """)
        coordinator.stopRun(threadId: thread.id)
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertTrue(
            try ledger.records(forRunId: runId.value.uuidString).isEmpty,
            "a Stop claim and its failed retries must not append premature ledger rows"
        )
        XCTAssertNil(try runRepo.get(id: runId)?.finishedAt)

        try db.execute("DROP TRIGGER fail_terminal_stop_retry;")
        await fulfillment(of: [finished], timeout: 2)

        let records = try ledger.records(forRunId: runId.value.uuidString)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        let commitTime = try XCTUnwrap(record.commitTime)
        let presentTime = try XCTUnwrap(record.presentTime)
        XCTAssertEqual(record.reason, .userStop)
        XCTAssertLessThanOrEqual(record.eventTime, commitTime)
        XCTAssertLessThanOrEqual(commitTime, presentTime)
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .cancelled)
    }
}

private final class SaturatingStreamRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var callback: (@Sendable (AgentRunEvent) -> Void)?

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock { callback = onEvent }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func emitItemStarts(count: Int) {
        let callback = lock.withLock { self.callback }
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

    func finishCompleted() {
        lock.withLock { self.callback }?(.finished(
            .completed,
            finalMessage: "done",
            providerThreadId: "provider-thread"
        ))
    }
}
