import XCTest
import AppKit
import SwiftUI
import AgentRuntime
@testable import AppShell
@testable import CoreModel
import Persistence
import Surfaces
import SocketServer

/// The single Mac sidebar from plan/02-experiencia.html: top items, General Bots with Titio first,
/// a searchable Workspaces tree whose rows expand into linked Bots and Conversations, and a
/// "Manage Bots and Teams" footer. These drive the shipped model, view and router.
@MainActor
final class SidebarUnifiedNavigationTests: XCTestCase {
    private struct Fixture {
        let directory: String
        let context: AppContext
        let router: AppCommandRouter
        let vm: SidebarViewModel
        let host: String
    }

    private func make(_ name: String) throws -> Fixture {
        let directory = NSTemporaryDirectory() + "RC2SidebarUnified-\(name)-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = SidebarViewModel(context: context, router: router)
        return Fixture(directory: directory, context: context, router: router, vm: vm, host: context.liveActivityHostIdentity.serverId)
    }

    private func expand(_ vm: SidebarViewModel, _ id: WorkspaceID) async {
        if !vm.expandedWorkspaceIDs.contains(id) { vm.toggleWorkspaceExpanded(id) }
        await vm.reloadAuthorizedBotConversationRowsAndWait()
    }

    func test_generalBotsPutTitioFirstAndKeepWorkspaceOnlyBotsInTheirWorkspace() async throws {
        let f = try make("general")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let workspace = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let researcher = try f.context.botStore.create(name: "Researcher", title: "", description: "", handle: "researcher")
        let developer = try f.context.botStore.create(name: "Developer", title: "", description: "", handle: "developer")
        let reviewer = try f.context.botStore.create(name: "Reviewer", title: "", description: "", handle: "reviewer")
        let titio = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: developer.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: reviewer.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: reviewer.id, context: .general, actions: [.read], expectedRevision: 0)

        f.vm.reload()
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()

        XCTAssertEqual(f.vm.generalBots.first?.botID, titio.id, "Titio is pinned first in General Bots")
        let general = Set(f.vm.generalBots.map(\.botID))
        XCTAssertTrue(general.contains(researcher.id), "a never-bound catalog Bot is a general Bot")
        XCTAssertTrue(general.contains(reviewer.id), "a Bot with a General grant stays general even when also linked")
        XCTAssertFalse(general.contains(developer.id), "a workspace-only Bot lives under its workspace, not General")

