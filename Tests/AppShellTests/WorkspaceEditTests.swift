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

    // MARK: - Most-recently-used sidebar order

    private func mruWorkspace(_ name: String, activity: Int64? = nil, pinned: Bool = false) -> Workspace {
        var w = Workspace.empty(name: name, cwd: "/tmp")
        if let activity { w.metadata[LayoutReducer.lastActivityMetadataKey] = String(activity) }
        if pinned { w.metadata["pinned"] = "true" }
        return w
    }

    func test_mruOrder_floatsMostRecentActivityToTop_keepingPinnedFirst() {
        // WHY: the user's complaint — after using a workspace it must stay at the top
        // and not snap back. MRU order is derived from a monotonic activity timestamp,
        // so a just-used workspace sorts first within its group regardless of the
        // (revert-prone) window order. Pins still win the top.
        let a = mruWorkspace("never-used")
        let b = mruWorkspace("used-earlier", activity: 100)
        let c = mruWorkspace("used-latest", activity: 200)
        let p = mruWorkspace("pinned", pinned: true)
        let ordered = LayoutReducer.mostRecentlyUsedOrder([a, b, c, p])
        XCTAssertEqual(ordered.map(\.name), ["pinned", "used-latest", "used-earlier", "never-used"],
                       "pinned first, then most-recently-used; a never-used workspace stays below used ones")
    }

    func test_mruOrder_withoutActivityPreservesInputOrder() {
        // WHY: until a workspace is actually used, the list must keep its existing
        // (window/manual) order — the MRU sort only promotes workspaces that have a
        // real activity timestamp, so an idle session looks unchanged.
        let input = [mruWorkspace("x"), mruWorkspace("y"), mruWorkspace("z")]
        XCTAssertEqual(LayoutReducer.mostRecentlyUsedOrder(input).map(\.name), ["x", "y", "z"],
                       "with no activity timestamps the order is preserved (stable sort)")
    }

    func test_promoteWorkspace_stampsActivitySoSidebarOrdersMostRecentFirst() throws {
        // WHY: end-to-end — promoting (what every run start/finish does) must stamp the
        // activity time so the sidebar VM renders the used workspace at the top.
        let (ctx, router) = try make()
        let first = try router.createWorkspace(name: "first", cwd: "/tmp")
        let second = try router.createWorkspace(name: "second", cwd: "/tmp")
        let third = try router.createWorkspace(name: "third", cwd: "/tmp")
        var runningThread = AgentThread(workspaceId: third.id, title: "Running", provider: .claude, model: "claude-opus-4-7")
        runningThread.status = .running
        try ctx.threadRepo.upsert(runningThread)

        XCTAssertTrue(router.promoteWorkspaceIfBusy(third.id))
        XCTAssertNotNil(ctx.state.workspaces[third.id]?.metadata[LayoutReducer.lastActivityMetadataKey],
                        "an activity promote must stamp the workspace's last-activity time")

        let vm = SidebarViewModel(context: ctx, router: router)
        vm.reload()
        XCTAssertEqual(vm.workspaces.first?.id, third.id,
                       "the most-recently-used workspace must render at the top of the sidebar")
        XCTAssertEqual(vm.workspaces.map(\.id), [third.id, first.id, second.id],
                       "used workspace floats to top; the rest keep their prior relative order")
    }

    func test_busyThreadPromotionPersistsWindowOrderWithinPinnedAndUnpinnedGroups() throws {
        let (ctx, router) = try make()
        let pinnedIdle = try router.createWorkspace(name: "pinned-idle", cwd: "/tmp")
        let pinnedBusy = try router.createWorkspace(name: "pinned-busy", cwd: "/tmp")
        let idle = try router.createWorkspace(name: "idle", cwd: "/tmp")
        let busy = try router.createWorkspace(name: "busy", cwd: "/tmp")
        try router.setWorkspacePinned(pinnedIdle.id, true)
        try router.setWorkspacePinned(pinnedBusy.id, true)
        var pinnedThread = AgentThread(workspaceId: pinnedBusy.id, title: "Pinned running", provider: .codex, model: "gpt-5.5")
        pinnedThread.status = .running
        try ctx.threadRepo.upsert(pinnedThread)
        var unpinnedThread = AgentThread(workspaceId: busy.id, title: "Running", provider: .claude, model: "claude-opus-4-7")
        unpinnedThread.status = .running
        try ctx.threadRepo.upsert(unpinnedThread)

        XCTAssertTrue(router.promoteWorkspaceIfBusy(pinnedBusy.id))
        XCTAssertTrue(router.promoteWorkspaceIfBusy(busy.id))
        let vm = SidebarViewModel(context: ctx, router: router)
        vm.reload()

        XCTAssertEqual(ctx.state.window.workspaces, [pinnedBusy.id, pinnedIdle.id, busy.id, idle.id],
                       "a running agent thread must persist the promoted workspace order, with pinned workspaces always ahead of unpinned workspaces")
        XCTAssertEqual(vm.workspaces.map(\.id), [pinnedBusy.id, pinnedIdle.id, busy.id, idle.id],
                       "the sidebar must render the persisted order instead of applying a temporary spinner-only sort")
    }

    func test_busySurfacePromotionPersistsWindowOrderUntilRestart() throws {
        let (ctx, router) = try make()
        let idle = try router.createWorkspace(name: "idle", cwd: "/tmp")
        let busy = try router.createWorkspace(name: "busy", cwd: "/tmp")
        let later = try router.createWorkspace(name: "later", cwd: "/tmp")
        let descriptor = SurfaceDescriptor(
            type: .terminal,
            title: "terminal",
            iconName: "terminal",
            metadata: ["workspace": busy.id.value.uuidString]
        )
        let surface = WorkspaceBusyTestSurface(descriptor: descriptor)
        surface.isBusy = true
        SurfaceRegistry.shared.register(surface)
        try ctx.apply(.addSurface(busy.id, paneID: nil, descriptor: descriptor))

        XCTAssertTrue(router.promoteWorkspaceContainingBusySurface(descriptor.id))
        XCTAssertEqual(ctx.state.window.workspaces, [busy.id, idle.id, later.id],
                       "a terminal foreground job must persistently promote its workspace instead of only moving the visible row")

        surface.isBusy = false
        let vm = SidebarViewModel(context: ctx, router: router)
        vm.reload()

        XCTAssertEqual(vm.workspaces.map(\.id), [busy.id, idle.id, later.id],
                       "clearing the spinner must not undo the user's new persisted workspace order")
    }

    func test_browserLoadingDoesNotCreateWorkspaceSpinnerOrPromotion() throws {
        let (ctx, router) = try make()
        let idle = try router.createWorkspace(name: "idle", cwd: "/tmp")
        let browserWorkspace = try router.createWorkspace(name: "browser-loading", cwd: "/tmp")
        let descriptor = SurfaceDescriptor(
            type: .browser,
            title: "Loading",
            iconName: "globe",
            metadata: ["workspace": browserWorkspace.id.value.uuidString]
        )
        let surface = WorkspaceBusyTestSurface(descriptor: descriptor)
        surface.isBusy = true
        SurfaceRegistry.shared.register(surface)
        try ctx.apply(.addSurface(browserWorkspace.id, paneID: nil, descriptor: descriptor))

        XCTAssertFalse(router.isWorkspaceBusy(browserWorkspace.id),
                       "browser loading may show a tab-level progress state, but it must not create the workspace spinner")
        XCTAssertNil(try router.listWorkspaces().first(where: { $0.id == browserWorkspace.id })?.metadata["busy"],
                     "workspace busy metadata is reserved for terminal jobs and agent runs")
        XCTAssertFalse(router.promoteWorkspaceContainingBusySurface(descriptor.id),
                       "browser loading must not reorder the workspace list")
        XCTAssertEqual(ctx.state.window.workspaces, [idle.id, browserWorkspace.id])
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

    func test_sidebarDroppedFolderCreatesSelectedWorkspace() throws {
        let (ctx, router) = try make()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2DroppedWorkspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let vm = SidebarViewModel(context: ctx, router: router)

        XCTAssertTrue(vm.createWorkspace(fromFolder: folder),
                      "dropping a Finder folder onto the global sidebar must create a workspace from that folder")

        let selected = try XCTUnwrap(ctx.state.window.selectedWorkspaceID)
        let workspace = try XCTUnwrap(ctx.state.workspaces[selected])
        XCTAssertEqual(workspace.name, folder.lastPathComponent)
        XCTAssertEqual(workspace.cwd, folder.standardizedFileURL.path)
    }

    func test_sidebarDroppedFileIsRejectedForWorkspaceCreation() throws {
        let (ctx, router) = try make()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("RC2DroppedFile-\(UUID().uuidString).txt")
        try "not a workspace".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let vm = SidebarViewModel(context: ctx, router: router)

        XCTAssertFalse(vm.createWorkspace(fromFolder: file),
                       "dropping a regular file must not create a broken workspace")
        XCTAssertTrue(ctx.state.workspaces.isEmpty)
    }

    func test_sidebarDropDecodesFinderFileURLPayload() {
        let folder = URL(fileURLWithPath: "/tmp/RC2 Finder Drop", isDirectory: true)
        let data = folder.absoluteURL.dataRepresentation as NSData

        XCTAssertEqual(SidebarViewModel.fileURL(fromDroppedItem: data)?.path, folder.path,
                       "Finder drag payloads arrive as file-url data and must decode before workspace creation")
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

@MainActor
private final class WorkspaceBusyTestSurface: Surface {
    var descriptor: SurfaceDescriptor
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    var isBusy = false

    init(descriptor: SurfaceDescriptor) {
        self.descriptor = descriptor
    }

    func focus() {}
    func unfocus() {}
    func close() {}
    func sendText(_ text: String) {}
    func readText() -> String { "" }
    func snapshot() -> [String: String] { [:] }
}
