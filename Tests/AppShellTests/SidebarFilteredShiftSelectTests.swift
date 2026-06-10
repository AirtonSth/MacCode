import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence

// Tests for the P1 bug fix: shift-range selection when a filter is active must
// only select visible (filtered) workspaces so that "Remove" cannot delete rows
// the user never saw.
//
// SidebarViewModel is @MainActor, so the whole class must be too.
@MainActor
final class SidebarFilteredShiftSelectTests: XCTestCase {

    private func make() throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let dir = NSTemporaryDirectory() + "RC2FilterShift-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)
        return (ctx, router, vm)
    }

    // PASS: shift-range with no filter selects all rows in the span.
    func test_shiftRange_noFilter_selectsSpan() throws {
        let (_, router, vm) = try make()
        let a = try router.createWorkspace(name: "alpha", cwd: "/a")
        let b = try router.createWorkspace(name: "beta", cwd: "/b")
        let c = try router.createWorkspace(name: "gamma", cwd: "/c")
        vm.reload()

        vm.select(a.id)
        vm.selectWorkspaceRow(c, extendingSelection: true, togglingSelection: false)

        XCTAssertEqual(
            vm.selectedWorkspaceIDs,
            [a.id, b.id, c.id],
            "shift-clicking the last row must select the full span including the middle row"
        )
    }

    // PASS (P1 fix): shift-range while a filter is active must not include
    // workspaces hidden by the filter.
    func test_shiftRange_withFilter_excludesHiddenRows() throws {
        let (_, router, vm) = try make()
        let alpha = try router.createWorkspace(name: "alpha", cwd: "/a")
        _ = try router.createWorkspace(name: "HIDDEN", cwd: "/h")
        let beta  = try router.createWorkspace(name: "beta",  cwd: "/b")
        vm.reload()
        // Filter to "alpha" and "beta" only; "HIDDEN" disappears.
        vm.filterText = "a"  // matches "alpha" and "beta" (both contain 'a')
        // Verify the filter result has exactly the two visible workspaces
        // (order may vary, but neither should be HIDDEN).
        let visible = vm.filteredWorkspaces
        XCTAssertEqual(visible.count, 2,
            "filter 'a' must narrow the list to the two workspaces whose names contain 'a'")

        vm.select(alpha.id)
        vm.selectWorkspaceRow(beta, extendingSelection: true, togglingSelection: false)

        XCTAssertFalse(
            vm.selectedWorkspaceIDs.contains(
                vm.workspaces.first(where: { $0.name == "HIDDEN" })!.id
            ),
            "a shift-range with an active filter must never include a workspace hidden by the filter"
        )
        XCTAssertTrue(
            vm.selectedWorkspaceIDs.contains(alpha.id) &&
            vm.selectedWorkspaceIDs.contains(beta.id),
            "the two visible workspaces must be in the selection"
        )
    }

    // PASS: when the anchor is not in filteredWorkspaces (became hidden after
    // re-filter), only the clicked row is added rather than crashing.
    func test_shiftRange_anchorHiddenByFilter_fallsBackToInsert() throws {
        let (_, router, vm) = try make()
        let alpha = try router.createWorkspace(name: "alpha", cwd: "/a")
        let beta  = try router.createWorkspace(name: "beta",  cwd: "/b")
        vm.reload()

        vm.select(alpha.id)           // anchor = alpha

        // Now filter so alpha disappears from the visible list.
        vm.filterText = "beta"        // only beta is visible

        // Shift-click beta: anchor (alpha) is not visible; must not crash.
        vm.selectWorkspaceRow(beta, extendingSelection: true, togglingSelection: false)

        XCTAssertTrue(
            vm.selectedWorkspaceIDs.contains(beta.id),
            "when the anchor is hidden by the filter, shift-click must at minimum add the target"
        )
    }
}

// MARK: - Pure row a11y helper tests (no MainActor needed)

/// Tests for `SidebarViewModel.workspaceRowAccessibilityValue(...)`.
/// The helper is nonisolated static so these run off-main.
final class SidebarRowA11yValueTests: XCTestCase {

    // PASS: idle row with no special state produces empty string.
    func test_idleRow_returnsEmpty() {
        let value = SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: nil,
            unreadCount: 0,
            pinned: false,
            checked: false
        )
        XCTAssertEqual(value, "",
            "an idle, normal workspace row must return an empty a11y value so VoiceOver does not add noisy state")
    }

    // PASS: busy with agent run surfaces the description.
    func test_agentRunBusy_includesBusyDescription() {
        let value = SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: "Agent run in thread \"My Thread\"",
            unreadCount: 0,
            pinned: false,
            checked: false
        )
        XCTAssertTrue(value.contains("Agent run in thread"),
            "busy row must include the busy-source description so VoiceOver reads what is running")
    }

    // PASS: unread count appears in the value.
    func test_unreadCount_included() {
        let value = SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: nil,
            unreadCount: 3,
            pinned: false,
            checked: false
        )
        XCTAssertTrue(value.contains("3 unread"),
            "unread count must appear so VoiceOver announces pending notifications")
    }

    // PASS: pinned state included.
    func test_pinned_included() {
        let value = SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: nil,
            unreadCount: 0,
            pinned: true,
            checked: false
        )
        XCTAssertTrue(value.contains("pinned"),
            "pinned state must be surfaced so VoiceOver users know the workspace is pinned")
    }

    // PASS: multi-select checked state included.
    func test_checked_included() {
        let value = SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: nil,
            unreadCount: 0,
            pinned: false,
            checked: true
        )
        XCTAssertTrue(value.contains("selected"),
            "checked (multi-select) state must be in the value so VoiceOver announces batch membership")
    }

    // PASS: all states combined produce a comma-separated string.
    func test_allStates_joinedWithComma() {
        let value = SidebarViewModel.workspaceRowAccessibilityValue(
            busyDescription: "Terminal job running in \"zsh\"",
            unreadCount: 2,
            pinned: true,
            checked: true
        )
        let parts = value.components(separatedBy: ", ")
        XCTAssertEqual(parts.count, 4,
            "all four active states must produce exactly four comma-separated parts")
    }
}
