import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class MirrorEventSnapshotTests: XCTestCase {
    private func streamEventCount(
        in db: SQLiteDB,
        runId: AgentRunID
    ) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM agent_stream_events WHERE run_id = ?;")
        try statement.bind(1, runId.value.uuidString)
        return try statement.step() ? Int(statement.columnInt64(0)) : 0
    }

    private func waitForRunToFinish(
        _ runId: AgentRunID,
        in runRepo: AgentRunRepository
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let run = try runRepo.get(id: runId), run.finishedAt != nil { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    func testSnapshotReturnsTheDurableAssistantTimelineAfterASuccessfulRun() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-success-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "mirror", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))]
        )
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "test successful mirror snapshot"
        ))

        let didFinish = try await waitForRunToFinish(runId, in: runRepo)
        XCTAssertTrue(didFinish)
        let events = try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 }

        XCTAssertTrue(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "a successful mirror snapshot must expose the same durable completed turn that macOS restores")
    }

    func testSnapshotRetriesRetainedStreamEventsBeforeCertifyingWatermark() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "mirror", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        try db.execute("""
            CREATE TRIGGER fail_mirror_stream_insert
            BEFORE INSERT ON agent_stream_events
            BEGIN
                SELECT RAISE(ABORT, 'forced mirror persistence failure');
            END;
            """)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))]
        )
        let persistenceIssue = PersistenceIssueBox()
        coordinator.onPersistenceIssue = { _, _, _ in persistenceIssue.record() }
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "test mirror persistence failure"
        ))

        let issueDeadline = Date().addingTimeInterval(2)
        while !persistenceIssue.observed, Date() < issueDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(persistenceIssue.observed, "the trigger must reach the terminal durability barrier")
        XCTAssertNil(try runRepo.get(id: runId)?.finishedAt,
                     "terminal state must remain pending while its retained stream batch cannot commit")
        XCTAssertEqual(try runRepo.countStreamEvents(threadId: thread.id), 0,
                       "the trigger must reproduce a stream-event persistence loss before the snapshot read")
        try db.execute("DROP TRIGGER fail_mirror_stream_insert;")

        let events = try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 }
        let didFinish = try await waitForRunToFinish(runId, in: runRepo)
        XCTAssertTrue(didFinish, "the retained terminal event must finish after the snapshot barrier commits its batch")
        XCTAssertTrue(events.contains { event in
            if case .turnCompleted = event { return true }
            return false
        }, "the snapshot barrier must retry the retained batch before certifying a watermark")
        XCTAssertGreaterThan(try runRepo.countStreamEvents(threadId: thread.id), 0,
                             "a transient SQLite failure must retain every event until a later snapshot barrier commits it")
    }

    func testPersistenceFailureDiagnosticDoesNotHoldMirrorLockAgainstSnapshot() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-diagnostic-lock-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let activeThread = AgentThread(title: "active", provider: .codex, model: "fake-model")
        let snapshotThread = AgentThread(title: "snapshot", provider: .codex, model: "fake-model")
        try threadRepo.upsert(activeThread)
        try threadRepo.upsert(snapshotThread)
        try db.execute("""
            CREATE TRIGGER fail_mirror_stream_insert
            BEFORE INSERT ON agent_stream_events
            BEGIN
                SELECT RAISE(ABORT, 'forced diagnostic lock failure');
            END;
            """)

        let runner = ControlledMirrorRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let diagnosticEntered = DispatchSemaphore(value: 0)
        let releaseDiagnostic = DispatchSemaphore(value: 0)
        let diagnosticGateLock = NSLock()
        var hasBlockedDiagnostic = false
        coordinator.onPersistenceIssue = { _, _, _ in
            let shouldBlock = diagnosticGateLock.withLock {
                guard !hasBlockedDiagnostic else { return false }
                hasBlockedDiagnostic = true
                return true
            }
            if shouldBlock {
                diagnosticEntered.signal()
                releaseDiagnostic.wait()
            }
        }
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: activeThread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "exercise diagnostic lock release"
        ))
        runner.emit(.event(.turnStarted(turnId: "turn-diagnostic")))

        let eventTask = Task.detached {
            runner.emit(.finished(.completed, finalMessage: nil, providerThreadId: "provider-thread"))
        }
        XCTAssertEqual(
            diagnosticEntered.wait(timeout: .now() + 2),
            .success,
            "the forced SQLite failure must reach the diagnostic callback"
        )

        let snapshotFinished = DispatchSemaphore(value: 0)
        let snapshotTask = Task.detached {
            _ = try? coordinator.withMirrorEventSnapshot(threadId: snapshotThread.id) { $0 }
            snapshotFinished.signal()
        }
        let snapshotResult = snapshotFinished.wait(timeout: .now() + 1)
        releaseDiagnostic.signal()
        await eventTask.value
        await snapshotTask.value

        XCTAssertEqual(
            snapshotResult,
            .success,
            "a persistence diagnostic must not keep mirrorEventLock held while host callbacks wait on main/UI work"
        )
    }

    /// The mirror lock is per thread (C5): a snapshot of a thread still orders
    /// that thread's terminal flush behind its watermark capture.
    func testTerminalFlushCannotCrossAnAtomicSnapshotLock() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-lock-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let activeThread = AgentThread(title: "active", provider: .codex, model: "fake-model")
        try threadRepo.upsert(activeThread)
        let runner = ControlledMirrorRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: activeThread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "test terminal flush locking"
        ))
        runner.emit(.event(.turnStarted(turnId: "turn-pending")))
        XCTAssertEqual(try runRepo.countStreamEvents(threadId: activeThread.id), 0,
                       "one event must remain buffered so the snapshot barrier owns the flush")

        let snapshotEntered = DispatchSemaphore(value: 0)
        let releaseSnapshot = DispatchSemaphore(value: 0)
        let snapshotTask = Task.detached {
            try coordinator.withMirrorEventSnapshot(threadId: activeThread.id) { events in
                snapshotEntered.signal()
                releaseSnapshot.wait()
                return events
            }
        }
        XCTAssertEqual(snapshotEntered.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try runRepo.countStreamEvents(threadId: activeThread.id), 1,
                       "the snapshot barrier persists the buffered event before capturing")

        let finishStarted = DispatchSemaphore(value: 0)
        let finishReturned = DispatchSemaphore(value: 0)
        let finishTask = Task.detached {
            finishStarted.signal()
            runner.emit(.finished(.completed, finalMessage: nil, providerThreadId: "provider-thread"))
            finishReturned.signal()
        }
        XCTAssertEqual(finishStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            finishReturned.wait(timeout: .now() + 0.2),
            .timedOut,
            "a terminal flush must wait behind its thread's mirror lock while a snapshot captures its watermark"
        )
        XCTAssertNil(try runRepo.get(id: runId)?.finishedAt,
                     "the terminal path must remain blocked until its durability barrier completes")

        releaseSnapshot.signal()
        let snapshot = try await snapshotTask.value
        await finishTask.value

        XCTAssertEqual(snapshot, [.turnStarted(turnId: "turn-pending")])
        XCTAssertEqual(try runRepo.countStreamEvents(threadId: activeThread.id), 1)
        XCTAssertNotNil(try runRepo.get(id: runId)?.finishedAt)
    }

    /// WHY (C5): with one process-wide lock, a paired device reading thread B
    /// held every other thread's stream durability and terminal path. A
    /// snapshot of another thread must not block this thread's terminal flush.
    func testTerminalFlushIsNotBlockedByAnotherThreadsSnapshotLock() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-other-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let activeThread = AgentThread(title: "active", provider: .codex, model: "fake-model")
        let snapshotThread = AgentThread(title: "snapshot", provider: .codex, model: "fake-model")
        try threadRepo.upsert(activeThread)
        try threadRepo.upsert(snapshotThread)
        let runner = ControlledMirrorRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: activeThread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "test terminal flush per-thread locking"
        ))
        runner.emit(.event(.turnStarted(turnId: "turn-pending")))

        let snapshotEntered = DispatchSemaphore(value: 0)
        let releaseSnapshot = DispatchSemaphore(value: 0)
        let snapshotTask = Task.detached {
            try coordinator.withMirrorEventSnapshot(threadId: snapshotThread.id) { events in
                snapshotEntered.signal()
                releaseSnapshot.wait()
                return events
            }
        }
        XCTAssertEqual(snapshotEntered.wait(timeout: .now() + 1), .success)

        let finishReturned = DispatchSemaphore(value: 0)
        let finishTask = Task.detached {
            runner.emit(.finished(.completed, finalMessage: nil, providerThreadId: "provider-thread"))
            finishReturned.signal()
        }
        XCTAssertEqual(finishReturned.wait(timeout: .now() + 2), .success,
                       "another thread's snapshot must not hold this thread's terminal path")
        XCTAssertEqual(try runRepo.countStreamEvents(threadId: activeThread.id), 1)
        XCTAssertNotNil(try runRepo.get(id: runId)?.finishedAt)

        releaseSnapshot.signal()
        _ = try await snapshotTask.value
        await finishTask.value
    }

    func testSnapshotIsPoisonedAndInvalidEventIsNotPublishedWhenEncodingFails() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-encode-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "encode", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = ControlledMirrorRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let published = AssistantEventRecorder()
        coordinator.onAssistantEvent = { event, _, _ in published.append(event) }
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "test encoding failure"
        ))

        runner.emit(.event(.itemProgress(itemId: "invalid-progress", progress: .nan)))

        XCTAssertEqual(try runRepo.countStreamEvents(threadId: thread.id), 0)
        XCTAssertFalse(published.containsItemProgress,
                       "an AssistantEvent that cannot become valid JSON must not reach EventBus")
        XCTAssertEqual(published.eventCount, 0,
                       "a local persistence diagnostic must not create another unpersisted EventBus event")
        XCTAssertThrowsError(
            try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 },
            "encoding loss must poison the snapshot before any later watermark can certify it"
        )
    }

    func testStartFailureIsPersistedBeforeItsEventBusPublication() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-start-failure-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "start failure", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FailingStartMirrorRunner()]
        )
        let published = AssistantEventRecorder()
        coordinator.onAssistantEvent = { event, _, _ in published.append(event) }

        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: appSupport,
                prompt: "fail before the run handle exists"
            ))
            XCTFail("the runner must reproduce a start failure")
        } catch {
            // Expected start failure.
        }

        let events = try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 }
        XCTAssertTrue(events.contains { event in
            if case .error(let message, _) = event { return message.contains("forced start failure") }
            return false
        }, "the exact start error published to iOS must already exist in the durable snapshot")
        XCTAssertTrue(published.containsError)
    }

    func testSnapshotFlushesEventEmittedBeforeActiveRunRegistration() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-early-event-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "early event", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = BlockingStartMirrorRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let eventPublished = expectation(description: "early event reached EventBus")
        coordinator.onAssistantEvent = { event, _, _ in
            if case .turnStarted(let turnId) = event, turnId == "early-turn" {
                eventPublished.fulfill()
            }
        }
        let startTask = Task {
            try await coordinator.startRun(AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: appSupport,
                prompt: "emit before startRun returns"
            ))
        }

        await fulfillment(of: [eventPublished], timeout: 1)
        XCTAssertNil(coordinator.activeRunId(threadId: thread.id),
                     "the regression requires the provider event to precede active-run registration")
        let events = try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 }
        XCTAssertTrue(events.contains { event in
            if case .turnStarted(let turnId) = event { return turnId == "early-turn" }
            return false
        }, "snapshot recovery must flush the buffered run owner even before activeThreads is populated")

        runner.releaseStart()
        let runId = try await startTask.value
        runner.emit(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .cancelled)
    }

    func testSnapshotRejectsMalformedPersistedEventInsteadOfCertifyingANewerWatermark() throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-malformed-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "malformed", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let run = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .completed,
            finishedAt: Date()
        )
        try runRepo.upsert(run)
        try runRepo.appendStreamEvent(
            runId: run.id,
            seq: 1,
            kind: "malformed",
            payloadJSON: "{not-valid-json"
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: FakeProviderRunner(scenario: .simpleAssistant(reply: "OK"))]
        )

        XCTAssertThrowsError(
            try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 },
            "a mirror snapshot must fail closed when a durable event cannot be decoded"
        )
    }

    func testMirrorSnapshotDoesNotWaitBehindOnAssistantEventHostCallback() async throws {
        // WHY: hang report (error2.txt) showed main HTTP mirror snapshot blocked on
        // mirrorEventLock while the codex parse queue held that lock across
        // handle -> onAssistantEvent -> NotificationCenter / NSOperation.wait.
        // Host callbacks must run after the lock is released so snapshot/watermark
        // capture cannot deadlock against provider event processing.
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-host-callback-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "host-callback", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = ControlledMirrorRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "test host callback lock scope"
        ))

        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        coordinator.onAssistantEvent = { event, _, _ in
            guard case .turnStarted(let turnId) = event, turnId == "lock-scope-turn" else { return }
            callbackEntered.signal()
            releaseCallback.wait()
        }

        let emitFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            runner.emit(.event(.turnStarted(turnId: "lock-scope-turn")))
            emitFinished.signal()
        }
        XCTAssertEqual(
            callbackEntered.wait(timeout: .now() + 2),
            .success,
            "provider event must reach onAssistantEvent"
        )

        // While the host callback is still blocked, a concurrent mirror snapshot
        // must complete. If handle still holds mirrorEventLock across the
        // callback, this times out (same shape as the 745s hang).
        let snapshotFinished = DispatchSemaphore(value: 0)
        var snapshotError: Error?
        var snapshotEvents: [AssistantEvent] = []
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                snapshotEvents = try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 }
            } catch {
                snapshotError = error
            }
            snapshotFinished.signal()
        }
        XCTAssertEqual(
            snapshotFinished.wait(timeout: .now() + 2),
            .success,
            "mirror snapshot must not block behind an in-flight onAssistantEvent host callback"
        )
        XCTAssertNil(snapshotError)
        XCTAssertTrue(
            snapshotEvents.contains {
                if case .turnStarted(let turnId) = $0 { return turnId == "lock-scope-turn" }
                return false
            },
            "snapshot taken during the host callback must still flush the buffered stream event"
        )

        releaseCallback.signal()
        XCTAssertEqual(emitFinished.wait(timeout: .now() + 2), .success)
    }

    func testBufferedEventsKeepTheirEmittingRunAcrossFailedStartAndRetry() async throws {
        let appSupport = NSTemporaryDirectory() + "rc2-mirror-snapshot-owner-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let thread = AgentThread(title: "ownership", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = FailAfterEventThenRetryMirrorRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [.codex: runner]
        )
        let failedRunId = AgentRunID()
        do {
            _ = try await coordinator.startRun(AgentRunRequest(
                runId: failedRunId,
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: appSupport,
                prompt: "first start fails after one event"
            ))
            XCTFail("the first provider start must fail after buffering its event")
        } catch {
            // Expected start failure.
        }

        let retryRunId = AgentRunID()
        _ = try await coordinator.startRun(AgentRunRequest(
            runId: retryRunId,
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: appSupport,
            prompt: "retry succeeds"
        ))
        _ = try coordinator.withMirrorEventSnapshot(threadId: thread.id) { $0 }

        XCTAssertEqual(
            try streamEventCount(in: db, runId: failedRunId),
            2,
            "the failed run must retain both its early turn and persisted start error"
        )
        XCTAssertEqual(
            try streamEventCount(in: db, runId: retryRunId),
            1,
            "the retry run must own only the event it emitted"
        )
        runner.finishRetry()
    }
}

