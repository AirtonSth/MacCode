import XCTest
@testable import Persistence
import CoreModel

/// Behavior-correctness pin for AgentMessageRepository.delete(ids:).
///
/// WHY: delete(ids:) was changed from a per-id loop (N separate DELETE statements,
/// no transaction) to a single batched DELETE ... WHERE id IN (...) inside one
/// transaction. This test pins that the batched form removes exactly the same rows
/// as the loop did: specified ids gone, unspecified ids present, empty call is a
/// no-op, unknown ids are silently ignored.
final class AgentMessageDeleteTests: XCTestCase {

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func seedThread(db: SQLiteDB) throws -> AgentThread {
        let thread = AgentThread(title: "delete-test", provider: .codex, model: "gpt-5")
        try AgentThreadRepository(db: db).upsert(thread)
        return thread
    }

    private func seedMessages(
        db: SQLiteDB,
        thread: AgentThread,
        count: Int
    ) throws -> [AgentMessage] {
        let repo = AgentMessageRepository(db: db)
        var messages: [AgentMessage] = []
        for i in 0..<count {
            let msg = AgentMessage(
                threadId: thread.id,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "message-\(i)"
            )
            try repo.append(msg)
            messages.append(msg)
        }
        return messages
    }

    // MARK: - Tests

    func test_delete_subsetByIds_removesExactlyThoseRows() throws {
        let db = try makeDB()
        let thread = try seedThread(db: db)
        let msgs = try seedMessages(db: db, thread: thread, count: 5)
        let repo = AgentMessageRepository(db: db)

        // delete indices 1 and 3
        let toDelete = [msgs[1].id, msgs[3].id]
        try repo.delete(ids: toDelete)

        let remaining = try repo.list(threadId: thread.id)
        let remainingIds = Set(remaining.map(\.id))

        XCTAssertFalse(remainingIds.contains(msgs[1].id),
            "batched DELETE must remove msg[1]: the row was in the id list")
        XCTAssertFalse(remainingIds.contains(msgs[3].id),
            "batched DELETE must remove msg[3]: the row was in the id list")
        XCTAssertTrue(remainingIds.contains(msgs[0].id),
            "batched DELETE must keep msg[0]: id was not in the delete list")
        XCTAssertTrue(remainingIds.contains(msgs[2].id),
            "batched DELETE must keep msg[2]: id was not in the delete list")
        XCTAssertTrue(remainingIds.contains(msgs[4].id),
            "batched DELETE must keep msg[4]: id was not in the delete list")
        XCTAssertEqual(remaining.count, 3,
            "exactly 3 rows must survive a 2-of-5 delete; count mismatch means the batch scope leaked")
    }

    func test_delete_emptyIds_isNoOp() throws {
        let db = try makeDB()
        let thread = try seedThread(db: db)
        let msgs = try seedMessages(db: db, thread: thread, count: 3)
        let repo = AgentMessageRepository(db: db)

        try repo.delete(ids: [])

        let remaining = try repo.list(threadId: thread.id)
        XCTAssertEqual(remaining.count, msgs.count,
            "delete(ids:[]) must be a no-op: empty list must not delete any rows")
    }

    func test_delete_unknownId_isIgnored() throws {
        let db = try makeDB()
        let thread = try seedThread(db: db)
        let msgs = try seedMessages(db: db, thread: thread, count: 3)
        let repo = AgentMessageRepository(db: db)

        let ghost = AgentMessageID(UUID())
        try repo.delete(ids: [ghost])

        let remaining = try repo.list(threadId: thread.id)
        XCTAssertEqual(remaining.count, msgs.count,
            "delete with an unknown id must be silently ignored; no existing rows must be removed")
    }

    func test_delete_allIds_removesAllRows() throws {
        let db = try makeDB()
        let thread = try seedThread(db: db)
        let msgs = try seedMessages(db: db, thread: thread, count: 4)
        let repo = AgentMessageRepository(db: db)

        try repo.delete(ids: msgs.map(\.id))

        let remaining = try repo.list(threadId: thread.id)
        XCTAssertTrue(remaining.isEmpty,
            "deleting all ids must leave the table empty for this thread")
    }
}
