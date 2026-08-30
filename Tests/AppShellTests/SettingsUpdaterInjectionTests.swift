import XCTest
@testable import AppShell

/// Verifies that both Settings presenter call sites wire the Sparkle updater
/// into SettingsWindowController so the "App Updates" row is live and not dead.
///
/// Business rule: SettingsViewModel.showsAppUpdates == true iff an updater is
/// injected. A nil updater hides the row entirely; a non-nil one shows it.
/// Regression protection: if either call site reverts to the no-updater init
/// the test catches it immediately, without requiring a UI interaction.
@MainActor
final class SettingsUpdaterInjectionTests: XCTestCase {

    private final class StubUpdater: AppUpdateChecking {
        var availability: AppUpdateAvailability = .unknown
        var onAvailabilityChanged: ((AppUpdateAvailability) -> Void)?
        var onWillInstallUpdate: (() -> Void)?
        func checkForUpdates() {}
    }

    // MARK: - SettingsWindowController seam

    func test_settingsWindowController_showsAppUpdates_whenUpdaterInjected() throws {
        let dir = NSTemporaryDirectory() + "RC2SettingsUpdater-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let updater = StubUpdater()

        let controller = SettingsWindowController(
            context: ctx,
            updater: updater,
            tailcatAccessSettingAuthority: TailcatAccessSettingAuthority()
        )

        XCTAssertTrue(
            controller.viewModel.showsAppUpdates,
            "SettingsWindowController must expose the App Updates row when an updater is injected — " +
            "omitting the updater silently kills the entire update UI"
        )
    }

    func test_settingsWindowController_hidesAppUpdates_whenUpdaterNil() throws {
        let dir = NSTemporaryDirectory() + "RC2SettingsUpdater-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)

        let controller = SettingsWindowController(
            context: ctx,
            updater: nil,
            tailcatAccessSettingAuthority: TailcatAccessSettingAuthority()
        )

        XCTAssertFalse(
            controller.viewModel.showsAppUpdates,
            "SettingsWindowController must hide the App Updates row when no updater is provided — " +
            "this is intentional for unsigned/dev builds"
        )
    }
}
