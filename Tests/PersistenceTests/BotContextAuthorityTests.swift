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
}
