import XCTest
@testable import AppShell

/// Tests for MainWindowController sidebar width clamp and persistence (T028).
///
/// WHY: The sidebar width clamp (min 180pt, max 560pt) and the DB-persistence
/// round-trip are pure logic that must be pinned against regressions. Without
/// these tests:
///   - A future change to the clamp constants (e.g. raising the minimum to 200
///     or lowering the maximum to 500) would silently accept out-of-range values
///     stored in the DB, producing a layout that looks broken on the next launch.
///   - If the settingsRepo read/write key drifts ("sidebar.width" vs "sidebarWidth")
///     the stored value is never found and every launch resets to the default width.
///
/// These tests cover only the pure storedSidebarWidth logic; the live NSSplitView
/// behavior is left to UI automation (deferred to the XCUITest target).
@MainActor
final class MainWindowControllerSidebarWidthTests: XCTestCase {

    private func makeContext() throws -> AppContext {
        let dir = NSTemporaryDirectory() + "RC2SidebarWidth-\(UUID().uuidString)"
        return try AppContext(channel: .debug, appSupportOverride: dir)
    }

    // MARK: - Default width when no persisted value exists

    /// WHY: On first launch there is no stored width. The default must be
    /// returned so the sidebar opens at a usable width instead of 0pt or
    /// some garbage value that collapses it.
    func test_storedSidebarWidth_noStoredValue_returnsDefault() throws {
        let ctx = try makeContext()
        let width = MainWindowController.storedSidebarWidth(context: ctx)
        XCTAssertEqual(width, MainWindowController.defaultSidebarWidth,
                       "With no persisted value, storedSidebarWidth must return defaultSidebarWidth " +
                       "so the sidebar opens at a usable width on first launch")
    }

    // MARK: - Clamp: values within range pass through unchanged

    /// WHY: A width of 300pt is within [180, 560]; it must survive the DB
    /// round-trip unmodified.
    func test_storedSidebarWidth_valueInRange_passesThroughUnchanged() throws {
        let ctx = try makeContext()
        try ctx.settingsRepo.set(MainWindowController.sidebarWidthSettingsKey, "300")

        let width = MainWindowController.storedSidebarWidth(context: ctx)
        XCTAssertEqual(width, 300.0, accuracy: 0.1,
                       "A stored value of 300pt is within [180, 560] and must be returned unchanged " +
                       " -  the user's exact resize preference must be honoured")
    }

    // MARK: - Clamp: too-small value is floored to 180pt

    /// WHY: A stored width below 180pt (e.g. from a bug or a future schema change
    /// that maps a different key) would produce an invisible sidebar. The clamp
    /// floor must prevent this so the user can always reach the sidebar controls.
    func test_storedSidebarWidth_tooSmall_clampsToMinimum() throws {
        let ctx = try makeContext()
        try ctx.settingsRepo.set(MainWindowController.sidebarWidthSettingsKey, "50")

        let width = MainWindowController.storedSidebarWidth(context: ctx)
        XCTAssertEqual(width, 180.0, accuracy: 0.1,
                       "A stored width of 50pt is below the 180pt minimum; it must be clamped to 180pt " +
                       "so the sidebar remains visible and usable instead of collapsing to an invisible sliver")
    }

    // MARK: - Clamp: too-large value is capped to 560pt

    /// WHY: A stored width above 560pt (e.g. from a wide external display session
    /// loaded on a smaller screen) would push the workspace content area off screen.
    /// The cap must prevent this so the layout stays usable on any screen size.
    func test_storedSidebarWidth_tooLarge_clampsToMaximum() throws {
        let ctx = try makeContext()
        try ctx.settingsRepo.set(MainWindowController.sidebarWidthSettingsKey, "9999")

        let width = MainWindowController.storedSidebarWidth(context: ctx)
        XCTAssertEqual(width, 560.0, accuracy: 0.1,
                       "A stored width of 9999pt exceeds the 560pt maximum; it must be clamped to 560pt " +
                       "so the workspace content area is never pushed entirely off screen")
    }

    // MARK: - Key stability: wrong key returns default

    /// WHY: If the key written by the persistence path drifts from the key read
    /// by storedSidebarWidth, every launch silently ignores the stored value.
    /// This test pins that the key constant is "sidebar.width".
    func test_sidebarWidthSettingsKey_isCorrect() {
        XCTAssertEqual(MainWindowController.sidebarWidthSettingsKey, "sidebar.width",
                       "The sidebar width settings key must be 'sidebar.width'  -  a drift (e.g. to " +
                       "'sidebarWidth') would cause the stored value to be silently ignored on every " +
                       "launch, resetting to the default each time")
    }

    // MARK: - Non-numeric stored value returns default

    /// WHY: A corrupt or migrated settings value (e.g. "none", empty string)
    /// must not crash or produce NaN  -  it must fall back to the default.
    func test_storedSidebarWidth_nonNumericValue_returnsDefault() throws {
        let ctx = try makeContext()
        try ctx.settingsRepo.set(MainWindowController.sidebarWidthSettingsKey, "not-a-number")

        let width = MainWindowController.storedSidebarWidth(context: ctx)
        XCTAssertEqual(width, MainWindowController.defaultSidebarWidth,
                       "A non-numeric stored value ('not-a-number') must fall back to defaultSidebarWidth " +
                       "instead of crashing or producing NaN  -  corrupt settings must not break the layout")
    }
}
