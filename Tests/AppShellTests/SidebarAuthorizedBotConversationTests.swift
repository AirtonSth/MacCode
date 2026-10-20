import XCTest
import AgentRuntime
@testable import AppShell
@testable import CoreModel
import Persistence

@MainActor
final class SidebarAuthorizedBotConversationTests: XCTestCase {
    private func make(operationErrorPresenter: @escaping SidebarViewModel.OperationErrorPresenter = { _, _ in }) throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let directory = NSTemporaryDirectory() + "RC2SidebarBotGroups-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router, SidebarViewModel(context: context, router: router, operationErrorPresenter: operationErrorPresenter))
    }

    /// Clicking a busy Bot must reopen its live run, not spawn a duplicate; another context's run is never reused.
    func test_runningConversationReusesOnlyLiveSameContextRun() {
        let bot = BotID()
        let workspaceContext = BotContext.workspace(WorkspaceID())
        let liveThread = AgentThreadID()
        let foreignThread = AgentThreadID()
        let idleThread = AgentThreadID()
        let foreign = BotConversation(botID: bot, title: "Foreign", linkedAgentThreadID: foreignThread)
        let idle = BotConversation(botID: bot, title: "Idle", linkedAgentThreadID: idleThread)
        let running = BotConversation(botID: bot, title: "Running", linkedAgentThreadID: liveThread)
        let pins: [BotConversationID: BotContext] = [foreign.id: .general, running.id: workspaceContext]
        let live: Set<AgentThreadID> = [liveThread, foreignThread]

        XCTAssertEqual(
            SidebarViewModel.runningConversation([idle, running], live: live, pinContext: { pins[$0] }, context: workspaceContext)?.id,
            running.id, "a live run pinned to the same context is reopened")
        XCTAssertEqual(
            SidebarViewModel.runningConversation([foreign, idle], live: live, pinContext: { pins[$0] }, context: workspaceContext),
            nil, "a live run pinned to another context is never reused")
        XCTAssertNil(
            SidebarViewModel.runningConversation([idle], live: live, pinContext: { pins[$0] }, context: workspaceContext),
            "with nothing running a new conversation is started")
    }

    func test_projectionRequiresExplicitCurrentHostReadBindingAndGroupsExistingExactConversation() async throws {
        let (context, router, viewModel) = try make()
        let workspace = try router.createWorkspace(name: "Grouped workspace", cwd: NSTemporaryDirectory())
        let linked = try context.botStore.create(name: "Linked", title: "", description: "", handle: "linked", workspaceID: workspace.id)
        let implicit = try context.botStore.create(name: "Implicit", title: "", description: "", handle: "implicit", workspaceID: workspace.id)
        let sendOnly = try context.botStore.create(name: "Send only", title: "", description: "", handle: "send-only")
        let host = context.liveActivityHostIdentity.serverId
        let binding = try context.botStore.grantContext(hostID: host, botID: linked.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        let generalBinding = try context.botStore.grantContext(hostID: host, botID: linked.id, context: .general, actions: [.read], expectedRevision: 0)
        _ = try context.botStore.grantContext(hostID: host, botID: sendOnly.id, context: .general, actions: [.send], expectedRevision: 0)
        var thread = AgentThread(workspaceId: workspace.id, title: "Exact title", provider: .distill, model: "fixture")
        thread.status = .completed
        let conversation = BotConversation(botID: linked.id, title: "Exact title", linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(conversation, newThread: thread, hostID: host, context: .workspace(workspace.id), policyRevision: binding.policyRevision)
        var generalThread = AgentThread(title: "General title", provider: .distill, model: "fixture")
        generalThread.status = .completed
        let generalConversation = BotConversation(botID: linked.id, title: "General title", linkedAgentThreadID: generalThread.id)
        try context.botStore.createContextualConversation(generalConversation, newThread: generalThread, hostID: host, context: .general, policyRevision: generalBinding.policyRevision)

        await viewModel.reloadAuthorizedBotConversationRowsAndWait()

        XCTAssertEqual(viewModel.authorizedBotConversationRows.count, 2)
        let row = try XCTUnwrap(viewModel.authorizedBotConversationRows.first(where: { $0.context == .workspace(workspace.id) }))
        XCTAssertEqual(row.botID, linked.id)
        XCTAssertEqual(row.conversationID, conversation.id)
        XCTAssertEqual(row.title, "Exact title")
        XCTAssertEqual(Set(viewModel.authorizedBotConversationRows.map(\.context)), [.general, .workspace(workspace.id)], "one Bot may appear under each explicitly authorized context")
        XCTAssertEqual(try AppCommandRouter.contextPinnedThreadDestination(thread.id, context: context), .bot(linked.id, conversation.id), "the row must resolve to its exact pinned Bot conversation")
        let botsViewModel = BotsViewModel(context: context, router: router)
        router.botsViewModel = botsViewModel
        // Bot rows, General or workspace, open the Bots Desk (workspace row: SidebarUnifiedNavigationTests).
        let generalRow = try XCTUnwrap(viewModel.authorizedBotConversationRows.first(where: { $0.context == .general }))
        viewModel.openAuthorizedBotConversation(generalRow)
        XCTAssertEqual(botsViewModel.selectedBotID, linked.id)
        XCTAssertEqual(botsViewModel.selectedConversation?.id, generalRow.conversationID)
        XCTAssertEqual(botsViewModel.selectedPinnedContextLabel, "General")
        XCTAssertFalse(viewModel.authorizedBotConversationRows.contains(where: { $0.botID == implicit.id || $0.botID == sendOnly.id }), "legacy workspace metadata and send-only grants must not authorize sidebar links")
    }

    func test_authorizedBindingWithoutConversationIsDisabledProjectionAndRevocationRemovesIt() async throws {
        var presentedErrors: [(String, String)] = []
        let (context, router, viewModel) = try make { presentedErrors.append(($0, $1)) }
        let bot = try context.botStore.create(name: "Empty", title: "", description: "", handle: "empty")
        let host = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .general, actions: [.read], expectedRevision: 0)

        await viewModel.reloadAuthorizedBotConversationRowsAndWait()
        let row = try XCTUnwrap(viewModel.authorizedBotConversationRows.first)
        XCTAssertNil(row.conversationID)
        XCTAssertEqual(row.title, "No conversations")
        viewModel.openAuthorizedBotConversation(row)
        XCTAssertFalse(viewModel.isBotsSelected, "empty binding must not open Bot detail or switch context")

        _ = try context.botStore.revokeContext(hostID: host, botID: bot.id, context: .general, expectedRevision: grant.policyRevision)
        viewModel.openAuthorizedBotConversation(row)
        XCTAssertEqual(presentedErrors.count, 0, "empty row must not attempt navigation")
        XCTAssertEqual(viewModel.authorizedBotConversationRows, [row], "stale projection remains visually in place until refresh")
        await viewModel.reloadAuthorizedBotConversationRowsAndWait()
        XCTAssertTrue(viewModel.authorizedBotConversationRows.isEmpty, "revoked authority must disappear on refresh")
        _ = router
    }

    func test_supersededProjectionNeverPublishesAfterQueuedRevocationRefresh() async throws {
        let (context, router, viewModel) = try make()
        let workspace = try router.createWorkspace(name: "Queued refresh", cwd: "/tmp/queued-refresh")
        let bot = try context.botStore.create(name: "Queued", title: "", description: "", handle: "queued")
        let host = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        var thread = AgentThread(workspaceId: workspace.id, title: "Existing", provider: .distill, model: "fixture")
        thread.status = .completed
        let conversation = BotConversation(botID: bot.id, title: "Existing", linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(conversation, newThread: thread, hostID: host, context: .workspace(workspace.id), policyRevision: grant.policyRevision)

        let firstLoaded = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondLoaded = DispatchSemaphore(value: 0)
        let releaseSecond = DispatchSemaphore(value: 0)
        let invocationLock = NSLock()
        var invocationCount = 0
        viewModel.authorizedBotRowsLoaderForTesting = { store, threads, hostID, workspaceIDs in
            let result = SidebarViewModel.loadAuthorizedBotConversationRows(botStore: store, threadRepo: threads, hostID: hostID, workspaceIDs: workspaceIDs)
            invocationLock.lock()
            invocationCount += 1
            let invocation = invocationCount
            invocationLock.unlock()
            if invocation == 1 {
                firstLoaded.signal()
                releaseFirst.wait()
            } else if invocation == 2 {
                secondLoaded.signal()
                releaseSecond.wait()
            }
            return result
        }
        viewModel.reload()
        let firstWait = await Task.detached { firstLoaded.wait(timeout: .now() + 5) }.value
        XCTAssertEqual(firstWait, .success)
        _ = try context.botStore.revokeContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), expectedRevision: grant.policyRevision)
        viewModel.reload()
        releaseFirst.signal()
        let secondWait = await Task.detached { secondLoaded.wait(timeout: .now() + 5) }.value
        XCTAssertEqual(secondWait, .success)
        XCTAssertTrue(viewModel.authorizedBotConversationRows.isEmpty, "superseded first result must not publish while newer authorized projection is held")
        releaseSecond.signal()
        await viewModel.reloadAuthorizedBotConversationRowsAndWait()
        XCTAssertTrue(viewModel.authorizedBotConversationRows.isEmpty)
    }

    func test_revokedExistingConversationFailsVisiblyWithoutRemovingStaleRowImmediately() async throws {
        var presentedErrors: [(String, String)] = []
        let (context, router, viewModel) = try make { presentedErrors.append(($0, $1)) }
        let workspace = try router.createWorkspace(name: "Visible revoke", cwd: NSTemporaryDirectory())
        let bot = try context.botStore.create(name: "Revocable", title: "", description: "", handle: "revocable")
        let host = context.liveActivityHostIdentity.serverId
        let grant = try context.botStore.grantContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        var thread = AgentThread(workspaceId: workspace.id, title: "Existing", provider: .distill, model: "fixture")
        thread.status = .completed
        let conversation = BotConversation(botID: bot.id, title: "Existing", linkedAgentThreadID: thread.id)
        try context.botStore.createContextualConversation(conversation, newThread: thread, hostID: host, context: .workspace(workspace.id), policyRevision: grant.policyRevision)
        await viewModel.reloadAuthorizedBotConversationRowsAndWait()
        let row = try XCTUnwrap(viewModel.authorizedBotConversationRows.first)
        XCTAssertEqual(row.context, .workspace(workspace.id))
        XCTAssertEqual(row.conversationID, conversation.id)

        _ = try context.botStore.revokeContext(hostID: host, botID: bot.id, context: .workspace(workspace.id), expectedRevision: grant.policyRevision)
        viewModel.openAuthorizedBotConversation(row)

        XCTAssertEqual(presentedErrors.count, 1, "tap must report revoked authority in place")
        XCTAssertEqual(viewModel.authorizedBotConversationRows, [row], "tap failure must not remove or repoint the visible row")
        await viewModel.reloadAuthorizedBotConversationRowsAndWait()
        XCTAssertTrue(viewModel.authorizedBotConversationRows.isEmpty)
    }
}
