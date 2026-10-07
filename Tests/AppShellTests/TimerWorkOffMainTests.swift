import XCTest
@testable import AppShell
import CoreModel
import AgentRuntime
@testable import Persistence

/// S-F6: the 30 s reaper timer and the scheduled-task tick used to run their
/// SQLite work on the main thread. Under writer contention (busy_timeout plus
/// retries) that froze the UI on the timer cadence. These tests watch every
/// statement the two paths step and fail if any of them runs on main.
@MainActor
final class TimerWorkOffMainTests: XCTestCase {
    // MARK: - Provider session reaper

    func test_reaperRunsItsDatabaseWorkOffMain_andHandsTheResultToMainExactlyOnce() async throws {
        let (ctx, tmp) = try makeContext("reaper-off-main")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let now = Date(timeIntervalSince1970: 10_000)
        let idle = AgentThread(title: "idle", provider: .codex, model: "gpt-5.5")
        try ctx.threadRepo.upsert(idle)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: idle.id, provider: .codex, status: .completed,
            resumeCursor: "idle", updatedAt: Date(timeIntervalSince1970: 1_000)
        ))

        let spy = StatementSpy(matching: ["provider_session_runtime", "agent_threads"], gateFirst: true)
        ctx.db.beforeStatementStepForTesting = spy.record
        defer {
            spy.release()
            ctx.db.beforeStatementStepForTesting = nil
        }

        var outcomes: [Result<ProviderSessionReaperResult, Error>] = []
        var completionOnMain: [Bool] = []
        let done = expectation(description: "reap finished")
        let started = ctx.reapIdleProviderSessionsOffMain(now: now, idleAge: 60) { outcome in
            completionOnMain.append(Thread.isMainThread)
            outcomes.append(outcome)
            done.fulfill()
        }
        XCTAssertTrue(started)

        // Immediate path: the call returned while the reap is parked inside its
        // first statement, so main was never blocked by it.
        let reachedDatabase = await spy.gateEntered(timeout: 5)
        XCTAssertTrue(reachedDatabase, "the reap must reach the database")
        XCTAssertFalse(
            ctx.reapIdleProviderSessionsOffMain(now: now, idleAge: 60) { _ in XCTFail("a dropped tick must not complete") },
            "a tick landing while a reap is in flight is dropped, so two reaps never race"
        )

        spy.release()
        await fulfillment(of: [done], timeout: 10)
        ctx.db.beforeStatementStepForTesting = nil

        XCTAssertFalse(spy.statements.isEmpty, "the spy must have seen the reap's statements")
        XCTAssertEqual(spy.mainThreadStatements, [], "no reaper statement may run on the main thread")
        XCTAssertEqual(completionOnMain, [true], "the result is handed over on main, exactly once")
        let result = try XCTUnwrap(outcomes.first).get()
        XCTAssertEqual(result.stoppedThreadIds, [idle.id], "the deferred reap must still stop the idle session")
        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: idle.id)?.status, .interrupted)

        // The in-flight latch is cleared by the owner, so the next tick runs.
        let next = expectation(description: "next reap")
        XCTAssertTrue(ctx.reapIdleProviderSessionsOffMain(now: now, idleAge: 60) { _ in next.fulfill() })
        await fulfillment(of: [next], timeout: 10)
    }

    func test_reaperFailureIsReportedOnMain_leavesSessionsUntouched_andDoesNotWedgeTheTimer() async throws {
        let (ctx, tmp) = try makeContext("reaper-off-main-failure")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let now = Date(timeIntervalSince1970: 10_000)
        let idle = AgentThread(title: "idle victim", provider: .codex, model: "gpt-5.5")
        var corruptRunning = AgentThread(
            title: "corrupt running",
            provider: .claude,
            model: "claude-opus-4-7",
            routingConfiguration: AgentRoutingConfiguration(
                mode: .auto,
                manualSelection: AgentModelSelection(provider: .claude, modelId: "claude-opus-4-7"),
                eligibleProviders: [.claude],
                revision: 2
            )
        )
        corruptRunning.status = .running
        try ctx.threadRepo.upsert(idle)
        try ctx.threadRepo.upsert(corruptRunning)
        try ctx.providerSessionRuntimeRepo.upsert(ProviderSessionRuntime(
            threadId: idle.id, provider: .codex, status: .completed,
            resumeCursor: "idle", updatedAt: Date(timeIntervalSince1970: 1_000)
        ))
        try ctx.db.execute(
            "UPDATE agent_thread_routing SET configuration_json = '{}' "
                + "WHERE thread_id = '\(corruptRunning.id.value.uuidString)';"
        )

        var failures = 0
        var onMain = false
        let done = expectation(description: "failed reap reported")
        XCTAssertTrue(ctx.reapIdleProviderSessionsOffMain(now: now, idleAge: 60) { outcome in
            onMain = Thread.isMainThread
            if case .failure = outcome { failures += 1 }
            done.fulfill()
        })
        await fulfillment(of: [done], timeout: 10)

        XCTAssertEqual(failures, 1, "the error must surface, not be swallowed")
        XCTAssertTrue(onMain)
        XCTAssertEqual(try ctx.providerSessionRuntimeRepo.get(threadId: idle.id)?.status, .completed,
                       "a failed active-thread snapshot must stop nothing")
        let retry = expectation(description: "retry runs")
        XCTAssertTrue(
            ctx.reapIdleProviderSessionsOffMain(now: now, idleAge: 60) { _ in retry.fulfill() },
            "a failed reap must clear its in-flight latch or the reaper stops for the session"
        )
        await fulfillment(of: [retry], timeout: 10)
    }

    func test_reaperTimerUsesTheOffMainEntry_becauseTheSyncPathBlocksMainOnTheWriter() throws {
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/AppShell/AppDelegate.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private func reapIdleProviderSessions() {"))
        let body = String(source[start.lowerBound...].prefix(900))
        XCTAssertTrue(body.contains("context.reapIdleProviderSessionsOffMain("))
        XCTAssertFalse(body.contains("try context.reapIdleProviderSessions("))
    }

    // MARK: - Scheduled task scheduler

    func test_schedulerTickRunsItsDatabaseWorkOffMain_andFinishesTheRunExactlyOnce() async throws {
        let (ctx, tmp) = try makeContext("scheduler-off-main")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let scheduler = ScheduledTaskScheduler(context: ctx, router: AppCommandRouter(context: ctx))
        let now = Date()
        // Launch tick on an empty store: reclaim + skip, nothing to finish.
        scheduler.tick(now: now)
        await scheduler.tickTaskForTesting?.value

        let store = ScheduledTaskStore(db: ctx.db)
        let runID = try makeRunningRun(ctx: ctx, store: store, now: now, agentStatus: .completed)

        let spy = StatementSpy(matching: ["scheduled_task"], gateFirst: true)
        ctx.db.beforeStatementStepForTesting = spy.record
        defer {
            spy.release()
            ctx.db.beforeStatementStepForTesting = nil
        }

        scheduler.tick(now: now)
        // Immediate path: tick returned while its first statement is parked.
        let reachedDatabase = await spy.gateEntered(timeout: 5)
        XCTAssertTrue(reachedDatabase, "the tick must reach the database")
        let inFlight = try XCTUnwrap(scheduler.tickTaskForTesting)
        // A timer or wake tick landing now is dropped; it must not start a second pass.
        scheduler.tick(now: now)
        spy.release()
        await inFlight.value
        ctx.db.beforeStatementStepForTesting = nil

        XCTAssertNil(scheduler.tickTaskForTesting, "the tick clears its own handle when it ends")
        XCTAssertFalse(spy.statements.isEmpty)
        XCTAssertEqual(spy.mainThreadStatements, [], "no scheduler maintenance statement may run on main")
        let runs = try store.listRuns()
        XCTAssertEqual(runs.map(\.id), [runID], "the dropped tick must not create or duplicate work")
        XCTAssertEqual(runs.first?.status, .completed, "the deferred pass must still finish the run")
    }

    func test_schedulerTickFailureKeepsTheLaunchReclaimPending_andTheNextTickCompletesIt() async throws {
        let (ctx, tmp) = try makeContext("scheduler-off-main-failure")
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let now = Date()
        let store = ScheduledTaskStore(db: ctx.db)
        // A run left `running` by a previous process: the launch tick reclaims it.
        let runID = try makeRunningRun(ctx: ctx, store: store, now: now, agentStatus: .completed)
        try ctx.db.execute("""
            CREATE TRIGGER fail_scheduled_run_update
            BEFORE UPDATE ON scheduled_task_runs
            BEGIN
                SELECT RAISE(ABORT, 'forced scheduled run write failure');
            END;
        """)
        let scheduler = ScheduledTaskScheduler(context: ctx, router: AppCommandRouter(context: ctx))

        scheduler.tick(now: now)
        await scheduler.tickTaskForTesting?.value
        XCTAssertNil(scheduler.tickTaskForTesting, "a failed tick must not wedge the scheduler")
        XCTAssertEqual(try store.listRuns().first?.status, .running, "a failed write leaves the run as it was")

        try ctx.db.execute("DROP TRIGGER fail_scheduled_run_update;")
        scheduler.tick(now: now)
        await scheduler.tickTaskForTesting?.value

        let runs = try store.listRuns()
        XCTAssertEqual(runs.map(\.id), [runID])
        XCTAssertEqual(
            runs.first?.status, .completed,
            "the launch reclaim must be retried after a failure, not marked done"
        )
    }

    // MARK: - Fixtures

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeContext(_ name: String) throws -> (AppContext, String) {
        let tmp = NSTemporaryDirectory() + "rc2-\(name)-" + UUID().uuidString
        return (try AppContext(channel: .debug, appSupportOverride: tmp), tmp)
    }

    /// A scheduled run already marked running and linked to an agent run that
    /// ended with `agentStatus`. The task is not due again for a day, so no
    /// tick in these tests claims new work.
    private func makeRunningRun(
        ctx: AppContext,
        store: ScheduledTaskStore,
        now: Date,
        agentStatus: AgentRunStatus
    ) throws -> UUID {
        let thread = AgentThread(title: "scheduled", provider: .codex, model: "gpt-5")
        try ctx.threadRepo.upsert(thread)
        let agentRun = AgentRun(
            threadId: thread.id, provider: .codex, model: "gpt-5", status: agentStatus,
            startedAt: now.addingTimeInterval(-60), finishedAt: now.addingTimeInterval(-1)
        )
        try ctx.runRepo.upsert(agentRun)
        let task = ScheduledTask(
            title: "Nightly", prompt: "Run tests", workspaceID: WorkspaceID(), workspacePathSnapshot: "/tmp",
            runAsUser: NSUserName(), runAsUID: 501, provider: .distill, providerInstanceID: "distill",
            model: "grok-4.6", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 9, minute: 0)!), timeZoneIdentifier: "UTC",
            nextRunAt: now.addingTimeInterval(24 * 60 * 60)
        )
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: now, owner: "previous-process")
        try store.markStarted(runID: claim.run.id, threadID: thread.id, agentRunID: agentRun.id)
        return claim.run.id
    }
}

