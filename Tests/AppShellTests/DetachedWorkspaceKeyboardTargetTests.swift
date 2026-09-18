import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel
@testable import Surfaces

/// WHY: a workspace detached into its own window owns its own `PaneTabsView`
/// controllers, but ⌘W/⌘D are menu key equivalents built with `target = self`
/// on `AppDelegate`, which used to hand them straight to the main window
/// controller. With the main window showing workspace A and a detached window
/// showing workspace W on screen, ⌘W pressed over W closed a tab of A:
/// `AppCommandRouter.closeSurfaces` reaches `permanentlyCloseRuntimeSurface`,
/// which runs `closeAndDeletePersistedHistory()` on the surface and unregisters
/// it, so the scrollback died with nothing on screen explaining why. ⌘D split
/// A's pane off-screen for the same reason.
///
/// `AppDelegate.keyWindowProviderForTests` is the seam
/// `SettingsWindowCloseRoutingTests` already uses to declare which window owns
/// the keyboard, so these specs drive the real menu actions
/// (`closeActiveTabOrWindow`, `splitFocusedPaneRight`) through
/// `NSApp.sendAction` exactly like the menu does.
@MainActor
final class DetachedWorkspaceKeyboardTargetTests: XCTestCase {
    func test_closeShortcut_closesTheTabOfTheKeyDetachedWindow_notTheMainWorkspace() throws {
        let fixture = try DetachedKeyboardFixture(prefix: "close")
        defer { fixture.cleanup() }

        let mainBefore = fixture.surfaceIDs(in: fixture.mainWorkspaceID)
        let detachedBefore = fixture.surfaceIDs(in: fixture.detachedWorkspaceID)
        let detachedTarget = try fixture.focusedSurfaceID(in: fixture.detachedWorkspaceID)
        XCTAssertEqual(mainBefore.count, 2, "precondition: the main workspace needs a tab for a wrongly routed ⌘W to destroy")
        XCTAssertEqual(detachedBefore.count, 2, "precondition: the detached window needs a tab for ⌘W to close")

        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("closeActiveTabOrWindow"), to: fixture.delegate, from: nil),
            "⌘W must stay reachable through the AppDelegate responder"
        )
        fixture.drainMainQueue()

        XCTAssertEqual(
            fixture.surfaceIDs(in: fixture.mainWorkspaceID), mainBefore,
            "⌘W over the detached window must not close a tab of the main window's workspace"
        )
        XCTAssertEqual(
            fixture.surfaceIDs(in: fixture.detachedWorkspaceID),
            detachedBefore.filter { $0 != detachedTarget },
            "⌘W must close the focused tab of the window the user is looking at"
        )
        XCTAssertTrue(
            fixture.detachedWindow.isVisible,
            "⌘W must not close the detached window while it still had a tab to close"
        )
    }

    func test_splitShortcut_splitsTheKeyDetachedWindow_notTheMainWorkspace() throws {
        let fixture = try DetachedKeyboardFixture(prefix: "split")
        defer { fixture.cleanup() }

        let mainPanesBefore = fixture.paneIDs(in: fixture.mainWorkspaceID)
        let detachedPanesBefore = fixture.paneIDs(in: fixture.detachedWorkspaceID)
        XCTAssertEqual(mainPanesBefore.count, 1, "precondition: the main workspace must start with a single pane")
        XCTAssertEqual(detachedPanesBefore.count, 1, "precondition: the detached workspace must start with a single pane")

        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("splitFocusedPaneRight"), to: fixture.delegate, from: nil),
            "⌘D must stay reachable through the AppDelegate responder"
        )
        fixture.drainMainQueue()

        XCTAssertEqual(
            fixture.paneIDs(in: fixture.mainWorkspaceID), mainPanesBefore,
            "⌘D over the detached window must not split a pane of the main window's workspace"
        )
        XCTAssertEqual(
            fixture.paneIDs(in: fixture.detachedWorkspaceID).count, detachedPanesBefore.count + 1,
            "⌘D must split the focused pane of the window the user is looking at"
        )
    }

    func test_tabShortcut_stepsTheTabsOfTheKeyDetachedWindow_notTheMainWorkspace() throws {
        let fixture = try DetachedKeyboardFixture(prefix: "tabs")
        defer { fixture.cleanup() }

        let mainSelectedBefore = try fixture.focusedSurfaceID(in: fixture.mainWorkspaceID)
        let detachedSelectedBefore = try fixture.focusedSurfaceID(in: fixture.detachedWorkspaceID)

        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("selectNextTab"), to: fixture.delegate, from: nil),
            "⌘⇧] must stay reachable through the AppDelegate responder"
        )
        fixture.drainMainQueue()

        XCTAssertEqual(
            try fixture.focusedSurfaceID(in: fixture.mainWorkspaceID), mainSelectedBefore,
            "⌘⇧] over the detached window must not step the tabs of the main window's workspace"
        )
        XCTAssertNotEqual(
            try fixture.focusedSurfaceID(in: fixture.detachedWorkspaceID), detachedSelectedBefore,
            "⌘⇧] must step the tabs of the window the user is looking at"
        )
    }
}

