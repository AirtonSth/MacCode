import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel
@testable import Surfaces

/// WHY: a bot Desk popped out with "Open in New Window" is a single-purpose
/// window with no tabs of its own, but ⌘W/⌘D are menu key equivalents built
/// with `target = self` on `AppDelegate` and handed to the main window
/// controller with the key window as the claimed target. `MainWindowController`
/// only knew how to resolve *workspace* windows (`detachedWindowController`),
/// so a key bot window fell through to the main window's selected workspace:
/// ⌘W closed a tab the user cannot see — `permanentlyCloseRuntimeSurface` runs
/// `closeAndDeletePersistedHistory()` and unregisters, so scrollback died with
/// nothing on screen explaining it — and ⌘D split that off-screen pane.
///
/// `AppDelegate.keyWindowProviderForTests` is the seam
/// `SettingsWindowCloseRoutingTests` and `DetachedWorkspaceKeyboardTargetTests`
/// already use to declare which window owns the keyboard, so these specs drive
/// the real menu actions through `NSApp.sendAction` exactly like the menu does.
@MainActor
final class BotWindowKeyboardTargetTests: XCTestCase {
    override func tearDown() {
        for window in Array(NSApplication.shared.windows) {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            if let parent = window.sheetParent { parent.endSheet(window) }
        }
        for window in Array(NSApplication.shared.windows) { window.orderOut(nil) }
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        super.tearDown()
    }

    func test_closeShortcut_withABotWindowFocused_closesTheBotWindow_notTheMainWorkspaceTab() throws {
        let fixture = try BotWindowKeyboardFixture(prefix: "close")
        defer { fixture.cleanup() }

        let before = fixture.mainSurfaceIDs
        XCTAssertEqual(before.count, 2, "precondition: the main workspace needs a tab for a wrongly routed ⌘W to destroy")

        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("closeActiveTabOrWindow"), to: fixture.delegate, from: nil),
            "⌘W must stay reachable through the AppDelegate responder"
        )
        fixture.drainMainQueue()

        XCTAssertEqual(
            fixture.mainSurfaceIDs, before,
            "⌘W over a bot window must not close a tab of the main window's workspace"
        )
        XCTAssertFalse(
            fixture.botWindow.isVisible,
            "⌘W must close the bot window the user is looking at"
        )
    }

    func test_splitShortcut_withABotWindowFocused_leavesTheMainWorkspacePanesAlone() throws {
        let fixture = try BotWindowKeyboardFixture(prefix: "split")
        defer { fixture.cleanup() }

        XCTAssertEqual(
            fixture.mainPaneIDs.count, 1,
            "precondition: the main workspace must start with a single pane"
        )

        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("splitFocusedPaneRight"), to: fixture.delegate, from: nil),
            "⌘D must stay reachable through the AppDelegate responder"
        )
        fixture.drainMainQueue()

        XCTAssertEqual(
            fixture.mainPaneIDs.count, 1,
            "⌘D over a bot window must not split a pane of the main window's workspace"
        )
        XCTAssertTrue(fixture.botWindow.isVisible, "⌘D must not close the bot window")
    }

    func test_tabNumberShortcut_withABotWindowFocused_leavesTheMainWorkspaceTabAlone() throws {
        let fixture = try BotWindowKeyboardFixture(prefix: "tab-number")
        defer { fixture.cleanup() }

        // Deterministic start: tab #1 selected, so a wrongly routed ⌘2 would
        // move the selection to tab #2 and the assertion below would fail.
        try fixture.router.focusSurface(workspace: fixture.mainWorkspaceID, surface: fixture.mainSurfaceIDs[0])
        fixture.drainMainQueue()
        let selectedBefore = fixture.mainSelectedSurfaceID
        XCTAssertEqual(
            selectedBefore, fixture.mainSurfaceIDs[0],
            "precondition: ⌘2 must have a different tab to move the main workspace to"
        )

        let item = NSMenuItem()
        item.tag = 2
        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("selectTabByNumber:"), to: fixture.delegate, from: item),
            "⌘2 must stay reachable through the AppDelegate responder"
        )
        fixture.drainMainQueue()

        XCTAssertEqual(
            fixture.mainSelectedSurfaceID, selectedBefore,
            "⌘2 over a bot window must not select a tab of the main window's workspace"
        )
    }
}

@MainActor
private final class BotWindowKeyboardFixture {
    let directory: String
    let context: AppContext
    let router: AppCommandRouter
    let main: MainWindowController
    let delegate: AppDelegate
    let mainWorkspaceID: WorkspaceID
    let botWindow: NSWindow
    let botID: BotID
    private var trackedSurfaceIDs: Set<SurfaceID> = []

    init(prefix: String) throws {
        directory = NSTemporaryDirectory() + "RC2BotWindowKeys-\(prefix)-" + UUID().uuidString
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

        // Two tabs: a wrongly routed ⌘W always has a tab to destroy.
        let workspace = try router.createWorkspace(name: "MAIN-KEEPS", cwd: NSTemporaryDirectory())
        mainWorkspaceID = workspace.id
        _ = try router.createSurface(workspace: workspace.id, type: .browser, paneID: nil, title: "main-2")
        try router.selectWorkspace(workspace.id)
        main.refreshFromState()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        let bot = try BotsViewModel(context: context, router: router).create(name: "Piper", title: "Scout", provider: .claude)
        botID = bot.id
        main.openBotInNewWindow(bot.id)
        let window = try XCTUnwrap(
            main.botWindow(for: bot.id),
            "the detached bot window must exist for the keyboard routing to be exercised"
        )
        botWindow = window
        XCTAssertFalse(window === main.window, "the bot desk must live in its own window, not in the main window")

        // The keyboard owner for every command below.
        delegate.keyWindowProviderForTests = { window }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        trackSurfaces()
        try assertPanesAreMounted(in: main.window, "the main window's panes must be mounted, otherwise a wrongly routed ⌘W would have no tab to close")
    }

    var mainSurfaceIDs: [SurfaceID] {
        guard let workspace = context.state.workspaces[mainWorkspaceID] else { return [] }
        return workspace.layout.paneIDs().flatMap { workspace.layout.find(paneID: $0)?.surfaces.map(\.id) ?? [] }
    }

    var mainPaneIDs: [PaneID] {
        context.state.workspaces[mainWorkspaceID]?.layout.paneIDs() ?? []
    }

    var mainSelectedSurfaceID: SurfaceID? {
        guard let workspace = context.state.workspaces[mainWorkspaceID],
              let paneID = workspace.focusedPaneID ?? workspace.layout.paneIDs().first else { return nil }
        return workspace.layout.find(paneID: paneID)?.selectedSurfaceID
    }

    func drainMainQueue(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func cleanup() {
        main.window.orderOut(nil)
        for workspaceID in context.state.workspaces.keys {
            main.workspaceWindow(for: workspaceID)?.orderOut(nil)
        }
        main.botWindow(for: botID)?.orderOut(nil)
        for surfaceID in trackedSurfaceIDs {
            SurfaceRegistry.shared.surface(surfaceID)?.close()
            SurfaceRegistry.shared.unregister(surfaceID)
        }
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func trackSurfaces() {
        trackedSurfaceIDs.formUnion(mainSurfaceIDs)
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
