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

    func test_showAccountsRoutePresentsAccountsAndAutoSection() throws {
        // WHY: the owner moved Accounts & Auto out of the Agent App header into
        // Settings (2026-10-15). The Agent App's empty-state link and any other
        // entry must land on that section, not on the top of Settings.
        let controller = try makeController()
        defer { close(controller) }

        XCTAssertTrue(controller.show(route: .accounts))
        XCTAssertEqual(controller.presentedRouteForTests, .accounts)
        XCTAssertTrue(controller.isRouteVisibleForTests(.accounts))
    }

    func test_accountsSummaryNeverClaimsAutoStateBeforeTheSavedProfileLoads() {
        // WHY: cache-first must stay honest — before Distill's saved state is
        // read, Settings must not say Auto is off (it may be on).
        XCTAssertEqual(
            DistillAccountsSettingsSection.summary(statuses: [], routing: .init(), loaded: false),
            "Loading accounts…"
        )
        XCTAssertEqual(
            DistillAccountsSettingsSection.summary(statuses: [], routing: .init(), loaded: true),
            "No accounts yet · Auto off"
        )
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
        let controller = SettingsWindowController(
            context: context
        )
        controller.window.animationBehavior = .none
        return controller
    }

    private func close(_ controller: SettingsWindowController) {
        controller.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
}
