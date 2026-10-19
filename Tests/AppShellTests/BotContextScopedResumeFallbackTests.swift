import AgentRuntime
import CoreModel
import Foundation
import Persistence
import SocketServer
import XCTest
@testable import AppShell

@MainActor
final class BotContextScopedResumeFallbackTests: XCTestCase {
    func testRetiredScopedHistoryRefusesSessionReplacementBeforeGuestPreparation() async throws {
        let scratch = try XCTUnwrap(ProcessInfo.processInfo.environment["RC_CONTEXT_PROBE_ROOT"])
        let root = URL(fileURLWithPath: scratch).appendingPathComponent("ScopedFallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let support = root.appendingPathComponent("support")
        let context = try AppContext(channel: .debug, dbPathOverride: root.appendingPathComponent("probe.sqlite").path,
            appSupportOverride: support.path, privateAccountAPI: SilentWakeRecordingAPI(),
            performLaunchRunReconciliation: false, contextualSecretStore: InMemoryBotSecretStore())
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspacePath = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspacePath, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "Scoped fallback refusal", cwd: workspacePath.path)
        let model = "openrouter/provider/model"
        let bot = try context.botStore.create(name: "Scoped fallback", title: "Scoped fallback", description: "", handle: "scoped-fallback", soul: "", provider: .distill, model: model)
        let grant = try context.botStore.grantContext(hostID: context.liveActivityHostIdentity.serverId, botID: bot.id,
            context: .workspace(workspace.id), actions: [.read, .send, .configure, .files], expectedRevision: 0)
        let thread = AgentThread(workspaceId: workspace.id, title: "Retired scoped history", provider: .distill, model: model)
        _ = try context.botStore.createContextualConversation(BotConversation(botID: bot.id, title: thread.title,
            linkedAgentThreadID: thread.id), newThread: thread, hostID: grant.hostID,
            context: grant.context, policyRevision: grant.policyRevision)
        let resolver = try XCTUnwrap(context.botGuestRunResolver)
        XCTAssertFalse(resolver.preservesSessionIdentity(thread.id), "a pinned thread without an isolated admission runs like a normal bot thread")
        let pin = try XCTUnwrap(context.botStore.conversationContextPin(linkedTo: thread.id))
        try context.contextualRunAdmissions.register(.init(runID: AgentRunID(), threadID: thread.id, pin: pin,
            parentRunID: nil, model: model, cwd: workspace.cwd, permit: AgentRunAcceptancePermit(),
            providerConfiguration: "", validates: { true }))
        XCTAssertTrue(resolver.preservesSessionIdentity(thread.id))
        let adapter = DistillACPAdapter()
        adapter.setGuestLaunchResolver(resolver)
        var request = AgentRunRequest(threadId: thread.id, provider: .distill, model: model, cwd: workspace.cwd,
            prompt: "must not replace scoped history", providerThreadId: "owned-retired-session")
        request.priorProviderSessionRetired = true
        do {
            _ = try await adapter.sendTurn(request) { _ in }
            XCTFail("Retired contextual history must not trigger session/new")
        } catch let error as DistillGuestLaunchError {
            XCTAssertEqual(error, .unavailable("Scoped Distill sessions cannot be replaced with a fresh session."))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: BotComputerGuestSpec.guestHomeRoot(appSupport: support).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("bot-context-sessions").path))
        XCTAssertTrue(try context.botStore.contextDelegations().isEmpty)
    }
}
