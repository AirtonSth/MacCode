import XCTest
@testable import Persistence
import CoreModel

/// Tests for AgentQueuedMessageRepository: enqueue ordering, promoteToFront,
/// delete-and-normalize, isolation across threads.
///
/// WHY these tests matter (T028):
///   - list() orders by (position ASC, created_at ASC). A bug in the position
///     assignment causes the wrong message to be sent first, silently mis-ordering
///     the user's queued prompts.
///   - promoteToFront() reassigns positions. If the target row ends up at position > 1
///     or other rows are not renumbered, the queue invariant breaks and the caller
///     sends the wrong message.
///   - delete() must renormalize positions after removal so gaps do not accumulate
///     (position=1,3,5 after two deletes would skip position=2 on the next enqueue).
final class AgentQueuedMessageRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    private func makeThread(db: SQLiteDB) throws -> AgentThread {
        let thread = AgentThread(title: "q-test", provider: .codex, model: "m")
        try AgentThreadRepository(db: db).upsert(thread)
        return thread
    }

    // MARK: - T028: enqueue ordering (position ASC, created_at ASC)

    /// WHY: list() must return messages in enqueue order so the coordinator sends
    /// the first-enqueued prompt first. If positions are wrong, a later prompt
    /// is sent before an earlier one.
    func test_T028_enqueue_assignsAscendingPositions() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        let m1 = try repo.enqueue(threadId: thread.id, text: "first", attachments: [], interactionMode: .default)
        let m2 = try repo.enqueue(threadId: thread.id, text: "second", attachments: [], interactionMode: .default)
        let m3 = try repo.enqueue(threadId: thread.id, text: "third", attachments: [], interactionMode: .default)

        XCTAssertEqual(m1.position, 1, "first enqueued message must get position 1")
        XCTAssertEqual(m2.position, 2, "second enqueued message must get position 2")
        XCTAssertEqual(m3.position, 3, "third enqueued message must get position 3")
    }

    func test_T028_list_returnsMessagesInPositionOrder() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        _ = try repo.enqueue(threadId: thread.id, text: "alpha", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "beta", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "gamma", attachments: [], interactionMode: .default)

        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["alpha", "beta", "gamma"],
            "list() must return queued messages in position order so the coordinator sends them FIFO")
    }

    // MARK: - promoteToFront

    /// WHY: the user can tap "send this first" on any queued message. After promotion,
    /// the promoted message must be at position 1 and others must shift up to fill
    /// the gap — no duplicate or missing positions.
    func test_T028_promoteToFront_movesTargetToPosition1() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        _ = try repo.enqueue(threadId: thread.id, text: "A", attachments: [], interactionMode: .default)
        let msgB = try repo.enqueue(threadId: thread.id, text: "B", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "C", attachments: [], interactionMode: .default)

        let promoted = try repo.promoteToFront(id: msgB.id)
        XCTAssertEqual(promoted?.position, 1,
            "promoteToFront must assign position 1 to the promoted message so it is sent before all others")
    }

    func test_T028_promoteToFront_resultsInCorrectListOrder() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        _ = try repo.enqueue(threadId: thread.id, text: "A", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "B", attachments: [], interactionMode: .default)
        let msgC = try repo.enqueue(threadId: thread.id, text: "C", attachments: [], interactionMode: .default)

        _ = try repo.promoteToFront(id: msgC.id)

        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["C", "A", "B"],
            "after promoting C, list must return C first, preserving A-then-B relative order for the remaining messages")
    }

    func test_T028_promoteToFront_alreadyAtFront_isIdempotent() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        let msgA = try repo.enqueue(threadId: thread.id, text: "A", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "B", attachments: [], interactionMode: .default)

        _ = try repo.promoteToFront(id: msgA.id)

        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["A", "B"],
            "promoting the already-front message must be a no-op and must not corrupt positions")
    }

    func test_T028_promoteToFront_nonexistentID_returnsNil() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)
        _ = try makeThread(db: db)

        _ = try repo.enqueue(threadId: thread.id, text: "A", attachments: [], interactionMode: .default)

        let result = try repo.promoteToFront(id: AgentQueuedMessageID())
        XCTAssertNil(result, "promoteToFront with a nonexistent ID must return nil, not crash or corrupt the queue")
    }

    // MARK: - delete normalizes positions

    /// WHY: after deleting a message at position 2, positions must become [1, 2]
    /// not [1, 3]. Gaps accumulate indefinitely and cause the position counter to
    /// drift, eventually misrepresenting queue depth.
    func test_T028_delete_renormalizesPositionsAfterRemoval() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        _ = try repo.enqueue(threadId: thread.id, text: "X", attachments: [], interactionMode: .default)
        let msgY = try repo.enqueue(threadId: thread.id, text: "Y", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "Z", attachments: [], interactionMode: .default)

        _ = try repo.delete(id: msgY.id)

        let listed = try repo.list(threadId: thread.id)
        XCTAssertEqual(listed.map(\.text), ["X", "Z"],
            "delete must renormalize positions so X=1, Z=2 with no gap at position 2")
        XCTAssertEqual(listed.map(\.position), [1, 2],
            "positions must be contiguous after deletion so the next enqueue gets position 3, not 4")
    }

    // MARK: - thread isolation

    /// WHY: two threads share the agent_queued_messages table; a scoping bug in
    /// list() or enqueue() would silently cross-pollute two threads' queues.
    func test_T028_list_isolatesAcrossThreads() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let threadA = try makeThread(db: db)
        let threadB = try makeThread(db: db)

        _ = try repo.enqueue(threadId: threadA.id, text: "forA", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: threadB.id, text: "forB", attachments: [], interactionMode: .default)

        let listA = try repo.list(threadId: threadA.id)
        let listB = try repo.list(threadId: threadB.id)

        XCTAssertEqual(listA.map(\.text), ["forA"],
            "list for threadA must not include threadB messages")
        XCTAssertEqual(listB.map(\.text), ["forB"],
            "list for threadB must not include threadA messages")
    }

    // MARK: - first() and update()

    func test_first_returnsLowestPositionMessage() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        _ = try repo.enqueue(threadId: thread.id, text: "second", attachments: [], interactionMode: .default)
        _ = try repo.enqueue(threadId: thread.id, text: "third", attachments: [], interactionMode: .default)
        // Insert another at position 1 via promote
        let msgFirst = try repo.enqueue(threadId: thread.id, text: "first-enqueued-last", attachments: [], interactionMode: .default)
        _ = try repo.promoteToFront(id: msgFirst.id)

        let first = try repo.first(threadId: thread.id)
        XCTAssertEqual(first?.text, "first-enqueued-last",
            "first() must return the message at position 1 so the coordinator always dispatches the front of the queue")
    }

    func test_update_modifiesTextAndAttachments() throws {
        let db = try makeDB()
        let repo = AgentQueuedMessageRepository(db: db)
        let thread = try makeThread(db: db)

        let msg = try repo.enqueue(threadId: thread.id, text: "original", attachments: [], interactionMode: .default)
        let updated = try repo.update(id: msg.id, text: "revised", attachments: [])
        XCTAssertEqual(updated?.text, "revised",
            "update() must persist the new text so an edited queued message sends the corrected prompt")
    }
}