/// Records every stepped statement whose SQL mentions one of `fragments`, and
/// optionally parks the first one until `release()` so a test can observe the
/// caller while the database work is still in progress.
private final class StatementSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let fragments: [String]
    private var gatePending: Bool
    private let entered = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private var released = false
    private var _statements: [(sql: String, onMain: Bool)] = []

    init(matching fragments: [String], gateFirst: Bool) {
        self.fragments = fragments
        self.gatePending = gateFirst
    }

    var statements: [String] { lock.withLock { _statements.map(\.sql) } }
    var mainThreadStatements: [String] { lock.withLock { _statements.filter(\.onMain).map(\.sql) } }

    var record: (String) -> Void {
        { [self] sql in
            guard fragments.contains(where: sql.contains) else { return }
            let shouldPark = lock.withLock { () -> Bool in
                _statements.append((sql, Thread.isMainThread))
                defer { gatePending = false }
                return gatePending && !released
            }
            guard shouldPark else { return }
            entered.signal()
            // Bounded so a regression (work back on main) fails instead of hanging.
            _ = gate.wait(timeout: .now() + 5)
        }
    }

    /// Waits off main: the tick's own Task needs the main actor to start.
    func gateEntered(timeout: TimeInterval) async -> Bool {
        let entered = entered
        return await Task.detached {
            entered.wait(timeout: .now() + timeout) == .success
        }.value
    }

    func release() {
        let first = lock.withLock { () -> Bool in
            defer { released = true }
            return !released
        }
        if first { gate.signal() }
    }
}
