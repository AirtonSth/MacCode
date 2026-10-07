import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// Passive recovery must never borrow terminal ownership from a finished lastRunId.
///
/// Incident: recovery mapped every adapter callback onto session.lastRunId, so a
/// replayed Claude result synthesized turn/status/finished against a terminal
/// run and painted early green completion while newer work was active.
final class AgentRunCoordinatorPassiveRecoveryFirewallTests: XCTestCase {

    private final class LifecycleRecorder: AgentRunObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var _finished: [(AgentRunID, AgentRunStatus)] = []
        private var _statuses: [(AgentRunID, AgentRunStatus)] = []
        private var _events: [(AgentRunID, AssistantEvent)] = []
        private var _runFinished: [(AgentThreadID, AgentRunID, AgentRunStatus)] = []

        var finished: [(AgentRunID, AgentRunStatus)] {
            lock.lock(); defer { lock.unlock() }; return _finished
        }
        var statuses: [(AgentRunID, AgentRunStatus)] {
            lock.lock(); defer { lock.unlock() }; return _statuses
        }
        var events: [(AgentRunID, AssistantEvent)] {
            lock.lock(); defer { lock.unlock() }; return _events
        }
        var runFinished: [(AgentThreadID, AgentRunID, AgentRunStatus)] {
            lock.lock(); defer { lock.unlock() }; return _runFinished
        }

