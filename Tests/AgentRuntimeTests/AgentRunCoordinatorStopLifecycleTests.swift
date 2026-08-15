import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Regression coverage for the stop/error/auto-continuation lifecycle fixes:
///
/// - F17: stopRun(threadId:) must not double-fire terminal lifecycle events when
///   the adapter's cancel finishes the run synchronously (codex interrupt path).
///   Duplicates posted two "cancelled" notifications and scheduled two concurrent
///   queued-message drains for one stopped run.
/// - F19: a stop for a thread that is NOT running/pending must be a no-op — it
///   used to respawn a provider process (recoverSession) for a dead thread and
///   broadcast a spurious `.cancelled` ("Thread cancelled" for a thread that
///   finished hours ago). The idle reaper releases sessions silently instead.
/// - F22: runner-level `.error` events must be persisted as stream events, or a
///   failed run shows no explanation after a thread switch or relaunch.
/// - F37: a user-initiated run must invalidate a scheduled background-await
///   auto-continuation, or a stale autonomous "continue" turn fires after the
///   user already redirected the thread.
final class AgentRunCoordinatorStopLifecycleTests: XCTestCase {

    // MARK: - Shared recorders

    /// Thread-safe recorder for coordinator lifecycle broadcasts.
    private final class LifecycleRecorder: AgentRunObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var _finished: [(AgentRunID, AgentRunStatus)] = []
        private var _cancelledStatusChanges = 0
        private var _runFinishedCallbacks: [(AgentThreadID, AgentRunStatus)] = []

        var finished: [(AgentRunID, AgentRunStatus)] { lock.lock(); defer { lock.unlock() }; return _finished }
        var cancelledStatusChanges: Int { lock.lock(); defer { lock.unlock() }; return _cancelledStatusChanges }
        var runFinishedCallbacks: [(AgentThreadID, AgentRunStatus)] { lock.lock(); defer { lock.unlock() }; return _runFinishedCallbacks }

        func recordRunFinished(threadId: AgentThreadID, status: AgentRunStatus) {
            lock.lock(); _runFinishedCallbacks.append((threadId, status)); lock.unlock()
        }

