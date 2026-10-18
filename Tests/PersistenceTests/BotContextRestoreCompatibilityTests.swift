import Foundation
import XCTest
import CoreModel
@testable import Persistence

final class BotContextRestoreCompatibilityTests: XCTestCase {
    func test_restoreSnapshotAfterRevocationKeepsHistoryButNeverRestoresAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BotContextRestore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: root))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }

        let sourcePath = root.appendingPathComponent("source.sqlite").path
        let snapshotPath = root.appendingPathComponent("restore.sqlite").path
        let support = root.appendingPathComponent("support", isDirectory: true)
        let restoredSupport = root.appendingPathComponent("restored-support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let botID: BotID
        let botBID: BotID
        let conversationID: BotConversationID
        let threadID: AgentThreadID
        let pin: BotConversationContextPin
        let queued: BotQueuedFollowUpRecord
        let grantA: [String: Any]
        let create: [String: Any]
        let revoke: [String: Any]
        let grantReceipt: [String: Any]
        let createReceipt: [String: Any]
        let revokeReceipt: [String: Any]

        do {
            let db = try SQLiteDB(path: sourcePath)
            try Schema.migrate(db)
            let store = BotStore(db: db)
            let authority = BotRemoteControlAuthority(db: db, store: store, settings: SettingsStore(db: db), appSupportDirectory: support)
            let createdA = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create-A", "name": "Restore A"])
            let createdB = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create-B", "name": "Restore B"])
            botID = BotID(try XCTUnwrap((createdA["bot_id"] as? String).flatMap(UUID.init(uuidString:))))
            botBID = BotID(try XCTUnwrap((createdB["bot_id"] as? String).flatMap(UUID.init(uuidString:))))
            _ = try authority.dispatch(method: "bot.routing.set", params: ["client_request_id": "route-A", "bot_id": botID.value.uuidString, "host_id": "host", "provider": "distill", "provider_instance_id": "distill", "model": "restore-test"])
            grantA = ["client_request_id": "grant-A", "host_id": "host", "bot_id": botID.value.uuidString, "context_key": "general:v1", "context_version": 1, "policy_revision": 0, "actions": ["read", "send"]]
            var grantB: [String: Any] = grantA
            grantB["client_request_id"] = "grant-B"
            grantB["bot_id"] = botBID.value.uuidString
            grantReceipt = try authority.dispatch(method: "bot.context.grant", params: grantA)
            _ = try authority.dispatch(method: "bot.context.grant", params: grantB)
            create = ["client_request_id": "create-conversation", "bot_id": botID.value.uuidString, "title": "Historical", "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1]
            createReceipt = try authority.dispatch(method: "bot.conversation.create", params: create)
            let createdConversation = createReceipt
            let readback = try XCTUnwrap(createdConversation["readback"] as? [String: Any])
            conversationID = BotConversationID(try XCTUnwrap((readback["conversation_id"] as? String).flatMap(UUID.init(uuidString:))))
            let conversation = try XCTUnwrap(store.conversation(id: conversationID))
            threadID = try XCTUnwrap(conversation.linkedAgentThreadID)
            pin = try XCTUnwrap(store.conversationContextPin(conversationID: conversationID))
            queued = try store.enqueueQueuedFollowUp(BotQueuedFollowUpRecord(id: "queued-restore", botID: botID, conversationID: conversationID.value.uuidString, text: "queued payload", payloadJSON: "{\"client_request_id\":\"queued-request\",\"attachment_ids\":[\"attachment-restore\"]}", sortOrder: 0, createdAt: Date(timeIntervalSince1970: 123)))
            revoke = ["client_request_id": "revoke-A", "host_id": "host", "bot_id": botID.value.uuidString, "context_key": "general:v1", "context_version": 1, "policy_revision": 1]
            revokeReceipt = try authority.dispatch(method: "bot.context.revoke", params: revoke)
            let escaped = snapshotPath.replacingOccurrences(of: "'", with: "''")
            try db.execute("VACUUM INTO '\(escaped)';")
        }
        try FileManager.default.copyItem(at: support, to: restoredSupport)

        func rowCount(_ db: SQLiteDB, _ table: String) throws -> Int64 {
            let query = try db.prepare("SELECT COUNT(*) FROM \(table);")
            XCTAssertTrue(try query.step())
            return query.columnInt64(0)
        }
        func assertInactiveAuthority(_ authority: BotRemoteControlAuthority, method: String, params: [String: Any]) {
            XCTAssertThrowsError(try authority.dispatch(method: method, params: params)) {
                XCTAssertEqual(($0 as? BotRemoteControlAuthority.Error)?.message, "Bot context authority is not active for this request.")
            }
        }

        let restoredDB = try SQLiteDB(path: snapshotPath)
        try Schema.migrate(restoredDB)
        let restoredStore = BotStore(db: restoredDB)
        let restoredAuthority = BotRemoteControlAuthority(db: restoredDB, store: restoredStore, settings: SettingsStore(db: restoredDB), appSupportDirectory: restoredSupport)
        XCTAssertEqual(try restoredStore.get(id: botID)?.id, botID)
        XCTAssertEqual(try restoredStore.get(id: botBID)?.id, botBID)
        XCTAssertEqual(try restoredStore.conversation(id: conversationID)?.id, conversationID)
        XCTAssertEqual(try restoredStore.conversation(id: conversationID)?.botID, botID)
        XCTAssertEqual(try restoredStore.conversation(id: conversationID)?.linkedAgentThreadID, threadID)
        XCTAssertEqual(try restoredStore.conversationContextPin(conversationID: conversationID), pin)
        XCTAssertEqual(pin.policyRevision, 1)
        XCTAssertEqual(try AgentThreadRepository(db: restoredDB).get(id: threadID)?.id, threadID)
        XCTAssertEqual(try restoredStore.listQueuedFollowUps(botID: botID), [queued])
        let bindingA = try XCTUnwrap(restoredStore.getContextBinding(hostID: "host", botID: botID, context: .general))
        let bindingB = try XCTUnwrap(restoredStore.getContextBinding(hostID: "host", botID: botBID, context: .general))
        XCTAssertEqual(bindingA.state, .revoked)
        XCTAssertEqual(bindingA.policyRevision, 2)
        XCTAssertEqual(bindingB.state, .active)
        XCTAssertEqual(bindingB.policyRevision, 1)

        var sends = 0
        var routineSends = 0
        restoredAuthority.onSend = { _, _, _, _, _, _ in sends += 1; return [:] }
        restoredAuthority.onRoutineSend = { _ in routineSends += 1; return [:] }
        try Schema.migrate(restoredDB)
        XCTAssertEqual(try restoredStore.getContextBinding(hostID: "host", botID: botID, context: .general), bindingA)
        XCTAssertEqual(try restoredStore.listQueuedFollowUps(botID: botID), [queued])
        let restoredQueued = try XCTUnwrap(restoredStore.listQueuedFollowUps(botID: botID).first)
        XCTAssertEqual(restoredQueued.id, "queued-restore")
        XCTAssertEqual(restoredQueued.payloadJSON, "{\"client_request_id\":\"queued-request\",\"attachment_ids\":[\"attachment-restore\"]}")
        XCTAssertEqual(grantReceipt["request_id"] as? String, "grant-A")
        XCTAssertEqual(createReceipt["request_id"] as? String, "create-conversation")
        XCTAssertEqual(revokeReceipt["request_id"] as? String, "revoke-A")
        XCTAssertEqual(createReceipt["status"] as? String, "completed")
        XCTAssertEqual((createReceipt["readback"] as? [String: Any])?["conversation_id"] as? String, conversationID.value.uuidString.lowercased())
        XCTAssertEqual((createReceipt["readback"] as? [String: Any])?["thread_id"] as? String, threadID.value.uuidString.lowercased())

        let conversationsBefore = try restoredStore.listConversations(botID: botID).map(\.id)
        let runsBefore = try rowCount(restoredDB, "agent_runs")
        let messagesBefore = try rowCount(restoredDB, "agent_messages")
        let queuesBefore = try rowCount(restoredDB, "bot_queued_follow_ups")
        let grantReplay = try restoredAuthority.dispatch(method: "bot.context.grant", params: grantA)
        XCTAssertEqual(grantReplay as NSDictionary, grantReceipt as NSDictionary)
        let afterGrantReplay = try XCTUnwrap(restoredStore.getContextBinding(hostID: "host", botID: botID, context: .general))
        XCTAssertEqual(afterGrantReplay, bindingA)
        XCTAssertEqual(try restoredStore.getContextBinding(hostID: "host", botID: botBID, context: .general), bindingB)
        XCTAssertFalse(try restoredStore.authorizes(hostID: "host", botID: botID, context: .general, action: .read, policyRevision: 1))
        XCTAssertFalse(try restoredStore.authorizes(hostID: "host", botID: botID, context: .general, action: .send, policyRevision: 1))
        assertInactiveAuthority(restoredAuthority, method: "bot.conversation.create", params: create)
        XCTAssertEqual(try restoredStore.getContextBinding(hostID: "host", botID: botID, context: .general), bindingA)
        XCTAssertEqual(try restoredStore.getContextBinding(hostID: "host", botID: botBID, context: .general), bindingB)
        let revokeReplay = try restoredAuthority.dispatch(method: "bot.context.revoke", params: revoke)
        XCTAssertEqual(revokeReplay as NSDictionary, revokeReceipt as NSDictionary)
        XCTAssertEqual(try restoredStore.getContextBinding(hostID: "host", botID: botID, context: .general), bindingA)
        XCTAssertEqual(try restoredStore.getContextBinding(hostID: "host", botID: botBID, context: .general), bindingB)
        assertInactiveAuthority(restoredAuthority, method: "bot.send", params: ["client_request_id": "denied-send", "bot_id": botID.value.uuidString, "text": "must stay denied", "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        assertInactiveAuthority(restoredAuthority, method: "bot.routine.run", params: ["client_request_id": "denied-routine-run", "bot_id": botID.value.uuidString, "routine_id": UUID().uuidString, "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        assertInactiveAuthority(restoredAuthority, method: "bot.scheduler.tick", params: ["client_request_id": "denied-scheduler-tick", "bot_id": botID.value.uuidString, "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(routineSends, 0)
        XCTAssertEqual(try restoredStore.listQueuedFollowUps(botID: botID), [queued])
        XCTAssertEqual(try restoredStore.listConversations(botID: botID).map(\.id), conversationsBefore)
        XCTAssertEqual(try rowCount(restoredDB, "agent_runs"), runsBefore)
        XCTAssertEqual(try rowCount(restoredDB, "agent_messages"), messagesBefore)
        XCTAssertEqual(try rowCount(restoredDB, "bot_queued_follow_ups"), queuesBefore)

        let reopenedDB = try SQLiteDB(path: snapshotPath)
        try Schema.migrate(reopenedDB)
        let reopenedStore = BotStore(db: reopenedDB)
        let reopenedAuthority = BotRemoteControlAuthority(db: reopenedDB, store: reopenedStore, settings: SettingsStore(db: reopenedDB), appSupportDirectory: restoredSupport)
        assertInactiveAuthority(reopenedAuthority, method: "bot.send", params: ["client_request_id": "denied-send-reopened", "bot_id": botID.value.uuidString, "text": "must stay denied", "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        assertInactiveAuthority(reopenedAuthority, method: "bot.routine.run", params: ["client_request_id": "denied-routine-reopened", "bot_id": botID.value.uuidString, "routine_id": UUID().uuidString, "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        assertInactiveAuthority(reopenedAuthority, method: "bot.scheduler.tick", params: ["client_request_id": "denied-tick-reopened", "bot_id": botID.value.uuidString, "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1])
        XCTAssertEqual(try reopenedStore.getContextBinding(hostID: "host", botID: botID, context: .general), bindingA)
        XCTAssertEqual(try reopenedStore.getContextBinding(hostID: "host", botID: botBID, context: .general), bindingB)
        XCTAssertEqual(try reopenedStore.conversationContextPin(conversationID: conversationID), pin)
        XCTAssertEqual(try reopenedStore.listQueuedFollowUps(botID: botID), [queued])
        XCTAssertEqual(try reopenedStore.listConversations(botID: botID).map(\.id), conversationsBefore)
        XCTAssertEqual(try rowCount(reopenedDB, "agent_runs"), runsBefore)
        XCTAssertEqual(try rowCount(reopenedDB, "agent_messages"), messagesBefore)
        XCTAssertEqual(try rowCount(reopenedDB, "bot_queued_follow_ups"), queuesBefore)
    }
}
