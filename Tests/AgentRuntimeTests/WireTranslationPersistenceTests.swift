import XCTest
@testable import AgentRuntime
import CoreModel
import Persistence

final class WireTranslationPersistenceTests: XCTestCase {
    func test_wireTranslationEventRoundTripsAndIndexesByMessageId() throws {
        let messageId = UUID().uuidString
        let wire = "RCW1\tA\t1\nO\tFocused tests passed.\n.\n"
        let request = "RCW1\tQ\t1\nG\tRun focused tests.\n.\n"
        let rendered = "Focused tests passed."
        let event = AssistantEvent.wireTranslation(.init(
            messageId: messageId,
            originalText: wire,
            rewrittenText: rendered,
            wireRequestText: request
        ))

        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(AssistantEvent.self, from: data)
        var state = AssistantTimelineState()
        state.apply(decoded)

        XCTAssertEqual(state.sr1TranslationsByMessageId[messageId]?.originalText, wire)
        XCTAssertEqual(state.sr1TranslationsByMessageId[messageId]?.rewrittenText, rendered)
        XCTAssertEqual(state.tokenSaverTranslationsByMessageId[messageId]?.wireRequestText, request,
                       "restart replay must retain the exact provider-bound request for explicit disclosure")
    }

    func test_historicalSR1EventStillDecodesForExistingThreads() throws {
        let messageId = UUID().uuidString
        let historical = AssistantEvent.sr1Translation(.init(
            messageId: messageId,
            originalText: "O: legacy result",
            rewrittenText: "Legacy result"
        ))
        let data = try JSONEncoder().encode(historical)
        let decoded = try JSONDecoder().decode(AssistantEvent.self, from: data)
        var state = AssistantTimelineState()
        state.apply(decoded)

        XCTAssertEqual(state.sr1TranslationsByMessageId[messageId]?.rewrittenText, "Legacy result")
    }

    func test_rcw1RequestTranslationSurvivesStreamEventPruning() throws {
        let appSupport = NSTemporaryDirectory() + "rcw1-request-retention-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let runs = AgentRunRepository(db: db)
        let thread = AgentThread(title: "RCW1 retention", provider: .codex, model: "test-model")
        let message = AgentMessage(threadId: thread.id, role: .user, content: "Run focused tests.")
        let run = AgentRun(threadId: thread.id, provider: .codex, model: "test-model", status: .running)
        let request = "RCW1\tQ\t1\nG\tRun focused tests.\n.\n"

        try threads.upsert(thread)
        try messages.append(message)
        try messages.upsertRCW1RequestTranslation(messageId: message.id, wireRequestText: request)
        try runs.upsert(run)

        let translation = AssistantEvent.wireTranslation(.init(
            messageId: message.id.value.uuidString,
            originalText: "",
            rewrittenText: "",
            wireRequestText: request
        ))
        try runs.appendStreamEvent(
            runId: run.id,
            seq: 1,
            kind: "wireTranslation",
            payloadJSON: try encodedJSON(translation)
        )
        for index in 2...102 {
            let event = AssistantEvent.turnStarted(turnId: "turn-\(index)")
            try runs.appendStreamEvent(
                runId: run.id,
                seq: index,
                kind: "turnStarted",
                payloadJSON: try encodedJSON(event)
            )
        }

        XCTAssertEqual(try runs.countStreamEvents(threadId: thread.id), 100,
                       "the production stream cap must actually prune this test's original disclosure event")
        XCTAssertFalse(try runs.listLatestStreamEvents(threadId: thread.id).contains { event in
            if case .wireTranslation = event { return true }
            return false
        }, "the stream precondition must prove the RCW1 translation can no longer be replayed from events")
        XCTAssertEqual(
            try AgentMessageRepository(db: db).rcw1RequestTranslations(
                threadId: thread.id,
                messageIds: [message.id]
            )[message.id],
            request,
            "a retained user message must keep its exact provider-bound RCW1 bytes after stream pruning"
        )
    }

    func test_deletingMessageCascadesItsRCW1RequestTranslation() throws {
        let appSupport = NSTemporaryDirectory() + "rcw1-request-cascade-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let thread = AgentThread(title: "RCW1 cascade", provider: .codex, model: "test-model")
        let message = AgentMessage(threadId: thread.id, role: .user, content: "Delete me.")
        let request = "RCW1\tQ\t1\nG\tDelete me.\n.\n"

        try threads.upsert(thread)
        try messages.append(message)
        try messages.upsertRCW1RequestTranslation(messageId: message.id, wireRequestText: request)
        XCTAssertEqual(try messages.rcw1RequestTranslations(
            threadId: thread.id,
            messageIds: [message.id]
        )[message.id], request)

        try messages.delete(ids: [message.id])

        XCTAssertTrue(try messages.rcw1RequestTranslations(
            threadId: thread.id,
            messageIds: [message.id]
        ).isEmpty,
                      "deleting a retained message must cascade its RCW1 disclosure row instead of leaking dead data")
        let count = try db.prepare("SELECT COUNT(*) FROM agent_message_rcw1_requests WHERE message_id = ?;")
        try count.bind(1, message.id.value.uuidString)
        XCTAssertTrue(try count.step())
        XCTAssertEqual(count.columnInt64(0), 0,
                       "the child row itself must be gone, not merely hidden by the repository join")
    }

    func test_rcw1RequestTranslationRejectsNonUserOwner() throws {
        let appSupport = NSTemporaryDirectory() + "rcw1-request-owner-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: appSupport) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: appSupport).run()
        let threads = AgentThreadRepository(db: db)
        let messages = AgentMessageRepository(db: db)
        let thread = AgentThread(title: "RCW1 owner", provider: .codex, model: "test-model")
        let assistant = AgentMessage(threadId: thread.id, role: .assistant, content: "Readable answer")

        try threads.upsert(thread)
        try messages.append(assistant)

        XCTAssertThrowsError(try messages.upsertRCW1RequestTranslation(
            messageId: assistant.id,
            wireRequestText: "RCW1\tQ\t1\nG\tRun focused tests.\n.\n"
        ), "a Human-to-RCW1 toggle must never attach provider-bound request bytes to an assistant row")
    }

    private func encodedJSON(_ event: AssistantEvent) throws -> String {
        let data = try JSONEncoder().encode(event)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
