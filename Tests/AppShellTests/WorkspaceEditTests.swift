import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

@MainActor
final class WorkspaceEditTests: XCTestCase {
    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    override func tearDown() {
        closeAndUnregisterAllSurfaces()
        super.tearDown()
    }

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

    func test_agentAttachmentUploadWritesMobileImportIntoWorkspace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RC2AttachmentUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (_, router) = try make()
        let ws = try router.createWorkspace(name: "w", cwd: dir.path)

        let uploaded = try router.uploadAgentAttachment(
            workspace: ws.id,
            filename: "../mobile note.txt",
            mimeType: "text/plain",
            dataBase64: Data("hello from ios".utf8).base64EncodedString()
        )

        XCTAssertTrue(uploaded.path.hasPrefix(dir.appendingPathComponent(".remotecode/attachments").path),
                      "iOS imports must be copied into the host workspace before they are sent as provider attachments")
        XCTAssertEqual(uploaded.displayName, "mobile note.txt")
        XCTAssertEqual(uploaded.sizeBytes, 14)
        XCTAssertEqual(try String(contentsOfFile: uploaded.path), "hello from ios")
    }

    func test_workspacePinAndDragOrder_useSharedWindowOrder() throws {
        let (ctx, router) = try make()
        let first = try router.createWorkspace(name: "one", cwd: "/tmp")
        let second = try router.createWorkspace(name: "two", cwd: "/tmp")
        let third = try router.createWorkspace(name: "three", cwd: "/tmp")
        let vm = SidebarViewModel(context: ctx, router: router)

        vm.setWorkspacePinned(second, true)
        XCTAssertEqual(ctx.state.window.workspaces, [second.id, first.id, third.id],
                       "pinning from the sidebar must sort pinned workspaces above unpinned ones")

        vm.reorderWorkspace(third.id, before: first.id)
        XCTAssertEqual(ctx.state.window.workspaces, [second.id, third.id, first.id],
                       "dragging a workspace row must update the host window order while preserving pinned-first sorting")
    }

    func test_remove_dropsWorkspace() throws {
        let (ctx, router) = try make()
        let ws = try router.createWorkspace(name: "w", cwd: "/tmp")
        XCTAssertNotNil(ctx.state.workspaces[ws.id])
        try router.closeWorkspace(ws.id)
        XCTAssertNil(ctx.state.workspaces[ws.id])
        XCTAssertFalse(ctx.state.window.workspaces.contains(ws.id))
    }

    func test_batchRemoveDropsSelectedWorkspacesAndPublishesMirrorEvents() throws {
        let (ctx, router) = try make()
        let first = try router.createWorkspace(name: "one", cwd: "/tmp")
        let second = try router.createWorkspace(name: "two", cwd: "/tmp")
        let third = try router.createWorkspace(name: "three", cwd: "/tmp")
        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            if event.kind == "workspace.closed" { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }

        try router.closeWorkspaces([first.id, second.id])

        XCTAssertNil(ctx.state.workspaces[first.id],
                     "bulk workspace deletion must remove every selected workspace from host state")
        XCTAssertNil(ctx.state.workspaces[second.id],
                     "bulk workspace deletion must not stop after the first selected workspace")
        XCTAssertEqual(ctx.state.window.workspaces, [third.id],
                       "bulk workspace deletion must leave the sidebar with only non-selected workspaces")
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, third.id,
                       "after deleting selected workspaces, the app must select a remaining workspace instead of hanging on a deleted id")
        XCTAssertEqual(events.map(\.kind), ["workspace.closed", "workspace.closed"],
                       "bulk workspace deletion must publish one host event per removed workspace so paired iOS mirrors do not keep stale rows")
        XCTAssertEqual(events.compactMap { $0.payload.objectValue?["workspace_id"]?.stringValue },
                       [first.id.value.uuidString, second.id.value.uuidString],
                       "workspace.closed events must carry the exact payload key consumed by the iOS mirror reducer")
    }

    func test_finderURL_requiresExistingWorkspaceDirectory() throws {
        let (ctx, router) = try make()
        let dir = NSTemporaryDirectory()
        let ws = try router.createWorkspace(name: "finder", cwd: dir)
        XCTAssertEqual(SidebarViewModel.finderURL(for: ws)?.path, URL(fileURLWithPath: dir, isDirectory: true).path,
                       "Open in Finder must target the workspace cwd directory")

        let missing = try router.createWorkspace(name: "missing", cwd: dir + "/missing-\(UUID().uuidString)")
        XCTAssertNil(SidebarViewModel.finderURL(for: missing),
                     "Open in Finder must fail loud instead of opening an invalid path")
    }

    func test_sidebarShiftSelection_tracksRangeWithoutOpeningWorkspace() throws {
        let (ctx, router) = try make()
        let first = try router.createWorkspace(name: "one", cwd: "/tmp")
        let second = try router.createWorkspace(name: "two", cwd: "/tmp")
        let third = try router.createWorkspace(name: "three", cwd: "/tmp")
        let selectedBefore = ctx.state.window.selectedWorkspaceID

        let vm = SidebarViewModel(context: ctx, router: router)
        vm.select(first.id)
        vm.selectWorkspaceRow(third, extendingSelection: true)

        XCTAssertEqual(vm.selectedWorkspaceIDs, [first.id, second.id, third.id],
                       "Shift-click selection must select the workspace range for bulk deletion without a separate Select mode")
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, first.id,
                       "Shift-clicking rows for bulk deletion must not switch the active workspace")

        vm.select(second.id)
        XCTAssertTrue(vm.selectedWorkspaceIDs.isEmpty,
                      "a normal click must clear the Shift-selected bulk set and open that workspace")
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, second.id)
        XCTAssertNotEqual(ctx.state.window.selectedWorkspaceID, selectedBefore)
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
