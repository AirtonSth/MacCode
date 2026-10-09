import XCTest
@testable import Persistence
import CoreModel

/// Side/fork thread persistence (v90 columns).
/// WHY: ephemeral side threads must be hidden from the rail (`agent.thread.list`)
/// and deletable in one sweep, while fork children stay visible and carry their
/// `parent_thread_id`.
final class SideThreadPersistenceTests: XCTestCase {
    private func makeDB() throws -> SQLiteDB {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return db
    }

    func test_ephemeralThread_isHiddenFromList_butReadableById() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let root = AgentThread(title: "root", provider: .distill, model: "m")
        try repo.upsert(root)
        let side = AgentThread(title: "Side", provider: .distill, model: "m", parentThreadId: root.id, isEphemeral: true)
        try repo.upsert(side)

        XCTAssertEqual(try repo.list().map(\.id), [root.id])
        let loaded = try XCTUnwrap(repo.get(id: side.id))
        XCTAssertTrue(loaded.isEphemeral)
        XCTAssertEqual(loaded.parentThreadId, root.id)
    }

    func test_deleteEphemeralThreads_removesOnlySideThreads() throws {
        let db = try makeDB()
        let repo = AgentThreadRepository(db: db)
        let root = AgentThread(title: "root", provider: .distill, model: "m")
        try repo.upsert(root)
        // A persisted (non-ephemeral) fork child must survive the sweep.
        let forkChild = AgentThread(title: "fork", provider: .distill, model: "m", parentThreadId: root.id, isEphemeral: false)
        try repo.upsert(forkChild)
        let side = AgentThread(title: "side", provider: .distill, model: "m", parentThreadId: root.id, isEphemeral: true)
        try repo.upsert(side)

        let removed = try repo.deleteEphemeralThreads()
        XCTAssertEqual(Set(removed), [side.id])
        XCTAssertEqual(Set(try repo.list().map(\.id)), [root.id, forkChild.id])
        XCTAssertTrue(try repo.ephemeralThreadIds().isEmpty)
    }
}
