import XCTest
import AppKit
@testable import AppShell

/// Tests for the "Check for Updates..." app-menu item and the pure
/// NSMenuItemValidation helper.
///
/// Business rules:
///   R1 — "Check for Updates..." is ENABLED iff an updater is configured
///         (non-nil). When no updater exists (unsigned/dev build without a
///         Sparkle feed URL) the item must be disabled so the user gets
///         no confusing feedback when tapping a dead action.
///   R2 — All other AppDelegate-owned actions are unconditionally enabled
///         by the helper (existing behavior is preserved; this rule guards
///         against accidentally disabling unrelated items via the catch-all).
///   R3 — validateMenuItem routes through the pure helper, so the two code
///         paths cannot drift.
///
/// The pure helper (menuItemEnabled) is static and has no AppKit side-effects.
/// @MainActor is required because AppUpdateAvailability and AppUpdateChecking
/// conformances are @MainActor-isolated.
@MainActor
final class AppMenuUpdateItemTests: XCTestCase {

    // MARK: - Pure helper: updater configured / not configured

    func test_updateItemEnabled_whenUpdaterConfigured() {
        // R1: item must be enabled so the user can trigger a check.
        let enabled = AppDelegate.menuItemEnabled(
            action: #selector(AppDelegate.checkForUpdatesAction),
            updaterConfigured: true
        )
        XCTAssertTrue(
            enabled,
            "\"Check for Updates...\" must be enabled when an updater is injected — " +
            "disabling it would silently hide the only user-visible update trigger"
        )
    }

    func test_updateItemDisabled_whenNoUpdaterConfigured() {
        // R1: item must be disabled for unsigned/dev builds that have no feed URL.
        let enabled = AppDelegate.menuItemEnabled(
            action: #selector(AppDelegate.checkForUpdatesAction),
            updaterConfigured: false
        )
        XCTAssertFalse(
            enabled,
            "\"Check for Updates...\" must be disabled when no updater is configured — " +
            "triggering the action without an updater is a no-op that would confuse the user"
        )
    }

    // MARK: - Pure helper: unrelated actions remain enabled

    func test_unrelatedAction_alwaysEnabled_withUpdater() {
        // R2: An action that is not checkForUpdatesAction must not be accidentally
        // disabled by the validation catch-all, regardless of updater state.
        // We use NSSelectorFromString with a representative action name to avoid
        // coupling to private method access levels on AppDelegate.
        let otherAction = NSSelectorFromString("showSettings:")
        let enabled = AppDelegate.menuItemEnabled(
            action: otherAction,
            updaterConfigured: true
        )
        XCTAssertTrue(
            enabled,
            "Non-update actions must remain enabled regardless of updater state — " +
            "the catch-all must not disable unrelated menu items"
        )
    }

    func test_unrelatedAction_alwaysEnabled_withoutUpdater() {
        // R2: absence of updater must not disable unrelated actions.
        let otherAction = NSSelectorFromString("newWorkspace:")
        let enabled = AppDelegate.menuItemEnabled(
            action: otherAction,
            updaterConfigured: false
        )
        XCTAssertTrue(
            enabled,
            "Non-update actions must remain enabled even when no updater is configured — " +
            "update-item state must be independent of all other menu items"
        )
    }

    // MARK: - validateMenuItem routes through the helper (integration seam)

    func test_validateMenuItem_enablesUpdateItem_whenUpdaterSet() {
        // R3: validateMenuItem must agree with the pure helper when updater != nil.
        let delegate = AppDelegate()
        delegate.updater = StubUpdater()

        let item = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(AppDelegate.checkForUpdatesAction),
            keyEquivalent: ""
        )
        item.target = delegate

        XCTAssertTrue(
            delegate.validateMenuItem(item),
            "validateMenuItem must enable the update item when AppDelegate.updater is set — " +
            "a greyed-out item when the updater is live would prevent the user from checking"
        )
    }

    func test_validateMenuItem_disablesUpdateItem_whenUpdaterNil() {
        // R3: validateMenuItem must agree with the pure helper when updater == nil.
        let delegate = AppDelegate()
        // updater is nil by default

        let item = NSMenuItem(
            title: "Check for Updates\u{2026}",
            action: #selector(AppDelegate.checkForUpdatesAction),
            keyEquivalent: ""
        )
        item.target = delegate

        XCTAssertFalse(
            delegate.validateMenuItem(item),
            "validateMenuItem must disable the update item when AppDelegate.updater is nil — " +
            "the action is a no-op without an updater and must not be tappable"
        )
    }
}

// MARK: - Helpers

@MainActor
private final class StubUpdater: AppUpdateChecking {
    var availability: AppUpdateAvailability = .unknown
    var onAvailabilityChanged: ((AppUpdateAvailability) -> Void)?
    var onWillInstallUpdate: (() -> Void)?
    func checkForUpdates() {}
}
