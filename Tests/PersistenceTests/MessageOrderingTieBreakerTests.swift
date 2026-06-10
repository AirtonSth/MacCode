import XCTest
@testable import Persistence
import CoreModel

// Verifies that list() and listPage() use identical insertion-order (rowid) tie-breaking
// when two messages share the same created_at second (ISO8601 truncates sub-second).
// A prior attempt changed list() to 'id ASC' which broke rowid semantics; this test
// guards against regression and confirms the fix to listPage()'s ORDER BY tie-breaker.
final class MessageOrderingTieBreakerTests: XCTestCase {

    private func makeDB() throws -> (SQLiteDB, AgentThreadID) {
        let tmp = NSTemporaryDirectory() + "RC2MsgOrder-" + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let tr = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "order-test", provider: .codex, model: "gpt-5")
        try tr.upsert(thread)
        return (db, thread.id)
    }

    // Two messages with the SAME created_at second must come out in insertion (rowid) order
    // from BOTH list() and listPage(). The tie-breaker column must be rowid, not the UUID
    // string of 'id', so that whichever message was inserted first always appears first.
    func test_sameSecond_listAndListPage_returnIdenticalInsertionOrder() throws {
        let (db, tid) = try makeDB()
        let mr = AgentMessageRepository(db: db)

        // Use a fixed timestamp so both messages share an identical ISO8601 second string.
        let sharedDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

        // UUID ordering (alphabetic) is INTENTIONALLY inverse to insertion order so the
        // test fails if ORDER BY uses 'id' instead of 'rowid'.
        // "z-first" would sort AFTER "a-second" alphabetically, but "z-first" is inserted
        // FIRST, so rowid-order returns ["z-first", "a-second"].
        let idFirst  = AgentMessageID(UUID(uuidString: "ZFFFFFFF-0000-0000-0000-000000000001")!)
        let idSecond = AgentMessageID(UUID(uuidString: "A0000000-0000-0000-0000-000000000002")!)

        try mr.append(AgentMessage(id: idFirst,  threadId: tid, role: .user,      content: "z-first",  createdAt: sharedDate))
        try mr.append(AgentMessage(id: idSecond, threadId: tid, role: .assistant, content: "a-second", createdAt: sharedDate))

        // list() must return insertion order (rowid ASC tie-breaker is unchanged)
        let listed = try mr.list(threadId: tid)
        XCTAssertEqual(listed.map(\.content), ["z-first", "a-second"],
            "list() must use rowid as tie-breaker so same-second messages preserve insertion order; " +
            "alphabetic id-sort would return [a-second, z-first] instead")

        // listPage() initial load (no cursor) must match list() - both rowid-ordered
        let page = try mr.listPage(threadId: tid, limit: 10, before: nil)
        XCTAssertEqual(page.messages.map(\.content), ["z-first", "a-second"],
            "listPage() ORDER BY tie-breaker must be rowid (not id) so same-second ordering " +
            "matches list() and the UI does not reorder messages on paginated load")
    }

    // Existing insertion-order round-trip must still pass - list() untouched.
    // This guards against the previously broken attempt that changed list() to 'id ASC'.
    func test_list_preservesInsertionOrderAcrossDistinctSeconds() throws {
        let (db, tid) = try makeDB()
        let mr = AgentMessageRepository(db: db)
        let base = Date(timeIntervalSinceReferenceDate: 600_000_000)
        for i in 0..<5 {
            try mr.append(AgentMessage(
                threadId: tid,
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "msg-\(i)",
                createdAt: base.addingTimeInterval(Double(i))
            ))
        }
        let msgs = try mr.list(threadId: tid)
        XCTAssertEqual(msgs.map(\.content), (0..<5).map { "msg-\($0)" },
            "list() must preserve strict insertion order across distinct timestamps; " +
            "any change to its ORDER BY that swaps rowid for id would break this")
    }
}
