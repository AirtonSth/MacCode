import XCTest
@testable import Surfaces

/// Tests for `FeedPanelViewModel.pauseBadgeText(isPaused:pendingCount:)`.
/// Pure static helper - no @MainActor required.
/// WHY: the badge is the only user-visible signal that events are buffered
/// while paused; these tests guard the exact text contract and the
/// "no badge when not applicable" contract so regressions are caught
/// before they reach the UI.
final class FeedPauseBadgeTests: XCTestCase {

    // MARK: - paused + N pending -> badge shows N

    func test_paused_fivePending_badgeShowsFive() {
        let result = FeedPanelViewModel.pauseBadgeText(isPaused: true, pendingCount: 5)
        XCTAssertEqual(result, "5",
                       "Badge must show the exact pending count so user knows how many events are buffered.")
    }

    func test_paused_onePending_badgeShowsOne() {
        let result = FeedPanelViewModel.pauseBadgeText(isPaused: true, pendingCount: 1)
        XCTAssertEqual(result, "1",
                       "Single buffered event must still show a badge (minimum meaningful signal).")
    }

    func test_paused_largePending_badgeContainsCount() {
        let result = FeedPanelViewModel.pauseBadgeText(isPaused: true, pendingCount: 199)
        XCTAssertEqual(result, "199",
                       "Badge text must contain the full integer count, not a truncated/abbreviated value.")
    }

    // MARK: - not paused -> nil regardless of pending count

    func test_notPaused_zeroPending_nilBadge() {
        let result = FeedPanelViewModel.pauseBadgeText(isPaused: false, pendingCount: 0)
        XCTAssertNil(result,
                     "No badge when feed is running and nothing is buffered.")
    }

    func test_notPaused_nonZeroPending_nilBadge() {
        // Defensive: pending could transiently be non-zero during flush;
        // badge must only appear when paused, never during live streaming.
        let result = FeedPanelViewModel.pauseBadgeText(isPaused: false, pendingCount: 10)
        XCTAssertNil(result,
                     "Badge must not appear while feed is running, even if pendingCount is non-zero.")
    }

    // MARK: - paused + zero pending -> nil (nothing to signal)

    func test_paused_zeroPending_nilBadge() {
        let result = FeedPanelViewModel.pauseBadgeText(isPaused: true, pendingCount: 0)
        XCTAssertNil(result,
                     "Paused with nothing buffered: showing '0' would be noise; badge must be hidden.")
    }
}
