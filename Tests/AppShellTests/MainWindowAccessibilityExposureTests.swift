import AppKit
import XCTest
@testable import AppShell

@MainActor
final class MainWindowAccessibilityExposureTests: XCTestCase {
    private var retainedControllers: [MainWindowController] = []

    private func sourceURL(_ relative: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MainWindowAccessibilityExposureTests.swift
            .deletingLastPathComponent() // AppShellTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent(relative)
    }

    override func tearDown() {
        for controller in retainedControllers {
            controller.window.orderOut(nil)
        }
        retainedControllers.removeAll()
        super.tearDown()
    }

    func test_mainWindowPreservesNativeAXWindowMetadataForComputerUseAndVoiceOver() throws {
        let dir = NSTemporaryDirectory() + "RC2MainWindowAX-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: context)
        context.router = router
        let controller = MainWindowController(context: context, router: router)
        router.windowController = controller
        retainedControllers.append(controller)

        XCTAssertTrue(
            controller.window.isAccessibilityElement(),
            "The main RemoteCode window must remain an accessibility element so AXWindows can expose it directly."
        )
        XCTAssertEqual(
            controller.window.accessibilityRole(),
            .window,
            "The main RemoteCode window must retain AppKit's native AXWindow role so automation and VoiceOver inspect the UI tree."
        )
        XCTAssertNotNil(
            controller.window.accessibilitySubrole(),
            "The main RemoteCode window must let AppKit supply the native AX subrole for its current host and presentation state."
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

    func test_productWindowsDoNotOverrideNativeAXRoleOrSubrole() throws {
        // WHY: assigning AXWindow/AXStandardWindow directly to NSWindow makes the
        // out-of-process AXWindows collection expose AXApplication children. That
        // breaks Computer Use window matching even though in-process getters still
        // report the requested values. AppKit must remain the owner of role/subrole.
        for relative in [
            "Sources/AppShell/MainWindowController.swift",
            "Sources/AppShell/SettingsWindow.swift",
        ] {
            let source = try String(contentsOf: sourceURL(relative), encoding: .utf8)
            XCTAssertFalse(
                source.contains("setAccessibilityRole(.window)"),
                "\(relative) must not override NSWindow's native AXWindow role."
            )
            XCTAssertFalse(
                source.contains("setAccessibilitySubrole(.standardWindow)"),
                "\(relative) must not override NSWindow's native AXStandardWindow subrole."
            )
        }
    }
}
