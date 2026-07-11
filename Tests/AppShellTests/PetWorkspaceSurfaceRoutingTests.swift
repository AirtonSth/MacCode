import AppKit
import XCTest
@testable import AppShell
import CoreModel
import Persistence
import Surfaces

/// Exercises the Pet's existing `onOpenItem` seam so persistence is cleared only
/// after the exact main or detached destination is mounted and visible.
@MainActor
final class PetWorkspaceSurfaceRoutingTests: XCTestCase {
    func test_mainWorkspaceRouteClearsOnlyAfterSelectingExactVisibleWindow() throws {
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

    func test_detachedWorkspaceRoutePreservesMainSelectionAndClearsAfterActivation() throws {
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
        let staleSurfaceID = SurfaceID(UUID())
        try fixture.notifications.insert(AppNotification(
            id: "stale-workspace",
            workspaceId: staleWorkspaceID,
            title: "unsafe git detail",
            category: PetNotificationCategory.gitCompleted.rawValue,
            createdAt: Date(timeIntervalSince1970: 200)
        ))
        try fixture.notifications.insert(AppNotification(
            id: "stale-surface",
            workspaceId: existingWorkspace.id,
            surfaceId: staleSurfaceID,
            title: "unsafe script detail",
            category: PetNotificationCategory.projectScriptCompleted.rawValue,
            createdAt: Date(timeIntervalSince1970: 100)
        ))

        let pet = try fixture.startPet()
        defer { pet.stop() }
        fixture.open(itemID: "notification:stale-workspace", with: pet)
        fixture.open(itemID: "notification:stale-surface", with: pet)

        XCTAssertEqual(
            Set(try fixture.notifications.list(unreadOnly: true).map(\.id)),
            Set(["stale-workspace", "stale-surface"]),
            "Missing exact destinations must never acknowledge ready items the user could not inspect."
        )
        XCTAssertEqual(pet.modelForTests.count, 2)
        XCTAssertEqual(
            pet.modelForTests.routeError,
            "The exact destination could not be opened. The item was kept."
        )
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
        while !drained, RunLoop.main.run(mode: .default, before: deadline) {}
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
