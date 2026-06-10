import XCTest
@testable import AppShell

// Pure-helper tests — no MainActor required; InsomniaStatusPillState + the
// helper that derives it carry no UI dependencies.
final class InsomniaStatusPillTests: XCTestCase {

    // MARK: - isVisible

    func test_pillHiddenWhenInsomniaOff() {
        let state = SidebarViewModel.insomniaStatusPill(enabled: false)
        XCTAssertFalse(
            state.isVisible,
            "the insomnia status pill must be hidden when no keep-awake assertions are held, " +
            "so it does not distract users who have not turned Insomnia on"
        )
    }

    func test_pillVisibleWhenInsomniaOn() {
        let state = SidebarViewModel.insomniaStatusPill(enabled: true)
        XCTAssertTrue(
            state.isVisible,
            "the insomnia status pill must be visible whenever keep-awake assertions are held, " +
            "so the user has a clear at-a-glance signal that the battery-draining feature is active"
        )
    }

    // MARK: - label

    func test_pillLabelNonEmptyWhenOn() {
        let state = SidebarViewModel.insomniaStatusPill(enabled: true)
        XCTAssertFalse(
            state.label.isEmpty,
            "the pill label must be a non-empty human-readable string when Insomnia is on; " +
            "an empty label would leave the user with no indication of what the pill represents"
        )
    }

    func test_pillLabelEmptyOrIrrelevantWhenOff() {
        let state = SidebarViewModel.insomniaStatusPill(enabled: false)
        // When hidden the label content does not matter for the user, but the
        // helper must not crash and must return a defined value.
        // We only assert it does not throw; no label content contract when hidden.
        _ = state.label
    }

    // MARK: - disableAction semantic contract

    func test_pillStateCarriesDisableIntent() {
        // The pill exposes a disable flag so the view can wire one-click dismiss
        // without inspecting internal VM state from the view layer.
        let state = SidebarViewModel.insomniaStatusPill(enabled: true)
        XCTAssertTrue(
            state.disablesInsomniaOnTap,
            "tapping the active status pill must map to the disable action so users can " +
            "click once to stop the battery-draining keep-awake session"
        )
    }

    func test_pillStateOffDoesNotCarryDisableIntent() {
        let state = SidebarViewModel.insomniaStatusPill(enabled: false)
        XCTAssertFalse(
            state.disablesInsomniaOnTap,
            "the disable action must only be wired when the pill is visible and Insomnia is on"
        )
    }
}
