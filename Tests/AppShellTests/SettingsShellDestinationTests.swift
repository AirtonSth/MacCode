import XCTest
import AppKit
@testable import AppShell
@testable import CoreModel
import Persistence

/// Settings lives in the main content column. Its shell destination is user
/// workflow state: sidebar selection, persisted key, and restore must agree.
@MainActor
final class SettingsShellDestinationTests: XCTestCase {
    private var directory: String!
    private var retainedControllers: [MainWindowController] = []

    override func setUp() {
        super.setUp()
        directory = NSTemporaryDirectory() + "RC2SettingsShell-\(UUID().uuidString)"
    }

    override func tearDown() {
        retainedControllers.removeAll()
        super.tearDown()
    }

    func test_presentSettings_selectsSidebarRow_persistsDestination_andRestoresAfterRelaunch() throws {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let first = MainWindowController(context: context, router: router)
        router.windowController = first
        retainedControllers.append(first)

        first.presentSettingsInMainContent()
        XCTAssertEqual(first.window.title, "Settings")
        XCTAssertTrue(first.sidebarViewModelForTesting.isSettingsSelected)
        XCTAssertFalse(first.sidebarViewModelForTesting.isActiveThreadsSelected)
        XCTAssertEqual(
            try context.settingsRepo.get(MainWindowController.botsShellSettingsKey) ?? "",
            "settings"
        )

        let reopened = MainWindowController(context: context, router: router)
        retainedControllers.append(reopened)
        XCTAssertEqual(reopened.window.title, "Settings")
        XCTAssertTrue(reopened.sidebarViewModelForTesting.isSettingsSelected)
    }

    func test_presentActivityAfterSettings_clearsSettingsSelection() throws {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let wc = MainWindowController(context: context, router: router)
        router.windowController = wc
        retainedControllers.append(wc)

        wc.presentSettingsInMainContent()
        XCTAssertTrue(wc.sidebarViewModelForTesting.isSettingsSelected)

        wc.presentActiveThreadsInMainContent()
        XCTAssertFalse(wc.sidebarViewModelForTesting.isSettingsSelected)
        XCTAssertTrue(wc.sidebarViewModelForTesting.isActiveThreadsSelected)
        XCTAssertEqual(wc.window.title, "Active Threads")
    }
}
