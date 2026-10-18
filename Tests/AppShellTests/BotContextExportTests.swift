import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class BotContextExportTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let context: AppContext
        let router: AppCommandRouter
        let dispatcher: JSONRPCDispatcher
        let host: String
        let bot: BotDefinition
        let source: BotConversation
        let target: BotConversation
        let targetContext: BotContext
        let selected: AgentMessage
        let foreign: AgentMessage
        let system: AgentMessage
        let params: [String: JSONValue]
        var principal: MutationRequestContext { .init(ownerFingerprint: "export-owner", hostId: host, bootEpoch: 1) }
    }

    private func fixture(actions: Set<BotContextAction> = [.read, .send, .export]) throws -> Fixture {
        let parent = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true)
        let root = parent.appendingPathComponent("ContextExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var ready = false
        defer { if !ready { try? FileManager.default.removeItem(at: root) } }
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("owned.sqlite").path,
            appSupportOverride: root.appendingPathComponent("support").path, privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: false, contextualSecretStore: InMemoryBotSecretStore())
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true }
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "Export target", cwd: workspaceRoot.path)
        let targetContext = BotContext.workspace(workspace.id)
        let bot = try context.botStore.create(name: "Export", title: "Export", description: "", soul: "", provider: .distill, model: "unused")
        let host = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general, actions: actions, expectedRevision: 0)
        let targetGrant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: targetContext, actions: [.read, .send], expectedRevision: 0)
        let sourceThread = AgentThread(title: "Source", provider: .distill, model: "unused")
        let source = BotConversation(botID: bot.id, title: "Source", linkedAgentThreadID: sourceThread.id)
        try context.botStore.createContextualConversation(source, newThread: sourceThread, hostID: host, context: .general, policyRevision: grant.policyRevision)
        let targetThread = AgentThread(workspaceId: workspace.id, title: "Target", provider: .distill, model: "unused")
        let target = BotConversation(botID: bot.id, title: "Target", linkedAgentThreadID: targetThread.id)
        try context.botStore.createContextualConversation(target, newThread: targetThread, hostID: host, context: targetContext, policyRevision: targetGrant.policyRevision)
        let attachment = AgentAttachment(path: "/nonexistent/private-attachment-marker", displayName: "private-attachment-marker", kind: .file)
        let selected = AgentMessage(threadId: sourceThread.id, role: .assistant, content: "approved-source-excerpt", attachments: [attachment])
        let foreign = AgentMessage(threadId: targetThread.id, role: .assistant, content: "foreign-context-secret")
        let system = AgentMessage(threadId: sourceThread.id, role: .system, content: "system-private-marker")
        for message in [selected, foreign, system, AgentMessage(threadId: sourceThread.id, role: .user, content: "unselected-source-secret")] {
            try context.messageRepo.append(message)
        }
        let params: [String: JSONValue] = [
            "host_id": .string("forged-host"), "bot_id": .string(bot.id.value.uuidString.lowercased()),
            "context_key": .string("general:v1"), "context_version": .number(1), "policy_revision": .number(Double(grant.policyRevision)),
            "conversation_id": .string(source.id.value.uuidString.lowercased()), "target_context_key": .string(targetContext.storageKey),
            "target_policy_revision": .number(Double(targetGrant.policyRevision)),
            "message_ids": .array([.string(selected.id.value.uuidString.lowercased())]),
        ]
        ready = true
        return Fixture(root: root, context: context, router: router, dispatcher: JSONRPCDispatcher(router: router),
            host: host, bot: bot, source: source, target: target, targetContext: targetContext,
            selected: selected, foreign: foreign, system: system, params: params)
    }

    private func request(_ method: String, _ params: [String: JSONValue]) throws -> JSONRPCRequest {
        let body = JSONValue.object(["jsonrpc": .string("2.0"), "id": .string("export-action"), "method": .string(method), "params": .object(params)])
        return try JSONDecoder().decode(JSONRPCRequest.self, from: JSONEncoder().encode(body))
    }

    private func invoke(_ f: Fixture, method: String = "bot.conversation.export.preview", params: [String: JSONValue]? = nil) async throws -> JSONRPCResponse {
        await f.dispatcher.dispatchHTTP(try request(method, params ?? f.params), mutationContext: f.principal)
    }

    private func assertDenied(_ response: JSONRPCResponse, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNotNil(response.error, file: file, line: line)
        XCTAssertNil(response.result, file: file, line: line)
        XCTAssertFalse(response.error?.message.contains("secret") == true, file: file, line: line)
    }

    private func count(_ f: Fixture, _ table: String) throws -> Int64 {
        let query = try f.context.db.prepare("SELECT COUNT(*) FROM \(table);")
        defer { query.reset() }
        XCTAssertTrue(try query.step())
        return query.columnInt64(0)
    }

    func testRealHTTPExportsOnlyReviewedSelectionAndRevocationCannotReplayContent() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let auth = ContextExportAuth()
        defer { withExtendedLifetime(auth) {} }
        var listener: DirectHTTPServer?
        var port: UInt16 = 0
        for _ in 0..<10 where listener == nil {
            port = UInt16.random(in: 33000...44000)
            let candidate = DirectHTTPServer(port: port, loopbackOnly: true, dispatcher: f.dispatcher, auth: auth, serverId: f.host, bootEpoch: 1)
            do { try candidate.start(); listener = candidate }
            catch let error as POSIXError where error.code == .EADDRINUSE { candidate.stop() }
        }
        let server = try XCTUnwrap(listener)
        defer { server.stop() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let endpoint = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/rpc"))
        func post(_ method: String, _ params: [String: JSONValue], bearer: String? = "owned-export-bearer") async throws -> JSONRPCResponse {
            var http = URLRequest(url: endpoint)
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let bearer { http.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            http.httpBody = try JSONEncoder().encode(request(method, params))
            let (data, response) = try await session.data(for: http)
            let headers = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(headers.statusCode, 200)
            XCTAssertEqual(headers.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            return try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        }
        let beforeThreads = try count(f, "agent_threads")
        let beforeMessages = try count(f, "agent_messages")
        let beforeReceipts = try count(f, "command_receipts")
        for bearer: String? in [nil, "invalid-export-bearer"] {
            let denied = try await post("bot.conversation.export.preview", f.params, bearer: bearer)
            XCTAssertEqual(denied.error?.code, -32098)
            XCTAssertNil(denied.result)
        }
        let preview = try await post("bot.conversation.export.preview", f.params)
        XCTAssertNil(preview.error)
        let result = try XCTUnwrap(preview.result?.objectValue)
        XCTAssertEqual(result["summary"]?.stringValue, "assistant:\napproved-source-excerpt")
        XCTAssertEqual(result["host_id"]?.stringValue, f.host)
        XCTAssertEqual(result["target_context_key"]?.stringValue, f.targetContext.storageKey)
        XCTAssertEqual(result["exported"]?.boolValue, false)
        let digest = try XCTUnwrap(result["selection_sha256"]?.stringValue)
        var approved = f.params
        approved["approved"] = .bool(true)
        approved["selection_sha256"] = .string(digest)
        for (method, params) in [("bot.conversation.export.preview", f.params), ("bot.conversation.export", approved)] {
            let writeOnly = try await post(method, params, bearer: "write-only-export-bearer")
            XCTAssertEqual(writeOnly.error?.code, -32003)
            XCTAssertNil(writeOnly.result)
        }
        func exportReceipts() throws -> [String] {
            let st = try f.context.db.prepare("SELECT detail FROM audit_log WHERE action='bot.context.export' ORDER BY id;")
            defer { st.reset() }
            var rows: [String] = []
            while try st.step() { rows.append(st.columnText(0) ?? "") }
            return rows
        }
        XCTAssertEqual(try exportReceipts(), [], "preview, unauthenticated and write-only calls must not write an export receipt")
        let exported = try await post("bot.conversation.export", approved)
        XCTAssertNil(exported.error)
        let receipts = try exportReceipts()
        XCTAssertEqual(receipts.count, 1, "one confirmed export writes exactly one durable receipt")
        XCTAssertTrue(receipts[0].contains(digest), "receipt binds the reviewed selection digest")
        XCTAssertFalse(receipts[0].contains("approved-source-excerpt"), "receipt must never carry message text")
        XCTAssertEqual(exported.result?.objectValue?["exported"]?.boolValue, true)
        XCTAssertEqual(exported.result?.objectValue?["summary"], result["summary"])
        let encoded = String(decoding: try JSONEncoder().encode(exported), as: UTF8.self)
        for forbidden in ["foreign-context-secret", "unselected-source-secret", "system-private-marker", "private-attachment-marker", "attachments"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
        _ = try f.context.botStore.revokeContext(hostID: f.host, botID: f.bot.id, context: .general, expectedRevision: 1)
        for _ in 0..<2 { assertDenied(try await post("bot.conversation.export", approved)) }
        XCTAssertEqual(try exportReceipts().count, 1, "denied exports leave no receipt")
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: f.bot.id, context: .general, actions: [.read, .send, .export], expectedRevision: 2)
        assertDenied(try await post("bot.conversation.export", approved))
        XCTAssertEqual(try count(f, "command_receipts"), beforeReceipts, "private export content must never enter mutation replay receipts")
        XCTAssertEqual(try count(f, "agent_threads"), beforeThreads)
        XCTAssertEqual(try count(f, "agent_messages"), beforeMessages)
        XCTAssertEqual(try count(f, "agent_runs"), 0)
        XCTAssertEqual(try count(f, "agent_queued_messages"), 0)
    }

    func testGuessedResourcesForeignSelectionAndChangedApprovalDiscloseNothing() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let preview = try await invoke(f)
        let digest = try XCTUnwrap(preview.result?.objectValue?["selection_sha256"]?.stringValue)
        var approved = f.params
        approved["approved"] = .bool(true)
        approved["selection_sha256"] = .string(digest)
        for field in ["bot_id", "conversation_id", "target_context_key"] {
            var guessed = f.params
            guessed[field] = .string(field == "target_context_key" ? "workspace:v1:\(UUID().uuidString.lowercased())" : UUID().uuidString.lowercased())
            assertDenied(try await invoke(f, params: guessed))
        }
        for id in [f.foreign.id.value, f.system.id.value, UUID()] {
            var other = f.params
            other["message_ids"] = .array([.string(id.uuidString.lowercased())])
            assertDenied(try await invoke(f, params: other))
        }
        var targetChanged = approved
        targetChanged["target_context_key"] = .string("general:v1")
        assertDenied(try await invoke(f, method: "bot.conversation.export", params: targetChanged))
        var otherConversation = f.params
        otherConversation["conversation_id"] = .string(f.target.id.value.uuidString.lowercased())
        assertDenied(try await invoke(f, params: otherConversation))
        for approval in [JSONValue.bool(false), .number(1)] {
            var invalidApproval = approved
            invalidApproval["approved"] = approval
            assertDenied(try await invoke(f, method: "bot.conversation.export", params: invalidApproval))
        }
        var missingApproval = approved
        missingApproval.removeValue(forKey: "selection_sha256")
        assertDenied(try await invoke(f, method: "bot.conversation.export", params: missingApproval))
        var edited = f.selected
        edited.content = "changed-after-review"
        try f.context.messageRepo.append(edited)
        assertDenied(try await invoke(f, method: "bot.conversation.export", params: approved))
        let unix = await f.dispatcher.dispatchUnixSocket(try request("bot.conversation.export", approved))
        XCTAssertEqual(unix.error?.code, -32098)
        let unauthenticated = await f.dispatcher.dispatchHTTP(try request("bot.conversation.export.preview", f.params), mutationContext: nil)
        assertDenied(unauthenticated)
        XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod("bot.conversation.export"))
        XCTAssertEqual(try count(f, "agent_runs"), 0)
    }

    func testExplicitPermissionsTargetRevocationAndSelectionBoundsAreRequired() async throws {
        let missingExport = try fixture(actions: [.read, .send])
        defer { try? FileManager.default.removeItem(at: missingExport.root) }
        assertDenied(try await invoke(missingExport))
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let preview = try await invoke(f)
        let digest = try XCTUnwrap(preview.result?.objectValue?["selection_sha256"]?.stringValue)
        var approved = f.params
        approved["approved"] = .bool(true)
        approved["selection_sha256"] = .string(digest)
        _ = try f.context.botStore.revokeContext(hostID: f.host, botID: f.bot.id, context: f.targetContext, expectedRevision: 1)
        assertDenied(try await invoke(f, method: "bot.conversation.export", params: approved))
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: f.bot.id, context: f.targetContext, actions: [.read], expectedRevision: 2)
        var noSend = f.params
        noSend["target_policy_revision"] = .number(3)
        assertDenied(try await invoke(f, params: noSend))
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: f.bot.id, context: f.targetContext, actions: [.read, .send], expectedRevision: 3)
        var current = f.params
        current["target_policy_revision"] = .number(4)
        for values: [JSONValue] in [[], [.string(f.selected.id.value.uuidString), .string(f.selected.id.value.uuidString.lowercased())]] {
            var invalid = current
            invalid["message_ids"] = .array(values)
            assertDenied(try await invoke(f, params: invalid))
        }
        var selectedIDs: [JSONValue] = []
        for _ in 0..<33 {
            let message = AgentMessage(threadId: f.selected.threadId, role: .assistant, content: "bounded excerpt")
            try f.context.messageRepo.append(message)
            selectedIDs.append(.string(message.id.value.uuidString.lowercased()))
        }
        var many = current
        many["message_ids"] = .array(Array(selectedIDs.prefix(32)))
        let maximumSelection = try await invoke(f, params: many)
        XCTAssertNil(maximumSelection.error)
        many["message_ids"] = .array(selectedIDs)
        assertDenied(try await invoke(f, params: many))
        var oversized = f.selected
        oversized.content = String(repeating: "x", count: 65_536)
        try f.context.messageRepo.append(oversized)
        let maximumText = try await invoke(f, params: current)
        XCTAssertNil(maximumText.error)
        oversized.content = String(repeating: "x", count: 65_537)
        try f.context.messageRepo.append(oversized)
        assertDenied(try await invoke(f, params: current))
        oversized.content = "valid selection"
        try f.context.messageRepo.append(oversized)
        let validAgain = try await invoke(f, params: current)
        XCTAssertNil(validAgain.error)
        SettingsStore(db: f.context.db).update { $0.botsControlPlaneEnabled = false }
        assertDenied(try await invoke(f, params: current))
    }
}

private final class ContextExportAuth: DirectAuthProvider {
    func verify(token: String) -> Bool { ["owned-export-bearer", "write-only-export-bearer"].contains(token) }
    func authorizedRPCPrincipal(token: String) -> DirectRPCPrincipal? {
        guard verify(token: token) else { return nil }
        return DirectRPCPrincipal(ownerFingerprint: "export-owner", grantedCapabilities: token == "owned-export-bearer" ? "read" : "write")
    }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}
