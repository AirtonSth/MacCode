import XCTest
import CoreModel
@testable import Persistence

final class AgentRoutingPersistenceTests: XCTestCase {
    private func database() throws -> (SQLiteDB, String) {
        let root = NSTemporaryDirectory() + "rc-auto-routing-" + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: root).run()
        return (db, root)
    }

    func testMissingRoutingRowUsesExplicitLegacyManualPrecedence() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = AgentThreadRepository(db: db)
        let selection = AgentModelSelection(
            provider: .codex,
            modelId: "gpt-5.6-sol",
            reasoningEffort: .high,
            serviceTier: .fast
        )
        var thread = AgentThread(
            title: "legacy",
            provider: .codex,
            model: selection.effectiveModel,
            reasoningEffort: selection.reasoningEffort,
            serviceTier: selection.serviceTier,
            modelSelection: selection
        )
        thread.routingConfiguration = nil
        try repo.upsert(thread)
        try db.execute("DELETE FROM agent_thread_routing WHERE thread_id = '\(thread.id.value.uuidString)';")

        let loaded = try XCTUnwrap(repo.get(id: thread.id))
        XCTAssertNil(loaded.routingConfiguration)
        XCTAssertEqual(loaded.effectiveRoutingConfiguration.mode, .manual)
        XCTAssertEqual(loaded.effectiveRoutingConfiguration.manualSelection, selection)
        XCTAssertEqual(loaded.effectiveRoutingConfiguration.manualSelection.serviceTier, .fast)
    }

    func testAutoRoutingRoundTripsAndQueueCapturesImmutableRevision() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threads = AgentThreadRepository(db: db)
        let queue = AgentQueuedMessageRepository(db: db)
        let manual = AgentModelSelection(provider: .claude, modelId: "claude-opus-4-1", reasoningEffort: .max, serviceTier: .fast)
        let routing = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: manual,
            manualProviderInstanceId: "claude-work",
            eligibleProviders: [.claude, .codex],
            policyDigest: String(repeating: "c", count: 64),
            revision: 4,
            updatedAt: Date(timeIntervalSince1970: 40)
        )
        let thread = AgentThread(title: "auto", provider: .claude, model: manual.effectiveModel,
                                 serviceTier: .fast, modelSelection: manual,
                                 routingConfiguration: routing)
        try threads.upsert(thread)

        let queued = try queue.enqueue(
            threadId: thread.id,
            text: "ship it",
            attachments: [],
            interactionMode: .default,
            routingConfiguration: routing
        )
        var changed = routing
        changed.revision = 5
        changed.mode = .manual
        try threads.setRoutingConfiguration(changed, threadId: thread.id, expectedRevision: 4)

        XCTAssertEqual(try threads.get(id: thread.id)?.routingConfiguration?.revision, 5)
        XCTAssertEqual(try queue.routingConfiguration(id: queued.id)?.revision, 4,
                       "queued work must replay the routing revision captured at enqueue, not the current picker")
        XCTAssertEqual(try queue.routingConfiguration(id: queued.id)?.mode, .auto)
    }

    func testModeAndJSONConflictReturnsTypedError() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = AgentThreadRepository(db: db)
        let config = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .codex, modelId: "gpt-5.6-sol"),
            eligibleProviders: [.codex],
            policyDigest: String(repeating: "d", count: 64),
            revision: 1
        )
        let thread = AgentThread(title: "conflict", provider: .codex, model: "gpt-5.6-sol", routingConfiguration: config)
        try repo.upsert(thread)
        try db.execute("UPDATE agent_thread_routing SET mode = 'manual' WHERE thread_id = '\(thread.id.value.uuidString)';")

        XCTAssertThrowsError(try repo.get(id: thread.id)) { error in
            XCTAssertEqual(error as? AgentRoutingPersistenceError,
                           .modeConflict(column: .manual, configuration: .auto))
        }
    }
}
