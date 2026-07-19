import XCTest
import CoreModel
@testable import Persistence

final class ScheduledTaskStoreTests: XCTestCase {
    private var db: SQLiteDB!
    private var store: ScheduledTaskStore!

    override func setUpWithError() throws {
        db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        store = ScheduledTaskStore(db: db)
    }

    override func tearDown() {
        store = nil
        db = nil
    }

    func test_schemaVersionIncludesScheduledTables_becauseUpgradesMustBeAtomic() throws {
        XCTAssertEqual(Schema.currentVersion, 44)
        let statement = try db.prepare("SELECT MAX(version) FROM schema_meta;")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnInt64(0), 44)
    }

    func test_saveAndListRoundTripEveryExecutionField_becauseAgentRunsMustBeExact() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)

        XCTAssertEqual(try store.list(), [task])
    }

    func test_claimDueDeduplicatesOccurrenceAndBlocksSameTaskOverlap_becauseCrashesMustNotDoubleRun() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)

        let first = try store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent-a")
        let second = try store.claimDue(now: Date(timeIntervalSince1970: 102), owner: "agent-b")

        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(try store.listRuns().count, 1)
    }

    func test_globalConcurrencyAllowsOnlyTwoClaims_becauseProvidersMustStayBounded() throws {
        for offset in 0..<3 {
            try store.save(makeTask(id: UUID(), title: "Task \(offset)", nextRunAt: Date(timeIntervalSince1970: 100)))
        }

        XCTAssertEqual(try store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent", limit: 3).count, 2)
    }

    func test_recoverStaleLeaseMarksFailedAndPermitsFutureClaim_becauseProcessDeathMustSelfHeal() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try XCTUnwrap(store.claimDue(now: Date(timeIntervalSince1970: 101), owner: "agent").first)

        XCTAssertEqual(try store.recoverStaleLeases(now: Date(timeIntervalSince1970: 200), maximumRunAge: 50), 1)
        XCTAssertEqual(try store.listRuns().first?.status, .failed)
        XCTAssertEqual(try store.get(id: claim.task.id)?.id, task.id)
        XCTAssertTrue(try store.claimDue(now: Date(timeIntervalSince1970: 201), owner: "agent-b").isEmpty)
        XCTAssertEqual(try store.get(id: task.id)?.nextRunAt, task.calculatedNextRun(after: Date(timeIntervalSince1970: 100)))
    }

    func test_manualRunRejectsSameTaskOverlap_becauseRunNowMustNotBypassLeasePolicy() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        _ = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent-a")

        XCTAssertThrowsError(try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 102), owner: "agent-b"))
    }

    func test_deleteRejectsActiveRun_becauseExecutionMustNotBecomeOrphaned() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")

        XCTAssertThrowsError(try store.delete(id: task.id))

        try store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 102))
        XCTAssertNoThrow(try store.delete(id: task.id))
    }

    func test_listActiveRunsIsUnboundedByHistoryLimit_becauseLongRunsMustKeepHeartbeats() throws {
        let activeTask = makeTask(id: UUID(), title: "Active", nextRunAt: nil)
        try store.save(activeTask)
        let claim = try store.claimManual(taskID: activeTask.id, now: Date(timeIntervalSince1970: 1), owner: "agent")
        try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())

        XCTAssertEqual(try store.listActiveRuns().map(\.id), [claim.run.id])
    }

    func test_runCountsUsesAllHistory_becauseOverviewMustNotCapAtOneThousand() throws {
        let task = makeTask(nextRunAt: nil)
        try store.save(task)
        for offset in 0..<1_001 {
            let claim = try store.claimManual(
                taskID: task.id,
                now: Date(timeIntervalSince1970: TimeInterval(offset)),
                owner: "agent"
            )
            try store.finish(
                runID: claim.run.id,
                status: .completed,
                at: Date(timeIntervalSince1970: TimeInterval(offset) + 0.5)
            )
        }

        XCTAssertEqual(try store.runCounts()[task.id], 1_001)
    }

    func test_runAuditFieldsRecordTriggerQueueLeaseAndHeartbeat_becauseHistoryMustExplainExecution() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)

        let claim = try XCTUnwrap(store.claimDue(now: Date(timeIntervalSince1970: 200), owner: "agent-a").first)

        XCTAssertEqual(claim.run.trigger, .catchUp)
        XCTAssertEqual(claim.run.queuedAt, Date(timeIntervalSince1970: 200))
        XCTAssertNil(claim.run.startedAt)
        XCTAssertEqual(claim.run.leaseOwner, "agent-a")
        XCTAssertEqual(claim.run.heartbeatAt, Date(timeIntervalSince1970: 200))
    }

    func test_terminalRunCannotReturnToRunning_becauseHistoryTransitionsMustBeMonotonic() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())
        try store.finish(runID: claim.run.id, status: .completed, at: Date(timeIntervalSince1970: 102))

        XCTAssertThrowsError(try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID()))
    }

    func test_heartbeatPreventsPrematureStaleRecovery_becauseLongRunsMustNotOverlap() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        try store.heartbeat(runID: claim.run.id, at: Date(timeIntervalSince1970: 190))

        XCTAssertEqual(try store.recoverStaleLeases(now: Date(timeIntervalSince1970: 200), maximumRunAge: 50), 0)
    }

    func test_failureHistoryRedactsCredentialShapes_becauseRunRowsAreSafeMetadataOnly() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")

        try store.finish(runID: claim.run.id, status: .failed, errorSummary: "token=abc123 Bearer topsecret sk-abcdefghijk")

        let summary = try XCTUnwrap(store.listRuns().first?.errorSummary)
        XCTAssertFalse(summary.contains("abc123"))
        XCTAssertFalse(summary.contains("topsecret"))
        XCTAssertFalse(summary.contains("sk-abcdefghijk"))
    }

    func test_failureHistoryRedactsSavedPrompt_becauseProviderEchoesMustNotLeakInstructions() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")

        try store.finish(
            runID: claim.run.id,
            status: .failed,
            errorSummary: "Provider rejected: \(task.prompt)"
        )

        let summary = try XCTUnwrap(store.listRuns().first?.errorSummary)
        XCTAssertFalse(summary.contains(task.prompt))
        XCTAssertTrue(summary.contains("[REDACTED PROMPT]"))
    }

    func test_pauseKeepsActiveRunRecoverable_becausePauseOnlyBlocksFutureOccurrences() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let claim = try store.claimManual(taskID: task.id, now: Date(timeIntervalSince1970: 101), owner: "agent")
        try store.markStarted(runID: claim.run.id, threadID: AgentThreadID(), agentRunID: AgentRunID())

        try store.setEnabled(id: task.id, enabled: false, nextRunAt: nil, updatedAt: Date(timeIntervalSince1970: 110))
        try store.heartbeat(runID: claim.run.id, at: Date(timeIntervalSince1970: 190))

        XCTAssertEqual(try store.recoverStaleLeases(now: Date(timeIntervalSince1970: 200), maximumRunAge: 50), 0)
        XCTAssertEqual(try store.listActiveRuns().map(\.id), [claim.run.id])
    }

    func test_dueClaimsAreFIFO_becauseOlderOccurrencesMustNotStarve() throws {
        let oldest = makeTask(id: UUID(), title: "Oldest", nextRunAt: Date(timeIntervalSince1970: 100))
        let middle = makeTask(id: UUID(), title: "Middle", nextRunAt: Date(timeIntervalSince1970: 101))
        let newest = makeTask(id: UUID(), title: "Newest", nextRunAt: Date(timeIntervalSince1970: 102))
        try store.save(newest)
        try store.save(oldest)
        try store.save(middle)

        let claims = try store.claimDue(now: Date(timeIntervalSince1970: 200), owner: "agent", limit: 2)

        XCTAssertEqual(claims.map(\.task.id), [oldest.id, middle.id])
    }

    func test_onceAdvanceDisablesTask_becauseOneShotSchedulesMustNeverRepeat() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)

        try store.advance(taskID: task.id, nextRunAt: nil, lastRunAt: nil, at: Date(timeIntervalSince1970: 101))

        let stored = try XCTUnwrap(store.get(id: task.id))
        XCTAssertFalse(stored.isEnabled)
        XCTAssertNil(stored.nextRunAt)
    }

    func test_deleteTaskDoesNotDeleteAgentThread_becauseRunHistoryLinksAreNotOwnership() throws {
        let task = makeTask(nextRunAt: Date(timeIntervalSince1970: 100))
        try store.save(task)
        let thread = AgentThread(workspaceId: task.workspaceID, title: "Scheduled", provider: .codex, model: "gpt-5")
        try AgentThreadRepository(db: db).upsert(thread)

        try store.delete(id: task.id)

        XCTAssertNotNil(try AgentThreadRepository(db: db).get(id: thread.id))
    }

    private func makeTask(
        id: UUID = UUID(),
        title: String = "Audit",
        nextRunAt: Date?
    ) -> ScheduledTask {
        let created = Date(timeIntervalSince1970: 10)
        return ScheduledTask(
            id: id, title: title, prompt: "Inspect the workspace", workspaceID: WorkspaceID(),
            workspacePathSnapshot: "/tmp", runAsUser: "sam", runAsUID: 501,
            provider: .codex, providerInstanceID: "codex-primary",
            model: "gpt-5", reasoningEffort: .high,
            recurrence: .daily(at: ScheduledLocalTime(hour: 8, minute: 15)!),
            timeZoneIdentifier: "America/Asuncion", isEnabled: true,
            nextRunAt: nextRunAt, createdAt: created, updatedAt: created
        )
    }
}
