import XCTest
@testable import Persistence
import CoreModel

final class AgentThreadBatchDeleteTests: XCTestCase {
    func test_deleteIDsRollsBackEveryThreadWhenLaterDeleteFails() throws {
        // WHY: bulk UI deletion promises all-or-nothing. A SQLite failure after
        // the first row must not leave the user's selection partially removed.
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repo = AgentThreadRepository(db: db)
        let threads = [
            AgentThread(title: "first", provider: .codex, model: "gpt"),
            AgentThread(title: "reject", provider: .claude, model: "sonnet"),
            AgentThread(title: "third", provider: .grok, model: "grok"),
        ]
        for thread in threads {
            try repo.upsert(thread)
        }
        try db.execute("""
            CREATE TRIGGER reject_second_thread_delete
            BEFORE DELETE ON agent_threads
            WHEN OLD.id = '\(threads[1].id.value.uuidString)'
            BEGIN
                SELECT RAISE(ABORT, 'injected batch delete failure');
            END;
        """)

        XCTAssertThrowsError(try repo.delete(ids: threads.map(\.id)))
        for thread in threads {
            XCTAssertNotNil(
                try repo.get(id: thread.id),
                "a later DELETE failure must roll back every earlier member"
            )
        }
    }
}
