import XCTest
@testable import DesignSystemKit

final class AdaptiveSidebarPolicyTests: XCTestCase {
    func test_autoSidebarHidesWhenSplitWouldMakePrimaryContentTooNarrow() {
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 640,
            contentMinimumExtent: 520,
            sidebarExtent: 260,
            currentVisible: true,
            intent: .auto,
            event: .structural,
            now: 10,
            lastAutomaticChange: nil
        )

        XCTAssertEqual(decision, AdaptiveSidebarDecision(isVisible: false, didChangeAutomatically: true),
                       "creating a split must hide contextual sidebars before it lets the editor, terminal, or agent content clip")
    }

    func test_autoSidebarUsesHysteresisBeforeShowingAgain() {
        let stillHidden = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 760,
            contentMinimumExtent: 520,
            sidebarExtent: 220,
            currentVisible: false,
            intent: .auto,
            event: .resize,
            now: 10,
            lastAutomaticChange: nil
        )
        let visible = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 880,
            contentMinimumExtent: 520,
            sidebarExtent: 220,
            currentVisible: false,
            intent: .auto,
            event: .resize,
            now: 10,
            lastAutomaticChange: nil
        )

        XCTAssertFalse(stillHidden.isVisible,
                       "resize should not show a sidebar again until the content has enough extra width to avoid hide/show churn")
        XCTAssertTrue(visible.isVisible)
    }

    func test_cooldownPreventsResizeFlicker() {
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 640,
            contentMinimumExtent: 520,
            sidebarExtent: 260,
            currentVisible: true,
            intent: .auto,
            event: .resize,
            now: 11,
            lastAutomaticChange: 10
        )

        XCTAssertTrue(decision.isVisible,
                      "continuous resize must not repeatedly toggle a contextual sidebar during the cooldown window")
        XCTAssertFalse(decision.didChangeAutomatically)
    }

    func test_manualShowWinsUntilLayoutIsImpossible() {
        let tightButPossible = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 640,
            contentMinimumExtent: 520,
            sidebarExtent: 260,
            currentVisible: true,
            intent: .forcedVisible,
            event: .resize,
            now: 10,
            lastAutomaticChange: nil
        )
        let impossible = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 480,
            contentMinimumExtent: 520,
            sidebarExtent: 260,
            currentVisible: true,
            intent: .forcedVisible,
            event: .resize,
            now: 10,
            lastAutomaticChange: nil
        )

        XCTAssertTrue(tightButPossible.isVisible,
                      "after the user explicitly shows a sidebar, normal tight layouts must not immediately hide it again")
        XCTAssertFalse(impossible.isVisible,
                       "manual show can be overridden only when keeping the sidebar would make primary content unusable")
    }

    func test_manualHidePreventsAutoShowOnWideResize() {
        let decision = AdaptiveSidebarPolicy.nextVisibility(
            availableExtent: 1400,
            contentMinimumExtent: 520,
            sidebarExtent: 260,
            currentVisible: false,
            intent: .forcedHidden,
            event: .resize,
            now: 10,
            lastAutomaticChange: nil
        )

        XCTAssertFalse(decision.isVisible,
                       "manual hide must not be undone by a later wide resize")
    }
}
