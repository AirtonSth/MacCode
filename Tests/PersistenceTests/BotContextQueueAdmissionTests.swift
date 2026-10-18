import XCTest
import Foundation
import CoreModel
@testable import Persistence

final class BotContextQueueAdmissionTests: XCTestCase {
    func testQueueAdmissionRollsBackReceiptAndRetriesIdempotently() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let directory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("QueueAdmission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbPath = directory.appendingPathComponent("authority.sqlite").path
        let db = try SQLiteDB(path: dbPath)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let settings = SettingsStore(db: db)
        settings.update { $0.botsControlPlaneEnabled = true }
        var authority = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: directory)
        let created = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create", "name": "Queue test"])
        let botID = try XCTUnwrap(created["bot_id"] as? String)
        let routed = try authority.dispatch(method: "bot.routing.set", params: [
            "client_request_id": "route", "bot_id": botID, "host_id": "host",
            "provider": "distill", "provider_instance_id": "distill", "model": "main-a", "routing_mode": "explicit",
        ])
        XCTAssertNotNil(routed)
        let grant: [String: Any] = [
            "client_request_id": "grant", "host_id": "host", "bot_id": botID,
            "context_key": "general:v1", "context_version": 1, "policy_revision": 0,
            "actions": ["read", "send"],
        ]
        _ = try authority.dispatch(method: "bot.context.grant", params: grant)
        let createdConversation = try authority.dispatch(method: "bot.conversation.create", params: [
            "client_request_id": "conversation", "bot_id": botID, "title": "Fresh",
            "host_id": "host", "context_key": "general:v1", "context_version": 1, "policy_revision": 1,
        ])
        let conversationID = try XCTUnwrap((createdConversation["readback"] as? [String: Any])?["conversation_id"] as? String)
        let params: [String: Any] = [
            "client_request_id": "queue-same-request", "bot_id": botID, "host_id": "host",
            "conversation_id": conversationID, "context_key": "general:v1", "context_version": 1,
            "policy_revision": 1, "text": "secret queue payload",
        ]
        let receiptsBefore = try setting(db, key: "bot.remote.receipts")
        let claimsBefore = try setting(db, key: "bot.remote.receipt_claims")
        try db.execute("""
            CREATE TRIGGER fail_bot_receipt BEFORE INSERT ON settings
            WHEN NEW.key = 'bot.remote.receipts'
            BEGIN SELECT RAISE(ABORT, 'owned receipt failure'); END;
            """)
        XCTAssertThrowsError(try authority.dispatch(method: "bot.conversation.enqueue", params: params))
        XCTAssertEqual(try count(db, "agent_queued_messages"), 0)
        XCTAssertEqual(try count(db, "host_restore_queue_holds"), 0)
        XCTAssertEqual(try count(db, "agent_runs"), 0)
        XCTAssertEqual(try count(db, "agent_messages"), 0)
        XCTAssertEqual(try count(db, "bot_conversations"), 1)
        XCTAssertEqual(try count(db, "bot_conversation_contexts"), 1)
        XCTAssertEqual(try setting(db, key: "bot.remote.receipts"), receiptsBefore)
        XCTAssertEqual(try setting(db, key: "bot.remote.receipt_claims"), claimsBefore)

        try db.execute("DROP TRIGGER fail_bot_receipt;")
        let accepted = try authority.dispatch(method: "bot.conversation.enqueue", params: params)
        let queueID = try XCTUnwrap((accepted["readback"] as? [String: Any])?["queue_id"] as? String)
        XCTAssertEqual(try count(db, "agent_queued_messages"), 1)
        XCTAssertEqual(try count(db, "host_restore_queue_holds"), 1)
        XCTAssertEqual(try setting(db, key: "bot.remote.receipts")?.contains("secret queue payload"), false)
        XCTAssertEqual(try setting(db, key: "bot.remote.receipt_claims")?.contains("secret queue payload"), false)

        let reopenedDB = try SQLiteDB(path: dbPath)
        try Schema.migrate(reopenedDB)
        authority = BotRemoteControlAuthority(db: reopenedDB, store: BotStore(db: reopenedDB), settings: SettingsStore(db: reopenedDB), appSupportDirectory: directory)
        let replayed = try authority.dispatch(method: "bot.conversation.enqueue", params: params)
        XCTAssertEqual((replayed["readback"] as? [String: Any])?["queue_id"] as? String, queueID)
        XCTAssertEqual(try count(reopenedDB, "agent_queued_messages"), 1)
        XCTAssertEqual(try count(reopenedDB, "host_restore_queue_holds"), 1)
        let threadRaw = try XCTUnwrap((createdConversation["readback"] as? [String: Any])?["thread_id"] as? String)
        let threadID = AgentThreadID(try XCTUnwrap(UUID(uuidString: threadRaw)))
        let queue = try AgentQueuedMessageRepository(db: reopenedDB).list(threadId: threadID)
        XCTAssertEqual(queue.map(\.text), ["secret queue payload"])
    }

    private func count(_ db: SQLiteDB, _ table: String) throws -> Int {
        let statement = try db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { statement.reset() }
        guard try statement.step() else { return 0 }
        return Int(statement.columnInt64(0))
    }

    private func setting(_ db: SQLiteDB, key: String) throws -> String? {
        let statement = try db.prepare("SELECT value FROM settings WHERE key = ?;")
        defer { statement.reset() }
        try statement.bind(1, key)
        return try statement.step() ? statement.columnText(0) : nil
    }
}
