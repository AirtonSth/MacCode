import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

/// S-F3: the idle reaper only looked at `completed` rows, so a thread whose
/// last run failed, was cancelled or was interrupted kept its provider process
/// tree (distill agent plus MCP sidecars) until the app quit; long sessions
/// reached 24 provider processes (2 GB) before dying. These tests drive the
/// production pair (ProviderSessionReaper + AgentRunCoordinator release) against
/// an adapter that holds real resident-session state.
final class ProviderSessionReaperLivenessTests: XCTestCase {
    /// Holds sessions the way the real adapters do: a thread stays listed until
    /// stopSession releases its process.
    private final class ResidentAdapter: AgentProviderAdapter, @unchecked Sendable {
        let provider: AgentProvider = .distill
        private let lock = NSLock()
        private var sessions: [AgentThreadID: AgentRunStatus] = [:]
        private var toolsRunning: Set<AgentThreadID> = []
        private var _stopped: [AgentThreadID] = []

        var stopped: [AgentThreadID] { lock.withLock { _stopped } }
        func resident(_ threadId: AgentThreadID, status: AgentRunStatus) {
            lock.withLock { sessions[threadId] = status }
        }
        func setToolsMayStillRun(_ threadId: AgentThreadID, _ running: Bool) {
            lock.withLock {
                if running { toolsRunning.insert(threadId) } else { toolsRunning.remove(threadId) }
            }
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
            lock.withLock {
                sessions.removeValue(forKey: threadId)
                _stopped.append(threadId)
            }
        }
        /// Like Distill and Grok: a recovered session is resident and reports `.completed`.
        func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
            resident(request.threadId, status: .completed)
        }
        func listSessions() -> [AgentProviderSessionSummary] {
            lock.withLock {
                sessions.map {
                    AgentProviderSessionSummary(
                        threadId: $0.key, provider: .distill, status: $0.value,
                        providerThreadId: "p-\($0.key.value.uuidString)",
                        toolsMayStillRun: toolsRunning.contains($0.key)
                    )
                }
            }
        }
        func hasSession(threadId: AgentThreadID) -> Bool { lock.withLock { sessions[threadId] != nil } }
        func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] { [] }
        func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {}
        func stopAll() {}
        func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {}
    }

    private struct Fixture {
        let threadRepo: AgentThreadRepository
        let runRepo: AgentRunRepository
        let sessionRepo: ProviderSessionRuntimeRepository
        let adapter: ResidentAdapter
        let coordinator: AgentRunCoordinator

        /// A thread with a durable session row and, unless `resident` is nil, a live adapter session.
        func thread(row: AgentRunStatus, updatedAt: Date, resident: AgentRunStatus? = nil) throws -> AgentThreadID {
            let thread = AgentThread(title: "t", provider: .distill, model: "m")
            try threadRepo.upsert(thread)
            try sessionRepo.upsert(ProviderSessionRuntime(
                threadId: thread.id, provider: .distill, status: row,
                resumeCursor: "cursor-\(thread.id.value.uuidString)", updatedAt: updatedAt
            ))
            if let resident { adapter.resident(thread.id, status: resident) }
            return thread.id
        }

        /// One reaper tick exactly as AppContext runs it.
        func tick(
            cutoff: Date,
            active: Set<AgentThreadID> = [],
            cap: Int = ProviderSessionReaper.providerRootCap
        ) throws -> ProviderSessionReaperResult {
            let live = coordinator.liveProviderSessions()
            let result = try ProviderSessionReaper(
                sessionRepo: sessionRepo,
                liveSessions: { live },
                providerRootCap: cap
            ) { active }.reapIdleSessions(olderThan: cutoff)
            coordinator.releaseReapedProviderSessions(result)
            return result
        }
    }

    private func makeFixture(_ label: String) throws -> Fixture {
        let tmp = NSTemporaryDirectory() + "rc2-\(label)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let threadRepo = AgentThreadRepository(db: db)
        let sessionRepo = ProviderSessionRuntimeRepository(db: db)
        let adapter = ResidentAdapter()
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: AgentMessageRepository(db: db),
            threadRepo: threadRepo,
            providerSessionRepo: sessionRepo,
            providerAdapters: [.distill: adapter]
        )
        return Fixture(threadRepo: threadRepo, runRepo: runRepo, sessionRepo: sessionRepo, adapter: adapter, coordinator: coordinator)
    }

    func test_failedCancelledAndInterruptedSessionsAreReleasedAfterIdle_activeAndInFlightKept() throws {
        let f = try makeFixture("reaper-liveness")
        let old = Date(timeIntervalSince1970: 1_000)
        let cutoff = Date(timeIntervalSince1970: 2_000)
        let fresh = Date(timeIntervalSince1970: 3_000)

        let failed = try f.thread(row: .failed, updatedAt: old, resident: .failed)
        let cancelled = try f.thread(row: .cancelled, updatedAt: old, resident: .cancelled)
        let interrupted = try f.thread(row: .interrupted, updatedAt: old, resident: .interrupted)
        let freshFailed = try f.thread(row: .failed, updatedAt: fresh, resident: .failed)
        let activeFailed = try f.thread(row: .failed, updatedAt: old, resident: .failed)
        let inFlight = try f.thread(row: .failed, updatedAt: old, resident: .running)
        let alreadyReleased = try f.thread(row: .failed, updatedAt: old)

        let result = try f.tick(cutoff: cutoff, active: [activeFailed])

        XCTAssertEqual(Set(result.stoppedThreadIds), [failed, cancelled, interrupted],
                       "a session idle past idleReleaseAge must be released whatever its row status; only `completed` was before, so failed runs leaked their process tree until quit")
        XCTAssertEqual(Set(f.adapter.stopped), [failed, cancelled, interrupted],
                       "marking rows is not enough: the adapter session (and its process) must actually be stopped")
        XCTAssertTrue(f.adapter.hasSession(threadId: activeFailed),
                      "an active thread's session is never released, however old its row")
        XCTAssertTrue(f.adapter.hasSession(threadId: inFlight),
                      "an adapter session still inside a turn is never released")
        XCTAssertTrue(f.adapter.hasSession(threadId: freshFailed),
                      "a session idle for less than idleReleaseAge stays warm for a quick Retry")
        XCTAssertFalse(result.stoppedThreadIds.contains(alreadyReleased),
                       "a row with no live session has nothing to release")

        XCTAssertEqual(try f.sessionRepo.get(threadId: failed)?.status, .failed,
                       "releasing the process must not rewrite a failed session as completed")
        XCTAssertEqual(try f.sessionRepo.get(threadId: cancelled)?.status, .cancelled)
        XCTAssertEqual(try f.sessionRepo.get(threadId: interrupted)?.status, .interrupted,
                       "an interrupted row is the relaunch Continue target; stamping completed would hide Continue")

        let writesBefore = f.sessionRepo.markStoppedCountForTesting
        let second = try f.tick(cutoff: cutoff, active: [activeFailed])
        XCTAssertTrue(second.stoppedThreadIds.isEmpty && second.cappedThreadIds.isEmpty,
                      "released sessions are no longer live, so the 30 s tick must not pick them again")
        XCTAssertEqual(f.sessionRepo.markStoppedCountForTesting, writesBefore,
                       "the liveness scan must not rewrite historical rows on every tick")
    }

    func test_residentCapReleasesLeastRecentlyUsedIdleSessions_neverActiveOnes() throws {
        let f = try makeFixture("reaper-lru-cap")
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let cap = ProviderSessionReaper.providerRootCap
        XCTAssertEqual(cap, 8)

        // Active threads are the oldest rows, so a cap that ranked them would pick them first.
        var active: Set<AgentThreadID> = []
        for index in 0..<3 {
            active.insert(try f.thread(row: .running, updatedAt: cutoff.addingTimeInterval(Double(index + 1)), resident: .running))
        }
        var idleByAge: [AgentThreadID] = []
        for index in 0..<8 {
            idleByAge.append(try f.thread(row: .completed, updatedAt: cutoff.addingTimeInterval(Double(100 + index)), resident: .completed))
        }

        let result = try f.tick(cutoff: cutoff, active: active)

        XCTAssertTrue(result.stoppedThreadIds.isEmpty, "nothing is idle past the cutoff yet")
        XCTAssertEqual(result.cappedThreadIds, Array(idleByAge.prefix(3)),
                       "11 resident sessions over a cap of 8: the three least recently used idle sessions go, oldest first")
        XCTAssertEqual(f.coordinator.liveProviderSessions().count, cap)
        for threadId in active {
            XCTAssertTrue(f.adapter.hasSession(threadId: threadId),
                          "the cap never interrupts a running agent; the user decides how many run at once")
        }
        for threadId in idleByAge.prefix(3) {
            XCTAssertEqual(try f.sessionRepo.get(threadId: threadId)?.status, .completed)
        }
    }

    func test_residentCapCannotGoBelowActiveSessions() throws {
        let f = try makeFixture("reaper-cap-active")
        let cutoff = Date(timeIntervalSince1970: 1_000)
        var active: Set<AgentThreadID> = []
        for index in 0..<(ProviderSessionReaper.providerRootCap + 1) {
            active.insert(try f.thread(row: .running, updatedAt: cutoff.addingTimeInterval(Double(index + 1)), resident: .running))
        }
        let idle = try f.thread(row: .completed, updatedAt: cutoff.addingTimeInterval(500), resident: .completed)

        let result = try f.tick(cutoff: cutoff, active: active)

        XCTAssertEqual(result.cappedThreadIds, [idle],
                       "only idle sessions can be released; the count stays above the cap while the user runs more agents")
        XCTAssertEqual(Set(f.coordinator.liveProviderSessions().map(\.threadId)), active)
    }

    func test_sessionWhoseToolsMayStillRun_isKeptUntilItsPromptReturns() throws {
        // WHY (S-F3 review): the inactivity watchdog ends a turn as interrupted
        // while a tool call is still open (a long silent build). That tool may
        // still be running in the session's process tree, so neither the idle
        // pass nor the cap may kill it; once the prompt returns it is releasable.
        let f = try makeFixture("reaper-open-tools")
        let old = Date(timeIntervalSince1970: 1_000)
        let cutoff = Date(timeIntervalSince1970: 2_000)
        let building = try f.thread(row: .interrupted, updatedAt: old, resident: .interrupted)
        f.adapter.setToolsMayStillRun(building, true)
        let recentBuilding = try f.thread(row: .interrupted, updatedAt: cutoff.addingTimeInterval(10), resident: .interrupted)
        f.adapter.setToolsMayStillRun(recentBuilding, true)

        let first = try f.tick(cutoff: cutoff, cap: 0)
        XCTAssertTrue(first.stoppedThreadIds.isEmpty && first.cappedThreadIds.isEmpty)
        XCTAssertTrue(f.adapter.hasSession(threadId: building),
                      "an idle session whose tool may still run must not be killed by the idle pass")
        XCTAssertTrue(f.adapter.hasSession(threadId: recentBuilding),
                      "nor by the cap, even at a cap of zero")

        f.adapter.setToolsMayStillRun(building, false)
        let second = try f.tick(cutoff: cutoff, cap: ProviderSessionReaper.providerRootCap)
        XCTAssertEqual(second.stoppedThreadIds, [building], "once its prompt returned, the idle session is released")
        XCTAssertFalse(f.adapter.hasSession(threadId: building))
        XCTAssertEqual(try f.sessionRepo.get(threadId: building)?.status, .interrupted)
    }

    func test_releaseWaitsOutAFinishInFlightAndAReservedStart() throws {
        // WHY (S-F3 review): the cap targets sessions that finished seconds ago.
        // Releasing one whose finish (or a queued follow-up start) is still in
        // flight kills a turn that just began or forces a respawn nobody needed.
        let f = try makeFixture("reaper-barrier")
        let cutoff = Date(timeIntervalSince1970: 1_000)
        let finishing = try f.thread(row: .completed, updatedAt: cutoff.addingTimeInterval(10), resident: .completed)
        let reserved = try f.thread(row: .completed, updatedAt: cutoff.addingTimeInterval(20), resident: .completed)
        let finishingRun = AgentRunID()
        let reservedRun = AgentRunID()
        f.coordinator.setFinishingRunForTesting(threadId: finishing, runId: finishingRun, finishing: true)
        f.coordinator.reserveProviderStart(threadId: reserved, runId: reservedRun)

        let first = try f.tick(cutoff: cutoff, cap: 0)
        XCTAssertEqual(Set(first.cappedThreadIds), [finishing, reserved], "both are over a cap of zero")
        XCTAssertTrue(f.adapter.hasSession(threadId: finishing),
                      "a session whose run is still finishing must not be released")
        XCTAssertTrue(f.adapter.hasSession(threadId: reserved),
                      "a session a surface reserved a start on must not be released")
        XCTAssertTrue(f.adapter.stopped.isEmpty)

        f.coordinator.setFinishingRunForTesting(threadId: finishing, runId: finishingRun, finishing: false)
        f.coordinator.releaseProviderStartReservation(threadId: reserved, runId: reservedRun)
        _ = try f.tick(cutoff: cutoff, cap: 0)
        XCTAssertEqual(Set(f.adapter.stopped), [finishing, reserved],
                       "once the finish and the start reservation are gone, the next tick releases them")
    }

    func test_tickReadsSessionAgesInOneQuery() throws {
        // WHY (S-F3 review): the reaper ticks every 30 s on the main actor over the
        // single serialized SQLite connection; one row read per live session made
        // the tick cost grow with every resident agent.
        let f = try makeFixture("reaper-batched-read")
        let cutoff = Date(timeIntervalSince1970: 1_000)
        for index in 0..<5 {
            _ = try f.thread(row: .completed, updatedAt: cutoff.addingTimeInterval(Double(10 + index)), resident: .completed)
        }
        let getsBefore = f.sessionRepo.durableGetCountForTesting
        let batchesBefore = f.sessionRepo.updatedAtBatchCountForTesting

        _ = try f.tick(cutoff: cutoff)

        XCTAssertEqual(f.sessionRepo.durableGetCountForTesting, getsBefore, "no per-session row read")
        XCTAssertEqual(f.sessionRepo.updatedAtBatchCountForTesting, batchesBefore + 1)
    }

    func test_recoveredSessionCountsAsUse_notReleasedOnTheNextTick() async throws {
        // WHY (S-F3 review): opening an interrupted thread recovers its session,
        // which spawns a provider process that reports `.completed`. With an old
        // row, the next tick released that fresh process and the next open spawned
        // it again: spawn-then-kill churn, and a cold respawn on Continue.
        let f = try makeFixture("reaper-recovery-use")
        var thread = AgentThread(title: "t", provider: .distill, model: "m")
        thread.status = .interrupted
        thread.worktreePath = NSTemporaryDirectory()
        try f.threadRepo.upsert(thread)
        let run = AgentRun(threadId: thread.id, provider: .distill, model: "m", status: .interrupted)
        try f.runRepo.upsert(run)
        let old = Date(timeIntervalSince1970: 1_000)
        try f.sessionRepo.upsert(ProviderSessionRuntime(
            threadId: thread.id, provider: .distill, status: .interrupted,
            resumeCursor: "cursor-\(thread.id.value.uuidString)", cwd: NSTemporaryDirectory(),
            lastRunId: run.id, updatedAt: old
        ))

        let recoveryStartedAt = Date()
        _ = try await f.coordinator.readThread(threadId: thread.id)
        XCTAssertTrue(f.adapter.hasSession(threadId: thread.id), "opening the thread recovered its session")
        let stamped = try XCTUnwrap(f.sessionRepo.get(threadId: thread.id)?.updatedAt)
        XCTAssertGreaterThanOrEqual(stamped.timeIntervalSince1970, recoveryStartedAt.timeIntervalSince1970 - 1,
                                    "a recovery that reuses its last run must still count as use")

        let result = try f.tick(cutoff: recoveryStartedAt.addingTimeInterval(-60))
        XCTAssertFalse(result.stoppedThreadIds.contains(thread.id))
        XCTAssertTrue(f.adapter.hasSession(threadId: thread.id),
                      "the process recovery just spawned must not be released on the next tick")
        XCTAssertEqual(try f.sessionRepo.get(threadId: thread.id)?.status, .interrupted,
                       "recovery keeps the Continue target")
    }
}
