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

    func testQueuePersistsAndReloadsAdmissionSnapshot() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let queue = AgentQueuedMessageRepository(db: db)
        let thread = AgentThread(title: "snapshot", provider: .claude, model: "claude")
        try AgentThreadRepository(db: db).upsert(thread)
        let configuration = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .claude, modelId: "claude"),
            policyDigest: String(repeating: "a", count: 64),
            revision: 7
        )
        let receiptID = UUID()
        let snapshot = AgentQueuedMessageRoutingSnapshot(
            configuration: configuration,
            deadlineAt: Date(timeIntervalSince1970: 123),
            budgetTokens: 4_000,
            budgetCostMicros: 125,
            reservationId: "reservation-7",
            reservedTokens: 3_500,
            reservedCostMicros: 100,
            admissionReceiptId: receiptID
        )

        let queued = try queue.enqueue(
            threadId: thread.id,
            text: "queued",
            attachments: [],
            interactionMode: .default,
            routingSnapshot: snapshot
        )

        XCTAssertEqual(try queue.routingSnapshot(id: queued.id), snapshot,
                       "enqueue must durably preserve every admission value for replay")
        XCTAssertEqual(queued.routingSnapshot, snapshot,
                       "the host queue payload must carry the same immutable snapshot for iOS replay")
    }

    func testQueueAdmissionSnapshotSurvivesThreadRoutingChange() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let threads = AgentThreadRepository(db: db)
        let queue = AgentQueuedMessageRepository(db: db)
        let original = AgentRoutingConfiguration(
            mode: .auto,
            manualSelection: AgentModelSelection(provider: .claude, modelId: "claude"),
            policyDigest: String(repeating: "b", count: 64),
            revision: 2
        )
        let thread = AgentThread(title: "immutable", provider: .claude, model: "claude",
                                 routingConfiguration: original)
        try threads.upsert(thread)
        let snapshot = AgentQueuedMessageRoutingSnapshot(
            configuration: original,
            deadlineAt: Date(timeIntervalSince1970: 200),
            budgetTokens: 900,
            reservationId: "reservation-original"
        )
        let queued = try queue.enqueue(
            threadId: thread.id,
            text: "queued",
            attachments: [],
            interactionMode: .default,
            routingSnapshot: snapshot
        )

        let changed = try original.replacing(
            expectedRevision: original.revision,
            mode: .manual,
            manualSelection: original.manualSelection,
            manualProviderInstanceId: original.manualProviderInstanceId,
            eligibleProviders: original.eligibleProviders,
            policyDigest: original.policyDigest
        )
        try threads.setRoutingConfiguration(changed, threadId: thread.id, expectedRevision: original.revision)

        XCTAssertEqual(try threads.get(id: thread.id)?.effectiveRoutingConfiguration.mode, .manual)
        XCTAssertEqual(try queue.routingSnapshot(id: queued.id), snapshot,
                       "replay must use the enqueue snapshot, not the thread's current routing")
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

    /// WHY: rail reload lists every retained thread. A per-row routing SELECT
    /// would multiply with the 20-thread workspace cap and hitch the list path.
    func test_listJoinsRoutingInsteadOfPerThreadSelect() throws {
        let (db, root) = try database()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = AgentThreadRepository(db: db)
        var expected: [AgentThreadID: Int] = [:]
        for index in 0..<AgentThreadRepository.maxThreadsPerWorkspace {
            let routing = AgentRoutingConfiguration(
                mode: .manual,
                manualSelection: AgentModelSelection(provider: .codex, modelId: "gpt-5.6-sol"),
                revision: index + 1
            )
            let thread = AgentThread(
                title: "rail-\(index)",
                provider: .codex,
                model: "gpt-5.6-sol",
                routingConfiguration: routing
            )
            try repo.upsert(thread)
            expected[thread.id] = routing.revision
        }

        var standaloneRoutingSelects = 0
        db.beforeStatementStepForTesting = { sql in
            if sql.contains("FROM agent_thread_routing") && !sql.contains("LEFT JOIN") {
                standaloneRoutingSelects += 1
            }
        }
        defer { db.beforeStatementStepForTesting = nil }

        let listed = try repo.list()
        XCTAssertEqual(listed.count, AgentThreadRepository.maxThreadsPerWorkspace)
        for thread in listed {
            XCTAssertEqual(thread.routingConfiguration?.revision, expected[thread.id],
                           "list must return the persisted routing revision without a follow-up get()")
        }
        XCTAssertEqual(standaloneRoutingSelects, 0,
                       "list must JOIN routing; a per-thread SELECT would stall a 20-row rail")
    }
}
