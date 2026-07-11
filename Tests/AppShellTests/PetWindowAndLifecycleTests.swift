import AppKit
import XCTest
@testable import AppShell
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
        panel.setFrame(
            PetPlacement.frame(
                size: panel.frame.size,
                normalizedPosition: PetNormalizedPosition(x: 0, y: 0),
                in: screen.visibleFrame
            ),
            display: false
        )

        let sleeping = try atlas.canonicalFrame(for: .sleeping)
        model.setFrame(sleeping)
        controller.animationFrameDidChange()

        XCTAssertEqual(panel.frame.minX, screen.visibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY, accuracy: 0.001)
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
        panel.setFrame(
            PetPlacement.frame(
                size: panel.frame.size,
                normalizedPosition: PetNormalizedPosition(x: 0, y: 0),
                in: screen.visibleFrame
            ),
            display: false
        )
        let idleSize = panel.frame.size
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(controller.modelForTests.animationState, .sleeping)
        XCTAssertNotEqual(panel.frame.size, idleSize,
            "the controller frame callback must resize the window to the sleeping visual envelope")
        XCTAssertEqual(panel.frame.minX, screen.visibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY, accuracy: 0.001)

        controller.windowControllerForTests.onInteraction?()
        XCTAssertEqual(controller.modelForTests.animationState, .idle)
        XCTAssertEqual(panel.frame.width, idleSize.width, accuracy: 0.001)
        XCTAssertEqual(panel.frame.height, idleSize.height, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minX, screen.visibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(panel.frame.minY, screen.visibleFrame.minY, accuracy: 0.001)

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
