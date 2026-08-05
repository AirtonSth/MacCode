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
        let messageRepo: AgentMessageRepository
        let runRepo: AgentRunRepository
        let db: SQLiteDB
        let workspaceID: WorkspaceID
        let cwd: String
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
                       messageRepo: messageRepo, runRepo: runRepo, db: db,
                       workspaceID: workspaceID, cwd: tmp, threadId: thread.id)
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

    /// Backlogged terminal callback for old run A must not idle-paint newer active B.
    func test_lateTerminalFinishForRunA_doesNotClearSelectedOwnershipOfActiveRunB() async throws {
        let h = try makeHarness()
        let runA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .completed,
            startedAt: Date().addingTimeInterval(-120),
            finishedAt: Date().addingTimeInterval(-60)
        )
        try h.runRepo.upsert(runA)
        let runB = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(runB)

        // Latch B as the surface's live tracked generation.
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: runB.id, threadId: h.threadId)
        await waitAsync("surface owns live run B") {
            h.vm.currentRunId == runB.id && h.vm.status == .running
        }
        XCTAssertTrue(h.vm.isThreadStartingOrRunning(h.threadId))

        // Delayed didFinish for terminal A (main-actor backlog / stale recovery).
        h.vm.runCoordinator(
            h.coordinator,
            didFinish: runA.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "stale A final",
            providerThreadId: "provider-a"
        )

        await waitAsync("main-actor drains finish callback") {
            // Give the Task { @MainActor } a turn without requiring state change.
            true
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(h.vm.currentRunId, runB.id,
                       "late terminal A must not clear currentRunId while exact durable/tracked B owns the thread")
        XCTAssertEqual(h.vm.status, .running,
                       "late terminal A must not paint selected status idle/completed over active B")
        XCTAssertTrue(h.vm.isThreadStartingOrRunning(h.threadId),
                      "Working/Stop chrome must stay bound to B")
        XCTAssertNotNil(h.vm.runStartedAt,
                        "Working-for clock for B must survive a stale A finish")
        XCTAssertFalse(try h.messageRepo.list(threadId: h.threadId).contains {
            $0.role == .assistant && $0.content == "stale A final"
        }, "late A must not append stale final text after B has started")
    }

    func test_lateTerminalStatusForRunA_doesNotClearSelectedOwnershipOfActiveRunB() async throws {
        let h = try makeHarness()
        let runA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .completed,
            finishedAt: Date().addingTimeInterval(-30)
        )
        try h.runRepo.upsert(runA)
        let runB = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(runB)

        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: runB.id, threadId: h.threadId)
        await waitAsync("surface owns live run B") {
            h.vm.currentRunId == runB.id && h.vm.status == .running
        }

        h.vm.runCoordinator(
            h.coordinator,
            didChangeStatus: .completed,
            runId: runA.id,
            threadId: h.threadId
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(h.vm.currentRunId, runB.id)
        XCTAssertEqual(h.vm.status, .running)
        XCTAssertTrue(h.vm.isThreadStartingOrRunning(h.threadId))
    }

    func test_staleRunningStatusForRunACannotClaimEmptySurfaceWhileDurableRunBIsActive() async throws {
        let h = try makeHarness()
        let runA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .completed,
            finishedAt: Date().addingTimeInterval(-30)
        )
        try h.runRepo.upsert(runA)
        let runB = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(runB)
        XCTAssertNil(h.vm.currentRunId, "precondition: selected surface has not latched B yet")

        h.vm.runCoordinator(
            h.coordinator,
            didChangeStatus: .running,
            runId: runA.id,
            threadId: h.threadId
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(h.vm.currentRunId,
                     "ambient running callback for terminal A must not exploit an empty surface latch")
        XCTAssertNotEqual(h.vm.status, .running)
        XCTAssertFalse(h.vm.isThreadStartingOrRunning(h.threadId))
    }

    func test_matchingTerminalFinishForTrackedRunStillClearsSelectedState() async throws {
        let h = try makeHarness()
        let runA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(runA)
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: runA.id, threadId: h.threadId)
        await waitAsync("surface owns run A") {
            h.vm.currentRunId == runA.id
        }
        try h.runRepo.markStopped(id: runA.id, status: .completed)

        h.vm.runCoordinator(
            h.coordinator,
            didFinish: runA.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "done",
            providerThreadId: nil
        )
        await waitAsync("matching terminal A clears selected ownership") {
            h.vm.currentRunId == nil && h.vm.status == .completed
        }
        XCTAssertFalse(h.vm.isThreadStartingOrRunning(h.threadId))
    }

    func test_staleRunMapDoesNotRejectCurrentRunTerminal() async throws {
        let h = try makeHarness()
        let staleA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(staleA)
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: staleA.id, threadId: h.threadId)
        await waitAsync("surface caches run A") { h.vm.currentRunId == staleA.id }
        try h.runRepo.markStopped(id: staleA.id, status: .completed)

        let currentB = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(currentB)
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: currentB.id, threadId: h.threadId)
        await waitAsync("surface advances to run B while stale A map remains") {
            h.vm.currentRunId == currentB.id
        }
        try h.runRepo.markStopped(id: currentB.id, status: .completed)

        h.vm.runCoordinator(
            h.coordinator,
            didFinish: currentB.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "current B final",
            providerThreadId: "provider-b"
        )
        await waitAsync("current B terminal clears the selected projection") {
            h.vm.currentRunId == nil && h.vm.status == .completed
        }

        XCTAssertFalse(h.vm.isThreadStartingOrRunning(h.threadId))
        XCTAssertTrue(try h.messageRepo.list(threadId: h.threadId).contains {
            $0.role == .assistant && $0.content == "current B final"
        }, "a stale cache entry for A must not suppress B's authoritative terminal/final")

        // B is now fully terminal and currentRunId is nil. A callback arriving
        // even later must still be rejected by retained generation ordering.
        h.vm.runCoordinator(
            h.coordinator,
            didFinish: staleA.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "late stale A final",
            providerThreadId: "provider-a"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(h.vm.currentRunId)
        XCTAssertEqual(h.vm.status, .completed)
        XCTAssertFalse(try h.messageRepo.list(threadId: h.threadId).contains {
            $0.role == .assistant && $0.content == "late stale A final"
        }, "older A must remain rejected after newer B already cleared current ownership")
    }

    func test_freshViewModelRejectsLateAAfterNewerTerminalB() async throws {
        let h = try makeHarness()
        let staleA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .completed,
            startedAt: Date().addingTimeInterval(60),
            finishedAt: Date().addingTimeInterval(61)
        )
        try h.runRepo.upsert(staleA)
        let newerB = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .completed,
            startedAt: Date().addingTimeInterval(-60),
            finishedAt: Date().addingTimeInterval(-59)
        )
        try h.runRepo.upsert(newerB)
        // Updating A must not move its durable generation after B.
        try h.runRepo.upsert(staleA)
        XCTAssertEqual(try h.runRepo.latest(for: h.threadId)?.id, newerB.id)

        h.vm.dispose()
        let fresh = AgentAppViewModel(
            workspaceID: h.workspaceID,
            cwd: h.cwd,
            coordinator: h.coordinator,
            threadRepo: h.threadRepo,
            messageRepo: h.messageRepo,
            promptHistoryStore: PromptHistoryStore(db: h.db)
        )
        fresh.reloadThreads()
        fresh.selectThread(h.threadId, markRead: false)
        fresh.runCoordinator(
            h.coordinator,
            didFinish: staleA.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "stale A after reload",
            providerThreadId: "provider-a"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(try h.messageRepo.list(threadId: h.threadId).contains {
            $0.role == .assistant && $0.content == "stale A after reload"
        })
        XCTAssertNil(fresh.currentRunId)
        fresh.dispose()
    }

    func test_terminalCallbackFailsClosedWhenNewestDurabilityIsUnknown() async throws {
        XCTAssertEqual(AgentAppViewModel.terminalCallbackAuthority(
            runId: AgentRunID(),
            latestObservedRunId: nil,
            activeRunId: nil,
            currentRunId: nil,
            durableNewestLookup: { throw SQLiteError.step("injected") }
        ), .unknown)

        let h = try makeHarness()
        let staleA = AgentRun(threadId: h.threadId, provider: .codex, model: "gpt-5.6-sol", status: .completed)
        try h.runRepo.upsert(staleA)
        let newerB = AgentRun(threadId: h.threadId, provider: .codex, model: "gpt-5.6-sol", status: .completed)
        try h.runRepo.upsert(newerB)

        h.db.beforeStatementStepForTesting = { sql in
            guard sql.contains("FROM agent_runs"), sql.contains("ORDER BY rowid DESC") else { return }
            h.db.beforeStatementStepForTesting = nil
            h.db.injectedResultCodesForTesting = [10]
        }
        h.vm.runCoordinator(
            h.coordinator,
            didFinish: staleA.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "stale A during durability error",
            providerThreadId: "provider-a"
        )
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(try h.messageRepo.list(threadId: h.threadId).contains {
            $0.role == .assistant && $0.content == "stale A during durability error"
        })
        XCTAssertNil(h.vm.currentRunId)
    }

    func test_rejectedOptimisticRunBRestoresLiveRunAAsLatestGeneration() async throws {
        let h = try makeHarness()
        let liveA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(liveA)
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: liveA.id, threadId: h.threadId)
        await waitAsync("surface owns recovered live A") {
            h.vm.currentRunId == liveA.id
        }

        // Mirrors startProviderRun's optimistic UI update followed by admission
        // rejection because A still owns the provider session.
        let rejectedB = AgentRunID()
        let tracking = h.vm.beginOptimisticRunTracking(rejectedB, threadId: h.threadId)
        h.vm.rollbackOptimisticRunTracking(tracking, durability: .confirmedAbsent)

        try h.runRepo.markStopped(id: liveA.id, status: .completed)
        h.vm.runCoordinator(
            h.coordinator,
            didFinish: liveA.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "legitimate A final",
            providerThreadId: "provider-a"
        )
        await waitAsync("A terminal remains authorized after rejected B") {
            h.vm.currentRunId == nil && h.vm.status == .completed
        }

        XCTAssertTrue(try h.messageRepo.list(threadId: h.threadId).contains {
            $0.role == .assistant && $0.content == "legitimate A final"
        }, "a rejected non-durable B must restore A's generation marker")
    }

    func test_unknownOptimisticRunBDurabilityFailsClosedAndPreservesBOrdering() async throws {
        let h = try makeHarness()
        let runA = AgentRun(
            threadId: h.threadId,
            provider: .codex,
            model: "gpt-5.6-sol",
            status: .running
        )
        try h.runRepo.upsert(runA)
        h.vm.runCoordinator(h.coordinator, didReceive: mcpStartupEvent(),
                            run: runA.id, threadId: h.threadId)
        await waitAsync("surface owns A") { h.vm.currentRunId == runA.id }

        let runB = AgentRunID()
        let tracking = h.vm.beginOptimisticRunTracking(runB, threadId: h.threadId)
        let durability = AgentAppViewModel.optimisticRunDurability {
            throw NSError(
                domain: "SQLite",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "database is locked"]
            )
        }
        h.vm.rollbackOptimisticRunTracking(tracking, durability: durability)

        try h.runRepo.markStopped(id: runA.id, status: .completed)
        h.vm.runCoordinator(
            h.coordinator,
            didFinish: runA.id,
            threadId: h.threadId,
            status: .completed,
            finalMessage: "stale A during unknown B durability",
            providerThreadId: "provider-a"
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(try h.messageRepo.list(threadId: h.threadId).contains {
            $0.role == .assistant && $0.content == "stale A during unknown B durability"
        }, "a durability read error must preserve B ordering instead of treating B as absent")
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
