import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentThreadRunActorPersistenceTests: XCTestCase {
    private func makeRepository() throws -> (AgentThreadRepository, SQLiteDB) {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return (AgentThreadRepository(db: db), db)
    }

    func test_actorLockAndTargetSurviveUpsertGetAndList() throws {
        let (repository, _) = try makeRepository()
        let botID = BotID()
        let lock = Date(timeIntervalSince1970: 1_700_000_000)
        let thread = AgentThread(
            title: "bot",
            provider: .distill,
            model: "grok-4.6",
            actor: .bot(botID),
            actorLockedAt: lock,
            executionTarget: .vm
        )
        try repository.upsert(thread)

        for loaded in [
            try XCTUnwrap(repository.get(id: thread.id)),
            try XCTUnwrap(repository.threadWithoutRouting(of: thread.id)),
            try XCTUnwrap(repository.list().first { $0.id == thread.id })
        ] {
            XCTAssertEqual(loaded.actor, .bot(botID))
            XCTAssertEqual(loaded.actorLockedAt, lock)
            XCTAssertEqual(loaded.executionTarget, .vm)
        }
    }

    func test_rowsWithNullActorColumnsReadAsNoActorSoPreMigrationThreadsKeepWorking() throws {
        let (repository, db) = try makeRepository()
        let thread = AgentThread(
            title: "old",
            provider: .distill,
            model: "grok-4.6",
            actor: .bot(BotID()),
            actorLockedAt: Date(timeIntervalSince1970: 1_700_000_000),
            executionTarget: .mac
        )
        try repository.upsert(thread)
        try db.execute("UPDATE agent_threads SET actor_json = NULL, actor_locked_at = NULL, execution_target = NULL;")

        for loaded in [
            try XCTUnwrap(repository.get(id: thread.id)),
            try XCTUnwrap(repository.list().first { $0.id == thread.id })
        ] {
            XCTAssertEqual(loaded.actor, .none)
            XCTAssertNil(loaded.actorLockedAt)
            XCTAssertNil(loaded.executionTarget)
        }
    }

    func test_noActorThreadStoresNullActorJSON() throws {
        let (repository, db) = try makeRepository()
        let thread = AgentThread(title: "plain", provider: .distill, model: "grok-4.6")
        try repository.upsert(thread)
        let st = try db.prepare("SELECT actor_json FROM agent_threads WHERE id = ?;")
        try st.bind(1, thread.id.value.uuidString)
        XCTAssertTrue(try st.step())
        XCTAssertNil(st.columnText(0))
    }
}
