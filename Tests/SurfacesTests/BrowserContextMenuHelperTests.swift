import XCTest
@testable import Surfaces

// BrowserContextMenuHelper and ContextMenuItemSpec are pure value types with no
// @MainActor isolation, so no MainActor annotation is needed here.
//
// WHY these tests matter:
//   The context-menu injection path (willOpenMenu) runs inside AppKit and cannot
//   be driven from a unit test process. The pure helper is the seam: testing it
//   guarantees that the correct items are produced for any hit-test result
//   WITHOUT relying on AppKit menu infrastructure. If the business rule changes
//   (e.g. a third item is added, or "Copy Link" is renamed), exactly these tests
//   will fail, preventing silent regressions in the user-visible context menu.

final class BrowserContextMenuHelperTests: XCTestCase {

    // MARK: - No-link case

    func test_noLink_returnsEmptySpecs() {
        // WHY: right-clicking text/images must NOT inject link-specific items;
        // injecting them on non-links would confuse the user and clutter the menu.
        let specs = BrowserContextMenuHelper.menuItemSpecs(linkURL: nil)
        XCTAssertTrue(specs.isEmpty,
                      "nil linkURL must produce no custom menu items; non-link targets must see the default WKWebView menu only")
    }

    // MARK: - Link present

    private let sampleURL = URL(string: "https://example.com/docs/page")!

    func test_withLink_returnsTwoSpecs() {
        // WHY: exactly two items must be injected — "Open Link in New Surface"
        // and "Copy Link" — matching the task requirement. A different count would
        // mean an item was silently dropped or an unintended item was added.
        let specs = BrowserContextMenuHelper.menuItemSpecs(linkURL: sampleURL)
        XCTAssertEqual(specs.count, 2,
                       "a link hit-test must produce exactly 2 custom menu items")
    }

    func test_withLink_firstItemTitleIsOpenLinkInNewSurface() {
        // WHY: the user-visible title must match the task spec exactly; a typo
        // or rename here would break the UX requirement without a compile error.
        let specs = BrowserContextMenuHelper.menuItemSpecs(linkURL: sampleURL)
        XCTAssertEqual(specs[0].title, "Open Link in New Surface",
                       "first context-menu item must be titled 'Open Link in New Surface'")
    }

    func test_withLink_secondItemTitleIsCopyLink() {
        // WHY: same title-correctness guarantee for the copy action.
        let specs = BrowserContextMenuHelper.menuItemSpecs(linkURL: sampleURL)
        XCTAssertEqual(specs[1].title, "Copy Link",
                       "second context-menu item must be titled 'Copy Link'")
    }

    func test_withLink_firstActionCarriesCorrectURL() {
        // WHY: the action must carry the exact URL so the coordinator can open
        // a new surface navigating to the right page; a URL mismatch means the
        // wrong page opens.
        let specs = BrowserContextMenuHelper.menuItemSpecs(linkURL: sampleURL)
        XCTAssertEqual(specs[0].action, .openLinkInNewSurface(sampleURL),
                       "openLinkInNewSurface action must carry the hit-tested link URL")
    }

    func test_withLink_secondActionCarriesCorrectURL() {
        // WHY: copyLink must write the hit-tested URL to the pasteboard, not the
        // current page URL; the action value is the sole source of truth for that.
        let specs = BrowserContextMenuHelper.menuItemSpecs(linkURL: sampleURL)
        XCTAssertEqual(specs[1].action, .copyLink(sampleURL),
                       "copyLink action must carry the hit-tested link URL")
    }

    func test_withLink_specsForDifferentURLsDiffer() {
        // WHY: ContextMenuItemSpec must be URL-sensitive; two links with different
        // URLs must produce non-equal specs so actions route to the correct target.
        let urlA = URL(string: "https://alpha.example.com")!
        let urlB = URL(string: "https://beta.example.com")!
        let specsA = BrowserContextMenuHelper.menuItemSpecs(linkURL: urlA)
        let specsB = BrowserContextMenuHelper.menuItemSpecs(linkURL: urlB)
        XCTAssertNotEqual(specsA, specsB,
                          "specs for different link URLs must not be equal; Equatable must respect URL identity")
    }

    func test_withLink_specsForSameURLAreEqual() {
        // WHY: idempotency — calling the helper twice with the same URL must
        // produce equal specs so callers can safely deduplicate or cache results.
        let specsA = BrowserContextMenuHelper.menuItemSpecs(linkURL: sampleURL)
        let specsB = BrowserContextMenuHelper.menuItemSpecs(linkURL: sampleURL)
        XCTAssertEqual(specsA, specsB,
                       "repeated calls with the same URL must produce equal specs (pure function)")
    }
}
