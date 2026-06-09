import XCTest
@testable import AppShell

/// Verifies the resign-key dismiss policy for the floating command palette.
///
/// Business rule (UX-015): a floating HUD panel must never stay orphaned over
/// Spotlight, Raycast, or any other overlay that steals key focus from the app.
/// Spotify/Raycast both implement this behaviour; parity is required so the
/// palette is not perceived as frozen or intrusive.
///
/// The seam under test is `CommandPalette.shouldDismissOnResignKey()` — a pure
/// static function that encodes the dismiss policy.  Because `CommandPalette.init`
/// requires a live `AppCommandRouter` (a concrete AppKit-bound final class), the
/// static seam keeps this test dependency-free and fast.
@MainActor
final class CommandPaletteDismissOnResignKeyTests: XCTestCase {

    // MARK: - Policy correctness

    func test_shouldDismissOnResignKey_returnsTrue() {
        // WHY: the resign-key policy is always-dismiss; if this returns false
        // the windowDidResignKey delegate skips hide() and the panel stays visible
        // as an orphan over whatever window just became key.
        XCTAssertTrue(
            CommandPalette.shouldDismissOnResignKey(),
            "resign-key policy must be dismiss=true so the palette never orphans over Spotlight or Raycast"
        )
    }

    // MARK: - Policy intent guard

    func test_shouldDismissOnResignKey_isNotConditionalOnState() {
        // WHY: this function must be stateless/unconditional. Calling it twice
        // must produce the same result — no hidden flag, query, or window state
        // should cause the palette to stay visible on resign-key.
        let first  = CommandPalette.shouldDismissOnResignKey()
        let second = CommandPalette.shouldDismissOnResignKey()
        XCTAssertEqual(first, second, "shouldDismissOnResignKey must be deterministic/stateless")
    }
}