        func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID) {
            lock.lock(); _events.append((run, event)); lock.unlock()
        }
        func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?) {
            lock.lock(); _finished.append((runId, status)); lock.unlock()
        }
        func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID) {
            lock.lock(); _statuses.append((runId, status)); lock.unlock()
        }
    }

    /// Recovery adapter that can inject late callbacks after recoverSession returns.
    private final class InjectingRecoverAdapter: AgentProviderAdapter, @unchecked Sendable {
        let provider: AgentProvider = .claude
        private let lock = NSLock()
        private var _hasSession = false
        private var _recoverCalls = 0
        private var _stopSessionCalls = 0
        private var _sendTurnCalls = 0
        private var recoveryOnEvent: (@Sendable (AgentRunEvent) -> Void)?
        private var turnOnEvent: (@Sendable (AgentRunEvent) -> Void)?
        private let initialRecoveryEvents: [AgentRunEvent]
        private let turnEvents: [AgentRunEvent]

        var recoverCalls: Int { lock.lock(); defer { lock.unlock() }; return _recoverCalls }
        var stopSessionCalls: Int { lock.lock(); defer { lock.unlock() }; return _stopSessionCalls }
        var sendTurnCalls: Int { lock.lock(); defer { lock.unlock() }; return _sendTurnCalls }

        init(
            initialRecoveryEvents: [AgentRunEvent] = [],
            turnEvents: [AgentRunEvent] = []
        ) {
            self.initialRecoveryEvents = initialRecoveryEvents
            self.turnEvents = turnEvents
        }

        func listModels() async -> [AgentModelDescriptor] { [] }
        func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            throw AgentProviderAdapterError.unsupported("startSession")
        }
        func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
            lock.lock()
            _sendTurnCalls += 1
            _hasSession = true
            turnOnEvent = onEvent
            lock.unlock()
            let providerThreadId = request.providerThreadId ?? "provider-thread-live"
            onEvent(.status(.running))
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: "live-turn")))
            if turnEvents.isEmpty {
                // Leave open for explicit inject of terminal.
                return AgentRunHandle(runId: request.runId, process: nil) {
                    onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: providerThreadId))
                }
            }
            for event in turnEvents {
                onEvent(event)
            }
            return AgentRunHandle(runId: request.runId, process: nil) {}
        }
        func interruptTurn(threadId: AgentThreadID) throws {}
        func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
        func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
        func stopSession(threadId: AgentThreadID) throws {
            lock.lock(); _stopSessionCalls += 1; _hasSession = false; recoveryOnEvent = nil; turnOnEvent = nil; lock.unlock()
        }
        func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
            lock.lock()
            _recoverCalls += 1
            _hasSession = true
            recoveryOnEvent = onEvent
            let events = initialRecoveryEvents
            lock.unlock()
            for event in events {
                onEvent(event)
            }
        }
        func listSessions() -> [AgentProviderSessionSummary] { [] }
        func hasSession(threadId: AgentThreadID) -> Bool {
            lock.lock(); defer { lock.unlock() }; return _hasSession
        }
        func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
        func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
        func stopAll() {}
        func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}

        func injectRecovery(_ event: AgentRunEvent) {
            let cb: (@Sendable (AgentRunEvent) -> Void)?
            lock.lock(); cb = recoveryOnEvent; lock.unlock()
            cb?(event)
        }

        func injectTurn(_ event: AgentRunEvent) {
            let cb: (@Sendable (AgentRunEvent) -> Void)?
            lock.lock(); cb = turnOnEvent; lock.unlock()
            cb?(event)
        }
    }

    private func makeRepos(_ label: String) throws -> (
        AgentThreadRepository,
        AgentMessageRepository,
        AgentRunRepository,
        ProviderSessionRuntimeRepository,
        String
    ) {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return (
            AgentThreadRepository(db: db),
            AgentMessageRepository(db: db),
            AgentRunRepository(db: db),
            ProviderSessionRuntimeRepository(db: db),
            tmp
        )
    }

    private func waitUntil(_ timeout: TimeInterval = 4, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func syntheticLifecycleEvents(providerThreadId: String = "recovered-provider") -> [AgentRunEvent] {
        [
            .status(.running),
            .event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)),
            .event(.turnStarted(turnId: "replayed-turn")),
            .event(.turnCompleted(turnId: "replayed-turn", finalMessage: "ambient task-notification result")),
            .finished(.completed, finalMessage: "ambient task-notification result", providerThreadId: providerThreadId)
        ]
    }

    // MARK: - Terminal lastRunId cannot finalize via passive recovery

    func test_passiveRecovery_terminalLastRunId_doesNotPublishLifecycleOrFinish() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("passive-terminal-firewall")
        var thread = AgentThread(title: "terminal history", provider: .claude, model: "fake-model")
        thread.status = .completed
        thread.providerThreadId = "stale-provider"
        try threadRepo.upsert(thread)

        let terminalRun = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            status: .completed,
            startedAt: Date().addingTimeInterval(-3600),
            finishedAt: Date().addingTimeInterval(-3500)
        )
        try runRepo.upsert(terminalRun)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .claude,
            status: .completed,
            resumeCursor: "stale-provider",
            cwd: tmp,
            model: "fake-model",
            lastRunId: terminalRun.id,
            lastEventKind: "run.completed"
        ))

        let adapter = InjectingRecoverAdapter(initialRecoveryEvents: syntheticLifecycleEvents())
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.claude: adapter]
        )
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)
        var onRunFinishedCount = 0
        coordinator.onRunFinished = { _, _, _ in onRunFinishedCount += 1 }

        _ = try await coordinator.readThread(threadId: thread.id)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            recorder.finished.filter { $0.0 == terminalRun.id }.count,
            0,
            "passive recovery must not didFinish a terminal lastRunId — that paints early green completion"
        )
        XCTAssertEqual(onRunFinishedCount, 0,
                       "no onRunFinished / queue-drain / notification edge from terminal recovery lifecycle")
        XCTAssertFalse(
            recorder.statuses.contains { $0.0 == terminalRun.id && ($0.1 == .running || $0.1 == .completed) },
            "terminal lastRunId must not receive recovered status callbacks"
        )
        XCTAssertFalse(
            recorder.events.contains { runId, event in
                guard runId == terminalRun.id else { return false }
                switch event {
                case .turnStarted, .turnCompleted: return true
                default: return false
                }
            },
            "terminal lastRunId must not receive recovered turnStarted/turnCompleted"
        )
        XCTAssertEqual(try runRepo.get(id: terminalRun.id)?.status, .completed,
                       "durable terminal status must stay completed")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.status, .completed,
                       "thread must not be re-marked running/completed by recovery lifecycle")
        XCTAssertEqual(try threadRepo.get(id: thread.id)?.hasUnread, false,
                       "recovery must not flip unread on a terminal historical run")
    }

    func test_completedTerminalHistory_usesDurableStreamWithoutLiveRecovery() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("durable-terminal-history")
        var thread = AgentThread(title: "done", provider: .claude, model: "fake-model")
        thread.status = .completed
        try threadRepo.upsert(thread)
        let terminalRun = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            status: .completed,
            finishedAt: Date().addingTimeInterval(-60)
        )
        try runRepo.upsert(terminalRun)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .claude,
            status: .completed,
            resumeCursor: "provider-done",
            cwd: tmp,
            model: "fake-model",
            lastRunId: terminalRun.id
        ))
        // Seed a durable stream event the UI can still paint after relaunch.
        let historical = AssistantEvent.turnCompleted(turnId: "t1", finalMessage: "historical answer")
        let payload = try String(data: JSONEncoder().encode(historical), encoding: .utf8) ?? "{}"
        try runRepo.appendStreamEvent(
            runId: terminalRun.id,
            seq: 1,
            kind: "turnCompleted",
            payloadJSON: payload
        )

        let adapter = InjectingRecoverAdapter(
            initialRecoveryEvents: syntheticLifecycleEvents(providerThreadId: "must-not-spawn")
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.claude: adapter]
        )

        _ = try await coordinator.readThread(threadId: thread.id)
        // The Agent App open path (gatherThreadOpenBundle) paints from the
        // coordinator's durable stream window, not from the adapter replay.
        let events = coordinator.latestStreamEvents(threadId: thread.id)

        XCTAssertEqual(adapter.recoverCalls, 0,
                       "completed terminal history must be served from durable stream events without live recovery")
        XCTAssertFalse(events.isEmpty,
                       "bounded durable history must still hydrate the recent stream window")
        XCTAssertTrue(events.contains { event in
            if case .turnCompleted(_, let finalMessage) = event { return finalMessage == "historical answer" }
            return false
        }, "the durable window must carry the persisted historical answer")
    }

    // MARK: - Recovery epoch A cannot finalize after foreground B starts

    func test_recoverTerminalA_startB_lateRecoveryCallbackA_cannotAffectB() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("recovery-epoch-a-b")
        var thread = AgentThread(title: "epoch race", provider: .claude, model: "fake-model")
        thread.status = .completed
        thread.providerThreadId = "provider-a"
        try threadRepo.upsert(thread)

        let runA = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            status: .completed,
            finishedAt: Date().addingTimeInterval(-120)
        )
        try runRepo.upsert(runA)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .claude,
            status: .completed,
            resumeCursor: "provider-a",
            cwd: tmp,
            model: "fake-model",
            lastRunId: runA.id
        ))

        // Start with empty recovery events so we can inject late A after B starts.
        // For completed sessions the durable-history path may skip recover entirely;
        // force an interrupted/recoverable session shape with terminal lastRunId so
        // live recovery still installs a callback epoch, then start B.
        thread.status = .interrupted
        try threadRepo.upsert(thread)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .claude,
            status: .interrupted,
            resumeCursor: "provider-a",
            cwd: tmp,
            model: "fake-model",
            lastRunId: runA.id
        ))

        let adapter = InjectingRecoverAdapter(initialRecoveryEvents: [])
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.claude: adapter]
        )
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)

        // Install recovery epoch A (no lifecycle ownership — lastRun is terminal).
        _ = try await coordinator.readThread(threadId: thread.id)
        XCTAssertEqual(adapter.recoverCalls, 1, "interrupted session still needs live recovery install")

        let runB = try await coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            cwd: tmp,
            prompt: "new foreground turn",
            providerThreadId: "provider-a"
        ))
        await waitUntil { coordinator.activeRunId(threadId: thread.id) == runB }

        // Late ambient result from recovery epoch A after B is live.
        adapter.injectRecovery(.status(.running))
        adapter.injectRecovery(.event(.turnStarted(turnId: "stale-a")))
        adapter.injectRecovery(.event(.turnCompleted(turnId: "stale-a", finalMessage: "stale A result")))
        adapter.injectRecovery(.finished(
            .completed,
            finalMessage: "stale A result",
            providerThreadId: "provider-a"
        ))
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(coordinator.activeRunId(threadId: thread.id), runB,
                       "late recovery A must not release or steal active ownership of B")
        XCTAssertEqual(try runRepo.get(id: runB)?.status, .running,
                       "B must remain durable-running after late A callbacks")
        XCTAssertEqual(try runRepo.get(id: runA.id)?.status, .completed,
                       "A stays terminal; recovery cannot re-complete it")
        XCTAssertFalse(
            recorder.finished.contains { $0.0 == runB },
            "late A must not synthesize didFinish for B"
        )
        XCTAssertEqual(
            recorder.finished.filter { $0.0 == runA.id }.count,
            0,
            "late A recovery lifecycle must not publish didFinish for terminal A either"
        )

        // B's own matching terminal completes exactly once.
        adapter.injectTurn(.event(.turnCompleted(turnId: "live-turn", finalMessage: "B answer")))
        adapter.injectTurn(.finished(
            .completed,
            finalMessage: "B answer",
            providerThreadId: "provider-a"
        ))
        await waitUntil {
            recorder.finished.filter { $0.0 == runB }.count >= 1
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            recorder.finished.filter { $0.0 == runB }.count,
            1,
            "B must complete exactly once from its own terminal callback"
        )
        XCTAssertEqual(try runRepo.get(id: runB)?.status, .completed)
        XCTAssertNil(coordinator.activeRunId(threadId: thread.id))
    }

    // MARK: - Live pending/running lastRunId still receives recovery lifecycle

    func test_passiveRecovery_pendingLastRunId_stillForwardsLifecycle() async throws {
        let (threadRepo, messageRepo, runRepo, sessionRepo, tmp) = try makeRepos("passive-live-lifecycle")
        var thread = AgentThread(title: "live recovery", provider: .claude, model: "fake-model")
        thread.status = .running
        try threadRepo.upsert(thread)
        let liveRun = AgentRun(
            threadId: thread.id,
            provider: .claude,
            model: "fake-model",
            status: .running
        )
        try runRepo.upsert(liveRun)
        try sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id,
            provider: .claude,
            status: .running,
            resumeCursor: "provider-live",
            cwd: tmp,
            model: "fake-model",
            lastRunId: liveRun.id
        ))

        let adapter = InjectingRecoverAdapter(
            initialRecoveryEvents: [
                .status(.running),
                .event(.threadStarted(threadId: "provider-live", providerThreadId: "provider-live")),
                .event(.turnStarted(turnId: "resume-turn")),
                .event(.turnCompleted(turnId: "resume-turn", finalMessage: "recovered answer")),
                .finished(.completed, finalMessage: "recovered answer", providerThreadId: "provider-live")
            ]
        )
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.claude: adapter]
        )
        let recorder = LifecycleRecorder()
        coordinator.addObserver(recorder)

        _ = try await coordinator.readThread(threadId: thread.id)
        await waitUntil {
            recorder.finished.contains { $0.0 == liveRun.id }
        }

        XCTAssertEqual(adapter.recoverCalls, 1)
        XCTAssertEqual(
            recorder.finished.filter { $0.0 == liveRun.id }.count,
            1,
            "exact durable pending/running lastRunId still owns recovered lifecycle completion"
        )
        XCTAssertEqual(try runRepo.get(id: liveRun.id)?.status, .completed)
    }
}
