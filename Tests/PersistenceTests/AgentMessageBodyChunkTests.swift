import XCTest
@testable import Persistence
import CoreModel

final class AgentMessageBodyChunkTests: XCTestCase {
    private func makeFixture() throws -> (
        db: SQLiteDB,
        repo: AgentMessageRepository,
        thread: AgentThread
    ) {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let thread = AgentThread(
            title: "body-chunk",
            provider: .codex,
            model: "gpt-5"
        )
        try AgentThreadRepository(db: db).upsert(thread)
        return (db, AgentMessageRepository(db: db), thread)
    }

    func testContinuationReadsSQLiteSubstringAndFreezesBodyIdentity() throws {
        let fixture = try makeFixture()
        let body = String(repeating: "🙂-cellular-", count: 20_000)
        let message = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: body
        )
        try fixture.repo.append(message)

        let first = try XCTUnwrap(try fixture.repo.bodyChunk(
            id: message.id,
            offsetBytes: 0,
            maxContentBytes: 32 * 1_024,
            expectedBodyRevision: nil,
            expectedBodySHA256: nil
        ))
        XCTAssertNotNil(first.metadata)
        XCTAssertEqual(first.bodyByteCount, body.utf8.count)
        XCTAssertEqual(first.bodyRevision, 1)

        var steppedSQL: [String] = []
        fixture.db.beforeStatementStepForTesting = {
            steppedSQL.append($0)
        }
        let offset = first.content.utf8.count
        let continuation = try XCTUnwrap(try fixture.repo.bodyChunk(
            id: message.id,
            offsetBytes: offset,
            maxContentBytes: 32 * 1_024,
            expectedBodyRevision: first.bodyRevision,
            expectedBodySHA256: first.bodySHA256
        ))
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertNil(
            continuation.metadata,
            "attachments and message metadata must cross only at offset zero"
        )
        XCTAssertTrue(
            steppedSQL.contains {
                $0.contains("substr(CAST(content AS BLOB)")
            },
            "continuation must read a bounded SQLite BLOB range"
        )
        XCTAssertFalse(
            steppedSQL.contains {
                $0.contains("SELECT content\n")
            },
            "continuation must never select or hash the complete body"
        )

