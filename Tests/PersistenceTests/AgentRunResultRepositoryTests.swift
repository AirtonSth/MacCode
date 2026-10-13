import XCTest
import CoreModel
@testable import Persistence

final class AgentRunResultRepositoryTests: XCTestCase {
    private func make() throws -> (SQLiteDB, AgentRunRepository, AgentRunResultRepository) {
        let path = NSTemporaryDirectory() + "run-results-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        return (db, AgentRunRepository(db: db), AgentRunResultRepository(db: db))
    }

    private func persistThread(_ db: SQLiteDB, id: AgentThreadID) throws {
        try AgentThreadRepository(db: db).upsert(
            AgentThread(id: id, title: "test", provider: .codex, model: "test")
        )
    }

    private func completed(_ runs: AgentRunRepository, text: String, threadId: AgentThreadID = AgentThreadID(), event: String = "{}") throws -> AgentRunID {
        let threadID = threadId
        try persistThread(runs.db, id: threadID)
        let run = AgentRun(threadId: threadID, provider: .codex, model: "test")
        try runs.upsert(run)
        try runs.persistTerminalGraph(
            assistantMessage: AgentMessage(threadId: threadID, role: .assistant, content: text),
            run: { var copy = run; copy.status = .completed; return copy }(),
            thread: nil,
            providerSession: nil,
            streamEvent: .init(seq: 1, kind: "assistant.text", payloadJSON: event, providerEvent: nil)
        )
        return run.id
    }

    func test_terminalReplayIsRunLinkedIdempotentAndRollbackSafe() throws {
        let (_, runs, results) = try make()
        let runId = try completed(runs, text: "first")
        let original = try XCTUnwrap(results.get(runId: runId))
        XCTAssertEqual(original.summary, "first")
        XCTAssertNotNil(original.finalMessageId)

        let viewedAt = Date(timeIntervalSince1970: 1_700_000_010)
        _ = try results.setViewed(runIds: [runId], viewedAt: viewedAt)
        let run = try XCTUnwrap(runs.get(id: runId))
        try runs.persistTerminalGraph(
            assistantMessage: AgentMessage(id: try XCTUnwrap(original.finalMessageId), threadId: run.threadId, role: .assistant, content: "first"),
            run: run,
            thread: nil,
            providerSession: nil,
            streamEvent: .init(seq: 1, kind: "assistant.text", payloadJSON: "{}", providerEvent: nil)
        )
        XCTAssertEqual(try results.get(runId: runId)?.viewedAt, viewedAt, "replay must preserve separate read state")
        let conflictingMessage = AgentMessage(
            id: try XCTUnwrap(original.finalMessageId),
            threadId: run.threadId,
            role: .assistant,
            content: "replacement"
        )
        XCTAssertThrowsError(try runs.persistTerminalGraph(
            assistantMessage: conflictingMessage,
            run: run,
            thread: nil,
            providerSession: nil,
            streamEvent: .init(seq: 1, kind: "assistant.text", payloadJSON: "{\"conflict\":true}", providerEvent: nil)
        ))
        let after = try XCTUnwrap(results.get(runId: runId))
        XCTAssertEqual(after.summary, "first", "failed terminal replay must roll back result changes")
        XCTAssertEqual(after.viewedAt, viewedAt)
    }

