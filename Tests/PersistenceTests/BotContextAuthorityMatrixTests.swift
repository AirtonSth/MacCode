import XCTest
import Foundation
import CoreModel
@testable import Persistence

/// One table of principal x context x policy-state x entry point, driven through the shipped
/// `BotRemoteControlAuthority.dispatch` and the real SQLite store. Every row states the decision
/// the host must make, so a change that widens access in any single entry point fails here.
final class BotContextAuthorityMatrixTests: XCTestCase {
    private struct Row {
        let name: String
        let method: String
        let bot: String      // "A" or "B"
        let context: String  // "general" or "workspace"
        let revision: Int    // policy revision sent
        let allowed: Bool
    }

    func testAllowDenyMatrixAcrossDirectQueueExportCreateAndNonContextualEntryPoints() throws {
        let root = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent("AuthorityMatrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try SQLiteDB(path: directory.appendingPathComponent("matrix.sqlite").path)
        try Schema.migrate(db)
        let store = BotStore(db: db)
        let settings = SettingsStore(db: db)
        settings.update { $0.botsControlPlaneEnabled = true }
        let authority = BotRemoteControlAuthority(db: db, store: store, settings: settings, appSupportDirectory: directory)
        let host = "host"
        let workspace = WorkspaceID(UUID())
        let workspaceKey = BotContext.workspace(workspace).storageKey

        func makeBot(_ name: String) throws -> String {
            let created = try authority.dispatch(method: "bot.create", params: ["client_request_id": "create-\(name)", "name": name])
            let id = try XCTUnwrap(created["bot_id"] as? String)
            _ = try authority.dispatch(method: "bot.routing.set", params: [
                "client_request_id": "route-\(name)", "bot_id": id, "host_id": host, "provider": "distill",
                "provider_instance_id": "distill", "model": "main-a", "routing_mode": "explicit"])
            return id
        }
        let botA = try makeBot("Matrix A")
        let botB = try makeBot("Matrix B")
        let botC = try makeBot("Matrix C")
        func grant(_ bot: String, key: String, actions: [String]) throws {
            _ = try authority.dispatch(method: "bot.context.grant", params: [
                "client_request_id": UUID().uuidString, "host_id": host, "bot_id": bot, "context_key": key,
                "context_version": 1, "policy_revision": 0, "actions": actions])
        }
        try grant(botA, key: "general:v1", actions: ["read", "send", "export"])
        try grant(botA, key: workspaceKey, actions: ["read", "send"])
        try grant(botB, key: "general:v1", actions: ["read"])  // read-only principal
        // C can read and send everywhere it is bound but never export: only the export check can deny it.
        try grant(botC, key: "general:v1", actions: ["read", "send"])
        try grant(botC, key: workspaceKey, actions: ["read", "send"])

        func conversation(_ bot: String, key: String) throws -> (id: String, thread: AgentThreadID) {
            let made = try authority.dispatch(method: "bot.conversation.create", params: [
                "client_request_id": UUID().uuidString, "bot_id": bot, "title": "T", "host_id": host,
                "context_key": key, "context_version": 1, "policy_revision": 1])
            let id = try XCTUnwrap((made["readback"] as? [String: Any])?["conversation_id"] as? String)
            let thread = try XCTUnwrap(UUID(uuidString: try XCTUnwrap((made["readback"] as? [String: Any])?["thread_id"] as? String)))
            return (id, AgentThreadID(thread))
        }
        let generalA = try conversation(botA, key: "general:v1")
        let workspaceA = try conversation(botA, key: workspaceKey)
        let generalC = try conversation(botC, key: "general:v1")
        let workspaceAWithoutExportSource = workspaceA
        let message = AgentMessage(threadId: generalA.thread, role: .assistant, content: "approved excerpt")
        let messageC = AgentMessage(threadId: generalC.thread, role: .assistant, content: "approved excerpt C")
        let messageWorkspaceA = AgentMessage(threadId: workspaceAWithoutExportSource.thread, role: .assistant, content: "workspace excerpt")
        for item in [message, messageC, messageWorkspaceA] { try AgentMessageRepository(db: db).append(item) }

        func params(_ method: String, bot: String, key: String, revision: Int, convo: String) -> [String: Any] {
            var p: [String: Any] = ["bot_id": bot, "host_id": host, "context_key": key, "context_version": 1, "policy_revision": revision]
            switch method {
            case "bot.conversation.list": break
            case "bot.conversation.select": p["conversation_id"] = convo; p["client_request_id"] = UUID().uuidString
            case "bot.conversation.create": p["title"] = "x"; p["client_request_id"] = UUID().uuidString
            case "bot.conversation.enqueue": p["conversation_id"] = convo; p["text"] = "hold"; p["client_request_id"] = UUID().uuidString
            default:
                p["conversation_id"] = convo
                p["target_context_key"] = key == workspaceKey ? "general:v1" : workspaceKey
                p["target_policy_revision"] = 1
                let item = convo == generalC.id ? messageC : (convo == workspaceA.id ? messageWorkspaceA : message)
                p["message_ids"] = [item.id.value.uuidString.lowercased()]
            }
            return p
        }
        let rows: [Row] = [
            Row(name: "list general A", method: "bot.conversation.list", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "list general B read", method: "bot.conversation.list", bot: "B", context: "general", revision: 1, allowed: true),
            Row(name: "list workspace B no binding", method: "bot.conversation.list", bot: "B", context: "workspace", revision: 1, allowed: false),
            Row(name: "list stale revision", method: "bot.conversation.list", bot: "A", context: "general", revision: 9, allowed: false),
            Row(name: "select general A", method: "bot.conversation.select", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "select general B lacks send", method: "bot.conversation.select", bot: "B", context: "general", revision: 1, allowed: false),
            Row(name: "create workspace A", method: "bot.conversation.create", bot: "A", context: "workspace", revision: 1, allowed: true),
            Row(name: "create general B lacks send", method: "bot.conversation.create", bot: "B", context: "general", revision: 1, allowed: false),
            Row(name: "create stale revision", method: "bot.conversation.create", bot: "A", context: "general", revision: 7, allowed: false),
            Row(name: "enqueue general A", method: "bot.conversation.enqueue", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "enqueue workspace A", method: "bot.conversation.enqueue", bot: "A", context: "workspace", revision: 1, allowed: true),
            Row(name: "enqueue B lacks send", method: "bot.conversation.enqueue", bot: "B", context: "general", revision: 1, allowed: false),
            Row(name: "enqueue wrong context for conversation", method: "bot.conversation.enqueue", bot: "A", context: "workspace", revision: 1, allowed: false),
            Row(name: "export general A", method: "bot.conversation.export.preview", bot: "A", context: "general", revision: 1, allowed: true),
            Row(name: "export C has read and send but no export", method: "bot.conversation.export.preview", bot: "C", context: "general", revision: 1, allowed: false),
            Row(name: "export from workspace without export action", method: "bot.conversation.export.preview", bot: "A", context: "workspace", revision: 1, allowed: false),
            Row(name: "export stale revision", method: "bot.conversation.export.preview", bot: "A", context: "general", revision: 5, allowed: false),
        ]
        func run(_ row: Row, convoOverride: String? = nil) -> (allowed: Bool, code: Int?) {
            let bot = row.bot == "A" ? botA : (row.bot == "B" ? botB : botC)
            let key = row.context == "general" ? "general:v1" : workspaceKey
            var convo = row.context == "general" ? (row.bot == "C" ? generalC.id : generalA.id) : workspaceA.id
            if row.name == "enqueue wrong context for conversation" { convo = generalA.id }
            if let convoOverride { convo = convoOverride }
            do {
                _ = try authority.dispatch(method: row.method, params: params(row.method, bot: bot, key: key, revision: row.revision, convo: convo))
                return (true, nil)
            } catch let error as BotRemoteControlAuthority.Error {
                return (false, error.code)
            } catch { return (false, nil) }
        }
        for row in rows {
            let outcome = run(row)
            XCTAssertEqual(outcome.allowed, row.allowed, "\(row.name): expected \(row.allowed ? "allow" : "deny") (code \(String(describing: outcome.code)))")
        }

        // Entry points with no contextual contract must refuse a context instead of inferring a grant.
        for method in ["bot.send", "bot.routine.run", "bot.routine.create", "bot.files.list", "bot.conversation.fork", "bot.queue.force_now", "bot.guest.start"] {
            var p = params("bot.conversation.list", bot: botA, key: "general:v1", revision: 1, convo: generalA.id)
            p["client_request_id"] = UUID().uuidString
            p["text"] = "x"
            XCTAssertThrowsError(try authority.dispatch(method: method, params: p), "\(method) must not accept a contextual grant implicitly")
        }

        // Revocation flips every previously allowed row to deny.
        let current = try XCTUnwrap(try store.getContextBinding(hostID: host, botID: BotID(UUID(uuidString: botA)!), context: .general))
        _ = try store.revokeContext(hostID: host, botID: current.botID, context: .general, expectedRevision: current.policyRevision)
        for row in rows where row.allowed && row.bot == "A" && row.context == "general" {
            XCTAssertFalse(run(row).allowed, "\(row.name) must deny after revocation")
        }
        let workspaceStillAllowed = run(Row(name: "enqueue workspace A after general revoke", method: "bot.conversation.enqueue", bot: "A", context: "workspace", revision: 1, allowed: true))
        XCTAssertTrue(workspaceStillAllowed.allowed, "revoking general must not revoke the independent workspace binding")
    }
}