private final class PersistenceIssueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var observed: Bool { lock.withLock { value } }
    func record() { lock.withLock { value = true } }
}

private final class ControlledMirrorRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var onEvent: (@Sendable (AgentRunEvent) -> Void)?

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.withLock {
            self.onEvent = onEvent
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func emit(_ event: AgentRunEvent) {
        lock.lock()
        let callback = onEvent
        lock.unlock()
        callback?(event)
    }
}

private struct ForcedStartFailure: Error, CustomStringConvertible {
    var description: String { "forced start failure" }
}

private final class FailingStartMirrorRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    func listModels() async -> [AgentModelDescriptor] { [] }
    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        throw ForcedStartFailure()
    }
}

private final class BlockingStartMirrorRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var onEvent: (@Sendable (AgentRunEvent) -> Void)?
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var startReleased = false

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        lock.lock()
        self.onEvent = onEvent
        lock.unlock()
        onEvent(.event(.turnStarted(turnId: "early-turn")))
        await withCheckedContinuation { continuation in
            lock.lock()
            if startReleased {
                lock.unlock()
                continuation.resume()
            } else {
                startContinuation = continuation
                lock.unlock()
            }
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func releaseStart() {
        lock.lock()
        startReleased = true
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func emit(_ event: AgentRunEvent) {
        lock.lock()
        let callback = onEvent
        lock.unlock()
        callback?(event)
    }
}

private final class FailAfterEventThenRetryMirrorRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var starts = 0
    private var retryCallback: (@Sendable (AgentRunEvent) -> Void)?

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let attempt = lock.withLock {
            starts += 1
            if starts > 1 { retryCallback = onEvent }
            return starts
        }
        if attempt == 1 {
            onEvent(.event(.turnStarted(turnId: "failed-run-turn")))
            throw ForcedStartFailure()
        }
        onEvent(.event(.turnStarted(turnId: "retry-run-turn")))
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func finishRetry() {
        lock.lock()
        let callback = retryCallback
        lock.unlock()
        callback?(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
    }
}

private final class AssistantEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AssistantEvent] = []

    func append(_ event: AssistantEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var containsItemProgress: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains { event in
            if case .itemProgress = event { return true }
            return false
        }
    }

    var containsError: Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains { event in
            if case .error = event { return true }
            return false
        }
    }

    var eventCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }
}