    func test_twoRunsAndViewedDoNotAcknowledgeFailureAndRestoreExactDate() throws {
        let (_, runs, results) = try make()
        let thread = AgentThreadID()
        let one = try completed(runs, text: "one", threadId: thread)
        let two = try completed(runs, text: "two", threadId: thread)
        XCTAssertEqual(Set(try results.list(runIds: [one, two]).compactMap(\.summary)), Set(["one", "two"]))

        let viewed = Date(timeIntervalSince1970: 1_700_000_000.123)
        XCTAssertEqual(try results.setViewed(runIds: [one], viewedAt: viewed), [one])
        let storedView = try XCTUnwrap(results.get(runId: one)?.viewedAt)
        XCTAssertEqual(storedView.timeIntervalSince1970, viewed.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(try results.get(runId: one)?.attentionAcknowledgedAt)
        try results.restoreViewed([one: .none])
        XCTAssertNil(try results.get(runId: one)?.viewedAt)
        XCTAssertFalse(try results.acknowledgeFailure(runId: one))
    }

    func test_prePersistedFinalMessageIsResolvedByExactIDAndNilReplayPreservesIt() throws {
        let (db, runs, results) = try make()
        let thread = AgentThreadID()
        try persistThread(db, id: thread)
        var run = AgentRun(threadId: thread, provider: .codex, model: "test")
        try runs.upsert(run)
        let finalMessage = AgentMessage(threadId: thread, role: .assistant, content: "persisted exact final")
        try AgentMessageRepository(db: db).append(finalMessage)
        run.status = .completed

        try runs.persistTerminalGraph(
            assistantMessage: nil,
            finalMessageId: finalMessage.id,
            run: run,
            thread: nil,
            providerSession: nil
        )
        let first = try XCTUnwrap(results.get(runId: run.id))
        XCTAssertEqual(first.finalMessageId, finalMessage.id)
        XCTAssertEqual(first.summary, "persisted exact final")

        try runs.persistTerminalGraph(assistantMessage: nil, run: run, thread: nil, providerSession: nil)
        let replay = try XCTUnwrap(results.get(runId: run.id))
        XCTAssertEqual(replay.finalMessageId, finalMessage.id)
        XCTAssertEqual(replay.summary, "persisted exact final")
    }

    func test_wrongThreadMessageRejectedAndTerminalTransactionRollsBack() throws {
        let (db, runs, results) = try make()
        let run = AgentRun(threadId: AgentThreadID(), provider: .codex, model: "test")
        try persistThread(db, id: run.threadId)
        try runs.upsert(run)
        let wrongThread = AgentThreadID()
        try persistThread(db, id: wrongThread)
        let wrongThreadMessage = AgentMessage(
            threadId: wrongThread,
            role: .assistant,
            content: "must not attach"
        )
        try AgentMessageRepository(db: db).append(wrongThreadMessage)
        var terminalRun = run
        terminalRun.status = .failed
        XCTAssertThrowsError(try runs.persistTerminalGraph(
            assistantMessage: nil,
            finalMessageId: wrongThreadMessage.id,
            run: terminalRun,
            thread: nil,
            providerSession: nil
        ))
        XCTAssertEqual(try runs.status(of: run.id), .running)
        XCTAssertNil(try results.get(runId: run.id))
    }

    func test_summaryRedactsEntireQuotedCredentialValues() throws {
        let (_, runs, results) = try make()
        let runID = try completed(runs, text: #"password="alpha beta gamma" {"api_key": "delta epsilon"} secret='zeta eta' password="unterminated theta iota"#)
        let summary = try XCTUnwrap(results.get(runId: runID)?.summary)
        for secret in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta", "iota"] {
            XCTAssertFalse(summary.contains(secret), "Quoted credential content must never reach persisted results or RPC summaries.")
        }
        XCTAssertTrue(summary.contains("[REDACTED]"))
    }

    func test_summaryIsCredentialRedactedAndBounded() throws {
        let (_, runs, results) = try make()
        let runId = try completed(runs, text: "Token: super-secret-value\n" + String(repeating: "x", count: 700))
        let summary = try XCTUnwrap(results.get(runId: runId)?.summary)
        XCTAssertFalse(summary.contains("super-secret-value"))
        XCTAssertTrue(summary.contains("[REDACTED]"))
        XCTAssertLessThanOrEqual(summary.count, 500)
    }

    func test_interruptedRunWithoutProjectionCanBeAcknowledgedAndKeepsHistory() throws {
        let (db, runs, results) = try make()
        let thread = AgentThreadID()
        try persistThread(db, id: thread)
        var run = AgentRun(threadId: thread, provider: .codex, model: "test")
        try runs.upsert(run)
        run.status = .interrupted
        try runs.persistTerminalGraph(assistantMessage: nil, run: run, thread: nil, providerSession: nil)
        try db.performSync { database in
            let delete = try database.prepare("DELETE FROM agent_run_results WHERE run_id = ?;")
            try delete.bind(1, run.id.description)
            _ = try delete.step()
        }
        XCTAssertNil(try results.get(runId: run.id))
        XCTAssertTrue(try results.acknowledgeFailure(runId: run.id))
        XCTAssertEqual(try runs.status(of: run.id), .interrupted)
        XCTAssertNotNil(try results.get(runId: run.id)?.attentionAcknowledgedAt)
    }

    func test_nonUserCancelledRunCanBeAcknowledged() throws {
        let (db, runs, results) = try make()
        let thread = AgentThreadID()
        try persistThread(db, id: thread)
        var run = AgentRun(threadId: thread, provider: .codex, model: "test")
        try runs.upsert(run)
        run.status = .cancelled
        try runs.persistTerminalGraph(assistantMessage: nil, run: run, thread: nil, providerSession: nil)
        try db.performSync { database in
            let update = try database.prepare("UPDATE agent_runs SET terminal_reason = NULL WHERE id = ?;")
            try update.bind(1, run.id.description)
            _ = try update.step()
        }
        XCTAssertTrue(try results.acknowledgeFailure(runId: run.id))
        XCTAssertEqual(try runs.status(of: run.id), .cancelled)
        XCTAssertNotNil(try results.get(runId: run.id)?.attentionAcknowledgedAt)
    }

    func test_userStopCancelledRunCannotBeAcknowledged() throws {
        let (db, runs, results) = try make()
        let thread = AgentThreadID()
        try persistThread(db, id: thread)
        var run = AgentRun(threadId: thread, provider: .codex, model: "test")
        try runs.upsert(run)
        run.status = .cancelled
        run.terminalReason = "userStop"
        try runs.persistTerminalGraph(assistantMessage: nil, run: run, thread: nil, providerSession: nil)
        XCTAssertFalse(try results.acknowledgeFailure(runId: run.id))
        XCTAssertNil(try results.get(runId: run.id)?.attentionAcknowledgedAt)
    }

    func test_failedRunCanBeAcknowledgedWithoutChangingRunState() throws {
        let (db, runs, results) = try make()
        let thread = AgentThreadID()
        try persistThread(db, id: thread)
        var run = AgentRun(threadId: thread, provider: .codex, model: "test")
        try runs.upsert(run)
        run.status = .failed
        run.errorMessage = "failure"
        try runs.persistTerminalGraph(assistantMessage: nil, run: run, thread: nil, providerSession: nil)
        XCTAssertTrue(try results.acknowledgeFailure(runId: run.id))
        XCTAssertEqual(try runs.status(of: run.id), .failed)
        XCTAssertNotNil(try results.get(runId: run.id)?.attentionAcknowledgedAt)
    }
}
