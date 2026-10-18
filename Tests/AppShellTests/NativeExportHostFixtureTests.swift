import AgentRuntime
import CoreModel
import Foundation
import Persistence
import XCTest
@testable import AppShell

@MainActor
final class NativeExportHostFixtureTests: XCTestCase {
    func testCreateOwnedNativeExportHostFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["RC_CONTEXT_NATIVE_EXPORT_HOST_ROOT"] else {
            throw XCTSkip("Set RC_CONTEXT_NATIVE_EXPORT_HOST_ROOT to create the owned native UI fixture.")
        }
        let parent = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"]), isDirectory: true).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        XCTAssertTrue(root.path.hasPrefix(parent.path + "/NativeExportHost-"))
        guard root.path.hasPrefix(parent.path + "/NativeExportHost-"), !FileManager.default.fileExists(atPath: root.path) else {
            return XCTFail("The export UI fixture requires a fresh invocation-owned root.")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let sourceSupport = root.appendingPathComponent("source-support", isDirectory: true)
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("source.sqlite").path,
            appSupportOverride: sourceSupport.path, privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: false, contextualSecretStore: InMemoryBotSecretStore())
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).update { $0.botsControlPlaneEnabled = true; $0.botsAutonomyEnabled = false }
        try context.settingsRepo.set("remote_access_enabled", "0")
        let workspaceRoot = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "Export Target", cwd: workspaceRoot.path)
        let host = context.liveActivityHostIdentity.serverId
        let bot = try context.botStore.create(name: "Export Review Bot", title: "Export Review", description: "", handle: "export-review", soul: "", provider: .distill, model: "unused")
        let sourceGrant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general, actions: [.read, .send, .export], expectedRevision: 0)
        let targetGrant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), actions: [.read, .send], expectedRevision: 0)
        var thread = AgentThread(title: "Review source", provider: .distill, model: "unused")
        thread.status = .completed
        let conversation = BotConversation(botID: bot.id, title: "Review source", linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(conversation, newThread: thread, hostID: host, context: .general, policyRevision: sourceGrant.policyRevision)
        let first = AgentMessage(threadId: thread.id, role: .user, content: "First reviewed native export excerpt")
        let second = AgentMessage(threadId: thread.id, role: .assistant, content: "Second native excerpt remains unselected")
        try context.messageRepo.append(first)
        try context.messageRepo.append(second)
        let authority = try XCTUnwrap(router.botRoutineAuthority)
        _ = try authority.dispatch(method: "bot.conversation.select", params: ["client_request_id": "owned-export-select", "host_id": host,
            "bot_id": bot.id.value.uuidString.lowercased(), "conversation_id": conversation.id.value.uuidString.lowercased(),
            "context_key": "general:v1", "context_version": 1, "policy_revision": sourceGrant.policyRevision])
        context.saveSnapshot()
        let support = root.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let snapshot = support.appendingPathComponent("remotecode.sqlite")
        let escaped = snapshot.path.replacingOccurrences(of: "'", with: "''")
        try context.db.execute("VACUUM INTO '\(escaped)';")
        let metadata: [String: String] = ["host_id": host, "bot_id": bot.id.value.uuidString.lowercased(),
            "conversation_id": conversation.id.value.uuidString.lowercased(), "thread_id": thread.id.value.uuidString.lowercased(),
            "first_message_id": first.id.value.uuidString.lowercased(), "second_message_id": second.id.value.uuidString.lowercased(),
            "target_context_key": BotContext.workspace(workspace.id).storageKey,
            "target_policy_revision": String(targetGrant.policyRevision)]
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent("fixture.json"), options: .atomic)
        XCTAssertEqual(try context.messageRepo.list(threadId: thread.id).count, 2)
        print("Owned native export fixture created.")
    }
}
