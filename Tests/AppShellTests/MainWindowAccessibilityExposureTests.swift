import AppKit
import XCTest
@testable import AppShell

@MainActor
final class MainWindowAccessibilityExposureTests: XCTestCase {
    private var retainedControllers: [MainWindowController] = []

    override func tearDown() {
        for controller in retainedControllers {
            controller.window.orderOut(nil)
        }
        retainedControllers.removeAll()
        super.tearDown()
    }

    func test_mainWindowDeclaresExplicitAXWindowMetadataForComputerUseAndVoiceOver() throws {
        let dir = NSTemporaryDirectory() + "RC2MainWindowAX-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        retainedControllers.append(controller)

        XCTAssertEqual(
            controller.window.accessibilityRole(),
            .window,
            "The main RemoteCode window must explicitly expose AXWindow so automation and VoiceOver inspect the UI tree."
        )
        XCTAssertEqual(
            controller.window.accessibilitySubrole(),
            .standardWindow,
            "The main RemoteCode window must expose AXStandardWindow semantics instead of relying on titlebar customization defaults."
        )
        XCTAssertEqual(
            controller.window.accessibilityTitle(),
            "RemoteCode",
            "The main RemoteCode window must have a stable AX title for Computer Use window matching and VoiceOver navigation."
        )
        XCTAssertEqual(
            controller.window.accessibilityIdentifier(),
            "window.main",
            "The main RemoteCode window must have a stable AX identifier so automation can target it without parsing user workspace text."
        )
    }
}
