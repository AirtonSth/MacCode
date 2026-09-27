import XCTest
@testable import CoreModel
@testable import Persistence

final class AgentThreadReasoningModelPersistenceTests: XCTestCase {
    func test_existingSchemaAtVersion83ReceivesReasoningModelColumn() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrateSteps(db, Schema.steps.filter { $0.version < 84 })

        try Schema.migrate(db)
        let repository = AgentThreadRepository(db: db)
        let thread = AgentThread(title: "upgraded", provider: .distill, model: "grok-4.6", reasoningModel: "grok-4.5")
        try repository.upsert(thread)

        XCTAssertEqual(try repository.get(id: thread.id)?.reasoningModel, "grok-4.5",
                       "an existing installation must receive the new column from a migration newer than its current schema version")
    }

    func test_reasoningModelRoundTripsIndependentlyPerConversation() throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-agent-thread-reasoning-model-\(UUID().uuidString)", isDirectory: true)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: support.path).run()
        let repository = AgentThreadRepository(db: db)
        let first = AgentThread(title: "first", provider: .distill, model: "grok-4.6", reasoningModel: "grok-4.5")
        let second = AgentThread(title: "second", provider: .distill, model: "grok-4.6", reasoningModel: nil)

        try repository.upsert(first)
        try repository.upsert(second)

        XCTAssertEqual(try repository.get(id: first.id)?.reasoningModel, "grok-4.5")
        XCTAssertNil(try repository.get(id: second.id)?.reasoningModel)
        let listedFirst = try XCTUnwrap(repository.list().first(where: { $0.id == first.id }))
        let listedSecond = try XCTUnwrap(repository.list().first(where: { $0.id == second.id }))
        XCTAssertEqual(listedFirst.reasoningModel, "grok-4.5", "conversation list hydration must preserve each independent Reasoning model")
        XCTAssertNil(listedSecond.reasoningModel, "disabling Reasoning in one conversation must not inherit another conversation's model")
    }
}
