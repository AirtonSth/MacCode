import AppKit
import XCTest
@testable import AppShell

@MainActor
final class SettingsRoutePresentationTests: XCTestCase {
    func test_showGeneralRoutePresentsRemoteAccessSection() throws {
        let controller = try makeController()
        defer { close(controller) }

        XCTAssertTrue(controller.show(route: .general))
        XCTAssertEqual(controller.presentedRouteForTests, .general)
        XCTAssertTrue(controller.isRouteVisibleForTests(.general))
        XCTAssertFalse(controller.isRouteVisibleForTests(.providers))
    }

    func test_showProvidersRoutePresentsProviderDiagnosticsSection() throws {
        let controller = try makeController()
        defer { close(controller) }

        XCTAssertTrue(controller.show(route: .providers))
        XCTAssertEqual(controller.presentedRouteForTests, .providers)
        XCTAssertTrue(controller.isRouteVisibleForTests(.providers))
        XCTAssertFalse(controller.isRouteVisibleForTests(.general))
    }

    func test_showRouteAttachedToMainWindowUsesTheSameVerifiedAnchorPath() throws {
        let parent = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        parent.animationBehavior = .none
        let controller = try makeController()
        defer {
            close(controller)
            parent.orderOut(nil)
        }

        XCTAssertTrue(controller.show(route: .providers, attachedTo: parent))
        XCTAssertTrue(parent.attachedSheet === controller.window)
        XCTAssertEqual(controller.presentedRouteForTests, .providers)
        XCTAssertTrue(controller.isRouteVisibleForTests(.providers))
    }

    private func makeController() throws -> SettingsWindowController {
        let directory = NSTemporaryDirectory() + "RC2SettingsRoute-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let controller = SettingsWindowController(context: context)
        controller.window.animationBehavior = .none
        return controller
    }

    private func close(_ controller: SettingsWindowController) {
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
