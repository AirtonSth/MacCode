import XCTest
@testable import AgentRuntime
import CoreModel

// Tests for ClaudeCLIAdapter session/event map pruning.
// Business rule: finished threads that are not rollback-reachable are evicted
// when the session map exceeds its cap, oldest-finished first.
// Rollback-reachable threads (those on which rollbackThread has been called)
// are never evicted by the pruner, so readable history survives checkpoint/revert.
final class ClaudeCLIAdapterSessionPruneTests: XCTestCase {

    // MARK: - Pure helper: threadStatesPruneEligible

    func test_pruneEligible_returnsEmptyWhenBelowCap() {
        // WHY: pruner must not touch anything when the map fits within the cap.
        let result = ClaudeCLIAdapter.pruneEligible(
            finishedOrder: [AgentThreadID(), AgentThreadID()],
            rolledBackThreadIds: [],
            cap: 10
        )
        XCTAssertTrue(result.isEmpty,
                      "no threads must be evicted when finished count is below the session cap")
    }

    func test_pruneEligible_returnsOldestFinishedFirstWhenOverCap() {
        // WHY: memory is bounded by evicting oldest-finished threads when the map exceeds the cap.
        let t1 = AgentThreadID()
        let t2 = AgentThreadID()
        let t3 = AgentThreadID()
        let result = ClaudeCLIAdapter.pruneEligible(
            finishedOrder: [t1, t2, t3],
            rolledBackThreadIds: [],
            cap: 2
        )
        XCTAssertEqual(result, [t1],
                       "oldest finished thread must be evicted first when the session map exceeds the cap")
    }

    func test_pruneEligible_skipsRolledBackThreadsEvenWhenOverCap() {
        // WHY: a rolled-back thread still holds checkpoint history the UI depends on; evicting it
        // would break readThread after rollback, reproducing the original regression.
        let t1 = AgentThreadID()
        let t2 = AgentThreadID()
        let t3 = AgentThreadID()
        let result = ClaudeCLIAdapter.pruneEligible(
            finishedOrder: [t1, t2, t3],
            rolledBackThreadIds: [t1],
            cap: 2
        )
        // t1 is rollback-reachable so t2 is the next oldest eligible
        XCTAssertEqual(result, [t2],
                       "rolled-back threads must be exempt from eviction so checkpoint history remains readable")
    }

    func test_pruneEligible_evictesMultipleWhenFarOverCap() {
        // WHY: large unbounded growth must drain back to cap in one prune pass.
        let ids = (0..<5).map { _ in AgentThreadID() }
        let result = ClaudeCLIAdapter.pruneEligible(
            finishedOrder: ids,
            rolledBackThreadIds: [],
            cap: 2
        )
        XCTAssertEqual(result, Array(ids.prefix(3)),
                       "all excess oldest-finished threads must be returned for eviction in one pass")
    }

    func test_pruneEligible_returnsEmptyWhenAllFinishedAreRolledBack() {
        // WHY: if every finished thread has been rolled back, none can be evicted - the cap
        // is a best-effort bound and must not destroy rollback-reachable history.
        let ids = (0..<5).map { _ in AgentThreadID() }
        let result = ClaudeCLIAdapter.pruneEligible(
            finishedOrder: ids,
            rolledBackThreadIds: Set(ids),
            cap: 2
        )
        XCTAssertTrue(result.isEmpty,
                      "no thread must be evicted when all finished threads are rollback-reachable")
    }

    // MARK: - Adapter integration: finished non-rollback-reachable thread evicted

