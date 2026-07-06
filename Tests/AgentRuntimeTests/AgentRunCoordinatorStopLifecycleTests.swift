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
        private var _recoverCalls = 0
        private var _stopSessionCalls = 0
        var recoverCalls: Int { lock.lock(); defer { lock.unlock() }; return _recoverCalls }
        var stopSessionCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopSessionCalls }

        init(hasSession: Bool = false) { _hasSession = hasSession }

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
            lock.lock(); _recoverCalls += 1; _hasSession = true; lock.unlock()
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
        let errorMessages: [String] = replayed.compactMap {
            if case .error(let message, _) = $0 { return message }
            return nil
        }
        XCTAssertTrue(errorMessages.contains("Invalid API key"),
                      "runner-level .error events must be persisted as stream events so replay after a " +
                      "thread switch or relaunch restores WHY the run failed (F22); got: \(errorMessages)")
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
}
