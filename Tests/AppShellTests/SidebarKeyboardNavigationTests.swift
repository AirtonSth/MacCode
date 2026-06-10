import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence

/// Tests for `SidebarViewModel.moveSelection(by:)` and friends.
/// These touch `SidebarViewModel` which is `@MainActor`, so the class is annotated accordingly.
@MainActor
final class SidebarKeyboardNavigationTests: XCTestCase {

    private func make() throws -> (AppContext, AppCommandRouter, SidebarViewModel) {
        let dir = NSTemporaryDirectory() + "RC2KBNav-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)
        return (ctx, router, vm)
    }

    // MARK: moveSelection(by:)

    func test_moveDown_advancesSelection() throws {
        let (_, router, vm) = try make()
        let first = try router.createWorkspace(name: "first", cwd: "/tmp")
        let second = try router.createWorkspace(name: "second", cwd: "/tmp")
        vm.reload()
        vm.select(first.id)

        vm.moveSelection(by: 1)

        XCTAssertEqual(vm.selectedWorkspaceID, second.id,
                       "↓ from the first row must advance selection to the second workspace")
    }

    func test_moveUp_retreatsSelection() throws {
        let (_, router, vm) = try make()
        let first = try router.createWorkspace(name: "first", cwd: "/tmp")
        let second = try router.createWorkspace(name: "second", cwd: "/tmp")
        vm.reload()
        vm.select(second.id)

        vm.moveSelection(by: -1)

        XCTAssertEqual(vm.selectedWorkspaceID, first.id,
                       "↑ from the second row must retreat selection to the first workspace")
    }

    func test_moveDown_clampsAtLastRow() throws {
        let (_, router, vm) = try make()
        let first = try router.createWorkspace(name: "first", cwd: "/tmp")
        let _ = try router.createWorkspace(name: "second", cwd: "/tmp")
        let last = try router.createWorkspace(name: "last", cwd: "/tmp")
        vm.reload()
        vm.select(last.id)

        vm.moveSelection(by: 1)

        XCTAssertEqual(vm.selectedWorkspaceID, last.id,
                       "↓ at the last row must keep selection on the last workspace instead of wrapping or crashing")
        _ = first // suppress unused warning
    }

    func test_moveUp_clampsAtFirstRow() throws {
        let (_, router, vm) = try make()
        let first = try router.createWorkspace(name: "first", cwd: "/tmp")
        let _ = try router.createWorkspace(name: "second", cwd: "/tmp")
        vm.reload()
        vm.select(first.id)

        vm.moveSelection(by: -1)

        XCTAssertEqual(vm.selectedWorkspaceID, first.id,
                       "↑ at the first row must keep selection on the first workspace")
    }

    func test_moveSelection_withFilter_operatesOnFilteredList() throws {
        let (_, router, vm) = try make()
        let _ = try router.createWorkspace(name: "alpha", cwd: "/tmp")
        let beta = try router.createWorkspace(name: "beta-1", cwd: "/tmp")
        let gamma = try router.createWorkspace(name: "beta-2", cwd: "/tmp")
        vm.reload()
        vm.filterText = "beta"
        // filtered list is [beta, gamma]; select beta then move down
        vm.select(beta.id)

        vm.moveSelection(by: 1)

        XCTAssertEqual(vm.selectedWorkspaceID, gamma.id,
                       "↓ while a filter is active must navigate within the filtered list, not the full list")
    }

    func test_moveSelection_emptyList_isNoOp() throws {
        let dir = NSTemporaryDirectory() + "RC2KBNavEmpty-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        let vm = SidebarViewModel(context: ctx, router: router)

        // No workspaces — must not crash.
        vm.moveSelection(by: 1)
        vm.moveSelection(by: -1)

        XCTAssertNil(vm.selectedWorkspaceID,
                     "moveSelection on an empty list must be a no-op and must not crash")
    }

    // MARK: openSelectedWorkspace

    func test_openSelected_isNoOpWhenNothingSelected() throws {
        let (ctx, _, vm) = try make()
        let initialSelected = ctx.state.window.selectedWorkspaceID

        vm.openSelectedWorkspace()

        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, initialSelected,
                       "Return with no selection must be a no-op")
    }
}
