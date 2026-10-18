import XCTest
import AppKit
import SwiftUI
import AgentRuntime
@testable import AppShell
@testable import CoreModel
import Persistence
import Surfaces

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
        XCTAssertTrue(general.contains(researcher.id), "a Bot with no workspace link is a general Bot")
        XCTAssertTrue(general.contains(reviewer.id), "a Bot with a General grant stays general even when also linked")
        XCTAssertFalse(general.contains(developer.id), "a workspace-only Bot lives under its workspace, not General")
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
        XCTAssertFalse(f.vm.showsAddBot(star.id), "a workspace with a linked Bot does not offer Add Bot")
        let empty = try f.router.createWorkspace(name: "empty", cwd: NSTemporaryDirectory())
        f.vm.reload()
        await expand(f.vm, empty.id)
        XCTAssertTrue(f.vm.workspaceBotRows(empty.id).isEmpty)
        XCTAssertTrue(f.vm.showsAddBot(empty.id), "a workspace without Bots shows Add Bot instead of empty sections")

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
        XCTAssertTrue(f.vm.visibleGeneralBots.isEmpty)

        f.vm.filterText = "titio"
        XCTAssertEqual(f.vm.visibleGeneralBots.map(\.handle), [TitioIdentity.handle])
        XCTAssertTrue(f.vm.treeWorkspaces.isEmpty)
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

        let botsVM = controller.sidebarBotsViewModelForTesting
        vm.openWorkspaceConversation(botRow)
        XCTAssertTrue(controller.isShowingBotsContent)
        XCTAssertEqual(botsVM.selectedBotID, bot.id)
        XCTAssertEqual(botsVM.selectedConversation?.id, conversation.id, "a Bot conversation opens its exact Desk conversation")

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
        let order = try ["accessibilityIdentifier(\"sidebar.newWorkspace\")", "accessibilityIdentifier(\"sidebar.activity\")",
                         "accessibilityIdentifier(\"sidebar.scheduleTasks\")", "            generalBotsSection\n",
                         "Text(\"Workspaces\")", "workspaceChildren(ws)", "            manageBotsFooter\n"].map(position)
        XCTAssertEqual(order, order.sorted(), "top items, General Bots, Workspaces tree, Manage Bots footer")
        XCTAssertEqual(f.vm.generalBots.first?.handle, TitioIdentity.handle)
        if let directory = ProcessInfo.processInfo.environment["RC_SIDEBAR_RENDER_DIR"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("unified-sidebar.png"))
        }
    }

    func test_manageBotsFooterOpensTheBotsCatalogWithTheRosterBesideIt() throws {
        let f = try make("manage")
        defer { try? FileManager.default.removeItem(atPath: f.directory) }
        let controller = MainWindowController(context: f.context, router: f.router)
        f.router.windowController = controller
        controller.window.isReleasedWhenClosed = false
        defer { controller.window.close() }
        controller.sidebarOpenBotsForTesting()
        XCTAssertTrue(controller.isShowingBotsContent, "Manage Bots and Teams opens the existing Bots catalog and Studio")
        XCTAssertTrue(controller.sidebarViewModelForTesting.isBotsSelected)
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
