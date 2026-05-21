import XCTest
@testable import Surfaces

final class TerminalScrollbackPolicyTests: XCTestCase {
    func test_autoScrollOnlyWhenUserWasAlreadyNearBottom() {
        XCTAssertTrue(
            TerminalScrollbackPolicy.shouldAutoScroll(visibleMaxY: 499, documentHeight: 500),
            "live terminal output should keep following the cursor when the user is already reading the newest output"
        )
        XCTAssertFalse(
            TerminalScrollbackPolicy.shouldAutoScroll(visibleMaxY: 260, documentHeight: 500),
            "users must be able to scroll up and keep reading older terminal messages without redraws forcing the bottom"
        )
    }
}
