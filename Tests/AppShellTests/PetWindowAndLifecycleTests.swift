import AppKit
import XCTest
@testable import AppShell
import AgentRuntime
import CoreModel
import Persistence
import SocketServer

@MainActor
final class PetWindowAndLifecycleTests: XCTestCase {
    private func database() throws -> SQLiteDB {
        let directory = NSTemporaryDirectory() + "RC2PetWindow-\(UUID().uuidString)"
        return try Bootstrap(channel: .debug, appSupportOverride: directory).run().1
    }

    func test_panelAndPopoverUseSeparateAccessibleAllSpacesWindows() throws {
        let db = try database()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }

        controller.show()
        let pet = try XCTUnwrap(controller.petPanelForTests)
        XCTAssertTrue(pet.isVisible)
        XCTAssertTrue(pet.styleMask.contains(.borderless))
        XCTAssertTrue(pet.styleMask.contains(.nonactivatingPanel))
        XCTAssertEqual(pet.level, .floating)
        XCTAssertFalse(pet.isOpaque)
        XCTAssertFalse(pet.hasShadow)
        XCTAssertTrue(pet.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(pet.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(pet.collectionBehavior.contains(.stationary))
        XCTAssertTrue(pet.collectionBehavior.contains(.ignoresCycle))
        XCTAssertEqual(pet.identifier?.rawValue, "pet.window")

        controller.openPopoverForTests()
        let popover = try XCTUnwrap(controller.popoverPanelForTests)
        XCTAssertFalse(popover === pet, "The popover must not share the sprite window and clip it.")
        XCTAssertTrue(popover.isVisible)
        XCTAssertTrue(popover.canBecomeKey)
        XCTAssertTrue(popover.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(popover.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(popover.identifier?.rawValue, "pet.popover")
        if let screen = popover.screen ?? NSScreen.main {
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(popover.frame))
        }

        controller.closePopover()
        XCTAssertFalse(popover.isVisible)
        XCTAssertTrue(pet.isVisible)
    }

    func test_bottomLeftPlacementUsesPhysicalScreenEdgeEvenWhenDockReservesSpace() throws {
        let db = try database()
        let model = PetViewModel(settings: AppSettings(
            petEnabled: true,
            petPosition: "bottomLeft"
        ))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)

        XCTAssertEqual(panel.frame.minX, screen.frame.minX, accuracy: 0.001,
            "the pet, unlike its popover, must be placeable under a left-side Dock")
        XCTAssertEqual(panel.frame.minY, screen.frame.minY, accuracy: 0.001,
            "the pet, unlike its popover, must be placeable under a bottom Dock")
    }

    func test_petPanelDoesNotReapplyAppKitSafeAreaWhenDraggedToPhysicalEdge() throws {
        let db = try database()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let proposed = CGRect(origin: screen.frame.origin, size: panel.frame.size)

        XCTAssertEqual(panel.constrainFrameRect(proposed, to: screen), proposed,
            "a borderless desktop pet must not inherit normal-window Dock/menu constraints")
    }

    func test_dragBeyondBottomLeftClampsAndPersistsPhysicalScreenEdge() throws {
        let db = try database()
        let placementStore = PetPlacementStore(repository: SettingsRepository(db: db))
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let controller = PetWindowController(model: model, placementStore: placementStore)
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let placementFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        let draggedBeyondEdge = CGRect(
            x: placementFrame.minX - 10,
            y: placementFrame.minY - 10,
            width: panel.frame.width,
            height: panel.frame.height
        )

        controller.finishDragForTests(frame: draggedBeyondEdge)

        XCTAssertEqual(panel.frame.minX, placementFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)
        XCTAssertEqual(
            try XCTUnwrap(placementStore.load()).position,
            PetNormalizedPosition(x: 0, y: 0),
            "relaunch must restore the exact physical bottom-left edge after the user drags there"
        )
    }

    func test_animationStateResizeKeepsVisualPanelOnChosenScreenEdges() throws {
        let db = try database()
        let atlas = try PetAtlas.bundled()
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        model.setFrame(try atlas.canonicalFrame(for: .idle))
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }

        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let placementFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(
            PetPlacement.frame(
                size: panel.frame.size,
                normalizedPosition: PetNormalizedPosition(x: 0, y: 0),
                in: placementFrame
            ),
            display: false
        )

        let sleeping = try atlas.canonicalFrame(for: .sleeping)
        model.setFrame(sleeping)
        controller.animationFrameDidChange()

        XCTAssertEqual(panel.frame.minX, placementFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)
        XCTAssertEqual(
            panel.frame.width,
            (CGFloat(sleeping.displayImage.width) * CGFloat(118.0 / 192.0) * 1.5).rounded(),
            accuracy: 0.001
        )
        XCTAssertEqual(
            panel.frame.height,
            (CGFloat(sleeping.displayImage.height) * CGFloat(118.0 / 192.0) * 1.5).rounded(),
            accuracy: 0.001
        )
    }

