import AppKit
import AgentRuntime
import XCTest
@testable import AppShell
import CoreModel
import Persistence
import Surfaces

/// Exercises the Pet's existing `onOpenItem` seam so persistence is cleared only
/// after the exact main or detached destination is mounted and visible.
@MainActor
final class PetWorkspaceSurfaceRoutingTests: XCTestCase {
    func test_legacyGitWorkspaceRouteClearsOnlyAfterSelectingExactVisibleWindow() throws {
        let fixture = try makeFixture(prefix: "MainWorkspace")
        defer { fixture.cleanup() }
        let workspace = try fixture.router.createWorkspace(name: "MAIN-TARGET", cwd: NSTemporaryDirectory())
        fixture.trackSurfaces(in: workspace.id)
        try fixture.notifications.insert(AppNotification(
            id: "main-workspace",
            workspaceId: workspace.id,
            title: "unsafe operation detail",
            category: PetNotificationCategory.gitCompleted.rawValue
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        fixture.open(itemID: "notification:main-workspace", with: pet)

        XCTAssertEqual(fixture.context.state.window.selectedWorkspaceID, workspace.id)
        XCTAssertTrue(fixture.windowController.window.isVisible)
        XCTAssertFalse(fixture.windowController.window.isMiniaturized)
        XCTAssertTrue(
            fixture.windowController.window.isKeyWindow || !NSApp.isActive,
            "The main window must become key whenever the XCTest host permits app activation."
        )
        XCTAssertTrue(try fixture.notifications.list(unreadOnly: true).isEmpty,
            "A verified main-window route must clear the completed ready item exactly once.")
        XCTAssertNil(pet.modelForTests.routeError)
    }

    func test_mainSurfaceRouteFocusesAndMountsExactSurfaceBeforeClearing() throws {
        let fixture = try makeFixture(prefix: "MainSurface")
        defer { fixture.cleanup() }
        let workspace = try fixture.router.createWorkspace(name: "MAIN-SURFACE", cwd: NSTemporaryDirectory())
        let targetSurfaceID = try fixture.focusedSurfaceID(in: workspace.id)
        let secondary = try fixture.router.createSurface(
            workspace: workspace.id,
            type: .markdown,
            paneID: nil,
            title: "secondary"
        )
        try fixture.router.focusSurface(workspace: workspace.id, surface: secondary.id)
        fixture.trackSurfaces(in: workspace.id)
        try fixture.notifications.insert(AppNotification(
            id: "main-surface",
            workspaceId: workspace.id,
            surfaceId: targetSurfaceID,
            title: "unsafe script detail",
            category: PetNotificationCategory.projectScriptCompleted.rawValue
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        fixture.open(itemID: "notification:main-surface", with: pet)

        XCTAssertEqual(try fixture.focusedSurfaceID(in: workspace.id), targetSurfaceID)
        XCTAssertTrue(fixture.windowController.window.isVisible)
        XCTAssertFalse(fixture.windowController.window.isMiniaturized)
        XCTAssertTrue(
            SurfaceRegistry.shared.surface(targetSurfaceID)?.view.window
                === fixture.windowController.window,
            "The exact surface must be mounted in the main window before clearing."
        )
        XCTAssertTrue(try fixture.notifications.list(unreadOnly: true).isEmpty)
        XCTAssertNil(pet.modelForTests.routeError)
    }

    func test_agentAttentionRouteFocusesExactAgentAppSurfaceAndRetainsActionRequiredRow() throws {
        let fixture = try makeFixture(prefix: "AgentAttention")
        defer { fixture.cleanup() }
        let workspace = try fixture.router.createWorkspace(
            name: "AGENT-ATTENTION",
            cwd: NSTemporaryDirectory()
        )
        let agentSurfaceID = try fixture.focusedSurfaceID(in: workspace.id)
        try fixture.notifications.insert(AppNotification(
            id: "agent-attention",
            workspaceId: workspace.id,
            surfaceId: agentSurfaceID,
            title: "Agent input requested",
            category: PetNotificationCategory.agentAttention.rawValue
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        fixture.open(itemID: "notification:agent-attention", with: pet)

        XCTAssertEqual(
            try fixture.focusedSurfaceID(in: workspace.id),
            agentSurfaceID,
            "Pet Agent attention must focus the exact Agent App surface that produced the notification."
        )
        XCTAssertTrue(fixture.windowController.window.isVisible)
        XCTAssertTrue(
            SurfaceRegistry.shared.surface(agentSurfaceID)?.view.window
                === fixture.windowController.window,
            "The Agent App surface must be mounted before Pet acknowledges its notification."
        )
        XCTAssertEqual(
            try fixture.notifications.list(unreadOnly: true).map(\.id),
            ["agent-attention"],
            "Opening Agent attention must not acknowledge an action-required row before the Agent thread is resolved."
        )
        XCTAssertNil(pet.modelForTests.routeError)
    }

    func test_mainSurfaceRouteFlushesWorkspaceSwitchBeforeClearing() throws {
        let fixture = try makeFixture(prefix: "MainSurfaceWorkspaceSwitch")
        defer { fixture.cleanup() }
        let targetWorkspace = try fixture.router.createWorkspace(
            name: "BACKGROUND-TARGET",
            cwd: NSTemporaryDirectory()
        )
        let targetSurfaceID = try fixture.focusedSurfaceID(in: targetWorkspace.id)
        fixture.trackSurfaces(in: targetWorkspace.id)
        let foregroundWorkspace = try fixture.router.createWorkspace(
            name: "FOREGROUND",
            cwd: NSTemporaryDirectory()
        )
        fixture.trackSurfaces(in: foregroundWorkspace.id)
        try fixture.notifications.insert(AppNotification(
            id: "main-surface-workspace-switch",
            workspaceId: targetWorkspace.id,
            surfaceId: targetSurfaceID,
            title: "unsafe script detail",
            category: PetNotificationCategory.projectScriptCompleted.rawValue
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        XCTAssertEqual(fixture.context.state.window.selectedWorkspaceID, foregroundWorkspace.id)
        XCTAssertFalse(
            SurfaceRegistry.shared.surface(targetSurfaceID)?.view.window
                === fixture.windowController.window,
            "The target must begin outside the destination window so this reproduces the live workspace-switch race."
        )

        fixture.open(itemID: "notification:main-surface-workspace-switch", with: pet)

        XCTAssertEqual(fixture.context.state.window.selectedWorkspaceID, targetWorkspace.id)
        XCTAssertEqual(try fixture.focusedSurfaceID(in: targetWorkspace.id), targetSurfaceID)
        XCTAssertTrue(
            SurfaceRegistry.shared.surface(targetSurfaceID)?.view.window
                === fixture.windowController.window,
            "The queued workspace refresh must be flushed before route verification."
        )
        XCTAssertTrue(
            try fixture.notifications.list(unreadOnly: true).isEmpty,
            "A project outcome clears only after the exact switched-to surface is mounted."
        )
        XCTAssertNil(pet.modelForTests.routeError)
    }

    func test_legacyDetachedGitWorkspaceRoutePreservesMainSelectionAndClearsAfterActivation() throws {
        let fixture = try makeFixture(prefix: "DetachedWorkspace")
        defer { fixture.cleanup() }
        let detachedWorkspace = try fixture.router.createWorkspace(
            name: "DETACHED-WORKSPACE",
            cwd: NSTemporaryDirectory()
        )
        fixture.trackSurfaces(in: detachedWorkspace.id)
        let mainWorkspace = try fixture.router.createWorkspace(name: "MAIN-STAYS", cwd: NSTemporaryDirectory())
        fixture.trackSurfaces(in: mainWorkspace.id)
        fixture.windowController.openWorkspaceInNewWindow(detachedWorkspace.id)
        let detachedWindow = try XCTUnwrap(
            fixture.windowController.workspaceWindow(for: detachedWorkspace.id)
        )
        try fixture.notifications.insert(AppNotification(
            id: "detached-workspace",
            workspaceId: detachedWorkspace.id,
            title: "unsafe git detail",
            category: PetNotificationCategory.gitCompleted.rawValue
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        fixture.open(itemID: "notification:detached-workspace", with: pet)

        XCTAssertEqual(fixture.context.state.window.selectedWorkspaceID, mainWorkspace.id)
        XCTAssertTrue(detachedWindow.isVisible)
        XCTAssertFalse(detachedWindow.isMiniaturized)
        XCTAssertTrue(try fixture.notifications.list(unreadOnly: true).isEmpty)
        XCTAssertNil(pet.modelForTests.routeError)
    }

    func test_detachedSurfaceRoutePreservesMainSelectionAndClearsAfterExactMount() throws {
        let fixture = try makeFixture(prefix: "DetachedSurface")
        defer { fixture.cleanup() }
        let detachedWorkspace = try fixture.router.createWorkspace(
            name: "DETACHED-TARGET",
            cwd: NSTemporaryDirectory()
        )
        fixture.trackSurfaces(in: detachedWorkspace.id)
        let targetSurfaceID = try fixture.focusedSurfaceID(in: detachedWorkspace.id)
        let mainWorkspace = try fixture.router.createWorkspace(name: "MAIN-STAYS", cwd: NSTemporaryDirectory())
        fixture.trackSurfaces(in: mainWorkspace.id)
        fixture.windowController.openWorkspaceInNewWindow(detachedWorkspace.id)
        let detachedWindow = try XCTUnwrap(
            fixture.windowController.workspaceWindow(for: detachedWorkspace.id)
        )
        try fixture.notifications.insert(AppNotification(
            id: "detached-surface",
            workspaceId: detachedWorkspace.id,
            surfaceId: targetSurfaceID,
            title: "unsafe script detail",
            category: PetNotificationCategory.projectScriptCompleted.rawValue
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        fixture.open(itemID: "notification:detached-surface", with: pet)

        XCTAssertEqual(
            fixture.context.state.window.selectedWorkspaceID,
            mainWorkspace.id,
            "Opening detached attention must not move the main sidebar selection."
        )
        XCTAssertTrue(detachedWindow.isVisible)
        XCTAssertFalse(detachedWindow.isMiniaturized)
        XCTAssertTrue(
            detachedWindow.isKeyWindow || !NSApp.isActive,
            "The detached window must become key whenever the XCTest host permits app activation."
        )
        XCTAssertTrue(
            SurfaceRegistry.shared.surface(targetSurfaceID)?.view.window === detachedWindow,
            "The exact surface must be mounted in its owning detached window before clearing."
        )
        XCTAssertTrue(try fixture.notifications.list(unreadOnly: true).isEmpty)
        XCTAssertNil(pet.modelForTests.routeError)
    }

    func test_staleWorkspaceAndSurfaceRoutesRemainUnreadWhenExactDestinationIsMissing() throws {
        let fixture = try makeFixture(prefix: "StaleDestinations")
        defer { fixture.cleanup() }
        let existingWorkspace = try fixture.router.createWorkspace(
            name: "EXISTING",
            cwd: NSTemporaryDirectory()
        )
        fixture.trackSurfaces(in: existingWorkspace.id)
        let staleWorkspaceID = WorkspaceID(UUID())
        let staleGitSurfaceID = SurfaceID(UUID())
        let staleProjectSurfaceID = SurfaceID(UUID())
        try fixture.notifications.insert(AppNotification(
            id: "stale-git-workspace",
            workspaceId: staleWorkspaceID,
            title: "unsafe git detail",
            category: PetNotificationCategory.gitCompleted.rawValue,
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        try fixture.notifications.insert(AppNotification(
            id: "stale-git-surface",
            workspaceId: existingWorkspace.id,
            surfaceId: staleGitSurfaceID,
            title: "unsafe git detail",
            category: PetNotificationCategory.gitFailed.rawValue,
            createdAt: Date(timeIntervalSince1970: 150)
        ))
        try fixture.notifications.insert(AppNotification(
            id: "stale-surface",
            workspaceId: existingWorkspace.id,
            surfaceId: staleProjectSurfaceID,
            title: "unsafe script detail",
            category: PetNotificationCategory.projectScriptCompleted.rawValue,
            createdAt: Date(timeIntervalSince1970: 100)
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        fixture.open(itemID: "notification:stale-git-workspace", with: pet)
        fixture.open(itemID: "notification:stale-git-surface", with: pet)
        fixture.open(itemID: "notification:stale-surface", with: pet)

        XCTAssertEqual(
            Set(try fixture.notifications.list(unreadOnly: true).map(\.id)),
            Set(["stale-git-workspace", "stale-git-surface", "stale-surface"]),
            "Missing exact destinations must never acknowledge ready items the user could not inspect."
        )
        XCTAssertEqual(pet.modelForTests.count, 3)
        XCTAssertEqual(
            pet.modelForTests.routeError,
            "The exact destination could not be opened. The item was kept."
        )
    }

    func test_pinnedBotAttentionOpensExactContextsAndRetainsRevokedTarget() throws {
        let fixture = try makeFixture(prefix: "PinnedBot")
        defer { fixture.cleanup() }
        let workspace = try fixture.router.createWorkspace(name: "Pinned workspace", cwd: NSTemporaryDirectory())
        fixture.trackSurfaces(in: workspace.id)
        let bot = try fixture.context.botStore.create(name: "Pinned Bot", title: "Scout", description: "", provider: .distill)
        let hostID = fixture.context.liveActivityHostIdentity.serverId
        var conversations: [BotConversation] = []
        var attentionItems: [BotAttentionItem] = []
        for pinContext in [BotContext.general, .workspace(workspace.id)] {
            let grant = try fixture.context.botStore.grantContext(
                hostID: hostID, botID: bot.id, context: pinContext, actions: [.read], expectedRevision: 0
            )
            let thread = AgentThread(workspaceId: pinContext == .general ? nil : workspace.id,
                                     title: "Pinned attention", provider: .distill, model: "test")
            let conversation = BotConversation(botID: bot.id, title: "Pinned attention",
                                               attentionState: .needsAttention, linkedAgentThreadID: thread.id)
            try fixture.context.botStore.createContextualConversation(
                conversation, newThread: thread, hostID: hostID, context: pinContext, policyRevision: grant.policyRevision
            )
            try fixture.context.runRepo.upsert(AgentRun(threadId: thread.id, provider: .distill, model: "test", status: .completed))
            let attention = BotAttentionItem(botID: bot.id, conversationID: conversation.id, kind: .question, title: "Context question")
            try fixture.context.botStore.upsertAttention(attention)
            attentionItems.append(attention)
            conversations.append(conversation)
        }
        let pet = try fixture.startPet()
        defer { pet.stop() }
        for (conversation, attention) in zip(conversations, attentionItems) {
            fixture.open(itemID: "bot.attention:\(attention.id.value.uuidString)", with: pet)
            XCTAssertEqual(fixture.router.botsViewModel?.selectedBotID, bot.id)
            XCTAssertEqual(fixture.router.botsViewModel?.screen, .desk)
            XCTAssertEqual(fixture.router.botsViewModel?.selectedConversation?.id, conversation.id)
            XCTAssertTrue(fixture.windowController.window.isVisible)
            XCTAssertFalse(fixture.windowController.window.isMiniaturized)
            XCTAssertNil(try fixture.context.botStore.listAttention(includeAcknowledged: true).first { $0.id == attention.id }?.acknowledgedAt)
            XCTAssertNil(pet.modelForTests.routeError)
        }
        fixture.open(itemID: "bot.attention:\(attentionItems[0].id.value.uuidString)", with: pet)
        let workspaceThreadID = try XCTUnwrap(conversations[1].linkedAgentThreadID)
        fixture.context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: workspaceThreadID, runId: AgentRunID())]), .started
        )
        let deadline = Date().addingTimeInterval(3)
        while pet.modelForTests.activeThreads.first?.route != .botsDesk(botID: bot.id), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let active = try XCTUnwrap(pet.modelForTests.activeThreads.first { $0.threadID == workspaceThreadID })
        pet.windowControllerForTests.onOpenActiveThread?(active)
        XCTAssertEqual(fixture.router.botsViewModel?.selectedConversation?.id, conversations[1].id,
                       "an active Bot row must open its exact thread, not the previously selected context")
        fixture.open(itemID: "bot.attention:\(attentionItems[0].id.value.uuidString)", with: pet)
        _ = try fixture.context.botStore.revokeContext(
            hostID: hostID, botID: bot.id, context: .workspace(workspace.id), expectedRevision: 1
        )
        pet.windowControllerForTests.onOpenActiveThread?(active)
        XCTAssertEqual(fixture.router.botsViewModel?.selectedConversation?.id, conversations[0].id)
        fixture.open(itemID: "bot.attention:\(attentionItems[1].id.value.uuidString)", with: pet)
        XCTAssertEqual(fixture.router.botsViewModel?.selectedConversation?.id, conversations[0].id,
                       "revoked attention must not change the visible conversation")
        XCTAssertNil(try fixture.context.botStore.listAttention(includeAcknowledged: true).first { $0.id == attentionItems[1].id }?.acknowledgedAt)
        XCTAssertNotNil(pet.modelForTests.routeError)
    }

    private func makeFixture(prefix: String) throws -> PetRouteFixture {
        let fixture = try PetRouteFixture(prefix: prefix)
        let directory = fixture.directory
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: directory)
        }
        return fixture
    }
}

@MainActor
private final class PetRouteFixture {
    let directory: String
    let context: AppContext
    let router: AppCommandRouter
    let windowController: MainWindowController
    let notifications: NotificationRepository
    private var surfaceIDs: Set<SurfaceID> = []

    init(prefix: String) throws {
        directory = NSTemporaryDirectory() + "RC2PetRoute-\(prefix)-" + UUID().uuidString
        context = try AppContext(channel: .debug, appSupportOverride: directory)
        router = AppCommandRouter(context: context)
        context.router = router
        windowController = MainWindowController(context: context, router: router)
        router.windowController = windowController
        notifications = NotificationRepository(db: context.db)
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
    }

    func startPet() throws -> PetController {
        drainScheduledWindowRefreshes()
        let pet = try PetController(context: context, router: router, openSettings: { _ in false })
        pet.destinationWindowIsKeyForTests = { _ in true }
        pet.start()
        return pet
    }

    private func drainScheduledWindowRefreshes() {
        var drained = false
        DispatchQueue.main.async { drained = true }
        let deadline = Date().addingTimeInterval(1)
        while !drained, Date() < deadline, RunLoop.main.run(mode: .default, before: deadline) {}
        XCTAssertTrue(drained, "The queued window tree refresh must finish before route verification.")
    }

    func open(itemID: String, with pet: PetController) {
        guard let item = pet.modelForTests.items.first(where: { $0.id == itemID }) else {
            return XCTFail("Expected persisted Pet item \(itemID)")
        }
        pet.windowControllerForTests.onOpenItem?(item)
    }

    func focusedSurfaceID(in workspaceID: WorkspaceID) throws -> SurfaceID {
        let workspace = try XCTUnwrap(context.state.workspaces[workspaceID])
        let paneID = try XCTUnwrap(workspace.focusedPaneID)
        return try XCTUnwrap(workspace.layout.find(paneID: paneID)?.selectedSurfaceID)
    }

    func trackSurfaces(in workspaceID: WorkspaceID) {
        guard let workspace = context.state.workspaces[workspaceID] else { return }
        collectSurfaceIDs(in: workspace.layout, into: &surfaceIDs)
    }

    func cleanup() {
        windowController.window.orderOut(nil)
        for workspaceID in context.state.workspaces.keys {
            windowController.workspaceWindow(for: workspaceID)?.orderOut(nil)
        }
        for surfaceID in surfaceIDs {
            SurfaceRegistry.shared.surface(surfaceID)?.close()
            SurfaceRegistry.shared.unregister(surfaceID)
        }
    }

    private func collectSurfaceIDs(in node: LayoutNode, into result: inout Set<SurfaceID>) {
        switch node {
        case .pane(let pane):
            result.formUnion(pane.surfaces.map(\.id))
        case .split(let split):
            for child in split.children {
                collectSurfaceIDs(in: child, into: &result)
            }
        }
    }
}
