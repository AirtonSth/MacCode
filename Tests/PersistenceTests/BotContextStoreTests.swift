import XCTest
import CoreModel
@testable import Persistence

final class BotContextStoreTests: XCTestCase {
    func test_explicitBindingAuthorizesOnlyExactHostContextActionAndRevision() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Context bot", title: "Teammate", description: "", provider: .claude)
        let context = BotContext.workspace(WorkspaceID())
        let grant = try store.grantContext(hostID: "host-a", botID: bot.id, context: context, actions: [.read, .send], expectedRevision: nil)
        XCTAssertTrue(try store.authorizes(hostID: "host-a", botID: bot.id, context: context, action: .read, policyRevision: grant.policyRevision))
        XCTAssertFalse(try store.authorizes(hostID: "host-b", botID: bot.id, context: context, action: .read, policyRevision: grant.policyRevision))
        XCTAssertFalse(try store.authorizes(hostID: "host-a", botID: bot.id, context: .general, action: .read, policyRevision: grant.policyRevision))
        XCTAssertFalse(try store.authorizes(hostID: "host-a", botID: bot.id, context: context, action: .files, policyRevision: grant.policyRevision))
        XCTAssertFalse(try store.authorizes(hostID: "host-a", botID: bot.id, context: context, action: .read, policyRevision: grant.policyRevision + 1))
        XCTAssertFalse(try store.authorizes(hostID: "absent", botID: bot.id, context: context, action: .read, policyRevision: 1))
    }

    func test_revokeAndRegrantAdvanceRevisionAndLegacyWorkspaceIsNotGrant() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let workspaceID = WorkspaceID()
        let bot = try store.create(name: "Legacy", title: "Teammate", description: "", workspaceID: workspaceID)
        let context = BotContext.workspace(workspaceID)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: context, action: .read, policyRevision: 1))
        let first = try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read], expectedRevision: nil)
        let revoked = try store.revokeContext(hostID: "host", botID: bot.id, context: context, expectedRevision: first.policyRevision)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: context, action: .read, policyRevision: revoked.policyRevision))
        let next = try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.send], expectedRevision: revoked.policyRevision)
        XCTAssertEqual(next.policyRevision, revoked.policyRevision + 1)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: context, action: .read, policyRevision: next.policyRevision))
        XCTAssertThrowsError(try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read], expectedRevision: first.policyRevision))
        XCTAssertEqual(try store.listContextBindings(hostID: "host", botID: bot.id).count, 1)
    }

    func test_hostMustBeNonemptyAndDuplicateTupleRequiresExpectedRevision() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Tuple", title: "Teammate", description: "", provider: .claude)
        XCTAssertThrowsError(try store.grantContext(hostID: " ", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil))
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        XCTAssertThrowsError(try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.send], expectedRevision: nil))
        XCTAssertEqual(try store.getContextBinding(hostID: "host", botID: bot.id, context: .general)?.policyRevision, grant.policyRevision)
    }

    func test_deletedBotCannotAuthorize() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Deleted", title: "Teammate", description: "")
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        try store.delete(id: bot.id)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: .general, action: .read, policyRevision: grant.policyRevision))
    }

    func test_unsupportedAndMalformedRowsFailClosedAndCannotResetRevision() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Corrupt", title: "Teammate", description: "")
        let context = BotContext.general
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read], expectedRevision: nil)
        let corrupt = try db.prepare("UPDATE bot_context_bindings SET contract_version=99 WHERE host_id='host';")
        _ = try corrupt.step()
        corrupt.reset()
        XCTAssertNil(try store.getContextBinding(hostID: "host", botID: bot.id, context: context))
        XCTAssertTrue(try store.listContextBindings(hostID: "host", botID: bot.id).isEmpty)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: context, action: .read, policyRevision: grant.policyRevision))
        XCTAssertThrowsError(try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.send], expectedRevision: nil))
        let repair = try db.prepare("UPDATE bot_context_bindings SET contract_version=1, actions='read,unknown' WHERE host_id='host';")
        _ = try repair.step()
        repair.reset()
        XCTAssertNil(try store.getContextBinding(hostID: "host", botID: bot.id, context: context))
        XCTAssertTrue(try store.listContextBindings(hostID: "host", botID: bot.id).isEmpty)
        XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: context, action: .read, policyRevision: grant.policyRevision))
        XCTAssertThrowsError(try store.grantContext(hostID: "host", botID: bot.id, context: context, actions: [.read], expectedRevision: nil))
    }

    func test_fractionalContractVersionAndRevisionFailClosedWithoutMutation() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Fractional", title: "Teammate", description: "")
        let grant = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        try db.execute("PRAGMA ignore_check_constraints=ON;")
        for column in ["contract_version", "policy_revision"] {
            let update = try db.prepare("UPDATE bot_context_bindings SET \(column)=1.5 WHERE host_id='host';")
            _ = try update.step()
            update.reset()
            XCTAssertNil(try store.getContextBinding(hostID: "host", botID: bot.id, context: .general))
            XCTAssertTrue(try store.listContextBindings(hostID: "host", botID: bot.id).isEmpty)
            XCTAssertFalse(try store.authorizes(hostID: "host", botID: bot.id, context: .general, action: .read, policyRevision: grant.policyRevision))
            XCTAssertThrowsError(try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.send], expectedRevision: nil))
            XCTAssertThrowsError(try store.revokeContext(hostID: "host", botID: bot.id, context: .general, expectedRevision: grant.policyRevision))
            let raw = try db.prepare("SELECT typeof(\(column)), \(column) FROM bot_context_bindings WHERE host_id='host';")
            XCTAssertTrue(try raw.step())
            XCTAssertEqual(raw.columnText(0), "real")
            XCTAssertEqual(raw.columnDouble(1), 1.5)
            raw.reset()
            let restore = try db.prepare("UPDATE bot_context_bindings SET \(column)=1 WHERE host_id='host';")
            _ = try restore.step()
            restore.reset()
        }
    }

    func test_int64MaxRevisionRejectsGrantAndRevokeWithoutMutation() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let bot = try store.create(name: "Maximum", title: "Teammate", description: "")
        _ = try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.read], expectedRevision: nil)
        let update = try db.prepare("UPDATE bot_context_bindings SET policy_revision=9223372036854775807 WHERE host_id='host';")
        _ = try update.step()
        update.reset()
        XCTAssertThrowsError(try store.grantContext(hostID: "host", botID: bot.id, context: .general, actions: [.send], expectedRevision: Int64.max))
        XCTAssertThrowsError(try store.revokeContext(hostID: "host", botID: bot.id, context: .general, expectedRevision: Int64.max))
        let raw = try db.prepare("SELECT typeof(policy_revision), policy_revision, state, actions FROM bot_context_bindings WHERE host_id='host';")
        XCTAssertTrue(try raw.step())
        XCTAssertEqual(raw.columnText(0), "integer")
        XCTAssertEqual(raw.columnInt64(1), Int64.max)
        XCTAssertEqual(raw.columnText(2), "active")
        XCTAssertEqual(raw.columnText(3), "read")
        raw.reset()
    }

    func test_fileReopenPreservesLegacyBotAndHistoryWithoutImplicitGrant() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let path = directory.appendingPathComponent("contexts.sqlite").path
        defer { try? FileManager.default.removeItem(at: directory) }
        var botID: BotID!
        let workspaceID = WorkspaceID()
        do {
            let db = try SQLiteDB(path: path)
            try Schema.migrateSteps(db, Schema.steps.filter { $0.version < Schema.botContextsSchemaVersion })
            let store = BotStore(db: db)
            let bot = try store.create(name: "Persisted", title: "Teammate", description: "", workspaceID: workspaceID)
            botID = bot.id
            let event = try db.prepare("INSERT INTO events(seq, kind, payload_json, created_at) VALUES(999, 'context-test', '{}', 'now');")
            _ = try event.step()
            event.reset()
        }
        do {
            let db = try SQLiteDB(path: path)
            try Schema.migrate(db)
            let store = BotStore(db: db)
            XCTAssertNotNil(try store.get(id: botID))
            XCTAssertFalse(try store.authorizes(hostID: "host", botID: botID, context: .workspace(workspaceID), action: .read, policyRevision: 1))
            let history = try db.prepare("SELECT COUNT(*) FROM events WHERE kind='context-test';")
            XCTAssertTrue(try history.step())
            XCTAssertEqual(history.columnInt64(0), 1)
            history.reset()
            XCTAssertEqual(Schema.botContextsSchemaVersion, 94)
        }
    }
}
