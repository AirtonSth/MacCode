import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class AssistantWireResponseDurabilityTests: XCTestCase {
    func test_responseSurvivesMoreThanOneHundredStreamEventsAndDatabaseReopen() throws {
        let fixture = try makeFixture("prune-reopen")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let wire = "RCW1\tA\t1\nO\tIsolation keeps tests safe.\n.\n"
        let assistant = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "Isolation keeps tests safe."
        )
        let run = AgentRun(
            threadId: fixture.thread.id,
            provider: .codex,
            model: "test-model",
            status: .running
        )
        try fixture.messages.append(assistant)
        try fixture.runs.upsert(run)
        try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: run.id,
            turnId: "turn-pruned",
            wireResponseText: wire
        )

        let event = AssistantEvent.wireTranslation(.init(
            messageId: assistant.id.value.uuidString,
            originalText: wire,
            rewrittenText: assistant.content
        ))
        try fixture.runs.appendStreamEvent(
            runId: run.id,
            seq: 1,
            kind: "wireTranslation",
            payloadJSON: try encodedJSON(event)
        )
        for sequence in 2...102 {
            try fixture.runs.appendStreamEvent(
                runId: run.id,
                seq: sequence,
                kind: "turnStarted",
                payloadJSON: try encodedJSON(.turnStarted(turnId: "turn-\(sequence)"))
            )
        }

        XCTAssertEqual(try fixture.runs.countStreamEvents(threadId: fixture.thread.id), 100)
        XCTAssertFalse(try fixture.runs.listLatestStreamEvents(threadId: fixture.thread.id).contains {
            if case .wireTranslation = $0 { return true }
            return false
        }, "the original stream disclosure must actually be outside the retained event window")

        let reopenedDB = try SQLiteDB(path: fixture.db.path)
        let reopenedMessages = AgentMessageRepository(db: reopenedDB)
        let reopened = try XCTUnwrap(
            reopenedMessages.rcw1ResponseTranslations(
                threadId: fixture.thread.id,
                messageIds: [assistant.id]
            )[assistant.id]
        )
        XCTAssertEqual(reopened.wireResponseText, wire,
                       "the exact provider bytes must not depend on evictable stream replay")
        XCTAssertEqual(reopened.turnId, "turn-pruned")
        XCTAssertEqual(reopened.runId, run.id)
        XCTAssertEqual(try reopenedMessages.get(id: assistant.id)?.content, assistant.content,
                       "the readable assistant message remains the canonical transcript body")
    }

    func test_deletingAssistantMessageCascadesRCW1Response() throws {
        let fixture = try makeFixture("cascade")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let assistant = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "Readable result."
        )
        let run = AgentRun(
            threadId: fixture.thread.id,
            provider: .codex,
            model: "test-model"
        )
        let wire = "RCW1\tA\t1\nO\tReadable result.\n.\n"
        try fixture.messages.append(assistant)
        try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: run.id,
            turnId: "turn-cascade",
            wireResponseText: wire
        )

        try fixture.messages.delete(ids: [assistant.id])

        XCTAssertTrue(try fixture.messages.rcw1ResponseTranslations(
            threadId: fixture.thread.id,
            messageIds: [assistant.id]
        ).isEmpty)
        let count = try fixture.db.prepare(
            "SELECT COUNT(*) FROM agent_message_rcw1_responses WHERE message_id = ?;"
        )
        try count.bind(1, assistant.id.value.uuidString)
        XCTAssertTrue(try count.step())
        XCTAssertEqual(count.columnInt64(0), 0,
                       "the FK must remove storage, not merely hide it behind a join")
    }

    func test_repositoryRejectsPlainLegacyAndWrongDirectionPayloads() throws {
        let fixture = try makeFixture("protocol-gate")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let assistant = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "Readable result."
        )
        try fixture.messages.append(assistant)

        let rejected = [
            "ordinary prose",
            "SR1\tA\t1\nO\tlegacy\n.\n",
            "RCW1\tQ\t1\nG\trequest not response\n.\n"
        ]
        for candidate in rejected {
            XCTAssertThrowsError(try fixture.messages.upsertRCW1ResponseTranslation(
                messageId: assistant.id,
                runId: AgentRunID(),
                turnId: "turn-invalid",
                wireResponseText: candidate
            ), "only strict RCW1 response frames may gain a durable toggle")
        }
        XCTAssertTrue(try fixture.messages.rcw1ResponseTranslations(
            threadId: fixture.thread.id,
            messageIds: [assistant.id]
        ).isEmpty)
    }

    func test_repositoryRejectsMissingTurnIdentity() throws {
        let fixture = try makeFixture("missing-turn")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let assistant = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "Readable result."
        )
        try fixture.messages.append(assistant)

        for turnId in ["", "   \n\t"] {
            XCTAssertThrowsError(try fixture.messages.upsertRCW1ResponseTranslation(
                messageId: assistant.id,
                runId: AgentRunID(),
                turnId: turnId,
                wireResponseText: "RCW1\tA\t1\nO\tReadable result.\n.\n"
            ), "a durable response must never be stored without a host-owned turn identity")
        }
    }

    func test_existingResponseCannotBeReassociatedByRunTurnOrBytes() throws {
        let fixture = try makeFixture("immutable-link")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let assistant = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "Canonical human result."
        )
        let runId = AgentRunID()
        let wire = "RCW1\tA\t1\nO\tCanonical result.\n.\n"
        try fixture.messages.append(assistant)
        try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: runId,
            turnId: "turn-original",
            wireResponseText: wire
        )

        XCTAssertThrowsError(try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: AgentRunID(),
            turnId: "turn-original",
            wireResponseText: wire
        ))
        XCTAssertThrowsError(try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: runId,
            turnId: "turn-other",
            wireResponseText: wire
        ))
        XCTAssertThrowsError(try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: runId,
            turnId: "turn-original",
            wireResponseText: "RCW1\tA\t1\nO\tDifferent bytes.\n.\n"
        ))

        let retained = try XCTUnwrap(fixture.messages.rcw1ResponseTranslations(
            threadId: fixture.thread.id,
            messageIds: [assistant.id]
        )[assistant.id])
        XCTAssertEqual(retained.runId, runId)
        XCTAssertEqual(retained.turnId, "turn-original")
        XCTAssertEqual(retained.wireResponseText, wire)
    }

    func test_relationalSnapshotIncludesAndRestoresRCW1ResponseChild() throws {
        let fixture = try makeFixture("snapshot")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let assistant = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "Readable snapshot."
        )
        let run = AgentRun(
            threadId: fixture.thread.id,
            provider: .codex,
            model: "test-model"
        )
        let wire = "RCW1\tA\t1\nO\tReadable snapshot.\n.\n"
        try fixture.messages.append(assistant)
        try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: run.id,
            turnId: "turn-snapshot",
            wireResponseText: wire
        )

        let snapshot = try fixture.threads.deleteWithRelationalSnapshot(ids: [fixture.thread.id])
        XCTAssertNil(try fixture.threads.get(id: fixture.thread.id))
        try fixture.threads.restore(snapshot)

        XCTAssertEqual(
            try fixture.messages.rcw1ResponseTranslations(
                threadId: fixture.thread.id,
                messageIds: [assistant.id]
            )[assistant.id]?.wireResponseText,
            wire
        )
    }

    func test_messageDisplayPreferenceKeepsAInRCW1AndBInHumanAcrossReopen() throws {
        let fixture = try makeFixture("display-reopen")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let first = AgentMessage(threadId: fixture.thread.id, role: .assistant, content: "Same Human")
        let second = AgentMessage(threadId: fixture.thread.id, role: .assistant, content: "Same Human")
        try fixture.messages.append(first)
        try fixture.messages.append(second)
        try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: first.id,
            runId: AgentRunID(),
            turnId: "turn-a",
            wireResponseText: "RCW1\tA\t1\nO\tfirst\n.\n"
        )
        try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: second.id,
            runId: AgentRunID(),
            turnId: "turn-b",
            wireResponseText: "RCW1\tA\t1\nO\tsecond\n.\n"
        )
        try fixture.messages.setTokenSaverDisplayMode(messageId: first.id, mode: .rcw1)

        let reopened = AgentMessageRepository(db: try SQLiteDB(path: fixture.db.path))
        let modes = try reopened.tokenSaverDisplayModes(
            threadId: fixture.thread.id,
            messageIds: [first.id, second.id]
        )
        XCTAssertEqual(modes[first.id], .rcw1)
        XCTAssertNil(modes[second.id], "absence is the durable Human default; A must not change B")
    }

    func test_moreThanFiveHundredTwelveLiveMessagePreferencesNeverEvictEarlierChoice() throws {
        let fixture = try makeFixture("display-no-eviction")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        var firstOwner: (thread: AgentThread, message: AgentMessage)?

        for index in 0..<513 {
            let thread = index == 0
                ? fixture.thread
                : AgentThread(title: "display-\(index)", provider: .codex, model: "test-model")
            if index != 0 { try fixture.threads.upsert(thread) }
            let message = AgentMessage(threadId: thread.id, role: .assistant, content: "Human \(index)")
            try fixture.messages.append(message)
            try fixture.messages.upsertRCW1ResponseTranslation(
                messageId: message.id,
                runId: AgentRunID(),
                turnId: "turn-\(index)",
                wireResponseText: "RCW1\tA\t1\nO\trow \(index)\n.\n"
            )
            try fixture.messages.setTokenSaverDisplayMode(messageId: message.id, mode: .rcw1)
            if index == 0 { firstOwner = (thread, message) }
        }

        let first = try XCTUnwrap(firstOwner)
        XCTAssertEqual(
            try fixture.messages.tokenSaverDisplayModes(
                threadId: first.thread.id,
                messageIds: [first.message.id]
            )[first.message.id],
            .rcw1,
            "the 513th live row must not silently revert the first live row to Human"
        )
    }

    func test_displayPreferenceFollowsRelationalUndoAndDefinitiveMessageCascade() throws {
        let fixture = try makeFixture("display-undo-cascade")
        defer { try? FileManager.default.removeItem(atPath: fixture.root) }
        let assistant = AgentMessage(threadId: fixture.thread.id, role: .assistant, content: "Human")
        try fixture.messages.append(assistant)
        try fixture.messages.upsertRCW1ResponseTranslation(
            messageId: assistant.id,
            runId: AgentRunID(),
            turnId: "turn-undo",
            wireResponseText: "RCW1\tA\t1\nO\traw\n.\n"
        )
        try fixture.messages.setTokenSaverDisplayMode(messageId: assistant.id, mode: .rcw1)

        let snapshot = try fixture.threads.deleteWithRelationalSnapshot(ids: [fixture.thread.id])
        XCTAssertTrue(try fixture.messages.tokenSaverDisplayModes(
            threadId: fixture.thread.id,
            messageIds: [assistant.id]
        ).isEmpty)
        try fixture.threads.restore(snapshot)
        XCTAssertEqual(try fixture.messages.tokenSaverDisplayModes(
            threadId: fixture.thread.id,
            messageIds: [assistant.id]
        )[assistant.id], .rcw1, "Undo must restore the per-message choice with the row")

        try fixture.messages.delete(ids: [assistant.id])
        XCTAssertTrue(try fixture.messages.tokenSaverDisplayModes(
            threadId: fixture.thread.id,
            messageIds: [assistant.id]
        ).isEmpty, "definitive row deletion must cascade the preference")
    }

    private typealias Fixture = (
        root: String,
        db: SQLiteDB,
        threads: AgentThreadRepository,
        messages: AgentMessageRepository,
        runs: AgentRunRepository,
        thread: AgentThread
    )

    private func makeFixture(_ suffix: String) throws -> Fixture {
        let root = NSTemporaryDirectory() + "rcw1-response-\(suffix)-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: suffix, provider: .codex, model: "test-model")
        try threads.upsert(thread)
        return (root, db, threads, messages, runs, thread)
    }

    private func encodedJSON(_ event: AssistantEvent) throws -> String {
        let data = try JSONEncoder().encode(event)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