    func test_adapterEvictsOldestFinishedThreadWhenOverCap() async throws {
        // WHY: sessions/events maps must not grow unbounded; finished threads that are not
        // rollback-reachable should be removed once the cap is exceeded.
        let adapter = ClaudeCLIAdapter(
            runner: ScriptedClaudeRunnerForPrune(),
            maxReadableEvents: 5_000,
            maxSessions: 2
        )
        let t1 = AgentThreadID()
        let t2 = AgentThreadID()
        let t3 = AgentThreadID()

        // Run three turns sequentially so ordering is deterministic.
        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: t1, provider: .claude, model: "m", cwd: NSTemporaryDirectory(), prompt: "p"),
            onEvent: { _ in }
        )
        try await waitUntilFinished(adapter: adapter, threadIds: [t1])

        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: t2, provider: .claude, model: "m", cwd: NSTemporaryDirectory(), prompt: "p"),
            onEvent: { _ in }
        )
        try await waitUntilFinished(adapter: adapter, threadIds: [t2])

        // t3 finishing brings finished count to 3, exceeding cap 2; t1 must be evicted.
        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: t3, provider: .claude, model: "m", cwd: NSTemporaryDirectory(), prompt: "p"),
            onEvent: { _ in }
        )
        try await waitUntilFinished(adapter: adapter, threadIds: [t3])

        XCTAssertFalse(adapter.hasSession(threadId: t1),
                       "oldest finished thread must be evicted from sessions when the cap is exceeded")
        XCTAssertTrue(adapter.hasSession(threadId: t2),
                      "second finished thread must be retained when cap is 2 and only 3 threads exist")
        XCTAssertTrue(adapter.hasSession(threadId: t3),
                      "newest finished thread must be retained when cap is 2 and only 3 threads exist")
    }

    func test_adapterKeepsRolledBackThreadDespiteCapExceeded() async throws {
        // WHY: a thread that the UI has rolled back still has checkpoint history that readThread
        // and subsequent UI renders depend on; evicting it would break the revert flow.
        let adapter = ClaudeCLIAdapter(
            runner: ScriptedClaudeRunnerForPrune(),
            maxReadableEvents: 5_000,
            maxSessions: 2
        )
        let t1 = AgentThreadID()
        let t2 = AgentThreadID()
        let t3 = AgentThreadID()

        // Run and finish t1.
        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: t1, provider: .claude, model: "m", cwd: NSTemporaryDirectory(), prompt: "p"),
            onEvent: { _ in }
        )
        try await waitUntilFinished(adapter: adapter, threadIds: [t1])

        // Roll back t1 - marks it rollback-reachable.
        try await adapter.rollbackThread(threadId: t1, toTurnId: "turn-p")

        // Run t2 and t3 to push map over cap.
        for threadId in [t2, t3] {
            _ = try await adapter.sendTurn(
                AgentRunRequest(threadId: threadId, provider: .claude, model: "m", cwd: NSTemporaryDirectory(), prompt: "p"),
                onEvent: { _ in }
            )
        }
        try await waitUntilFinished(adapter: adapter, threadIds: [t2, t3])

        // t1 must survive because it was rolled back.
        XCTAssertTrue(adapter.hasSession(threadId: t1),
                      "a rolled-back thread must not be evicted even when the session cap is exceeded")
        // t1 events must still be readable.
        let events = try await adapter.readThread(threadId: t1)
        XCTAssertFalse(events.isEmpty,
                       "rolled-back thread events must remain readable after the pruner runs")
    }

    func test_adapterKeepsActiveThreadDespiteCapExceeded() async throws {
        // WHY: an active (running) thread must never be evicted - it is not in finishedOrder
        // and the pruner must only consider finished threads, so the active thread survives
        // even when a completed thread triggers a prune that exceeds the cap.
        let multiRunner = MultiScriptedClaudeRunnerForPrune()
        let adapter = ClaudeCLIAdapter(
            runner: multiRunner,
            maxReadableEvents: 5_000,
            maxSessions: 1
        )
        let active = AgentThreadID()
        let finished1 = AgentThreadID()

        // Register active thread as slow (won't finish until told).
        multiRunner.setSlow(threadId: active)

        // Start both: active won't finish, finished1 will finish immediately.
        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: active, provider: .claude, model: "m", cwd: NSTemporaryDirectory(), prompt: "slow"),
            onEvent: { _ in }
        )
        _ = try await adapter.sendTurn(
            AgentRunRequest(threadId: finished1, provider: .claude, model: "m", cwd: NSTemporaryDirectory(), prompt: "fast"),
            onEvent: { _ in }
        )
        try await waitUntilFinished(adapter: adapter, threadIds: [finished1])

        // The active thread must still be in sessions (pruner only evicts finished threads).
        XCTAssertTrue(adapter.hasSession(threadId: active),
                      "an active thread must never be evicted by the session cap pruner")

        // Clean up.
        multiRunner.finishSlow()
    }

    // MARK: - Helpers

    private func waitUntilFinished(adapter: ClaudeCLIAdapter, threadIds: [AgentThreadID]) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let sessions = adapter.listSessions()
            let allDone = threadIds.allSatisfy { id in
                sessions.contains { $0.threadId == id && $0.status != .running && $0.status != .pending }
            }
            if allDone { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for threads to finish")
    }
}

// MARK: - Test doubles

private final class ScriptedClaudeRunnerForPrune: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .claude

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        Task.detached {
            let providerThreadId = request.providerThreadId ?? "prune-session-\(request.threadId.value.uuidString)"
            let turnId = "turn-\(request.prompt)"
            onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            onEvent(.event(.turnStarted(turnId: turnId)))
            onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "ok")))
            onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: providerThreadId))
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }
}

/// Runner where specific thread IDs can be marked "slow" (won't emit .finished until finishSlow() called).
/// All other threads finish immediately like ScriptedClaudeRunnerForPrune.
private final class MultiScriptedClaudeRunnerForPrune: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .claude
    private let lock = NSLock()
    private var slowThreadIds: Set<AgentThreadID> = []
    private var slowCallbacks: [(AgentThreadID, @Sendable (AgentRunEvent) -> Void, AgentRunRequest)] = []

    func listModels() async -> [AgentModelDescriptor] { [] }

    func setSlow(threadId: AgentThreadID) {
        lock.lock()
        slowThreadIds.insert(threadId)
        lock.unlock()
    }

    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        let isSlow = slowThreadIds.contains(request.threadId)
        lock.unlock()
        let providerThreadId = request.providerThreadId ?? "multi-session-\(request.threadId.value.uuidString)"
        let turnId = "turn-\(request.prompt)"
        if isSlow {
            lock.lock()
            slowCallbacks.append((request.threadId, onEvent, request))
            lock.unlock()
            Task.detached {
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
            }
        } else {
            Task.detached {
                onEvent(.event(.threadStarted(threadId: providerThreadId, providerThreadId: providerThreadId)))
                onEvent(.event(.turnStarted(turnId: turnId)))
                onEvent(.event(.turnCompleted(turnId: turnId, finalMessage: "ok")))
                onEvent(.finished(.completed, finalMessage: "ok", providerThreadId: providerThreadId))
            }
        }
        return AgentRunHandle(runId: request.runId, process: nil) {}
    }

    func finishSlow() {
        lock.lock()
        let entries = slowCallbacks
        lock.unlock()
        for (_, cb, req) in entries {
            let ptid = req.providerThreadId ?? "multi-session-\(req.threadId.value.uuidString)"
            cb(.event(.turnCompleted(turnId: "turn-slow", finalMessage: "done")))
            cb(.finished(.completed, finalMessage: "done", providerThreadId: ptid))
        }
    }
}
