import AppKit
import XCTest
@testable import AppShell

@MainActor
final class MainWindowAppearanceAndFocusTests: XCTestCase {
    private var retainedWindows: [NSWindow] = []

    override func tearDown() {
        for window in retainedWindows {
            window.orderOut(nil)
        }
        retainedWindows.removeAll()
        super.tearDown()
    }

    func test_applicationForcesDarkAppearanceRegardlessOfSystemTheme() {
        let app = NSApplication.shared
        let previousAppearance = app.appearance
        defer { app.appearance = previousAppearance }

        RemoteCodeAppearance.apply(to: app)

        XCTAssertEqual(
            app.appearance?.name,
            .darkAqua,
            "RemoteCode must set a dark app appearance so new windows inherit dark controls even under macOS light mode."
        )
    }

    func test_mainWindowForcesDarkAppearanceRegardlessOfSystemTheme() throws {
        let (context, router) = try makeContextAndRouter()
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        retainedWindows.append(controller.window)

        XCTAssertEqual(
            controller.window.appearance?.name,
            .darkAqua,
            "RemoteCode must force dark chrome so macOS light mode cannot make the sidebar/window render as a white surface."
        )
    }

    func test_sidebarForcesDarkAppearanceRegardlessOfSystemTheme() throws {
        let (context, router) = try makeContextAndRouter()
        let sidebar = SidebarView(context: context, router: router)

        XCTAssertEqual(
            sidebar.view.appearance?.name,
            .darkAqua,
            "Sidebar hosting must force dark appearance so SwiftUI/AppKit controls do not inherit macOS light mode."
        )
    }

    func test_unrelatedTextViewDoesNotBlockTerminalFocusRepair() throws {
        let (context, router) = try makeContextAndRouter()
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        retainedWindows.append(controller.window)

        let unrelatedTextView = NSTextView(frame: NSRect(x: 8, y: 8, width: 160, height: 32))
        controller.window.contentView?.addSubview(unrelatedTextView)
        XCTAssertTrue(controller.window.makeFirstResponder(unrelatedTextView))

        XCTAssertFalse(
            controller.hasProtectedInputFocus,
            "Only workspace text editing should block terminal focus repair; sidebar/search focus must not leave terminal TUI digits and arrow keys inert."
        )
    }

    func test_workspaceTextViewStillBlocksTerminalFocusRepair() {
        let workspaceContent = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        let workspaceTextView = NSTextView(frame: NSRect(x: 8, y: 8, width: 160, height: 32))
        workspaceContent.addSubview(workspaceTextView)

        XCTAssertTrue(
            MainWindowController.protectedTextFocusOwner(
                firstResponder: workspaceTextView,
                within: workspaceContent
            ) === workspaceTextView,
            "Active workspace text editing should remain protected so focus repair does not steal input from in-pane editors."
        )
    }

    private func makeContextAndRouter() throws -> (AppContext, AppCommandRouter) {
        let dir = NSTemporaryDirectory() + "RC2AppearanceFocus-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router)
    }
}