@MainActor
private final class DetachedKeyboardFixture {
    let directory: String
    let context: AppContext
    let router: AppCommandRouter
    let main: MainWindowController
    let delegate: AppDelegate
    let mainWorkspaceID: WorkspaceID
    let detachedWorkspaceID: WorkspaceID
    let detachedWindow: NSWindow
    private var trackedSurfaceIDs: Set<SurfaceID> = []

    init(prefix: String) throws {
        directory = NSTemporaryDirectory() + "RC2DetachedKeys-\(prefix)-" + UUID().uuidString
        context = try AppContext(channel: .debug, appSupportOverride: directory)
        router = AppCommandRouter(context: context)
        context.router = router
        main = MainWindowController(context: context, router: router)
        router.windowController = main
        main.window.animationBehavior = .none
        delegate = AppDelegate(channel: .debug, appSupportOverride: directory)
        delegate.context = context
        delegate.router = router
        delegate.windowController = main

        // Two tabs per workspace: a wrongly routed ⌘W always has a tab to
        // destroy, and a correctly closed tab leaves the window a pane.
        let mainWorkspace = try router.createWorkspace(name: "MAIN-KEEPS", cwd: NSTemporaryDirectory())
        mainWorkspaceID = mainWorkspace.id
        _ = try router.createSurface(workspace: mainWorkspace.id, type: .browser, paneID: nil, title: "main-2")

        let detachedWorkspace = try router.createWorkspace(name: "DETACHED-OWNS", cwd: NSTemporaryDirectory())
        detachedWorkspaceID = detachedWorkspace.id
        _ = try router.createSurface(workspace: detachedWorkspace.id, type: .browser, paneID: nil, title: "detached-2")

        // The main window keeps its own workspace selected while the second one
        // lives in a detached window.
        try router.selectWorkspace(mainWorkspaceID)
        main.refreshFromState()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        main.openWorkspaceInNewWindow(detachedWorkspaceID)
        let window = try XCTUnwrap(
            main.workspaceWindow(for: detachedWorkspaceID),
            "the detached workspace window must exist for the keyboard routing to be exercised"
        )
        detachedWindow = window
        XCTAssertFalse(window === main.window, "the detached workspace must live in its own window, not in the main window")

        // The keyboard owner for every command below.
        delegate.keyWindowProviderForTests = { window }
        main.refreshFromState()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        trackSurfaces(in: mainWorkspaceID)
        trackSurfaces(in: detachedWorkspaceID)
        try assertPanesAreMounted(in: main.window, "the main window's panes must be mounted, otherwise a wrongly routed ⌘W would have no tab to close")
        try assertPanesAreMounted(in: window, "the detached window's panes must be mounted, otherwise a correctly routed ⌘W would have no tab to close")
    }

    func drainMainQueue(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func focusedSurfaceID(in workspaceID: WorkspaceID) throws -> SurfaceID {
        let workspace = try XCTUnwrap(context.state.workspaces[workspaceID])
        let paneID = try XCTUnwrap(workspace.focusedPaneID)
        return try XCTUnwrap(workspace.layout.find(paneID: paneID)?.selectedSurfaceID)
    }

    func surfaceIDs(in workspaceID: WorkspaceID) -> [SurfaceID] {
        guard let workspace = context.state.workspaces[workspaceID] else { return [] }
        return workspace.layout.paneIDs().flatMap { workspace.layout.find(paneID: $0)?.surfaces.map(\.id) ?? [] }
    }

    func paneIDs(in workspaceID: WorkspaceID) -> [PaneID] {
        context.state.workspaces[workspaceID]?.layout.paneIDs() ?? []
    }

    func cleanup() {
        main.window.orderOut(nil)
        for workspaceID in context.state.workspaces.keys {
            main.workspaceWindow(for: workspaceID)?.orderOut(nil)
        }
        for surfaceID in trackedSurfaceIDs {
            SurfaceRegistry.shared.surface(surfaceID)?.close()
            SurfaceRegistry.shared.unregister(surfaceID)
        }
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func trackSurfaces(in workspaceID: WorkspaceID) {
        trackedSurfaceIDs.formUnion(surfaceIDs(in: workspaceID))
    }

    private func assertPanesAreMounted(in window: NSWindow, _ message: String) throws {
        let content = try XCTUnwrap(window.contentView)
        XCTAssertFalse(
            allSubviews(of: content).filter { $0.accessibilityIdentifier() == "pane.overflowMenu" }.isEmpty,
            "precondition: \(message)"
        )
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }
}
