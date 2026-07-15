import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentThreadInteractionModePersistenceTests: XCTestCase {
    func test_planModeRoundTripsThroughThreadRepository() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-thread-mode-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let repository = AgentThreadRepository(db: db)
        let thread = AgentThread(
            title: "durable plan",
            provider: .claude,
            model: "claude-opus-4-7",
            interactionMode: .plan
        )

        try repository.upsert(thread)

        XCTAssertEqual(try repository.get(id: thread.id)?.interactionMode, .plan,
                       "reopening a thread must restore its selected Plan mode instead of silently reverting to Default")
        XCTAssertEqual(try repository.list().first?.interactionMode, .plan,
                       "thread-list hydration and direct lookup must agree on the persisted interaction mode")
    }

    func test_preMigrationThreadDefaultsToDefaultMode() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Array(Schema.steps.dropLast()))
        try db.execute("""
            INSERT INTO agent_threads(id, title, provider, model, status, created_at, updated_at)
            VALUES('legacy-thread', 'legacy', 'codex', 'gpt-5', 'completed',
                   '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
        """)

        try Schema.migrate(db)

        let threadID = AgentThreadID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        try db.execute("UPDATE agent_threads SET id = '\(threadID.value.uuidString)' WHERE id = 'legacy-thread';")
        let loaded = try AgentThreadRepository(db: db).get(id: threadID)
        XCTAssertEqual(loaded?.interactionMode, .default,
                       "existing users must receive the non-destructive Default mode when the new column is introduced")
    }
}
