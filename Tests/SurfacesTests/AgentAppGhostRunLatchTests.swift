import XCTest
@testable import Surfaces
import CoreModel
@testable import Persistence
@testable import AgentRuntime

/// UX-MAC_AGENT-STOP-GHOST: a surface must only claim a thread is Working while a
/// run is genuinely active, and Stop must always be able to return the surface to
/// idle.
///
/// FIELD EVIDENCE (2026-07-29, samuel-blog workspace): thread
/// 1E2D58F4's only run finished 2026-07-28T03:36Z, yet 46 hours later the Agent
/// App painted "Working for 2765m" with a live Stop button. `agent_stream_events`
/// shows seq 1604-1613 written against that finished run at 2026-07-30T01:37:25Z —
/// ten seconds after an app relaunch — all of them the recovered codex session
/// re-announcing itself (`mcpServer/startupStatus`, then the `itemStarted` it had
/// been interrupted on). Those events re-latched the Working projection, and
/// because no run was actually alive, Stop could not undo it: the first click only
/// latched "Stopping…" and the second reported "Stop is taking longer than
/// expected" while the spinner kept counting.
@MainActor
final class AgentAppGhostRunLatchTests: XCTestCase {

    private struct Harness {
        let vm: AgentAppViewModel
        let coordinator: AgentRunCoordinator
        let threadRepo: AgentThreadRepository
        let runRepo: AgentRunRepository
        let threadId: AgentThreadID
    }

    private func makeHarness() throws -> Harness {
        let tmp = NSTemporaryDirectory() + "rc2-vm-ghost-run-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providers: [:])
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        let thread = AgentThread(workspaceId: workspaceID, title: "hourly", provider: .codex,
                                 model: "gpt-5.6-sol", status: .completed)
        try threadRepo.upsert(thread)
        vm.reloadThreads()
        vm.selectThread(thread.id, markRead: false)
        return Harness(vm: vm, coordinator: coordinator, threadRepo: threadRepo,
                       runRepo: runRepo, threadId: thread.id)
    }

    /// The exact frame codex replays when a recovered app-server session reconnects.
    private func mcpStartupEvent() -> AssistantEvent {
        .providerRuntime(ProviderRuntimeEvent(
            provider: .codex,
            source: "codex",
            method: "mcpServer/startupStatus",
            payloadJSON: #"{"server":"remote-code","state":"ready"}"#,
            receivedAtMs: 1
        ))
    }

    private func waitAsync(_ desc: String, timeout: TimeInterval = 4, _ cond: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if cond() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("timed out waiting for: \(desc)")
    }

    func test_recoveredSessionEventForFinishedRunDoesNotRelatchWorking() async throws {
        let h = try makeHarness()
        // Durable truth after a relaunch: the run ended yesterday. `terminalRunIds`
        // is in-memory only, so this fresh surface has never seen it end.
        let finished = AgentRun(threadId: h.threadId, provider: .codex, model: "gpt-5.6-sol",
                                status: .completed,
                                startedAt: Date().addingTimeInterval(-46 * 3600),
                                finishedAt: Date().addingTimeInterval(-46 * 3600 + 240))
        try h.runRepo.upsert(finished)
        // The coordinator stores a stream event before fanning it out to observers
        // (store-before-loss), so a real surface only ever sees replayed content the
        // next open bundle already contains. This spec calls the observer directly,
        // which makes the event non-durable — injecting it into the still-in-flight
        // open would just be erased by the replay swap, a state production cannot
        // reach. Settle the seed open first so the paint assertion measures the gate.
        await h.vm.waitForSelectThreadHydrationForTesting()

        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: finished.id, threadId: h.threadId)