    func test_visualEnvelopePreservesEverySupportedPetScale() throws {
        let db = try database()
        let atlas = try PetAtlas.bundled()
        let frame = try atlas.canonicalFrame(for: .idle)
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        model.setFrame(frame)
        let controller = PetWindowController(
            model: model,
            placementStore: PetPlacementStore(repository: SettingsRepository(db: db))
        )
        defer { controller.stop() }
        controller.show()
        let panel = try XCTUnwrap(controller.petPanelForTests)
        let sourcePixelScale = CGFloat(118.0 / 192.0)

        for scale in [0.75, 1.0, 1.25, 1.5] {
            let settings = AppSettings(petEnabled: true, petSize: scale)
            model.apply(settings: settings)
            controller.applySettings(settings)

            XCTAssertEqual(
                panel.frame.width,
                (CGFloat(frame.displayImage.width) * sourcePixelScale * scale).rounded(),
                accuracy: 0.001
            )
            XCTAssertEqual(
                panel.frame.height,
                (CGFloat(frame.displayImage.height) * sourcePixelScale * scale).rounded(),
                accuracy: 0.001
            )
        }
    }

    func test_viewModelFormatsBadgeAndSeparatesNeedsYouFromCompleted() {
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let callback = PetAttentionItem(
            id: "callback-1",
            kind: .callback(.approval, isStale: false),
            title: "Approval required",
            detail: nil,
            createdAt: Date(timeIntervalSince1970: 2),
            route: .settings(.general),
            source: .notification(id: "callback-1")
        )
        let outcome = PetAttentionItem(
            id: "outcome-1",
            kind: .notification(.gitCompleted),
            title: "Git delivery completed",
            detail: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            route: .settings(.general),
            source: .notification(id: "outcome-1")
        )
        model.apply(snapshot: PetAttentionSnapshot(items: [callback, outcome]))

        XCTAssertEqual(model.badgeText, "2")
        XCTAssertEqual(model.accessibilityValue, "2 items need attention")
        XCTAssertEqual(model.needsYouItems.map(\.id), ["callback-1"])
        XCTAssertEqual(model.completedItems.map(\.id), ["outcome-1"])

        let many = (0..<100).map { index in
            PetAttentionItem(
                id: "row-\(index)",
                kind: .notification(.gitCompleted),
                title: "Git delivery completed",
                detail: nil,
                createdAt: Date(),
                route: .settings(.general),
                source: .notification(id: "row-\(index)")
            )
        }
        model.apply(snapshot: PetAttentionSnapshot(items: many))
        XCTAssertEqual(model.badgeText, "99+")
        model.apply(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        XCTAssertNil(model.badgeText)
    }

    func test_viewModelFormatsBlueActiveBadgeAndKeepsItIndependentOfReadyCounterSetting() {
        let model = PetViewModel(settings: AppSettings(petEnabled: true))
        let threadA = AgentThreadID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
        let threadB = AgentThreadID(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        let secretTitle = "Run rm -rf /Users/private token=secret-token"

        let projected = PetActiveThreadProjector.items(
            threadIDs: [threadA, threadA, threadB],
            now: Date(timeIntervalSince1970: 1_000)
        ) { id in
            (
                workspaceID: WorkspaceID(UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!),
                workspaceName: "star",
                providerName: id == threadA ? "Codex" : "Claude",
                threadTitle: id == threadA ? "make title for agent run" : secretTitle,
                startedAt: id == threadA ? Date(timeIntervalSince1970: 880) : nil,
                lastUpdatePreview: nil as String?
            )
        }

        XCTAssertEqual(projected.count, 2, "Duplicate run IDs for one thread must count once.")
        XCTAssertEqual(projected.map(\.title), ["Agent run in progress", "Agent run in progress"])
        XCTAssertEqual(
            projected.map(\.detail),
            [
                "star - Codex - make title for agent run - 2m",
                "star - Claude - \(AgentThreadTitle.display(secretTitle))"
            ]
        )
        for item in projected {
            XCTAssertFalse(item.title.contains(secretTitle))
            XCTAssertFalse(item.detail?.contains("secret-token") == true)
            XCTAssertFalse(item.id.contains("secret"))
        }

        model.apply(activeThreads: projected)
        XCTAssertEqual(model.activeBadgeText, "2")
        XCTAssertEqual(model.activeThreadCount, 2)
        XCTAssertEqual(
            model.accessibilityValue,
            "2 active agent threads"
        )
        XCTAssertFalse(model.isPopoverEmpty)

        model.apply(settings: AppSettings(petEnabled: true, petReadyCounterEnabled: false))
        XCTAssertEqual(
            model.activeBadgeText,
            "2",
            "Active blue badge must remain visible when the red ready counter is disabled."
        )
        XCTAssertNil(model.badgeText)

        let attention = PetAttentionItem(
            id: "callback-1",
            kind: .callback(.approval, isStale: false),
            title: "Approval required",
            detail: nil,
            createdAt: Date(),
            route: .settings(.general),
            source: .notification(id: "callback-1")
        )
        model.apply(snapshot: PetAttentionSnapshot(items: [attention]))
        XCTAssertEqual(
            model.accessibilityValue,
            "2 active agent threads. 1 item needs attention"
        )

        model.apply(activeThreads: [])
        XCTAssertNil(model.activeBadgeText)
        XCTAssertEqual(model.accessibilityValue, "1 item needs attention")
        XCTAssertFalse(model.isPopoverEmpty)

        model.apply(snapshot: PetAttentionSnapshot(items: []))
        XCTAssertTrue(model.isPopoverEmpty)
        XCTAssertEqual(model.accessibilityValue, "No items need attention")
    }

    func test_activeThreadProjectorKeepsAuthoritativeMembershipWhenMetadataIsMissing() {
        let threadID = AgentThreadID(UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!)
        let items = PetActiveThreadProjector.items(threadIDs: [threadID]) { _ in nil }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].threadID, threadID)
        XCTAssertEqual(items[0].title, "Agent run in progress")
        XCTAssertNil(items[0].detail)
        if case .agentThread(let routedID, let workspaceID) = items[0].route {
            XCTAssertEqual(routedID, threadID)
            XCTAssertNil(workspaceID)
        } else {
            XCTFail("Active rows must route to their agent thread.")
        }
    }

