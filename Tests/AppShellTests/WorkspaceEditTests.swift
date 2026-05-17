import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence

@MainActor
final class WorkspaceEditTests: XCTestCase {
    private func make() throws -> (AppContext, AppCommandRouter) {
        let dir = NSTemporaryDirectory() + "RC2WSEdit-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    func test_rename_changesName() throws {
        let (ctx, router) = try make()
        let ws = try router.createWorkspace(name: "old", cwd: "/tmp")
        try router.renameWorkspace(ws.id, "new")
        XCTAssertEqual(ctx.state.workspaces[ws.id]?.name, "new")
    }

    func test_description_setAndClear() throws {
        let (ctx, router) = try make()
        let ws = try router.createWorkspace(name: "w", cwd: "/tmp")
        try router.setWorkspaceDescription(ws.id, "API service")
        XCTAssertEqual(ctx.state.workspaces[ws.id]?.metadata["description"], "API service")
        try router.setWorkspaceDescription(ws.id, "")
        XCTAssertNil(ctx.state.workspaces[ws.id]?.metadata["description"])
    }

    func test_remove_dropsWorkspace() throws {
        let (ctx, router) = try make()
        let ws = try router.createWorkspace(name: "w", cwd: "/tmp")
        XCTAssertNotNil(ctx.state.workspaces[ws.id])
        try router.closeWorkspace(ws.id)
        XCTAssertNil(ctx.state.workspaces[ws.id])
        XCTAssertFalse(ctx.state.window.workspaces.contains(ws.id))
    }

    func test_sidebarMultiSelect_tracksMultipleWorkspacesWithoutOpeningThem() throws {
        let (ctx, router) = try make()
        let first = try router.createWorkspace(name: "one", cwd: "/tmp")
        let second = try router.createWorkspace(name: "two", cwd: "/tmp")
        let selectedBefore = ctx.state.window.selectedWorkspaceID

        let vm = SidebarViewModel(context: ctx, router: router)
        vm.toggleMultiSelect()
        vm.toggleWorkspaceSelection(first)
        vm.toggleWorkspaceSelection(second)

        XCTAssertEqual(vm.selectedWorkspaceIDs, [first.id, second.id],
                       "bulk-delete mode must allow selecting several workspaces before one destructive confirmation")
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, selectedBefore,
                       "selecting rows for bulk deletion must not switch the active workspace")
    }

    func test_edits_persistAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2WSEdit-" + UUID().uuidString
        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx); ctx.router = router
            let ws = try router.createWorkspace(name: "orig", cwd: "/tmp")
            try router.renameWorkspace(ws.id, "renamed")
            try router.setWorkspaceDescription(ws.id, "notes here")
            ctx.saveSnapshot()
        }
        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let w = ctx2.state.workspaces.values.first
        XCTAssertEqual(w?.name, "renamed")
        XCTAssertEqual(w?.metadata["description"], "notes here")
    }
}
