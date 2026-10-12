import XCTest
import AgentRuntime
import CoreModel
@testable import AppShell
@testable import Persistence
@testable import Surfaces

@MainActor
final class LinkedBotVMAccessTests: XCTestCase {
    private func makeFixture() throws -> (AppContext, AppCommandRouter, AgentAppSurface, AgentThread, BotDefinition) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LinkedBotVM-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ctx = try AppContext(channel: .debug, appSupportOverride: root.appendingPathComponent("support").path)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let bot = try ctx.botStore.create(name: "Vera", title: "Scout", description: "", handle: "vera", soul: "soul")
        let workspace = try router.createWorkspace(name: "linked-vm", cwd: root.path)
        let thread = try router.createAgentThread(workspace: workspace.id, title: "Thread", provider: .codex, model: "fake-model", permissionMode: .supervised, reasoningEffort: .medium)
        let surface = AgentAppSurface(workspaceID: workspace.id, cwd: root.path, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, queuedMessageRepo: ctx.queuedMessageRepo, providerSessionRepo: ctx.providerSessionRuntimeRepo, checkpointRepo: ctx.turnCheckpointRepo, initialThreadId: thread.id)
        surface.viewModel.selectThread(thread.id)
        return (ctx, router, surface, thread, bot)
    }

    func test_linkedVMSelectedThreadNormalizesAndRejectsPermissionDowngrade() throws {
        let (ctx, _, surface, thread, bot) = try makeFixture()
        XCTAssertTrue(try ctx.threadRepo.setActor(id: thread.id, actor: .bot(bot.id), lockedAt: Date(), executionTarget: .vm))
        surface.viewModel.reloadThreads()
        surface.viewModel.selectThread(thread.id)
        XCTAssertEqual(surface.viewModel.permissionMode, .fullAccess)
        surface.viewModel.setPermissionMode(.supervised)
        XCTAssertEqual(surface.viewModel.permissionMode, .fullAccess)
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.permissionMode, .fullAccess)
    }

    func test_standaloneAndLocalThreadKeepPermissionChoice() throws {
        let (ctx, _, surface, thread, _) = try makeFixture()
        surface.viewModel.setPermissionMode(.supervised)
        XCTAssertEqual(surface.viewModel.permissionMode, .supervised)
        XCTAssertEqual(try ctx.threadRepo.get(id: thread.id)?.permissionMode, .supervised)
    }
}
