import AppKit
import XCTest
@testable import AppShell

final class AppLifecycleTests: XCTestCase {
    @MainActor func test_lastWindowCloseDoesNotTerminateLongRunningTerminalSessions() {
        let delegate = AppDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared),
            "closing the last macOS window must leave RemoteCode running so long terminal/agent sessions are not killed and the window can be reopened"
        )
    }

    @MainActor func test_mainWindowCloseHidesWindowInsteadOfDestroyingAppSession() throws {
        let tmp = NSTemporaryDirectory() + "RC2Lifecycle-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller

        controller.show()

        XCTAssertFalse(
            controller.windowShouldClose(controller.window),
            "the red close button must hide the main window instead of allowing AppKit to close the last window and terminate long-running terminal or agent work"
        )
        XCTAssertFalse(
            controller.window.isVisible,
            "close should leave RemoteCode reopenable without destroying the existing app session"
        )

        controller.window.orderOut(nil)
    }
}