        // The event must still paint (this is transcript content, not a lie about
        // liveness) — that is what proves the gate is on the latch, not the stream.
        await waitAsync("replayed provider event still reaches the timeline") {
            !h.vm.timeline.providerRuntimeEvents.isEmpty
        }
        XCTAssertFalse(h.vm.isThreadStartingOrRunning(h.threadId),
                       "a stream event for a run that finished 46h ago must not make the thread Working again")
        XCTAssertNil(h.vm.currentRunId,
                     "a finished run must not become the surface's current run (Stop would target a dead run)")
        XCTAssertNil(h.vm.runStartedAt,
                     "no Working-for clock may start for a run that is not active")
        XCTAssertNotEqual(h.vm.status, .running,
                          "thread status must stay terminal so the composer sends instead of queueing")
    }

    func test_liveRunStillLatchesWorkingFromStreamEvents() async throws {
        // Guard against over-correcting: a run the coordinator has committed as
        // pending/running (events can precede handle registration) must still
        // drive the Working projection off its stream events.
        let h = try makeHarness()
        let live = AgentRun(threadId: h.threadId, provider: .codex, model: "gpt-5.6-sol",
                            status: .running)
        try h.runRepo.upsert(live)

        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: live.id, threadId: h.threadId)

        await waitAsync("durable running run latches Working") {
            h.vm.currentRunId == live.id && h.vm.status == .running
        }
        XCTAssertTrue(h.vm.isThreadStartingOrRunning(h.threadId))
        XCTAssertNotNil(h.vm.runStartedAt)
    }

    func test_stopClearsWorkingProjectionWhenTheRunAlreadyFinished() async throws {
        // "It's never stopping when done": the turn ends, the surface keeps
        // spinning, and Stop must be the escape hatch instead of latching
        // "Stopping…" forever on a run that no longer exists.
        let h = try makeHarness()
        let run = AgentRun(threadId: h.threadId, provider: .codex, model: "gpt-5.6-sol",
                           status: .running)
        try h.runRepo.upsert(run)
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: run.id, threadId: h.threadId)
        await waitAsync("surface latches Working for the live run") {
            h.vm.isThreadStartingOrRunning(h.threadId)
        }
        // The run reaches its terminal state without the surface ever seeing
        // didFinish (workspace-filtered miss, relaunch, or a dropped observer).
        try h.runRepo.markStopped(id: run.id, status: .completed)
        XCTAssertTrue(h.vm.isThreadStartingOrRunning(h.threadId),
                      "precondition: the stale Working projection is what the user is looking at")

        h.vm.stop()

        XCTAssertFalse(h.vm.isStopping,
                       "Stop must not latch Stopping… when there is no run left to interrupt")
        XCTAssertFalse(h.vm.isThreadStartingOrRunning(h.threadId),
                       "Stop must return the thread to idle so the composer works again")
        XCTAssertNil(h.vm.currentRunId)
        XCTAssertNil(h.vm.runStartedAt)
        XCTAssertFalse(h.vm.statusMessage.contains("taking longer"),
                       "clearing a stale projection is not a stop timeout — no scary banner")
    }

    /// Ordering guard (Codex advisory, 2026-07-29): the stale-projection branch must
    /// NOT shadow the second-click force stop. The first Stop synthesizes a durable
    /// cancelled terminal with `providerTerminalAcknowledged: false` and releases
    /// coordinator ownership while the provider's own teardown is still outstanding —
    /// so at that instant the thread looks "not stoppable" even though a live adapter
    /// session remains. Only `stopAndAwaitTermination` releases that session, so a
    /// second click while `isStopping` must still reach it.
    func test_secondStopClickStillForcesProviderSessionTeardown() async throws {
        let tmp = NSTemporaryDirectory() + "rc2-vm-ghost-force-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let adapter = SessionCountingAdapter(provider: .codex)
        let coordinator = AgentRunCoordinator(runRepo: runRepo, messageRepo: messageRepo,
                                              threadRepo: threadRepo,
                                              providerAdapters: [.codex: adapter])
        let workspaceID = WorkspaceID()
        let vm = AgentAppViewModel(workspaceID: workspaceID, cwd: tmp,
                                   coordinator: coordinator, threadRepo: threadRepo,
                                   messageRepo: messageRepo,
                                   promptHistoryStore: PromptHistoryStore(db: db))
        // Durably terminal thread + no coordinator ownership: exactly the window
        // right after the first Stop claimed its terminal. stopRun(threadId:) alone
        // will not touch the adapter here, so only the force path can free it.
        let thread = AgentThread(workspaceId: workspaceID, title: "force stop", provider: .codex,
                                 model: "gpt-5.6-luna", status: .completed)
        try threadRepo.upsert(thread)
        vm.reloadThreads()
        vm.selectThread(thread.id, markRead: false)
        vm.isStopping = true

        vm.stop()

        await waitAsync("second Stop click reaches provider session teardown", timeout: 12) {
            adapter.stopSessionCount > 0
        }
        await waitAsync("force stop releases the Stopping… latch", timeout: 12) {
            vm.isStopping == false
        }
    }

    func test_stopButtonStateStopsShowingAfterStaleProjectionCleared() async throws {
        let h = try makeHarness()
        let run = AgentRun(threadId: h.threadId, provider: .codex, model: "gpt-5.6-sol",
                           status: .running)
        try h.runRepo.upsert(run)
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: run.id, threadId: h.threadId)
        await waitAsync("surface latches Working for the live run") {
            h.vm.selectedThreadRunIsStartingOrRunning
        }
        try h.runRepo.markStopped(id: run.id, status: .completed)
        h.vm.stop()
        XCTAssertEqual(
            AgentAppViewModel.stopButtonState(
                runActive: h.vm.selectedThreadRunIsStartingOrRunning,
                isStopping: h.vm.isStopping
            ),
            .hidden,
            "with the stale projection gone the Stop affordance must disappear, not sit on Stopping…"
        )
    }
}

/// Minimal adapter that always reports a live session and counts teardowns, so a
/// test can prove the force-stop path reached `stopSession`.
private final class SessionCountingAdapter: AgentProviderAdapter, @unchecked Sendable {
    let provider: AgentProvider
    private let lock = NSLock()
    private var _stopSessionCount = 0

    var stopSessionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stopSessionCount
    }

    init(provider: AgentProvider) { self.provider = provider }

    func listModels() async -> [AgentModelDescriptor] { [] }
    func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        AgentRunHandle(runId: request.runId, process: nil) {}
    }
    func interruptTurn(threadId: AgentThreadID) throws {}
    func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {}
    func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {}
    func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {}
    func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        _stopSessionCount += 1
        lock.unlock()
    }
    func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {}
    func listSessions() -> [AgentProviderSessionSummary] { [] }
    func hasSession(threadId: AgentThreadID) -> Bool { true }
    func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
    func forkThread(threadId: AgentThreadID) async throws -> String { "child" }
    func forkThread(_ request: AgentProviderForkRequest) async throws -> String { "child" }
    func compensateFork(_ request: AgentProviderForkRequest, providerChildThreadId: String) async throws {}
    func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
    func stopAll() {}
    func stopAllForAppTermination() {}
    func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
}
