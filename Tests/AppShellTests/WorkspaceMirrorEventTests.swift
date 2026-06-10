import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

/// P1: AppCommandRouter must publish workspace.created/renamed/updated/reordered
/// from its OWN mac-local mutation paths so a paired iOS device mirrors sidebar
/// edits live. Until now the router only published workspace.closed; the other
/// kinds came solely from the Dispatcher (iOS-initiated). These tests pin both
/// the pure payload schema (so it stays byte-compatible with the Dispatcher and
/// the iOS reducer) and the fact that the router actually emits the events.
@MainActor
final class WorkspaceMirrorEventTests: XCTestCase {
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
        let dir = NSTemporaryDirectory() + "RC2WSMirror-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    private func capture(kinds: Set<String>, _ body: () throws -> Void) rethrows -> [EventBus.Event] {
        let startSeq = EventBus.shared.snapshot().lastSeq
        var events: [EventBus.Event] = []
        let token = EventBus.shared.subscribe(since: startSeq) { event in
            if kinds.contains(event.kind) { events.append(event) }
        }
        defer { EventBus.shared.unsubscribe(token) }
        try body()
        return events
    }

    // MARK: - Pure payload builders match the Dispatcher schema

    func test_createdPayload_isFullWorkspaceObjectMatchingDispatcherEncode() throws {
        let ws = Workspace.empty(name: "demo", cwd: "/tmp/demo")
        let payload = AppCommandRouter.workspaceCreatedPayload(ws)
        // Dispatcher publishes workspace.created via encode(ws): a full Workspace
        // JSON object. iOS upserts the row from id/name/cwd, so those keys are
        // load-bearing and must survive the round-trip identically.
        guard let obj = payload.objectValue else {
            return XCTFail("workspace.created payload must be a JSON object, not \(payload)")
        }
        XCTAssertEqual(obj["id"]?.objectValue?["value"]?.stringValue, ws.id.value.uuidString,
                       "iOS keys the mirrored row by id; a missing/renamed id key would orphan the new workspace")
        XCTAssertEqual(obj["name"]?.stringValue, "demo",
                       "the created event must carry the workspace name so the iOS sidebar row is not blank")
        XCTAssertEqual(obj["cwd"]?.stringValue, "/tmp/demo",
                       "cwd must round-trip so iOS shows the correct working directory for the new workspace")
        XCTAssertNotNil(obj["layout"],
                        "the created payload mirrors the Dispatcher's full-Workspace encode, which includes layout")
    }

    func test_renamedPayload_usesWorkspaceIdAndNameKeys() {
        let id = WorkspaceID()
        let payload = AppCommandRouter.workspaceRenamedPayload(id: id, name: "renamed")
        // Must match Dispatcher workspace.rename: {workspace_id, name}.
        XCTAssertEqual(payload, .object([
            "workspace_id": .string(id.value.uuidString),
            "name": .string("renamed")
        ]), "workspace.renamed must use the exact {workspace_id,name} keys the iOS reducer reads")
    }

    func test_updatedPayload_nestsEditedFieldsUnderMetadata() {
        let id = WorkspaceID()
        let payload = AppCommandRouter.workspaceUpdatedPayload(id: id, metadata: ["description": .string("svc")])
        // Must match Dispatcher set_description -> workspace.updated:
        // {workspace_id, metadata:{description}}.
        XCTAssertEqual(payload, .object([
            "workspace_id": .string(id.value.uuidString),
            "metadata": .object(["description": .string("svc")])
        ]), "workspace.updated must nest edited fields under metadata so iOS merges them into the row metadata")
    }

    func test_reorderedPayload_carriesPositionAndFullOrder() {
        let id = WorkspaceID()
        let a = WorkspaceID(), b = WorkspaceID()
        let payload = AppCommandRouter.workspaceReorderedPayload(id: id, position: 2, order: [a, b, id])
        // Must match Dispatcher workspace.reorder: {workspace_id, position, order}.
        XCTAssertEqual(payload, .object([
            "workspace_id": .string(id.value.uuidString),
            "position": .number(2),
            "order": .array([.string(a.value.uuidString), .string(b.value.uuidString), .string(id.value.uuidString)])
        ]), "workspace.reordered must carry the new position and the full window order the iOS sidebar re-sorts by")
    }

    func test_reorderedPayload_omitsPositionWhenNilLikePinReorder() {
        let id = WorkspaceID()
        let payload = AppCommandRouter.workspaceReorderedPayload(id: id, position: nil, order: [id])
        // Pin-driven reorder (Dispatcher set_pinned) publishes order WITHOUT a
        // position; the order-only shape must be preserved so iOS does not read
        // a stale/zero position.
        XCTAssertEqual(payload, .object([
            "workspace_id": .string(id.value.uuidString),
            "order": .array([.string(id.value.uuidString)])
        ]), "pin-driven reorder must publish order only, with no position key")
    }

    // MARK: - The router actually emits the events from mac-local mutations

    func test_createWorkspace_publishesCreatedEventForIosMirror() throws {
        let (_, router) = try make()
        var ws: Workspace?
        let events = try capture(kinds: ["workspace.created"]) {
            ws = try router.createWorkspace(name: "live", cwd: "/tmp")
        }
        let created = try XCTUnwrap(ws)
        XCTAssertEqual(events.map(\.kind), ["workspace.created"],
                       "a mac-local sidebar 'new workspace' must publish exactly one workspace.created so iOS adds the row")
        XCTAssertEqual(events.first?.payload.objectValue?["id"]?.objectValue?["value"]?.stringValue, created.id.value.uuidString,
                       "the published id must be the real new workspace id the iOS mirror keys on")
    }

    func test_renameWorkspace_publishesRenamedEvent() throws {
        let (_, router) = try make()
        let ws = try router.createWorkspace(name: "old", cwd: "/tmp")
        let events = try capture(kinds: ["workspace.renamed"]) {
            try router.renameWorkspace(ws.id, "new")
        }
        XCTAssertEqual(events.map(\.kind), ["workspace.renamed"],
                       "renaming locally must mirror to iOS; before this fix only the Dispatcher path emitted it")
        XCTAssertEqual(events.first?.payload.objectValue?["name"]?.stringValue, "new",
                       "the rename event must carry the new name the iOS row should display")
    }

    func test_setColor_publishesUpdatedEventWithMetadata() throws {
        let (_, router) = try make()
        let ws = try router.createWorkspace(name: "w", cwd: "/tmp")
        let events = try capture(kinds: ["workspace.updated"]) {
            try router.setWorkspaceColor(ws.id, "#ff0000")
        }
        XCTAssertEqual(events.map(\.kind), ["workspace.updated"],
                       "a local color change must publish workspace.updated so the iOS accent mirrors live")
        XCTAssertEqual(events.first?.payload.objectValue?["metadata"]?.objectValue?["color"]?.stringValue, "#ff0000",
                       "the color must arrive under metadata.color to match the Dispatcher schema")
    }

    func test_setPinned_publishesUpdatedThenReordered() throws {
        let (_, router) = try make()
        let first = try router.createWorkspace(name: "one", cwd: "/tmp")
        let second = try router.createWorkspace(name: "two", cwd: "/tmp")
        let events = try capture(kinds: ["workspace.updated", "workspace.reordered"]) {
            try router.setWorkspacePinned(second.id, true)
        }
        XCTAssertEqual(events.map(\.kind), ["workspace.updated", "workspace.reordered"],
                       "pinning locally must mirror both the pinned metadata and the new order, matching the Dispatcher's two events")
        XCTAssertEqual(events.first?.payload.objectValue?["metadata"]?.objectValue?["pinned"]?.stringValue, "true",
                       "pinned metadata must read 'true' so iOS marks the row pinned")
        let order = events.last?.payload.objectValue?["order"]?.arrayValue?.compactMap { $0.stringValue }
        XCTAssertEqual(order, [second.id.value.uuidString, first.id.value.uuidString],
                       "the reorder event must carry the pinned-first window order the iOS sidebar re-sorts by")
        XCTAssertNil(events.last?.payload.objectValue?["position"],
                     "pin-driven reorder must omit position, matching the Dispatcher set_pinned event")
    }

    func test_reorderWorkspace_publishesReorderedWithPosition() throws {
        let (_, router) = try make()
        _ = try router.createWorkspace(name: "one", cwd: "/tmp")
        let target = try router.createWorkspace(name: "two", cwd: "/tmp")
        let events = try capture(kinds: ["workspace.reordered"]) {
            try router.reorderWorkspace(target.id, position: 0)
        }
        XCTAssertEqual(events.map(\.kind), ["workspace.reordered"],
                       "dragging a row locally must mirror the new order to iOS")
        XCTAssertEqual(events.first?.payload.objectValue?["position"]?.intValue, 0,
                       "the reorder event must carry the drop position, matching the Dispatcher workspace.reorder schema")
    }
}