        func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {}
        func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
            lock.lock(); _finished.append((runId, status)); lock.unlock()
        }
        func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {
            guard status == .cancelled else { return }
            lock.lock(); _cancelledStatusChanges += 1; lock.unlock()
        }
    }

    /// Mirrors the app-shell listener that turns coordinator events into visible
    /// surface updates. Recovery must use this same path, not silently consume
    /// adapter events while changing only in-memory adapter state.
    private final class AssistantEventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _received: [(AssistantEvent, AgentThreadID, AgentRunID)] = []

        var received: [(AssistantEvent, AgentThreadID, AgentRunID)] {
            lock.lock(); defer { lock.unlock() }
            return _received
        }

        func record(_ event: AssistantEvent, threadId: AgentThreadID, runId: AgentRunID) {
            lock.lock(); _received.append((event, threadId, runId)); lock.unlock()
        }
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeRepos(_ label: String) throws -> (AgentThreadRepository, AgentMessageRepository, AgentRunRepository, ProviderSessionRuntimeRepository, String) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (AgentThreadRepository(db: db), AgentMessageRepository(db: db), AgentRunRepository(db: db), ProviderSessionRuntimeRepository(db: db), tmp)
    }

    // MARK: - F17: stop double-fire

    /// Runner mimicking the codex app-server adapter: cancel() finishes the run
    /// SYNCHRONOUSLY with `.finished(.cancelled)` (CodexAppServerAdapter emits it
    /// inside interrupt); the run never finishes on its own.
    private final class SyncCancelFinishRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: "t1")))
            return AgentRunHandle(runId: request.runId, process: nil) {
                onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: providerThreadId))
            }
        }
    }

    func test_stopRun_whenCancelFinishesSynchronously_firesExactlyOneTerminalBroadcast() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-double-fire")
        let thread = AgentThread(title: "stop me", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providerSessionRepo: sessionRepo,
                                              providers: [.codex: SyncCancelFinishRunner()])
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in recorder.recordRunFinished(threadId: tid, status: status) }

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "long task"
        ))

        coordinator.stopRun(threadId: thread.id)
        // The cancel path is synchronous, but give any (buggy) duplicate every
        // chance to land before counting.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(recorder.runFinishedCallbacks.count, 1,
                       "one stopped run must produce exactly ONE onRunFinished — duplicates publish " +
                       "agent.run.finished twice, post the cancel notification twice and schedule two " +
                       "concurrent queued-message drains on the same thread (F17)")
        XCTAssertEqual(recorder.finished.filter { $0.0 == runId }.count, 1,
                       "didFinish must fire exactly once for the stopped run")
        XCTAssertEqual(recorder.cancelledStatusChanges, 0,
                       "the finish path already broadcast the terminal state via didFinish; " +
                       "markStopRequested must not re-broadcast didChangeStatus(.cancelled) for an already-finished run")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .cancelled,
                       "sanity: the stop must still land the thread in .cancelled")
    }

    // MARK: - F19: stop/reap on a finished thread

    /// Adapter spy: records recoverSession/stopSession calls; recoverSession
    /// "spawns" a session (hasSession flips true) like the real adapters do.
    private final class SpyRecoverAdapter: AgentProviderAdapter, @unchecked Sendable {
        let provider: AgentProvider = .codex
        private let lock = NSLock()
        private var _hasSession: Bool
        private let recoveryEvents: [AgentRunEvent]
        private var _recoverCalls = 0
        private var _stopSessionCalls = 0
        var recoverCalls: Int { lock.lock(); defer { lock.unlock() }; return _recoverCalls }
        var stopSessionCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopSessionCalls }

        init(hasSession: Bool = false, recoveryEvents: [AgentRunEvent] = []) {
            _hasSession = hasSession
            self.recoveryEvents = recoveryEvents
        }

        func listModels() async -> [AgentModelDescriptor] { [] }
        func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            throw AgentProviderAdapterError.unsupported("startSession")
        }
        func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            throw AgentProviderAdapterError.unsupported("sendTurn")
        }
        func interruptTurn(threadId: AgentThreadID) throws {}
        func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
        func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
        func stopSession(threadId: AgentThreadID) throws {
            lock.lock(); _stopSessionCalls += 1; _hasSession = false; lock.unlock()
        }
        func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
            let events = lock.withLock { () -> [AgentRunEvent] in
                _recoverCalls += 1
                _hasSession = true
                return recoveryEvents
            }
            for event in events {
                onEvent(event)
            }
        }
        func listSessions() -> [AgentProviderSessionSummary] { [] }
        func hasSession(threadId: AgentThreadID) -> Bool { lock.lock(); defer { lock.unlock() }; return _hasSession }
        func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
        func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
        func stopAll() {}
        func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
    }

    func test_stopRun_onLongFinishedThread_doesNotRespawnProviderOrBroadcastCancelled() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-finished-thread")
        var thread = AgentThread(title: "finished hours ago", provider: .codex, model: "fake-model")
        thread.status = .completed
        try threadRepo.upsert(thread)
        // A recoverable provider session exists (typical right after relaunch):
        // exactly the state that made the old recover-then-interrupt fallback
        // spawn a fresh provider process for this dead thread.
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id, provider: .codex, status: .completed,
            resumeCursor: "provider-thread-1", cwd: tmp, model: "fake-model"
        ))
        let adapter = SpyRecoverAdapter(hasSession: false)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in recorder.recordRunFinished(threadId: tid, status: status) }

        coordinator.stopRun(threadId: thread.id)
        // The buggy respawn ran on an unstructured Task — give it time to fire.
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(adapter.recoverCalls, 0,
                       "a stop for a thread that is not running/pending must NOT recover (= respawn) a " +
                       "provider session — the idle reap was leaving one fresh resident process per reaped thread (F19)")
        XCTAssertEqual(recorder.cancelledStatusChanges, 0,
                       "no spurious didChangeStatus(.cancelled) for a thread that finished long ago — " +
                       "it posted a phantom 'Thread cancelled' notification")
        XCTAssertTrue(recorder.runFinishedCallbacks.isEmpty,
                      "no onRunFinished for a thread with nothing running — it triggered an unprompted " +
                      "queued-message drain")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .completed,
                       "the finished thread's status must be left untouched")
    }

    func test_releaseProviderSession_freesResidentSessionWithoutLifecycleEvents() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("release-session")
        var thread = AgentThread(title: "idle 6h", provider: .codex, model: "fake-model")
        thread.status = .completed
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id, provider: .codex, status: .completed,
            resumeCursor: "provider-thread-1", cwd: tmp, model: "fake-model"
        ))
        let adapter = SpyRecoverAdapter(hasSession: true)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providerSessionRepo: sessionRepo,
                                              providerAdapters: [.codex: adapter])
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in recorder.recordRunFinished(threadId: tid, status: status) }

        coordinator.releaseProviderSession(threadId: thread.id)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(adapter.stopSessionCalls, 1,
                       "the reaper's whole point: the resident provider process must actually be released")
        XCTAssertEqual(recorder.cancelledStatusChanges, 0,
                       "releasing an idle session must be lifecycle-silent — no 'Thread cancelled' for a " +
                       "thread nobody stopped (F19)")
        XCTAssertTrue(recorder.runFinishedCallbacks.isEmpty,
                      "no onRunFinished from an idle-session release")
    }

    func test_recoverSessionPersistsFallbackCursorAndPublishesRecoverableDisclosure() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("recover-fallback-events")
        var thread = AgentThread(title: "recover fallback", provider: .codex, model: "fake-model")
        thread.status = .interrupted
        thread.providerThreadId = "stale-provider-thread"
        try threadRepo.upsert(thread)
        let priorRun = AgentRun(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            status: .interrupted
        )
        try runRepo.upsert(priorRun)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .codex,
            status: .interrupted,
            resumeCursor: "stale-provider-thread",
            cwd: tmp,
            model: "fake-model",
            lastRunId: priorRun.id,
            lastEventKind: "error"
        ))
        let adapter = SpyRecoverAdapter(
            hasSession: false,
            recoveryEvents: [
                .event(.threadStarted(threadId: "fresh-provider-thread", providerThreadId: "fresh-provider-thread")),
                .error("Previous session could not be resumed; starting a new session.")
            ]
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.codex: adapter]
        )
        let recorder = AssistantEventRecorder()
        coordinator.onAssistantEvent = { event, threadId, runId in
            recorder.record(event, threadId: threadId, runId: runId)
        }

        _ = try await coordinator.readThread(threadId: thread.id)

        XCTAssertEqual(adapter.recoverCalls, 1)
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.providerThreadId, "fresh-provider-thread",
                       "fallback threadStarted must replace the stale thread cursor before the next Resume")
        XCTAssertEqual(try sessionRepo.get(threadId: thread.id)?.resumeCursor, "fresh-provider-thread",
                       "fallback threadStarted must durably replace the stale provider-session cursor")
        XCTAssertTrue(
            recorder.received.contains { event, threadId, runId in
                guard threadId == thread.id, runId == priorRun.id,
                      case .error(let message, let recoverable) = event else { return false }
                return message == "Previous session could not be resumed; starting a new session." && recoverable
            },
            "the recoverable fallback disclosure must reach the app-shell listener with the durable prior run id"
        )
    }

    // MARK: - F22: runner-level errors are persisted

    /// Runner that fails mid-run the way a CLI does: a runner-level `.error`
    /// (stderr diagnosis, e.g. 'Invalid API key') followed by `.finished(.failed)`.
    private final class FailingRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        let errorMessage: String
        init(errorMessage: String) { self.errorMessage = errorMessage }
        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let message = errorMessage
            Task.detached {
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                onEvent(.event(.turnStarted(turnId: "t1")))
                onEvent(.error(message))
                onEvent(.finished(.failed, finalMessage: nil, providerThreadId: providerThreadId))
            }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
    }

    func test_runnerError_isPersistedToStreamEvents_soReplayExplainsTheFailure() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("error-persist")
        let thread = AgentThread(title: "fails", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providerSessionRepo: sessionRepo,
                                              providers: [.codex: FailingRunner(errorMessage: "Invalid API key")])
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "do it"
        ))
        await waitUntil { recorder.finished.contains { $0.1 == .failed } }

        // Replay is how a thread switch / app relaunch rebuilds the timeline: the
        // error must be in the persisted stream, or the user sees a 'Failed' chip
        // with no explanation anywhere.
        let replayed = coordinator.latestStreamEvents(threadId: thread.id)
        let persistedErrors: [(String, Bool)] = replayed.compactMap {
            if case .error(let message, let recoverable) = $0 { return (message, recoverable) }
            return nil
        }
        XCTAssertTrue(persistedErrors.contains { $0.0 == "Invalid API key" },
                      "runner-level .error events must be persisted as stream events so replay after a " +
                      "thread switch or relaunch restores WHY the run failed (F22); got: \(persistedErrors)")
        XCTAssertTrue(persistedErrors.contains { $0.0 == "Invalid API key" && $0.1 },
                      "an unexpected provider crash with a durable resume cursor must expose recovery after relaunch")
    }

    func test_pendingAndRegisteredStopRaceIsSafeAcrossOneThousandInterleavings() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-race-1000")
        let runner = PendingStopStressRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: runner]
        )
        var threadIds: [AgentThreadID] = []

        for iteration in 0..<1_000 {
            let ordinal = iteration + 1
            let thread = AgentThread(title: "stop-race-\(ordinal)", provider: .codex, model: "fake-model")
            try threadRepo.upsert(thread)
            threadIds.append(thread.id)
            let request = AgentRunRequest(
                threadId: thread.id,
                provider: .codex,
                model: "fake-model",
                cwd: tmp,
                prompt: "iteration \(ordinal)"
            )

            if iteration.isMultiple(of: 2) {
                let start = Task { try await coordinator.startRun(request) }
                await waitUntil { runner.enteredCount >= ordinal }
                coordinator.stopRun(threadId: thread.id)
                runner.releaseThrough(ordinal)
                _ = try await start.value
            } else {
                runner.releaseThrough(ordinal)
                _ = try await coordinator.startRun(request)
                coordinator.stopRun(threadId: thread.id)
            }
        }

        await waitUntil { runner.cancelledCount == 1_000 }
        XCTAssertEqual(runner.cancelledCount, 1_000,
                       "every Stop must cancel exactly one provider handle before or after registration")
        XCTAssertTrue(coordinator.activeThreadIdsSnapshot().isEmpty,
                      "no cancelled race iteration may leave a hidden active run")
        XCTAssertTrue(try threadIds.allSatisfy { try threadRepo.get(id: $0)?.status == .cancelled },
                      "every pending/running stop must persist a terminal cancelled thread")
    }

    // MARK: - F37: user run invalidates a scheduled auto-continuation

    /// Runner that stalls (background-await marker) only for the prompt "stall";
    /// every other prompt — including the auto-continuation nudge — completes with
    /// a genuine final answer. Records every prompt it was started with.
    private final class RedirectableStallRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .codex
        private let lock = NSLock()
        private var _prompts: [String] = []
        var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }

        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            lock.lock(); _prompts.append(request.prompt); lock.unlock()
            let final = request.prompt == "stall"
                ? BackgroundAwaitContinuation.awaitingMarker + "\nHolding for the background deploy job."
                : "All steps are done; the build is green."
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            Task.detached {
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                let turnId = UUID().uuidString
                onEvent(.event(.turnStarted(turnId: turnId)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: final)))
                onEvent(.status(.completed))
                onEvent(.finished(.completed, finalMessage: final, providerThreadId: providerThreadId))
            }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
    }

    func test_userInitiatedRun_cancelsScheduledBackgroundAwaitContinuation() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("bg-await-redirect")
        let thread = AgentThread(title: "redirected", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = RedirectableStallRunner()
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo, providerSessionRepo: sessionRepo,
                                              providers: [.codex: runner])
        // Long enough that the user's redirect reliably lands inside the window,
        // short enough to observe the (non-)firing within the test.
        coordinator.backgroundAwaitContinuationDelay = 1.0
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)

        // 1. Full-access run stalls awaiting a background job -> nudge scheduled.
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp,
            prompt: "stall", permissionMode: .fullAccess
        ))
        await waitUntil { recorder.finished.count >= 1 }

        // 2. Inside the delay window the USER redirects the thread; the run
        //    completes with real progress well before the nudge would fire.
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp,
            prompt: "drop that, summarize instead", permissionMode: .fullAccess
        ))
        await waitUntil { recorder.finished.count >= 2 }

        // 3. Let the scheduled nudge's timer elapse (plus slack), then prove the
        //    stale continuation did NOT fire.
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        XCTAssertFalse(runner.prompts.contains(BackgroundAwaitContinuation.continuationPrompt),
                       "a user-initiated run must invalidate the pending background-await nudge — a stale " +
                       "autonomous 'continue' after the user redirected the thread is an unrequested " +
                       "full-access turn built from the OLD run's metadata (F37); prompts: \(runner.prompts)")
        XCTAssertEqual(runner.prompts, ["stall", "drop that, summarize instead"],
                       "only the two user runs may have reached the provider")
    }

    // MARK: - AG-002: stop and await provider termination

    private final class DelayedCancelFinishRunner: AgentProviderRunner, @unchecked Sendable {
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
            let providerThreadId = UUID().uuidString
            onEvent(.status(.running))
            return AgentRunHandle(runId: request.runId, process: nil) { [finishDelayNanoseconds] in
                guard let finishDelayNanoseconds else { return }
                Task.detached {
                    try? await Task.sleep(nanoseconds: finishDelayNanoseconds)
                    onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: providerThreadId))
                }
            }
        }
    }

    func test_stopAndAwaitTermination_waitsForProviderTerminalAndLeavesNoSession() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-await")
        let thread = AgentThread(title: "await stop", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: DelayedCancelFinishRunner(finishDelayNanoseconds: 150_000_000)]
        )
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in
            recorder.recordRunFinished(threadId: tid, status: status)
        }
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "long task"
        ))

        let startedAt = Date()
        try await coordinator.stopAndAwaitTermination(threadId: thread.id)

        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(startedAt),
            0.12,
            "delete safety must await the provider terminal callback, not only the immediate cancelled DB status"
        )
        XCTAssertEqual(recorder.runFinishedCallbacks.count, 1,
                       "one stop-and-await request must publish exactly one terminal lifecycle callback")
        XCTAssertFalse(coordinator.hasProviderSession(threadId: thread.id),
                       "successful termination confirmation requires the provider session and its child work to be gone")
    }

    /// Durable terminal row left activeThreads owned (partial finish / multi-process
    /// reconcile). Stop must release in-memory ownership so Working cannot stick.
    func test_stopRun_whenFinishedAtAlreadySetButActiveInMemory_releasesOwnershipAndNotifiesOnce() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stale-ownership-stop")
        let thread = AgentThread(title: "ghost working", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: SyncCancelFinishRunner()]
        )
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in recorder.recordRunFinished(threadId: tid, status: status) }

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "long task"
        ))
        // Simulate multi-process reconcile / partial finish: durable row terminal
        // while this process still owns the run in memory.
        try runRepo.markStopped(id: runId, status: .interrupted)
        XCTAssertNotNil(coordinator.activeRunId(threadId: thread.id),
                        "precondition: run must still be owned in memory before Stop")

        coordinator.stopRun(threadId: thread.id)
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(coordinator.activeRunId(threadId: thread.id),
                     "Stop must release activeThreads when finishedAt is already set")
        XCTAssertTrue(coordinator.activeThreadIdsSnapshot().isEmpty)
        XCTAssertEqual(recorder.finished.filter { $0.0 == runId }.count, 1,
                       "stale-ownership release must fan out didFinish exactly once")
        XCTAssertEqual(recorder.runFinishedCallbacks.count, 1)
    }

    /// Late .finished after durable interrupted must clear ghost Working ownership.
    func test_finishedEvent_whenFinishedAtAlreadySetButActiveInMemory_releasesOwnership() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stale-ownership-finish")
        final class HangUntilCancelRunner: AgentProviderRunner, @unchecked Sendable {
            let provider: AgentProvider = .codex
            func listModels() async -> [AgentModelDescriptor] { [] }
            func startRun(
                _ request: AgentRunRequest,
                onEvent: @escaping @Sendable (AgentRunEvent) -> Void
            ) async throws -> AgentRunHandle {
                onEvent(.status(.running))
                return AgentRunHandle(runId: request.runId, process: nil) {
                    // Cancel does not finish — ownership stays until coordinator cleanup.
                }
            }
        }
        let thread = AgentThread(title: "late finish", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: HangUntilCancelRunner()]
        )
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "hang"
        ))
        try runRepo.markStopped(id: runId, status: .interrupted)
        XCTAssertNotNil(coordinator.activeRunId(threadId: thread.id))

        // Provider finally emits finished after another process already wrote finishedAt.
        // Drive via a synthetic finish by stopping (markStopRequested path) is covered
        // above; here exercise the .finished handle path by using stop which calls cancel
        // (no-op) then markStopRequested which hits finishedAt cleanup.
        coordinator.stopRun(threadId: thread.id)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(coordinator.activeRunId(threadId: thread.id))
        XCTAssertEqual(recorder.finished.filter { $0.0 == runId }.count, 1)
    }

    func test_stopAndAwaitTermination_hardTimeoutFailsLoud() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-await-timeout")
        let thread = AgentThread(title: "stuck stop", provider: .codex, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: DelayedCancelFinishRunner(finishDelayNanoseconds: nil)]
        )
        coordinator.gracefulStopTimeout = 0.05
        coordinator.hardStopTimeout = 0.15
        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "fake-model",
            cwd: tmp,
            prompt: "never exits"
        ))

        do {
            try await coordinator.stopAndAwaitTermination(threadId: thread.id)
            XCTFail("a provider that never confirms terminal state must fail after the hard timeout")
        } catch {
            XCTAssertTrue(String(describing: error).contains("did not terminate"))
        }
    }

    // MARK: - Stop must not stick on in-flight wire rendering

    /// Runner that streams an RCW1 assistant item then holds the run open until
    /// cancel (or a long hang). Mirrors the live case while the user hits Stop.
    private final class WireStreamThenHangRunner: AgentProviderRunner, @unchecked Sendable {
        let provider: AgentProvider = .claude
        private let lock = NSLock()
        private var onEvent: (@Sendable (AgentRunEvent) -> Void)?

        func listModels() async -> [AgentModelDescriptor] { [] }
        func startRun(
            _ request: AgentRunRequest,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) async throws -> AgentRunHandle {
            lock.lock(); self.onEvent = onEvent; lock.unlock()
            let providerThreadId = request.providerThreadId ?? UUID().uuidString
            let itemId = "wire-item-1"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: "t-wire")))
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            onEvent(.event(.itemStarted(item: AssistantItem(
                id: itemId,
                turnId: "t-wire",
                type: .assistantMessage,
                state: .streaming,
                body: "",
                startedAtMs: nowMs
            ))))
            // Exact byte-zero sentinel selects the bounded RCW1 hold path.
            onEvent(.event(.itemDelta(
                itemId: itemId,
                bodyAppend: "RCW1\tA\t1\nO\tBuild passed",
                outputAppend: nil,
                summary: nil
            )))
            return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
                guard let self else { return }
                self.lock.lock(); let emit = self.onEvent; self.lock.unlock()
                emit?(.finished(.cancelled, finalMessage: nil, providerThreadId: providerThreadId))
            }
        }
    }

    /// WHY: provider-completed `.finished` used to wait unbounded on
    /// providerTextTranslationsInFlight. A hung renderer left
    /// durable agent_runs running and Working latched for all providers.
    /// Token Saver must fail open: deadline drains the deferred terminal with
    /// the original provider payload.
    func test_providerCompletedFinished_drainsWhenTranslatorNeverReturns() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("defer-deadline")
        final class StreamThenHoldRunner: AgentProviderRunner, @unchecked Sendable {
            let provider: AgentProvider = .claude
            private let lock = NSLock()
            private var onEvent: (@Sendable (AgentRunEvent) -> Void)?
            func listModels() async -> [AgentModelDescriptor] { [] }
            func startRun(
                _ request: AgentRunRequest,
                onEvent: @escaping @Sendable (AgentRunEvent) -> Void
            ) async throws -> AgentRunHandle {
                lock.lock(); self.onEvent = onEvent; lock.unlock()
                onEvent(.status(.running))
                let itemId = "wire-item"
                onEvent(.event(.itemStarted(item: AssistantItem(
                    id: itemId,
                    turnId: "t1",
                    type: .assistantMessage,
                    state: .streaming,
                    body: "",
                    startedAtMs: 1
                ))))
                onEvent(.event(.itemDelta(
                    itemId: itemId,
                    bodyAppend: "RCW1\tA\t1\nO\tBuild passed\nE\tUnit tests are green\n.\n",
                    outputAppend: nil,
                    summary: nil
                )))
                onEvent(.event(.itemCompleted(itemId: itemId, finalState: .completed)))
                // Provider terminal while rendering is still in flight.
                onEvent(.finished(.completed, finalMessage: "RCW1\tA\t1\nO\tShipped\n.\n", providerThreadId: "pt-1"))
                return AgentRunHandle(runId: request.runId, process: nil) {}
            }
        }
        let thread = AgentThread(title: "defer deadline", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = StreamThenHoldRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.claude: runner]
        )
        // Short deadline so the test proves fail-open without a long sleep.
        coordinator.providerTerminalTranslationDeadline = 0.2
        let hangGate = DispatchSemaphore(value: 0)
        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { response, _, _, _ in
            hangGate.wait()
            return "Rendered: \(response)"
        }
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in
            recorder.recordRunFinished(threadId: tid, status: status)
        }

        let runId = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "do work"
        ))
        await waitUntil(3) {
            recorder.runFinishedCallbacks.contains { $0.0 == thread.id && $0.1 == .completed }
        }
        hangGate.signal()

        XCTAssertNil(coordinator.activeRunId(threadId: thread.id),
                     "translation deadline must release active ownership without waiting for local rendering")
        XCTAssertEqual(try runRepo.get(id: runId)?.status, .completed)
        XCTAssertNotNil(try runRepo.get(id: runId)?.finishedAt)
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .completed)
        XCTAssertEqual(recorder.runFinishedCallbacks.filter { $0.0 == thread.id }.count, 1,
                       "exactly one terminal lifecycle callback after deadline drain")
    }

    /// WHY: a split RCW1 prefix may be buffered when the user hits Stop. Cancel
    /// must drop the private transport buffer and complete immediately without
    /// leaking it into the transcript or waiting for a renderer.
    func test_stopRun_whileWirePrefixBuffered_cancelsWithoutWaitingForRenderer() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-during-wire")
        let thread = AgentThread(title: "wire stop", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let runner = WireStreamThenHangRunner()
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.claude: runner]
        )
        coordinator.finalResponseTranslator = { response, _, _, _ in
            XCTFail("an incomplete streamed frame must remain buffered, not reach the renderer")
            return response
        }
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in
            recorder.recordRunFinished(threadId: tid, status: status)
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "do work"
        ))
        // Let the partial RCW1 item enter the bounded private hold buffer.
        try await Task.sleep(nanoseconds: 80_000_000)

        let stopStarted = Date()
        coordinator.stopRun(threadId: thread.id)

        await waitUntil(2) {
            recorder.runFinishedCallbacks.contains { $0.0 == thread.id && $0.1 == .cancelled }
        }
        let elapsed = Date().timeIntervalSince(stopStarted)
        XCTAssertLessThan(elapsed, 1.0,
                          "Stop must finish as cancelled without waiting on a buffered wire prefix (took \(elapsed)s)")
        XCTAssertNil(coordinator.activeRunId(threadId: thread.id),
                     "Stop must release active ownership even when humanize was in flight")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .cancelled)
        XCTAssertEqual(recorder.runFinishedCallbacks.filter { $0.0 == thread.id }.count, 1,
                       "exactly one terminal lifecycle callback for the user Stop")
    }

    /// WHY: rail "Threads · N active" / Working spinners key off
    /// activeRunId/runThreads. When finishedAt is durable but activeThreads was
    /// never released (missed finish / filtered observer), ghosts remain until
    /// reconcile. Must free only run A, never a newer live run B.
    func test_reconcileStaleActiveOwnership_releasesDurableTerminalGhostsOnly() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("reconcile-ghost")
        final class HangRunner: AgentProviderRunner, @unchecked Sendable {
            let provider: AgentProvider = .codex
            func listModels() async -> [AgentModelDescriptor] { [] }
            func startRun(
                _ request: AgentRunRequest,
                onEvent: @escaping @Sendable (AgentRunEvent) -> Void
            ) async throws -> AgentRunHandle {
                onEvent(.status(.running))
                return AgentRunHandle(runId: request.runId, process: nil) {
                    // Cancel does not finish — ownership stays until reconcile.
                }
            }
        }
        let ghostThread = AgentThread(title: "ghost", provider: .codex, model: "fake-model")
        let liveThread = AgentThread(title: "live", provider: .codex, model: "fake-model")
        try threadRepo.upsert(ghostThread)
        try threadRepo.upsert(liveThread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.codex: HangRunner()]
        )
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)

        let ghostRunId = try await coordinator.startRun(AgentRunRequest(
            threadId: ghostThread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "ghost"
        ))
        let liveRunId = try await coordinator.startRun(AgentRunRequest(
            threadId: liveThread.id, provider: .codex, model: "fake-model", cwd: tmp, prompt: "live"
        ))
        // Simulate durable terminal without the normal finish path releasing memory.
        try runRepo.markStopped(id: ghostRunId, status: .completed)
        XCTAssertNotNil(coordinator.activeRunId(threadId: ghostThread.id),
                        "precondition: ghost still owned in memory")
        XCTAssertEqual(coordinator.activeRunId(threadId: liveThread.id), liveRunId)

        let released = coordinator.reconcileStaleActiveOwnershipWithDurableState()
        XCTAssertEqual(released, 1, "exactly one durable-terminal ghost must be released")
        XCTAssertNil(coordinator.activeRunId(threadId: ghostThread.id),
                     "ghost Working ownership must clear when finishedAt is durable")
        XCTAssertEqual(coordinator.activeRunId(threadId: liveThread.id), liveRunId,
                       "reconcile must not clear a still-live run on another thread")
        XCTAssertEqual(recorder.finished.filter { $0.0 == ghostRunId }.count, 1,
                       "stale release must fan out didFinish once for the ghost run")
        XCTAssertFalse(recorder.finished.contains { $0.0 == liveRunId },
                       "live run must not receive a terminal fan-out from reconcile")
    }

    /// WHY: finishingRuns was set while final-response RCW1 rendering ran, but
    /// pendingTerminalEvents was still empty. markStopRequested treated
    /// finishingRuns as durabilityPending and returned without claiming cancel —
    /// pure no-op Stop until rendering returned.
    func test_stopRun_duringFinalResponseWireRendering_claimsCancelImmediately() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("stop-final-wire")
        final class WireFinalThenHangRunner: AgentProviderRunner, @unchecked Sendable {
            let provider: AgentProvider = .claude
            func listModels() async -> [AgentModelDescriptor] { [] }
            func startRun(
                _ request: AgentRunRequest,
                onEvent: @escaping @Sendable (AgentRunEvent) -> Void
            ) async throws -> AgentRunHandle {
                let providerThreadId = request.providerThreadId ?? UUID().uuidString
                onEvent(.status(.running))
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                onEvent(.event(.turnStarted(turnId: "t-final")))
                // Provider terminal with RCW1 final — triggers finishingRuns + async rendering.
                onEvent(.finished(
                    .completed,
                    finalMessage: "RCW1\tA\t1\nO\tBuild passed\nE\tUnit tests are green\n.\n",
                    providerThreadId: providerThreadId
                ))
                return AgentRunHandle(runId: request.runId, process: nil) {}
            }
        }
        let thread = AgentThread(title: "final wire stop", provider: .claude, model: "fake-model")
        try threadRepo.upsert(thread)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providers: [.claude: WireFinalThenHangRunner()]
        )
        let hangGate = DispatchSemaphore(value: 0)
        var translatorEntered = false
        coordinator.finalResponseWireAdmissionCheck = { _, _ in true }
        coordinator.finalResponseTranslator = { response, _, _, _ in
            translatorEntered = true
            hangGate.wait()
            return "Rendered final: \(response)"
        }
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        coordinator.onRunFinished = { tid, _, status in
            recorder.recordRunFinished(threadId: tid, status: status)
        }

        _ = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "finish with wire"
        ))
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(translatorEntered,
                      "precondition: final RCW1 response must enter rendering before Stop")
        // Ownership may still be held while translation runs.
        XCTAssertNotNil(coordinator.activeRunId(threadId: thread.id),
                        "precondition: final RCW1 rendering must still own the run in memory")

        let stopStarted = Date()
        coordinator.stopRun(threadId: thread.id)
        await waitUntil(2) {
            recorder.runFinishedCallbacks.contains { $0.0 == thread.id }
        }
        let elapsed = Date().timeIntervalSince(stopStarted)
        hangGate.signal()

        XCTAssertLessThan(elapsed, 1.0,
                          "Stop during final RCW1 rendering must not no-op until the renderer returns")
        XCTAssertNil(coordinator.activeRunId(threadId: thread.id))
        let terminal = recorder.runFinishedCallbacks.first { $0.0 == thread.id }?.1
        XCTAssertEqual(terminal, .cancelled,
                       "user Stop during final rendering must publish cancelled, not wait for completed")
    }
}

private final class PendingStopStressRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex
    private let lock = NSLock()
    private var entered = 0
    private var released = 0
    private var cancelled = 0

    var enteredCount: Int { lock.withLock { entered } }
    var cancelledCount: Int { lock.withLock { cancelled } }

    func listModels() async -> [AgentModelDescriptor] { [] }

    func releaseThrough(_ ordinal: Int) {
        lock.withLock { released = max(released, ordinal) }
    }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let ordinal = lock.withLock { () -> Int in
            entered += 1
            return entered
        }
        onEvent(.status(.running))
        while lock.withLock({ released < ordinal }) {
            await Task.yield()
        }
        return AgentRunHandle(runId: request.runId, process: nil) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.cancelled += 1 }
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}
