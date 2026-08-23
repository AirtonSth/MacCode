import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// plan-final W0/W1: terminal reason classes never masquerade as provider completed.
final class TerminalTransitionLedgerTests: XCTestCase {
    private static func ledgerRecord(_ index: Int, baseDate: Date) -> TerminalTransitionRecord {
        let timestamp = baseDate.addingTimeInterval(Double(index) / 1_000)
        return TerminalTransitionRecord(
            runId: "run-\(index)",
            threadId: "thread-\(index)",
            reason: .providerCompleted,
            initiator: .providerTerminal,
            requestedStatus: .completed,
            eventSequence: Int64(index),
            bootId: "benchmark-boot",
            eventTime: timestamp,
            commitTime: timestamp,
            presentTime: timestamp
        )
    }

    private static func physicalRowCount(in directory: URL) throws -> Int {
        let data = try Data(contentsOf: directory.appendingPathComponent("terminal-transitions.jsonl"))
        return data.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }

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

    func test_classify_providerStartFailureIsFailedWithTruthfulMessage() {
        let reason = TerminalTransitionReason.classify(
            requestedStatus: .failed,
            initiator: .providerStartFailure
        )
        XCTAssertEqual(reason, .providerStartFailure)
        XCTAssertEqual(reason.durableStatus, .failed)
        XCTAssertEqual(reason.durableErrorMessage, "Provider start did not complete durably.")
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

    func test_ledger_appendFailsLoudlyWhenExistingFileIsNotUTF8() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-term-ledger-corrupt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF]).write(to: dir.appendingPathComponent("terminal-transitions.jsonl"))

        let ledger = TerminalTransitionLedger(directory: dir, maxRows: 10, ttl: 3600)
        XCTAssertThrowsError(
            try ledger.append(TerminalTransitionRecord(
                runId: "run-corrupt",
                threadId: "thread-corrupt",
                reason: .processDeath,
                initiator: .processDeath,
                requestedStatus: .failed
            )),
            "a damaged ledger must not be silently accepted and extended"
        )
    }

    func test_ledger_pruneHysteresis_keepsExactPublicTailAtAndAboveHighWater() throws {
        // WHY: internal disk slack must remove per-append rewrites without exposing
        // more than the configured public history window or changing FIFO order.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-term-ledger-high-water-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = TerminalTransitionLedger(directory: dir, maxRows: 3, ttl: 3_600, pruneSlack: 2)
        let baseDate = Date()

        for index in 0..<5 {
            try ledger.append(Self.ledgerRecord(index, baseDate: baseDate))
        }
        XCTAssertEqual(try Self.physicalRowCount(in: dir), 5, "the exact high-water mark must not rewrite")
        XCTAssertEqual(try ledger.allRecords().map(\.runId), ["run-2", "run-3", "run-4"])

        try ledger.append(Self.ledgerRecord(5, baseDate: baseDate))
        XCTAssertEqual(try Self.physicalRowCount(in: dir), 3, "crossing high-water must compact to maxRows")
        XCTAssertEqual(try ledger.allRecords().map(\.runId), ["run-3", "run-4", "run-5"])
    }

    func test_ledger_pruneHysteresis_reopenRecoversPhysicalCountAndTail() throws {
        // WHY: a relaunch loses the cached row count while the file may legitimately
        // contain internal slack; the next append must still compact at the same boundary.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-term-ledger-reopen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let baseDate = Date()

        do {
            let ledger = TerminalTransitionLedger(directory: dir, maxRows: 3, ttl: 3_600, pruneSlack: 2)
            for index in 0..<5 {
                try ledger.append(Self.ledgerRecord(index, baseDate: baseDate))
            }
        }

        let reopened = TerminalTransitionLedger(directory: dir, maxRows: 3, ttl: 3_600, pruneSlack: 2)
        XCTAssertEqual(try reopened.allRecords().map(\.runId), ["run-2", "run-3", "run-4"])
        XCTAssertEqual(try Self.physicalRowCount(in: dir), 5)

        try reopened.append(Self.ledgerRecord(5, baseDate: baseDate))
        XCTAssertEqual(try Self.physicalRowCount(in: dir), 3)
        XCTAssertEqual(try reopened.allRecords().map(\.runId), ["run-3", "run-4", "run-5"])
    }

    /// Same-process A/B using real JSONL append, mapped read, decode, encode, and
    /// atomic replacement I/O. Both paths start at the production 5,000-row cap;
    /// warmup=2, n=5, deterministic eight-record batch.
    func test_microbench_ledgerPruneHysteresis_amortizesRealFileRewrites() throws {
        let cap = TerminalTransitionLedger.defaultMaxRows
        let batchCount = 8
        let warmup = 2
        let samples = 5
        let baseDate = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var preseed = Data()
        for index in 0..<(cap - 1) {
            preseed.append(try encoder.encode(Self.ledgerRecord(index, baseDate: baseDate)))
            preseed.append(0x0A)
        }

        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }

        func measure(slack: Int, label: String, iteration: Int) throws -> (
            milliseconds: Double,
            records: [TerminalTransitionRecord],
            physicalRows: Int
        ) {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
                "rc-term-ledger-perf-\(label)-\(iteration)-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try preseed.write(to: dir.appendingPathComponent("terminal-transitions.jsonl"))
            let ledger = TerminalTransitionLedger(
                directory: dir,
                maxRows: cap,
                ttl: TerminalTransitionLedger.defaultTTL,
                pruneSlack: slack
            )

            // Fill the exact cap and cold-fill the cached physical row count outside timing.
            try ledger.append(Self.ledgerRecord(cap - 1, baseDate: baseDate))
            let start = DispatchTime.now().uptimeNanoseconds
            for index in cap..<(cap + batchCount) {
                try ledger.append(Self.ledgerRecord(index, baseDate: baseDate))
            }
            let end = DispatchTime.now().uptimeNanoseconds
            return (
                Double(end - start) / 1_000_000,
                try ledger.allRecords(),
                try Self.physicalRowCount(in: dir)
            )
        }

        func assertEquivalent(
            baseline: (milliseconds: Double, records: [TerminalTransitionRecord], physicalRows: Int),
            hysteresis: (milliseconds: Double, records: [TerminalTransitionRecord], physicalRows: Int)
        ) {
            XCTAssertEqual(baseline.records, hysteresis.records, "A/B public result and order must match")
            XCTAssertEqual(baseline.records.count, cap)
            XCTAssertEqual(baseline.records.first?.runId, "run-\(batchCount)")
            XCTAssertEqual(baseline.records.last?.runId, "run-\(cap + batchCount - 1)")
            XCTAssertEqual(baseline.physicalRows, cap, "legacy path rewrites after every over-cap append")
            XCTAssertEqual(hysteresis.physicalRows, cap + batchCount, "hysteresis path retains only internal slack")
        }

        for iteration in 0..<warmup {
            let baseline = try measure(slack: 0, label: "warm-before", iteration: iteration)
            let hysteresis = try measure(
                slack: TerminalTransitionLedger.defaultPruneSlack,
                label: "warm-after",
                iteration: iteration
            )
            assertEquivalent(baseline: baseline, hysteresis: hysteresis)
        }

        var before: [Double] = []
        var after: [Double] = []
        for iteration in 0..<samples {
            let baseline: (milliseconds: Double, records: [TerminalTransitionRecord], physicalRows: Int)
            let hysteresis: (milliseconds: Double, records: [TerminalTransitionRecord], physicalRows: Int)
            if iteration.isMultiple(of: 2) {
                baseline = try measure(slack: 0, label: "before", iteration: iteration)
                hysteresis = try measure(
                    slack: TerminalTransitionLedger.defaultPruneSlack,
                    label: "after",
                    iteration: iteration
                )
            } else {
                hysteresis = try measure(
                    slack: TerminalTransitionLedger.defaultPruneSlack,
                    label: "after",
                    iteration: iteration
                )
                baseline = try measure(slack: 0, label: "before", iteration: iteration)
            }
            assertEquivalent(baseline: baseline, hysteresis: hysteresis)
            before.append(baseline.milliseconds)
            after.append(hysteresis.milliseconds)
        }

        let beforeMedian = median(before)
        let afterMedian = median(after)
        let improvement = (beforeMedian - afterMedian) / beforeMedian * 100
        NSLog(
            "[perf-proof] terminalTransitionLedger per_append_rewrite_ms=%@ hysteresis_ms=%@ improvement_pct=%.2f before=%@ after=%@ cap=%d batch=%d slack=%d warmup=%d samples=%d",
            String(beforeMedian), String(afterMedian), improvement,
            String(describing: before), String(describing: after), cap, batchCount,
            TerminalTransitionLedger.defaultPruneSlack, warmup, samples
        )
        XCTAssertGreaterThan(
            improvement,
            5,
            "ledger hysteresis must beat rewriting 5,000 JSONL rows per append by at least 5%"
        )
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