    func test_placementStoreRoundTripsAndResetsNormalizedDisplayPosition() throws {
        let db = try database()
        let store = PetPlacementStore(repository: SettingsRepository(db: db))
        let placement = PetStoredPlacement(
            displayID: "display-2",
            position: PetNormalizedPosition(x: 0.25, y: 0.75)
        )

        store.save(placement)
        XCTAssertEqual(store.load(), placement)
        store.reset()
        XCTAssertNil(store.load())
    }

    func test_controllerRestoresAttentionSubscribesFromCurrentSequenceAndStopsCleanly() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetLifecycle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        var thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .completed,
            hasUnread: true
        )
        try context.threadRepo.upsert(thread)
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))

        let baselineSubscribers = EventBus.shared.subscriberCountForTests
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        XCTAssertEqual(controller.modelForTests.count, 1)
        XCTAssertFalse(controller.visualRuntimeIsLoadedForTests,
            "A disabled Pet must retain projection without decoding atlas assets or creating windows.")
        XCTAssertFalse(controller.togglePopoverFromKeyboard())
        XCTAssertEqual(EventBus.shared.subscriberCountForTests, baselineSubscribers + 1)

        EventBus.shared.publish(kind: "agent.run.started", payload: .object([
            "run_id": .string(UUID().uuidString)
        ]))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(controller.modelForTests.animationState, .coding)
        XCTAssertFalse(controller.animationTimerIsRunningForTests, "Disabled pet must not own a repeating timer.")

        controller.stop()
        XCTAssertEqual(EventBus.shared.subscriberCountForTests, baselineSubscribers)
        XCTAssertFalse(controller.animationTimerIsRunningForTests)

        thread = try XCTUnwrap(context.threadRepo.get(id: thread.id))
        XCTAssertTrue(thread.hasUnread, "Runtime observation must not clear attention without a verified route.")
    }

    func test_controllerProjectsActiveThreadsWithWorkspaceProviderAndRedactedTitle() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetActiveThreads-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let secretTitle = "Run rm -rf /Users/private Authorization: Bearer secret-token"
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: secretTitle,
            provider: .codex,
            model: "test",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        var previousHandlerInvocations = 0
        let previous = context.coordinator.onActiveRunProjectionChanged
        context.coordinator.onActiveRunProjectionChanged = { projection, cause in
            previous?(projection, cause)
            previousHandlerInvocations += 1
        }

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        XCTAssertEqual(controller.modelForTests.activeThreadCount, 0)
        XCTAssertNil(controller.modelForTests.activeBadgeText)

        let runID = AgentRunID()
        let projection = ActiveRunProjection(runs: [
            .init(threadId: thread.id, runId: runID),
            .init(threadId: thread.id, runId: AgentRunID())
        ])
        context.coordinator.onActiveRunProjectionChanged?(projection, .started)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(
            previousHandlerInvocations,
            1,
            "Pet must chain the existing ActiveRunProjection observer, not replace it."
        )
        XCTAssertEqual(
            controller.modelForTests.activeThreadCount,
            1,
            "Multiple run IDs for one thread still count as one active thread."
        )
        XCTAssertEqual(controller.modelForTests.activeBadgeText, "1")
        XCTAssertNil(
            controller.modelForTests.badgeText,
            "Red ready badge remains gated by petReadyCounterEnabled and independent of active runs."
        )
        let row = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertEqual(row.title, "Agent run in progress")
        // Display truncation + redaction keep credentials out of the always-on-top row.
        XCTAssertEqual(
            row.detail,
            "Pet - Codex - \(AgentThreadTitle.display(secretTitle))"
        )
        XCTAssertFalse(row.title.contains("rm -rf"))
        XCTAssertFalse(row.detail?.contains("secret-token") == true)
        XCTAssertFalse(controller.modelForTests.accessibilityValue.contains("secret-token"))

        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: []),
            .finished(.completed)
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.modelForTests.activeThreadCount, 0)
        XCTAssertNil(controller.modelForTests.activeBadgeText)
    }

    func test_itemStartedProgressRepublishKeepsElapsedAndUpdatesLastUpdatePreview() async throws {
        // WHY: material agent.item.started must refresh Live Activity last-update
        // preview without wiping startedAt (elapsed in pet detail / LA statusLine).
        // A prior path called applyActiveThreadIDs with an empty startedByThread
        // map and dropped the "1m" suffix on every tool event.
        let directory = NSTemporaryDirectory() + "RC2PetLAProgress-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "elephant", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "teste o funcionamento do distill",
            provider: .claude,
            model: "opus",
            status: .running,
            hasUnread: false
        )
        try context.threadRepo.upsert(thread)
        let runID = AgentRunID()
        let startedAt = Date().addingTimeInterval(-90)
        try context.runRepo.upsert(AgentRun(
            id: runID,
            threadId: thread.id,
            provider: .claude,
            model: "opus",
            status: .running,
            startedAt: startedAt
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReadyCounterEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        controller.start()
        defer { controller.stop() }

        context.coordinator.onActiveRunProjectionChanged?(
            ActiveRunProjection(runs: [.init(threadId: thread.id, runId: runID)]),
            .started
        )
        try await Task.sleep(nanoseconds: 40_000_000)

        let before = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertNil(before.lastUpdatePreview)
        XCTAssertTrue(
            before.detail?.contains("1m") == true,
            "projection with runRepo startedAt must embed elapsed; got \(before.detail ?? "nil")"
        )
        let detailBefore = before.detail

        EventBus.shared.publish(kind: "agent.item.started", payload: .object([
            "thread_id": .string(thread.id.value.uuidString),
            "item": .object([
                "id": .string("item-git"),
                "type": .string("commandExecution"),
                "summary": .string("git status"),
                "body": .string("git status --short")
            ])
        ]))
        try await Task.sleep(nanoseconds: 40_000_000)

        let after = try XCTUnwrap(controller.modelForTests.activeThreads.first)
        XCTAssertEqual(
            after.lastUpdatePreview,
            "git status",
            "item.started must land lastUpdatePreview for single-active LA description"
        )
        XCTAssertEqual(
            after.detail,
            detailBefore,
            "progress republish must preserve startedAt-derived elapsed detail"
        )
        XCTAssertTrue(after.detail?.contains("1m") == true)
    }

    func test_mergingStartedAtByThreadPreservesRetainedWhenIncomingEmpty() {
        let a = AgentThreadID(UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let b = AgentThreadID(UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        let merged = PetController.mergingStartedAtByThread(
            activeThreadIDs: [a],
            incoming: [:],
            retained: [a: t0, b: t1]
        )
        XCTAssertEqual(merged[a], t0, "empty incoming must keep retained startedAt for still-active threads")
        XCTAssertNil(merged[b], "inactive threads must leave the cache")

        let overridden = PetController.mergingStartedAtByThread(
            activeThreadIDs: [a],
            incoming: [a: t1],
            retained: [a: t0]
        )
        XCTAssertEqual(overridden[a], t1, "host projection startedAt wins when provided")
    }

    func test_controllerHydratesPersistentAttentionKindsBeforeRendering() throws {
        let directory = NSTemporaryDirectory() + "RC2PetHydration-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let fileSurface = try router.createSurface(
            workspace: workspace.id,
            type: .browser,
            paneID: nil,
            title: "Files"
        )
        defer { try? router.closeSurface(workspace: workspace.id, surface: fileSurface.id) }
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .running
        )
        try context.threadRepo.upsert(thread)
        try context.providerPendingCallbackRepo.record(
            threadId: thread.id,
            request: AssistantPendingRequest(
                id: "approval-1",
                turnId: "turn-1",
                kind: .commandExecution,
                title: "private command",
                detail: "private detail",
                createdAtMs: 1_000
            )
        )
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "conflict-1",
            workspaceId: workspace.id,
            surfaceId: fileSurface.id,
            title: "private path",
            category: PetNotificationCategory.fileConflict.rawValue
        ))
        try NotificationRepository(db: context.db).insert(AppNotification(
            id: "server-1",
            title: "private listener error",
            category: PetNotificationCategory.serverListenerFailed.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 3)
        XCTAssertEqual(
            controller.modelForTests.animationState,
            .approval,
            "A restored approval/file conflict must outrank generic waiting and reconnecting."
        )
    }

    func test_routerThreadReadEventRefreshesTheVisibleCounter() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetThreadRead-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .completed,
            hasUnread: true
        )
        try context.threadRepo.upsert(thread)
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()
        XCTAssertEqual(controller.modelForTests.count, 1)

        try router.markAgentThreadRead(thread: thread.id)
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(controller.modelForTests.count, 0)
    }

    func test_controllerCapturesCursorBeforeRefreshAndReplaysOnlyNewStartupBacklog() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetCursor-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))

        EventBus.shared.publish(kind: "git.push", payload: .object([
            "workspace_id": .string(UUID().uuidString),
            "ok": .bool(false)
        ]))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.afterStartupCursorCapturedForTests = {
            EventBus.shared.publish(kind: "agent.run.started", payload: .object([
                "run_id": .string(UUID().uuidString)
            ]))
        }

        controller.start()
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(
            controller.modelForTests.count,
            0,
            "A first-start watermark must not project terminal history published before its cursor."
        )
        XCTAssertEqual(
            controller.modelForTests.animationState,
            .coding,
            "The post-cursor startup event must replay, while pre-cursor terminal history stays excluded."
        )
    }

    func test_controllerProcessesConcurrentLiveEventsInSequenceOrder() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetOrderedEvents-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    EventBus.shared.publish(kind: "agent.run.started", payload: .object([
                        "run_id": .string(UUID().uuidString)
                    ]))
                }
            }
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(
            controller.handledEventOutOfOrderForTests,
            "The Pet reducer must observe the EventBus sequence monotonically under concurrent publication."
        )
        XCTAssertEqual(controller.handledEventCountForTests, 100,
            "Every concurrent meaningful event must reach the reducer exactly once.")
    }

    func test_highRateNoiseBurstIsPrefilteredBeforeMainActor() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetOutputPrefilter-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        for _ in 0..<250 {
            EventBus.shared.publish(kind: "surface.output", payload: .object([:]))
            EventBus.shared.publish(kind: "agent.item.delta", payload: .object([:]))
            EventBus.shared.publish(kind: "agent.item.progress", payload: .object([:]))
            EventBus.shared.publish(kind: "agent.account.usage", payload: .object([:]))
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(
            controller.handledEventCountForTests,
            0,
            "High-rate reducer noise must be discarded before dispatching work to MainActor."
        )
    }

    func test_controllerReplaysPersistedTerminalBeyondRecentRingWithoutAnimatingIt() throws {
        let directory = NSTemporaryDirectory() + "RC2PetProjectionRecovery-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let baseline = EventBus.shared.currentSeq
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(baseline))
        let terminalPayload = JSONValue.object([
            "workspace_id": .string(UUID().uuidString),
            "ok": .bool(false)
        ])
        let terminalSequence = baseline + 1
        let terminalJSON = String(
            decoding: try JSONEncoder().encode(terminalPayload),
            as: UTF8.self
        )
        try context.eventLog.append(
            seq: terminalSequence,
            kind: "git.push",
            payloadJSON: terminalJSON
        )
        var noiseEvents: [EventBus.Event] = []
        for offset in 1...300 {
            let sequence = terminalSequence + Int64(offset)
            try context.eventLog.append(
                seq: sequence,
                kind: "agent.account.usage",
                payloadJSON: "{}"
            )
            noiseEvents.append(EventBus.Event(
                seq: sequence,
                kind: "agent.account.usage",
                payload: .object([:]),
                ts: Date().timeIntervalSince1970
            ))
        }
        let capturedSequence = terminalSequence + 300
        EventBus.shared.reloadFromPersistence(
            lastSeq: capturedSequence,
            recent: Array(noiseEvents.suffix(256))
        )

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 1)
        XCTAssertEqual(
            controller.modelForTests.animationState,
            .waiting,
            "Recovery projects durable attention without replaying an old failure animation."
        )
        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(capturedSequence),
            "A successful paged scan advances through non-candidate rows after projecting every candidate."
        )
        XCTAssertEqual(
            try NotificationRepository(db: context.db).list(unreadOnly: true).map(\.id),
            ["pet.event.\(terminalSequence)"]
        )
    }

    func test_projectionRecoveryAdvancesAcrossPersistedNoiseWhenNoCandidateExists() throws {
        let directory = NSTemporaryDirectory() + "RC2PetProjectionNoise-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let baseline = EventBus.shared.currentSeq
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(baseline))
        let noiseSequence = baseline + 1
        try context.eventLog.append(
            seq: noiseSequence,
            kind: "agent.account.usage",
            payloadJSON: "{}"
        )
        EventBus.shared.reloadFromPersistence(lastSeq: noiseSequence, recent: [])

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 0)
        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(noiseSequence)
        )
    }

    func test_projectionRecoveryFailureSurvivesInitialAttentionRefresh() throws {
        let directory = NSTemporaryDirectory() + "RC2PetProjectionFailure-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let baseline = EventBus.shared.currentSeq
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(baseline))
        let corruptSequence = baseline + 1
        try context.eventLog.append(
            seq: corruptSequence,
            kind: "git.push",
            payloadJSON: "{"
        )
        EventBus.shared.reloadFromPersistence(lastSeq: corruptSequence, recent: [])

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.routeError, "A ready item could not be restored.")
        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(baseline),
            "A failed candidate must remain behind the watermark for the next recovery attempt."
        )
    }

    func test_projectionRecoveryNeverRewindsWatermarkWhenDurableLogIsAhead() throws {
        let directory = NSTemporaryDirectory() + "RC2PetWatermarkAhead-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: false))
        let capturedCursor = EventBus.shared.currentSeq
        let storedWatermark = capturedCursor + 20
        try context.settingsRepo.set(PetController.projectionWatermarkKey, String(storedWatermark))
        try context.eventLog.append(
            seq: capturedCursor + 50,
            kind: "git.push",
            payloadJSON: "{}"
        )

        let controller = try PetController(context: context, router: router, openSettings: { _ in false })
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(
            try context.settingsRepo.get(PetController.projectionWatermarkKey),
            String(storedWatermark),
            "A low in-memory cursor must not rewind durable projection state."
        )
        XCTAssertNotNil(controller.modelForTests.routeError)
    }

    func test_settingsRouteRemainsUnreadWhenExactSettingsOpenCannotBeVerified() throws {
        let directory = NSTemporaryDirectory() + "RC2PetSettingsRoute-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(
            id: "provider-update",
            title: "private provider error",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
        var requestedRoute: PetSettingsRoute?
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { route in
                requestedRoute = route
                return false
            }
        )
        defer { controller.stop() }
        controller.start()

        let item = try XCTUnwrap(controller.modelForTests.items.first)
        controller.windowControllerForTests.onOpenItem?(item)

        XCTAssertEqual(requestedRoute, .providers)
        XCTAssertEqual(try repository.list(unreadOnly: true).map(\.id), ["provider-update"])
        XCTAssertNotNil(controller.modelForTests.routeError)
    }

    func test_successfulRouteDismissalKeepsVerifiedDestinationKey() throws {
        let directory = NSTemporaryDirectory() + "RC2PetRouteDismiss-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(
            id: "provider-update-success-route",
            title: "private provider error",
            category: PetNotificationCategory.providerUpdateFailed.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { $0 == .providers }
        )
        defer { controller.stop() }
        controller.start()
        let previous = PetLifecycleRecordingKeyWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        controller.windowControllerForTests.keyWindowProviderForTests = { previous }
        controller.windowControllerForTests.openPopoverForTests()

        let item = try XCTUnwrap(controller.modelForTests.items.first)
        controller.windowControllerForTests.onOpenItem?(item)

        XCTAssertEqual(previous.restoreCount, 0)
        XCTAssertTrue(try repository.list(unreadOnly: true).isEmpty)
        XCTAssertFalse(controller.windowControllerForTests.isPopoverVisible)
    }

    /// WHY: "Mark all viewed" must clear completed outcomes and dismiss Ready for you only.
    /// Leaving the empty popover open (or re-opening it) is the failure mode users hit after bulk clear.
    func test_markAllViewed_marksOutcomesAndClosesPopoverWithoutReopening() throws {
        let directory = NSTemporaryDirectory() + "RC2PetMarkAllDismiss-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "Pet", cwd: NSTemporaryDirectory())
        let thread = AgentThread(
            workspaceId: workspace.id,
            title: "private prompt",
            provider: .codex,
            model: "test",
            status: .completed,
            hasUnread: true
        )
        try context.threadRepo.upsert(thread)
        let repository = NotificationRepository(db: context.db)
        try repository.insert(AppNotification(
            id: "git-completed-mark-all",
            workspaceId: workspace.id,
            title: "private git path",
            category: PetNotificationCategory.gitCompleted.rawValue
        ))
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false }
        )
        defer { controller.stop() }
        controller.start()

        XCTAssertEqual(controller.modelForTests.count, 2)
        controller.windowControllerForTests.openPopoverForTests()
        XCTAssertTrue(controller.windowControllerForTests.isPopoverVisible)

        controller.windowControllerForTests.onMarkAllViewed?()

        XCTAssertFalse(
            controller.windowControllerForTests.isPopoverVisible,
            "Mark all viewed must close Ready for you; it must not leave or reopen the empty panel."
        )
        XCTAssertEqual(controller.modelForTests.count, 0)
        XCTAssertFalse(try XCTUnwrap(context.threadRepo.get(id: thread.id)).hasUnread)
        XCTAssertTrue(try repository.list(unreadOnly: true).isEmpty)
        XCTAssertNil(controller.modelForTests.routeError)
    }

    func test_noiseDoesNotPostponeIdleSleep() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetNoiseIdle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReduceMotion: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false },
            idleTimeoutNanoseconds: 15_000_000
        )
        defer { controller.stop() }
        controller.start()

        for _ in 0..<5 {
            EventBus.shared.publish(kind: "agent.account.usage", payload: .object([:]))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(
            controller.modelForTests.animationState,
            .sleeping,
            "Ignored usage noise must not keep an otherwise idle pet awake."
        )
    }

    func test_controllerSleepsAfterIdleAndPetInteractionWakesIt() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetIdle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReduceMotion: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false },
            idleTimeoutNanoseconds: 10_000_000
        )
        defer { controller.stop() }

        controller.start()
        let panel = try XCTUnwrap(controller.windowControllerForTests.petPanelForTests)
        let screen = try XCTUnwrap(panel.screen ?? NSScreen.main)
        let placementFrame = PetScreenGeometry.petPlacementFrame(
            screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(
            PetPlacement.frame(
                size: panel.frame.size,
                normalizedPosition: PetNormalizedPosition(x: 0, y: 0),
                in: placementFrame
            ),
            display: false
        )
        let idleSize = panel.frame.size
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.modelForTests.animationState, .sleeping)
        XCTAssertNotEqual(panel.frame.size, idleSize,
            "the controller frame callback must resize the window to the sleeping visual envelope")
        XCTAssertEqual(panel.frame.minX, placementFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)

        controller.windowControllerForTests.onInteraction?()
        XCTAssertEqual(controller.modelForTests.animationState, .idle)
        XCTAssertEqual(panel.frame.width, idleSize.width, accuracy: 0.001)
        XCTAssertEqual(panel.frame.height, idleSize.height, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minX, placementFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, placementFrame.minY, accuracy: 0.001)

        XCTAssertTrue(controller.togglePopoverFromKeyboard())
        XCTAssertTrue(controller.windowControllerForTests.isVisible)
        XCTAssertTrue(controller.windowControllerForTests.isPopoverVisible)
        XCTAssertTrue(controller.togglePopoverFromKeyboard())
        XCTAssertFalse(controller.windowControllerForTests.isPopoverVisible)
    }

    func test_systemWakeClearsSleepAndRearmsIdleDeadline() async throws {
        let directory = NSTemporaryDirectory() + "RC2PetWakeIdle-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        SettingsStore(db: context.db).save(AppSettings(petEnabled: true, petReduceMotion: true))
        let controller = try PetController(
            context: context,
            router: router,
            openSettings: { _ in false },
            idleTimeoutNanoseconds: 10_000_000
        )
        defer { controller.stop() }
        controller.start()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.modelForTests.animationState, .sleeping)

        controller.handleSystemWake()
        XCTAssertEqual(controller.modelForTests.animationState, .idle)
        for _ in 0..<40 {
            if controller.modelForTests.animationState == .sleeping { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(controller.modelForTests.animationState, .sleeping,
            "Wake must rearm the idle deadline instead of leaving the Pet permanently awake.")
    }
}

@MainActor
private final class PetLifecycleRecordingKeyWindow: NSWindow {
    private(set) var restoreCount = 0
    override var isVisible: Bool { true }
    override var canBecomeKey: Bool { true }
    override func makeKeyAndOrderFront(_ sender: Any?) { restoreCount += 1 }
}
