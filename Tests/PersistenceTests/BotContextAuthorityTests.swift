import XCTest
import CoreModel
@testable import Persistence

final class BotContextAuthorityTests: XCTestCase {
    func testGrantReplayListRevokeAndContextResourceFailClosed() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("bot-context-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: support)
        let created = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Context test"])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let grant: [String: Any] = ["client_request_id": "grant", "host_id": "host-a", "bot_id": botID, "context_key": "general:v1", "context_version": 1, "policy_revision": 0, "actions": ["read", "send"]]
        let first = try authority.dispatch(method: "bot.context.grant", params: grant)
        XCTAssertEqual((first["readback"] as? [String: Any])?["policy_revision"] as? Int64, 1)
        let replay = try authority.dispatch(method: "bot.context.grant", params: grant)
        XCTAssertEqual((replay["readback"] as? [String: Any])?["policy_revision"] as? Int64, 1)
        let listed = try authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])
        XCTAssertEqual((listed["bindings"] as? [[String: Any]])?.count, 1)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.send", params: ["client_request_id": "send-scoped", "bot_id": botID, "text": "must not reach legacy thread", "host_id": "host-a", "context_key": "general:v1", "context_version": 1, "policy_revision": 1]))
        var revoke = grant
        revoke["client_request_id"] = "revoke"
        revoke["policy_revision"] = 1
        revoke.removeValue(forKey: "actions")
        _ = try authority.dispatch(method: "bot.context.revoke", params: revoke)
        let after = try authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])
        XCTAssertEqual(((after["bindings"] as? [[String: Any]])?.first)?["state"] as? String, "revoked")
        var malformed = grant
        malformed["client_request_id"] = "fractional"
        malformed["context_version"] = 1.5
        XCTAssertThrowsError(try authority.dispatch(method: "bot.context.grant", params: malformed))
    }

    func testContextCancellationReadbackAndDurableReplay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bot-context-cancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbPath = directory.appendingPathComponent("authority.sqlite").path
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: directory)
        let created = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Cancellation"])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let grant: [String: Any] = ["client_request_id": "grant-cancel", "host_id": "host-a", "bot_id": botID, "context_key": "general:v1", "context_version": 1, "policy_revision": 0, "actions": ["read", "send"]]

        let noCallback = try authority.dispatch(method: "bot.context.grant", params: grant)
        XCTAssertEqual((noCallback["readback"] as? [String: Any])?["run_cancellation_requested"] as? Bool, false)
        let revisionBefore = try XCTUnwrap((try XCTUnwrap(try authority.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]])).first?["policy_revision"] as? Int64)

        var callbackCount = 0
        authority.onContextBindingChanged = { binding in
            callbackCount += 1
            let stored = try? store.getContextBinding(hostID: binding.hostID, botID: binding.botID, context: binding.context)
            XCTAssertEqual(stored?.state, .revoked)
            return false
        }
        let revoke: [String: Any] = ["client_request_id": "revoke-cancel", "host_id": "host-a", "bot_id": botID, "context_key": "general:v1", "context_version": 1, "policy_revision": revisionBefore]
        let result = try authority.dispatch(method: "bot.context.revoke", params: revoke)
        let readback = try XCTUnwrap(result["readback"] as? [String: Any])
        XCTAssertEqual(readback["run_cancellation_requested"] as? Bool, false)
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertEqual((readback["state"] as? String), "revoked")
        XCTAssertEqual(callbackCount, 1)

        let reopenedDB = try SQLiteDB(path: dbPath)
        try Schema.migrate(reopenedDB)
        let reopened = BotRemoteControlAuthority(db: reopenedDB, store: BotStore(db: reopenedDB), settings: SettingsStore(db: reopenedDB), appSupportDirectory: directory)
        reopened.onContextBindingChanged = { _ in callbackCount += 1; return false }
        let replay = try reopened.dispatch(method: "bot.context.revoke", params: revoke)
        XCTAssertEqual(replay["status"] as? String, "completed")
        XCTAssertEqual((replay["readback"] as? [String: Any])?["state"] as? String, "revoked")
        XCTAssertEqual(callbackCount, 1)
        let durable = try XCTUnwrap((try XCTUnwrap(try reopened.dispatch(method: "bot.context.list", params: ["host_id": "host-a", "bot_id": botID])["bindings"] as? [[String: Any]])).first)
        XCTAssertEqual(durable["state"] as? String, "revoked")
        XCTAssertEqual(durable["policy_revision"] as? Int64, revisionBefore + 1)
    }

    func testScopedConversationListAndSelectEnforceContextAuthority() throws {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("bot-context-dispatch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: support)
        let created = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Context dispatch"])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let base: [String: Any] = ["bot_id": botID, "host_id": "host-a", "context_version": 1]

        let routed = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "routing", "bot_id": botID, "host_id": "host-a",
            "provider": "distill", "provider_instance_id": "distill", "model": "test-main",
        ])
        XCTAssertNotNil(routed)

        var generalGrant = base
        generalGrant["client_request_id"] = "grant-general"
        generalGrant["context_key"] = "general:v1"
        generalGrant["policy_revision"] = 0
        generalGrant["actions"] = ["read", "send"]
        _ = try authority.dispatch(method: "bot.context.grant", params: generalGrant)
        let workspaceKey = BotContext.workspace(WorkspaceID()).storageKey
        var workspaceGrant = generalGrant
        workspaceGrant["client_request_id"] = "grant-workspace"
        workspaceGrant["context_key"] = workspaceKey
        _ = try authority.dispatch(method: "bot.context.grant", params: workspaceGrant)

        let generalCreate: [String: Any] = [
            "client_request_id": "create-general", "bot_id": botID, "title": "General",
            "host_id": "host-a", "context_key": "general:v1", "context_version": 1,
            "policy_revision": 1,
        ]
        let generalResult = try authority.dispatch(method: "bot.conversation.create", params: generalCreate)
        let generalID = try XCTUnwrap((generalResult["readback"] as? [String: Any])?["conversation_id"] as? String)
        let workspaceCreate: [String: Any] = [
            "client_request_id": "create-workspace", "bot_id": botID, "title": "Workspace",
            "host_id": "host-a", "context_key": workspaceKey, "context_version": 1,
            "policy_revision": 1,
        ]
        let workspaceResult = try authority.dispatch(method: "bot.conversation.create", params: workspaceCreate)
        let workspaceID = try XCTUnwrap((workspaceResult["readback"] as? [String: Any])?["conversation_id"] as? String)

        let generalList: [String: Any] = [
            "bot_id": botID, "host_id": "host-a", "context_key": "general:v1",
            "context_version": 1, "policy_revision": 1,
        ]
        let scoped = try authority.dispatch(method: "bot.conversation.list", params: generalList)
        let rows = try XCTUnwrap(scoped["conversations"] as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, [generalID])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["host_id"] as? String, "host-a")
        XCTAssertEqual(row["context_key"] as? String, "general:v1")
        XCTAssertEqual(row["context_version"] as? Int, 1)
        XCTAssertEqual(row["policy_revision"] as? Int64, 1)
        XCTAssertNotNil(row["linked_agent_thread_id"] as? String)
        let legacy = try authority.dispatch(method: "bot.conversation.list", params: ["bot_id": botID])
        XCTAssertTrue(try XCTUnwrap(legacy["conversations"] as? [[String: Any]]).isEmpty)

        var select = generalList
        select["client_request_id"] = "select-general"
        select["conversation_id"] = generalID
        _ = try authority.dispatch(method: "bot.conversation.select", params: select)
        select["client_request_id"] = "select-workspace-with-general"
        select["conversation_id"] = workspaceID
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.select", params: select)) {
            XCTAssertEqual(($0 as? BotRemoteControlAuthority.Error)?.message, "Context resource unavailable.")
        }
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.select", params: ["client_request_id": "legacy-select", "bot_id": botID, "conversation_id": generalID])) {
            XCTAssertEqual(($0 as? BotRemoteControlAuthority.Error)?.message, "Context resource unavailable.")
        }

        let revoke: [String: Any] = [
            "client_request_id": "revoke-general", "bot_id": botID, "host_id": "host-a",
            "context_key": "general:v1", "context_version": 1, "policy_revision": 1,
        ]
        _ = try authority.dispatch(method: "bot.context.revoke", params: revoke)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.list", params: generalList)) {
            XCTAssertEqual(($0 as? BotRemoteControlAuthority.Error)?.message, "Bot context authority is not active for this request.")
        }
    }
}
