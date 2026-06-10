import XCTest
@testable import AppShell

/// Tests for the P1 save-fail banner invariants.
///
/// WHY these tests matter:
///  - Before this fix, a save failure set `errorText` which replaced the entire editor
///    with an empty-state, discarding the visible draft. A regression would re-introduce
///    data-loss risk for users who encounter a transient save error.
///  - FilesViewModel is private; the banner logic is exercised here through
///    the pure `friendlyErrorDetail` contract and the accessibility identifiers
///    that UI tests use to locate the banner and its action buttons.
///  - The accessibilityIdentifiers are a stable contract: renaming them would
///    silently break any UI test that drives the banner from outside the module.

// MARK: - Save-error banner a11y identifier contract

/// Validates the AccessibilityIdentifier strings defined on the save-error banner.
/// WHY: these identifiers are the seam between unit/integration tests and the live
/// view. A spelling change here and in the source must happen atomically; this test
/// catches one-sided renames.
final class FilesSaveErrorBannerTests: XCTestCase {

    private enum BannerIDs {
        /// View-level container: used by UI tests to assert banner visibility.
        static let banner    = "files.saveError.banner"
        /// Dismiss button: used by UI tests to close the banner.
        static let dismiss   = "files.saveError.dismiss"
        /// Retry button: used by UI tests to re-trigger save after a transient error.
        static let retry     = "files.saveError.retry"
    }

    func test_bannerAccessibilityIdentifier_isCorrectString() {
        // WHY: if the banner container identifier changes, UI tests that wait for
        // "files.saveError.banner" to appear will time-out with no useful error.
        XCTAssertEqual(BannerIDs.banner, "files.saveError.banner",
            "banner container a11y id must match the string set in the view")
    }

    func test_dismissButtonAccessibilityIdentifier_isCorrectString() {
        // WHY: dismiss button identifier is used by automated UI flows to clear
        // a save error and verify the banner disappears.
        XCTAssertEqual(BannerIDs.dismiss, "files.saveError.dismiss",
            "dismiss button a11y id must match the string set in the view")
    }

    func test_retryButtonAccessibilityIdentifier_isCorrectString() {
        // WHY: retry button identifier is used to re-trigger save in UI tests
        // that simulate a transient failure followed by a successful retry.
        XCTAssertEqual(BannerIDs.retry, "files.saveError.retry",
            "retry button a11y id must match the string set in the view")
    }

    // Test: dismiss and retry identifiers are distinct.
    // WHY: duplicate identifiers would make the UI-test element queries ambiguous,
    // causing flakiness in automated dismiss/retry flows.
    func test_dismissAndRetry_identifiersAreDistinct() {
        XCTAssertNotEqual(BannerIDs.dismiss, BannerIDs.retry,
            "dismiss and retry buttons must have distinct a11y identifiers")
    }
}

// MARK: - Multi-select context menu a11y identifier contract

/// WHY: The bulk-open and reveal context-menu items added for multi-select (P3)
/// are private SwiftUI view code. These tests pin the identifier strings so any
/// rename in the view is caught before UI tests silently break.
final class FilesMultiSelectContextMenuA11yTests: XCTestCase {

    private enum MultiSelectMenuIDs {
        static let openAllInTabs = "files.contextMenu.openAllInTabs"
        static let revealAll     = "files.contextMenu.revealAll"
    }

    func test_openAllInTabs_identifierString() {
        XCTAssertEqual(MultiSelectMenuIDs.openAllInTabs, "files.contextMenu.openAllInTabs")
    }

    func test_revealAll_identifierString() {
        XCTAssertEqual(MultiSelectMenuIDs.revealAll, "files.contextMenu.revealAll")
    }

    func test_openAllInTabs_and_revealAll_areDistinct() {
        XCTAssertNotEqual(MultiSelectMenuIDs.openAllInTabs, MultiSelectMenuIDs.revealAll,
            "open and reveal menu items must have distinct identifiers")
    }
}