        let revokedOnly = try f.context.botStore.create(name: "Revoked", title: "", description: "", handle: "revoked")
        let grant = try f.context.botStore.grantContext(hostID: f.host, botID: revokedOnly.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        _ = try f.context.botStore.revokeContext(hostID: f.host, botID: revokedOnly.id, context: .workspace(workspace.id), expectedRevision: grant.policyRevision)
        let sendOnly = try f.context.botStore.create(name: "Send only", title: "", description: "", handle: "send-only")
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: sendOnly.id, context: .general, actions: [.send], expectedRevision: 0)
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()
        let after = Set(f.vm.generalBots.map(\.botID))
        XCTAssertFalse(after.contains(revokedOnly.id), "revoking a workspace grant must not relocate the Bot into General")
        XCTAssertFalse(after.contains(sendOnly.id), "a General grant without read is not a General Bot row")
    }

    func test_conversationsHideRevokedAndForeignPinnedBotThreadsButKeepPlainWork() async throws {
        let f = try make("conversation-authority")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let workspace = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let plain = try f.router.createAgentThread(workspace: workspace.id, title: "Plain", provider: .codex, model: "fake", permissionMode: .supervised, reasoningEffort: .medium)
        let bot = try f.context.botStore.create(name: "Piper", title: "", description: "", provider: .distill)
        let grant = try f.context.botStore.grantContext(hostID: f.host, botID: bot.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        var thread = AgentThread(workspaceId: workspace.id, title: "Secret Bot title", provider: .distill, model: "fixture")
        thread.status = .completed
        try f.context.botStore.createContextualConversation(BotConversation(botID: bot.id, title: "Secret Bot title", linkedAgentThreadID: thread.id),
            newThread: thread, hostID: f.host, context: .workspace(workspace.id), policyRevision: grant.policyRevision)
        f.vm.reload()
        await expand(f.vm, workspace.id)
        XCTAssertEqual(Set(f.vm.workspaceConversationRows(workspace.id).map(\.threadID)), [plain.id, thread.id])

        _ = try f.context.botStore.revokeContext(hostID: f.host, botID: bot.id, context: .workspace(workspace.id), expectedRevision: grant.policyRevision)
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()
        XCTAssertEqual(f.vm.workspaceConversationRows(workspace.id).map(\.threadID), [plain.id],
                       "a revoked Bot conversation's title must disappear while plain work stays")
    }

    func test_untitledNewThreadsAreNotListedAndSelectingAWorkspaceExpandsIt() async throws {
        // WHY: "+ New conversation" already starts work; empty "New thread" rows were noise.
        let f = try make("untitled")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let workspace = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let other = try f.router.createWorkspace(name: "star", cwd: NSTemporaryDirectory())
        let real = try f.router.createAgentThread(workspace: other.id, title: "Elephant - Task", provider: .codex, model: "fake", permissionMode: .supervised, reasoningEffort: .medium)
        _ = try f.router.createAgentThread(workspace: other.id, title: SidebarViewModel.untitledThreadTitle, provider: .codex, model: "fake", permissionMode: .supervised, reasoningEffort: .medium)
        f.vm.reload()
        if f.vm.expandedWorkspaceIDs.contains(other.id) { f.vm.toggleWorkspaceExpanded(other.id) }
        _ = workspace
        f.vm.select(other.id)
        XCTAssertTrue(f.vm.expandedWorkspaceIDs.contains(other.id), "selecting a workspace expands its listing")
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()
        XCTAssertEqual(f.vm.workspaceConversationRows(other.id).map(\.threadID), [real.id])
    }

    func test_reconfiguringABotRefreshesTheSidebarWithoutManualReload() async throws {
        // WHY: renames and new workspace links made by Studio, a paired phone or Titio
        // must show up without restarting or toggling the sidebar.
        let f = try make("refresh")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let bot = try f.context.botStore.create(name: "Elephant Developer", title: "", description: "", handle: "elephant-developer")
        let botsVM = BotsViewModel(context: f.context, router: f.router)
        f.vm.observeActiveBots(botsVM)
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()
        _ = try f.context.botStore.updateProfile(id: bot.id, name: "Developer", title: "", description: "")
        EventBus.shared.publish(kind: .botUpdated, payload: .object(["bot_id": .string(bot.id.value.uuidString)]))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, f.vm.generalBots.first(where: { $0.botID == bot.id })?.name != "Developer" {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(f.vm.generalBots.first(where: { $0.botID == bot.id })?.name, "Developer")
    }

    func test_expandIsSeparateFromOpenAndSharedBotIsTheSameIdentityUnderEachWorkspace() async throws {
        let f = try make("tree")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let elephant = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let star = try f.router.createWorkspace(name: "star", cwd: NSTemporaryDirectory())
        let shared = try f.context.botStore.create(name: "Shared Reviewer", title: "", description: "", handle: "shared-reviewer")
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: shared.id, context: .workspace(elephant.id), actions: [.read], expectedRevision: 0)
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: shared.id, context: .workspace(star.id), actions: [.read], expectedRevision: 0)
        let plain = try f.router.createAgentThread(workspace: elephant.id, title: "Work without a Bot", provider: .codex, model: "fake", permissionMode: .supervised, reasoningEffort: .medium)

        f.vm.reload()
        XCTAssertEqual(f.vm.expandedWorkspaceIDs, [star.id], "the open workspace starts expanded")
        let selectedBefore = f.context.state.window.selectedWorkspaceID
        await expand(f.vm, elephant.id)
        XCTAssertEqual(f.context.state.window.selectedWorkspaceID, selectedBefore, "the disclosure indicator must not open the workspace")
        XCTAssertTrue(f.vm.expandedWorkspaceIDs.contains(elephant.id))

        let elephantBots = f.vm.workspaceBotRows(elephant.id)
        XCTAssertEqual(elephantBots.map(\.botID), [shared.id])
        XCTAssertEqual(f.vm.workspaceConversationRows(elephant.id).map(\.threadID), [plain.id], "Conversations includes work without a Bot")
        XCTAssertNil(f.vm.workspaceConversationRows(elephant.id).first?.botID)

        await expand(f.vm, star.id)
        XCTAssertEqual(f.vm.workspaceBotRows(star.id).map(\.botID), [shared.id], "a shared Bot is projected under every linked workspace")
        XCTAssertTrue(f.vm.workspaceConversationRows(star.id).isEmpty, "a workspace without threads shows no empty Conversations section")
        XCTAssertTrue(f.vm.showsAddBot(star.id), "Bots always lead with + New bot, even with a linked Bot")
        let empty = try f.router.createWorkspace(name: "empty", cwd: NSTemporaryDirectory())
        f.vm.reload()
        await expand(f.vm, empty.id)
        XCTAssertTrue(f.vm.workspaceBotRows(empty.id).isEmpty)
        XCTAssertTrue(f.vm.showsAddBot(empty.id), "a workspace without Bots still offers + New bot")

        f.vm.toggleWorkspaceExpanded(elephant.id)
        XCTAssertTrue(f.vm.workspaceBotRows(elephant.id).isEmpty, "collapsing hides the children")

        f.vm.select(star.id)
        XCTAssertEqual(f.context.state.window.selectedWorkspaceID, star.id, "clicking the name opens the workspace layout")
    }

    func test_searchFindsBotsInsideWorkspacesAndGeneralBots() async throws {
        let f = try make("search")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let elephant = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        _ = try f.router.createWorkspace(name: "star", cwd: NSTemporaryDirectory())
        let developer = try f.context.botStore.create(name: "Developer", title: "", description: "", handle: "developer")
        _ = try f.context.botStore.grantContext(hostID: f.host, botID: developer.id, context: .workspace(elephant.id), actions: [.read], expectedRevision: 0)
        _ = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        f.vm.reload()
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()

        f.vm.filterText = "develop"
        XCTAssertEqual(f.vm.treeWorkspaces.map(\.id), [elephant.id], "a Bot match keeps its workspace in the tree")
        XCTAssertEqual(f.vm.workspaceBotRows(elephant.id).map(\.botID), [developer.id], "search reveals the Bot without expanding")
        XCTAssertFalse(f.vm.visibleGeneralBots.contains { $0.handle == TitioIdentity.handle }, "one search filters General Bots too")

        f.vm.filterText = "titio"
        XCTAssertEqual(f.vm.visibleGeneralBots.map(\.handle), [TitioIdentity.handle], "the same search finds a General Bot")
        XCTAssertTrue(f.vm.treeWorkspaces.isEmpty, "and filters the workspace tree with the same query")
        f.vm.filterText = "no-such-bot"
        XCTAssertTrue(f.vm.visibleGeneralBots.isEmpty)
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "SidebarSearchField(").count - 1, 1, "the sidebar mounts exactly one search field")
        XCTAssertEqual(source.components(separatedBy: "SidebarSectionMoreMenu(help:").count - 1, 2, "Bots and Workspaces headers share one \"...\" menu component")
        XCTAssertTrue(source.contains("Text(\"Bots\")") && !source.contains("Text(\"General Bots\")"), "the section is titled Bots")
    }


    func test_generalBotsHeaderTeamsButtonAndShowHiddenStayMountedWhenNoBotIsListed() async throws {
        let f = try make("empty-general")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        f.vm.reload()
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()
        XCTAssertTrue(f.vm.generalBots.isEmpty, "no bot exists: the section would have been hidden before")
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("if !vm.generalBots.isEmpty {"), "the General Bots header never depends on the list being non-empty")
    }

    func test_activitySubtitleCountsRunningBotsWithTheWorkspaceActivity() {
        let counts = PetActivityCounts(running: 2, needsYou: 1, newResults: 0)
        XCTAssertEqual(SidebarViewModel.activitySubtitle(counts, activeBots: 0), "2 running · 1 need you")
        XCTAssertEqual(SidebarViewModel.activitySubtitle(counts, activeBots: 1), "2 running · 1 need you · 1 bot")
        XCTAssertEqual(SidebarViewModel.activitySubtitle(counts, activeBots: 3), "2 running · 1 need you · 3 bots")
        XCTAssertEqual(SidebarViewModel.activitySubtitle(.zero, activeBots: 2), "Activity unavailable")
    }

    func test_newConversationLeadsAnExpandedWorkspaceAndStartsAnAgentThreadThere() async throws {
        let f = try make("new-conversation")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let controller = MainWindowController(context: f.context, router: f.router)
        f.router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        defer { controller.window.close() }
        let workspace = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        f.vm.reload()
        if f.vm.expandedWorkspaceIDs.contains(workspace.id) { f.vm.toggleWorkspaceExpanded(workspace.id) }
        XCTAssertFalse(f.vm.showsNewConversation(workspace.id), "a collapsed workspace shows no Conversations")
        await expand(f.vm, workspace.id)
        XCTAssertTrue(f.vm.showsNewConversation(workspace.id), "the first Conversations row is always + New conversation")
        f.vm.filterText = "zzz"
        XCTAssertFalse(f.vm.showsNewConversation(workspace.id), "a search shows matches only")
        f.vm.filterText = ""

        let before = try f.context.threadRepo.list(workspaceId: workspace.id).map(\.id)
        let created = try f.router.createWorkspaceConversation(workspace: workspace.id)
        XCTAssertFalse(before.contains(created))
        XCTAssertEqual(try f.context.threadRepo.get(id: created)?.workspaceId, workspace.id, "the thread belongs to the clicked workspace")
        XCTAssertTrue(controller.isShowingWorkspaceContent, "the new conversation opens in the workspace content")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.all().compactMap { $0 as? AgentAppSurface }
            .first { $0.viewModel.workspaceID == workspace.id })
        XCTAssertEqual(surface.viewModel.selectedThreadId, created, "the Agent App has the new thread selected")
    }

    func test_conversationRowsOpenTheCanonicalThread() async throws {
        let f = try make("open")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let controller = MainWindowController(context: f.context, router: f.router)
        f.router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        defer { controller.window.close() }
        let workspace = try f.router.createWorkspace(name: "Canonical", cwd: NSTemporaryDirectory())
        defer {
            for surface in SurfaceRegistry.shared.all().compactMap({ $0 as? AgentAppSurface })
                where surface.viewModel.workspaceID == workspace.id {
                surface.close()
                SurfaceRegistry.shared.unregister(surface.descriptor.id)
            }
        }
        let plain = try f.router.createAgentThread(workspace: workspace.id, title: "Plain", provider: .codex, model: "fake", permissionMode: .supervised, reasoningEffort: .medium)
        let bot = try f.context.botStore.create(name: "Piper", title: "", description: "", provider: .distill)
        let grant = try f.context.botStore.grantContext(hostID: f.host, botID: bot.id, context: .workspace(workspace.id), actions: [.read], expectedRevision: 0)
        var botThread = AgentThread(workspaceId: workspace.id, title: "Bot work", provider: .distill, model: "fixture")
        botThread.status = .completed
        let conversation = BotConversation(botID: bot.id, title: "Bot work", linkedAgentThreadID: botThread.id)
        try f.context.botStore.createContextualConversation(conversation, newThread: botThread, hostID: f.host, context: .workspace(workspace.id), policyRevision: grant.policyRevision)

        let vm = controller.sidebarViewModelForTesting
        vm.reload()
        await expand(vm, workspace.id)
        let rows = vm.workspaceConversationRows(workspace.id)
        let plainRow = try XCTUnwrap(rows.first { $0.threadID == plain.id })
        let botRow = try XCTUnwrap(rows.first { $0.threadID == botThread.id }, "a Bot thread is also listed under Conversations")
        XCTAssertEqual(botRow.botID, bot.id)

        vm.openWorkspaceConversation(plainRow)
        let surface = try XCTUnwrap(SurfaceRegistry.shared.all().compactMap { $0 as? AgentAppSurface }.first { $0.viewModel.workspaceID == workspace.id })
        XCTAssertEqual(surface.viewModel.selectedThreadId, plain.id, "a plain conversation opens its exact thread in the Agent App")

        vm.openWorkspaceConversation(botRow)
        XCTAssertFalse(controller.isShowingBotsContent, "a workspace Bot conversation stays in its workspace")
        XCTAssertEqual(surface.viewModel.selectedThreadId, botThread.id, "a workspace Bot conversation opens as a workspace tab")

        let botLinkRow = try XCTUnwrap(vm.workspaceBotRows(workspace.id).first)
        vm.openWorkspaceConversation(plainRow)
        vm.openAuthorizedBotConversation(botLinkRow)
        XCTAssertFalse(controller.isShowingBotsContent, "the workspace Bot row opens as a workspace tab, not the Bots Desk")
        XCTAssertEqual(surface.viewModel.selectedThreadId, botThread.id)

        let botLink = try XCTUnwrap(vm.workspaceBotRows(workspace.id).first)
        XCTAssertEqual(botLink.conversationID, conversation.id, "the Bot row resumes its recent contextual conversation")
    }

    func test_renderedSidebarShowsRegionsInOrderWithoutTheModeToggle() async throws {
        let f = try make("render")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        _ = try f.router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        _ = try TitioBot.ensure(store: f.context.botStore, appSupportDirectory: f.context.appSupportDirectory)
        f.vm.reload()
        await f.vm.reloadAuthorizedBotConversationRowsAndWait()
        let hosting = NSHostingView(rootView: SidebarRootView(vm: f.vm).frame(width: 300, height: 860))
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 860)
        let window = NSWindow(contentRect: hosting.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        var painted = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { painted += 1 }
        }
        XCTAssertGreaterThan(painted, 500, "the unified sidebar must paint its rows")

        // Region order is the shipped body's declaration order (the live window readback checks the labels).
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/AppShell/SidebarView.swift"), encoding: .utf8)
        let body = try XCTUnwrap(source.range(of: "public struct SidebarRootView: View"))
        func position(_ needle: String) throws -> String.Index {
            try XCTUnwrap(source.range(of: needle, range: body.upperBound..<source.endIndex), needle).lowerBound
        }
        XCTAssertFalse(source.contains("BotsModeSwitcher"), "no Workspaces | Bots toggle")
        let order = try ["accessibilityIdentifier(\"sidebar.new\")", "accessibilityIdentifier(\"sidebar.activity\")",
                         "accessibilityIdentifier(\"sidebar.scheduleTasks\")", "            generalBotsSection\n",
                         "Text(\"Workspaces\")", "workspaceGroup(ws)", "            accountFooter\n"].map(position)
        XCTAssertEqual(order, order.sorted(), "top items, General Bots, Workspaces tree, account footer")
        XCTAssertEqual(f.vm.generalBots.first?.handle, TitioIdentity.handle)
        if let directory = ProcessInfo.processInfo.environment["RC_SIDEBAR_RENDER_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("unified-sidebar.png"))
        }
    }

    func test_addBotOpensTheExistingNewBotFlowWithoutAnyGrant() throws {
        let f = try make("addbot")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let controller = MainWindowController(context: f.context, router: f.router)
        f.router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        defer { controller.window.close() }
        SettingsStore(db: f.context.db).update { $0.botsControlPlaneEnabled = true }
        let botsVM = controller.sidebarBotsViewModelForTesting
        f.router.botsViewModel = botsVM
        controller.sidebarViewModelForTesting.addBot()
        XCTAssertTrue(controller.isShowingBotsContent)
        XCTAssertEqual(botsVM.screen, .studio, "Add Bot opens the existing New Bot Studio")
        let draft = try XCTUnwrap(botsVM.selectedBotID)
        XCTAssertTrue(botsVM.needsUnsavedNewBotConfirm, "the draft stays unpublished until the user saves it")
        XCTAssertTrue(try f.context.botStore.listContextBindings(hostID: f.host, botID: draft).isEmpty,
                      "Add Bot never grants a context; linking to a workspace is a separate explicit step")
    }
}