        try fixture.db.execute("""
            UPDATE agent_messages
            SET content = 'changed'
            WHERE id = '\(message.id.value.uuidString)';
            """)
        XCTAssertThrowsError(try fixture.repo.bodyChunk(
            id: message.id,
            offsetBytes: offset,
            maxContentBytes: 32 * 1_024,
            expectedBodyRevision: first.bodyRevision,
            expectedBodySHA256: first.bodySHA256
        )) {
            XCTAssertEqual(
                $0 as? AgentMessageBodyChunkError,
                .bodyRevisionConflict
            )
        }
        let changed = try XCTUnwrap(try fixture.repo.bodyChunk(
            id: message.id,
            offsetBytes: 0,
            maxContentBytes: 32 * 1_024,
            expectedBodyRevision: nil,
            expectedBodySHA256: nil
        ))
        XCTAssertEqual(changed.bodyRevision, 2)
        XCTAssertEqual(changed.content, "changed")
        XCTAssertNotEqual(changed.bodySHA256, first.bodySHA256)
    }

    func testLegacyRowHashesCompleteBodyOnlyOnceAtOffsetZero() throws {
        let fixture = try makeFixture()
        let id = AgentMessageID()
        let body = String(repeating: "legacy🙂", count: 5_000)
        let insert = try fixture.db.prepare("""
            INSERT INTO agent_messages(
                id, thread_id, role, content, created_at, attachments_json
            ) VALUES(?, ?, 'assistant', ?, ?, '[]');
            """)
        try insert.bind(1, id.value.uuidString)
        try insert.bind(2, fixture.thread.id.value.uuidString)
        try insert.bind(3, body)
        try insert.bind(
            4,
            ISO8601DateFormatter().string(from: Date())
        )
        _ = try insert.step()

        var firstSQL: [String] = []
        fixture.db.beforeStatementStepForTesting = {
            firstSQL.append($0)
        }
        _ = try fixture.repo.bodyChunk(
            id: id,
            offsetBytes: 0,
            maxContentBytes: 4 * 1_024,
            expectedBodyRevision: nil,
            expectedBodySHA256: nil
        )
        var secondSQL: [String] = []
        fixture.db.beforeStatementStepForTesting = {
            secondSQL.append($0)
        }
        _ = try fixture.repo.bodyChunk(
            id: id,
            offsetBytes: 0,
            maxContentBytes: 4 * 1_024,
            expectedBodyRevision: nil,
            expectedBodySHA256: nil
        )
        fixture.db.beforeStatementStepForTesting = nil

        XCTAssertTrue(firstSQL.contains { $0.contains("SELECT content\n") })
        XCTAssertFalse(
            secondSQL.contains { $0.contains("SELECT content\n") },
            "a migrated body digest must be persisted and reused"
        )
    }

    func testFirstOversizedListRowStillOwnsAPaginationCursor() throws {
        let fixture = try makeFixture()
        let message = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: String(repeating: "x", count: 20_000)
        )
        try fixture.repo.append(message)

        let page = try fixture.repo.listPageWithinBodyBudget(
            threadId: fixture.thread.id,
            limit: 10,
            budget: 1,
            contentLimit: 128,
            appendEllipsisOnCap: false
        )

        XCTAssertEqual(page.rows.map(\.id), [message.id])
        XCTAssertNotNil(page.nextBefore)
        XCTAssertTrue(page.truncatedIDs.contains(message.id))
    }

    func testListPageRejectsDeletedWrongThreadAndMismatchedDateCursors() throws {
        let fixture = try makeFixture()
        let createdAt = Date(timeIntervalSinceReferenceDate: 4_000)
        let message = AgentMessage(
            threadId: fixture.thread.id,
            role: .assistant,
            content: "cursor-owner",
            createdAt: createdAt
        )
        try fixture.repo.append(message)

        let wrongThread = AgentThread(
            title: "wrong-thread",
            provider: .codex,
            model: "gpt-5"
        )
        try AgentThreadRepository(db: fixture.db).upsert(wrongThread)
        let wrongThreadMessage = AgentMessage(
            threadId: wrongThread.id,
            role: .assistant,
            content: "other owner",
            createdAt: createdAt
        )
        try fixture.repo.append(wrongThreadMessage)

        let wrongThreadCursor = AgentMessageCursor(
            createdAt: createdAt,
            id: wrongThreadMessage.id
        )
        XCTAssertThrowsError(try fixture.repo.listPageWithinBodyBudget(
            threadId: fixture.thread.id,
            limit: 10,
            before: wrongThreadCursor,
            budget: 64 * 1_024
        )) {
            XCTAssertEqual(
                $0 as? AgentMessagePageCursorError,
                .staleOrInvalid
            )
        }

        let mismatchedDateCursor = AgentMessageCursor(
            createdAt: createdAt.addingTimeInterval(1),
            id: message.id
        )
        XCTAssertThrowsError(try fixture.repo.listPageWithinBodyBudget(
            threadId: fixture.thread.id,
            limit: 10,
            before: mismatchedDateCursor,
            budget: 64 * 1_024
        )) {
            XCTAssertEqual(
                $0 as? AgentMessagePageCursorError,
                .staleOrInvalid
            )
        }

        try fixture.db.execute("""
            DELETE FROM agent_messages
            WHERE id = '\(message.id.value.uuidString)';
            """)
        let deletedCursor = AgentMessageCursor(
            createdAt: createdAt,
            id: message.id
        )
        XCTAssertThrowsError(try fixture.repo.listPageWithinBodyBudget(
            threadId: fixture.thread.id,
            limit: 10,
            before: deletedCursor,
            budget: 64 * 1_024
        )) {
            XCTAssertEqual(
                $0 as? AgentMessagePageCursorError,
                .staleOrInvalid
            )
        }
    }

    func testSameTimestampKeysetVisitsEveryRowExactlyOnce() throws {
        let fixture = try makeFixture()
        let createdAt = Date(timeIntervalSinceReferenceDate: 5_000)
        let messages = (0..<4).map { index in
            AgentMessage(
                threadId: fixture.thread.id,
                role: .assistant,
                content: "same-time-\(index)",
                createdAt: createdAt
            )
        }
        for message in messages {
            try fixture.repo.append(message)
        }

        var cursor: AgentMessageCursor?
        var visited: [AgentMessageID] = []
        while true {
            let page = try fixture.repo.listPageWithinBodyBudget(
                threadId: fixture.thread.id,
                limit: 1,
                before: cursor,
                budget: 64 * 1_024
            )
            XCTAssertEqual(page.rows.count, 1)
            visited.append(contentsOf: page.rows.map(\.id))
            guard page.hasMoreOlder else { break }
            cursor = try XCTUnwrap(page.nextBefore)
        }

        XCTAssertEqual(visited.count, messages.count)
        XCTAssertEqual(Set(visited), Set(messages.map(\.id)))
    }
}
