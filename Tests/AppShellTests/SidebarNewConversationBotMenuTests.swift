import XCTest
import AgentRuntime
@testable import AppShell
@testable import CoreModel
import Persistence

@MainActor
final class SidebarNewConversationBotMenuTests: XCTestCase {
    /// Picking a Bot from the "New conversation" menu must start a fresh conversation even while
    /// that Bot has a live run; the plain Bot row keeps reopening the live run.
    func test_menuBotStartsNewConversationWhileRowReusesLiveRun() async throws {
        let directory = NSTemporaryDirectory() + "RC2SidebarNewConversationBot-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = SidebarViewModel(context: context, router: router)
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        defer {
            controller.window.close()
            try? FileManager.default.removeItem(atPath: directory)
        }
        let host = context.liveActivityHostIdentity.serverId
        let workspace = try router.createWorkspace(name: "Menu", cwd: NSTemporaryDirectory())
        let bot = try context.botStore.create(name: "Piper", title: "", description: "", provider: .distill)
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), actions: [.read, .send], expectedRevision: 0)
        var liveThread = AgentThread(workspaceId: workspace.id, title: "Live", provider: .distill, model: "fixture")
        liveThread.status = .running
        let live = BotConversation(botID: bot.id, title: "Live", linkedAgentThreadID: liveThread.id)
        _ = try context.botStore.createContextualConversation(live, newThread: liveThread, hostID: host, context: .workspace(workspace.id), policyRevision: grant.policyRevision)
        context.coordinator.bindActiveThreadForTesting(threadId: liveThread.id, runId: AgentRunID())

        if !vm.expandedWorkspaceIDs.contains(workspace.id) { vm.toggleWorkspaceExpanded(workspace.id) }
        vm.reload()
        await vm.reloadAuthorizedBotConversationRowsAndWait()
        let row = try XCTUnwrap(vm.workspaceBotRows(workspace.id).first)
        XCTAssertEqual(row.conversationID, live.id, "the Bot row targets the live conversation")

        vm.startBotConversation(row)
        XCTAssertEqual(controller.sidebarBotsViewModelForTesting.selectedConversation?.id, live.id,
                       "the plain Bot row reopens the live run instead of spawning a duplicate")

        vm.startNewBotConversation(row)
        let fresh = try XCTUnwrap(controller.sidebarBotsViewModelForTesting.selectedConversation)
        XCTAssertNotEqual(fresh.id, live.id, "the menu starts a new conversation even though the Bot is busy")
        XCTAssertEqual(vm.newBotConversationThreadID, fresh.linkedAgentThreadID, "the new draft owns selection")
    }
}
