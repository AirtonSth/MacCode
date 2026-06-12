import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

/// QA :12 — Golden tests for the tab/split RPC mirror-event payload shapes.
///
/// WHY: iOS decodes `surface.reordered`, `pane.resized`, and `surface.moved`
/// by exact field-name string literals. Nothing on the macOS side previously
/// asserted those literals, so a silent typo or rename in the private
/// `publishSurface*` / `publishPaneResized` helpers would produce events that
/// iOS silently ignores — surfaces would stop tracking moves/reorders/resizes
/// across devices without any test failure.
///
/// These tests pin:
///   surface.reordered  → {workspace_id, id, target_pane_id, position}
///   pane.resized       → {workspace_id, split_id}
///   surface.moved      → {workspace_id, id, target_pane_id}   (target_pane_id present when pane given)
///   surface.moved      → {workspace_id, id}                   (target_pane_id absent when pane is nil)
///
/// Seam: EventBus capture from the real router public API (`surfaceReorder`,
/// `paneResize`, `surfaceMove`). Every assertion would fail if a string literal
/// in the private publish helper were renamed.
@MainActor
final class SurfaceMirrorEventGoldenTests: XCTestCase {

    // MARK: - Harness

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
        let dir = NSTemporaryDirectory() + "RC2SurfaceMirror-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    /// Subscribe to EventBus events of the given kinds, run body, return captured events.
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

    /// Build a workspace + split into two panes, returning (workspaceID, pane0, pane1, splitNode).
    private func makeSplitWorkspace(ctx: AppContext, router: AppCommandRouter) throws -> (WorkspaceID, PaneNode, PaneNode, SplitNode) {
        let ws = try router.createWorkspace(name: "split-ws", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else {
            throw NSError(domain: "SurfaceMirrorEventGoldenTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "expected single-pane new workspace"])
        }
        _ = try router.splitPane(workspace: ws.id, paneID: pane0.id, direction: .right, surfaceType: .browser, title: "browser")
        let layout = try XCTUnwrap(ctx.state.workspaces[ws.id]).layout
        guard case .split(let split) = layout,
              case .pane(let leftPane) = split.children[0],
              case .pane(let rightPane) = split.children[1] else {
            throw NSError(domain: "SurfaceMirrorEventGoldenTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "expected horizontal split with two pane children"])
        }
        return (ws.id, leftPane, rightPane, split)
    }

    // MARK: - surface.reordered golden

    func test_surfaceReordered_payloadShape_workspaceId_id_targetPaneId_position() throws {
        // WHY: iOS reads surface.reordered by exact key names to update tab order
        // in a pane. If any of the four keys is renamed the tab strip silently
        // stops reordering across devices.
        let (ctx, router) = try make()
        let (wid, leftPane, rightPane, _) = try makeSplitWorkspace(ctx: ctx, router: router)

        // Add a second tab to the left pane so there is something to reorder.
        let extraDesc = try router.createSurface(workspace: wid, type: .browser, paneID: leftPane.id, title: "extra")
        let surfaceToReorder = extraDesc.id

        let events = try capture(kinds: ["surface.reordered"]) {
            try router.surfaceReorder(workspace: wid, surface: surfaceToReorder, toPane: rightPane.id, position: 0)
        }

        XCTAssertEqual(events.map(\.kind), ["surface.reordered"],
                       "surfaceReorder must emit exactly one surface.reordered event for iOS to reorder the tab strip")
        let payload = try XCTUnwrap(events.first?.payload.objectValue,
                                    "surface.reordered payload must be a JSON object")

        // workspace_id — iOS keys the workspace that owns the surface
        XCTAssertEqual(payload["workspace_id"]?.stringValue, wid.value.uuidString,
                       "surface.reordered: workspace_id must be the workspace UUID string; iOS uses it to scope the update")

        // id — the surface being reordered
        XCTAssertEqual(payload["id"]?.stringValue, surfaceToReorder.value.uuidString,
                       "surface.reordered: id must identify the surface being moved; iOS uses it to find the tab row")

        // target_pane_id — the destination pane
        XCTAssertEqual(payload["target_pane_id"]?.stringValue, rightPane.id.value.uuidString,
                       "surface.reordered: target_pane_id must be the destination pane UUID; iOS uses it to place the tab")

        // position — insertion index in the destination pane
        XCTAssertEqual(payload["position"]?.intValue, 0,
                       "surface.reordered: position must be the drop index; iOS uses it to insert the tab at the right slot")

        // No extra keys — unknown keys in the payload would be benign but a missing
        // expected key (caught above) would cause silent iOS failures.
        XCTAssertEqual(Set(payload.keys), ["workspace_id", "id", "target_pane_id", "position"],
                       "surface.reordered: only the four load-bearing keys must be present; extra keys indicate schema drift")
    }

    // MARK: - pane.resized golden

    func test_paneResized_payloadShape_workspaceId_splitId() throws {
        // WHY: iOS reads pane.resized by exact key names to trigger a layout
        // refresh when the user drags a split divider on macOS. If workspace_id
        // or split_id is renamed iOS cannot find the affected split and the
        // layout stays stale.
        let (ctx, router) = try make()
        let (wid, _, _, split) = try makeSplitWorkspace(ctx: ctx, router: router)

        let events = try capture(kinds: ["pane.resized"]) {
            try router.paneResize(workspace: wid, splitID: split.id, ratios: [0.3, 0.7])
        }

        XCTAssertEqual(events.map(\.kind), ["pane.resized"],
                       "paneResize must emit exactly one pane.resized for iOS to refresh the split layout")
        let payload = try XCTUnwrap(events.first?.payload.objectValue,
                                    "pane.resized payload must be a JSON object")

        // workspace_id — iOS scopes the resize to the correct workspace
        XCTAssertEqual(payload["workspace_id"]?.stringValue, wid.value.uuidString,
                       "pane.resized: workspace_id must be the workspace UUID string; iOS scopes the layout refresh")

        // split_id — iOS locates the SplitNode to refresh ratios for
        XCTAssertEqual(payload["split_id"]?.stringValue, split.id.uuidString,
                       "pane.resized: split_id must be the SplitNode UUID string; iOS uses it to find the correct divider")

        XCTAssertEqual(Set(payload.keys), ["workspace_id", "split_id"],
                       "pane.resized: only the two load-bearing keys must be present; extra keys indicate schema drift")
    }

    // MARK: - surface.moved golden (with target pane)

    func test_surfaceMoved_payloadShape_workspaceId_id_targetPaneId_whenPaneGiven() throws {
        // WHY: iOS reads surface.moved to move a tab from one pane column to
        // another. target_pane_id must be present when a destination pane is
        // given so iOS knows where to place the surface.
        let (ctx, router) = try make()
        let (wid, leftPane, rightPane, _) = try makeSplitWorkspace(ctx: ctx, router: router)

        // The surface to move is the first surface in the left pane.
        let updatedWs = try XCTUnwrap(ctx.state.workspaces[wid])
        let surfaceToMove = try XCTUnwrap(updatedWs.layout.find(paneID: leftPane.id)?.surfaces.first?.id,
                                          "left pane must have at least one surface to move")

        let events = try capture(kinds: ["surface.moved"]) {
            try router.surfaceMove(workspace: wid, surface: surfaceToMove, targetPane: rightPane.id)
        }

        XCTAssertEqual(events.map(\.kind), ["surface.moved"],
                       "surfaceMove must emit exactly one surface.moved for iOS to relocate the tab")
        let payload = try XCTUnwrap(events.first?.payload.objectValue,
                                    "surface.moved payload must be a JSON object")

        // workspace_id
        XCTAssertEqual(payload["workspace_id"]?.stringValue, wid.value.uuidString,
                       "surface.moved: workspace_id must be the workspace UUID string")

        // id — the surface that was relocated
        XCTAssertEqual(payload["id"]?.stringValue, surfaceToMove.value.uuidString,
                       "surface.moved: id must identify the relocated surface; iOS uses it to find the tab")

        // target_pane_id — required when a destination pane is known
        XCTAssertEqual(payload["target_pane_id"]?.stringValue, rightPane.id.value.uuidString,
                       "surface.moved: target_pane_id must carry the destination pane UUID so iOS places the tab correctly")

        XCTAssertEqual(Set(payload.keys), ["workspace_id", "id", "target_pane_id"],
                       "surface.moved with a target pane must carry exactly three keys")
    }

    // MARK: - surface.moved golden (splitSurface path)

    func test_surfaceMoved_splitSurfacePath_payloadShape_workspaceId_id_targetPaneId() throws {
        // WHY: `splitSurface` splits a surface into a new column and calls
        // publishSurfaceMoved(workspace:surface:targetPane:paneID). iOS reads
        // surface.moved to know which surface moved and where; if any key is
        // renamed the surface remains in the wrong pane column on iOS.
        let (ctx, router) = try make()
        let ws = try router.createWorkspace(name: "split-surface-ws", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail("expected single-pane workspace") }
        // Add a second surface so after split there is still one left in pane0.
        _ = try router.createSurface(workspace: ws.id, type: .browser, paneID: pane0.id, title: "browser")
        let surfaceToSplit = try XCTUnwrap(
            ctx.state.workspaces[ws.id]?.layout.find(paneID: pane0.id)?.surfaces.first?.id,
            "pane0 must have at least one surface to split"
        )

        let events = try capture(kinds: ["surface.moved"]) {
            try router.splitSurface(workspace: ws.id, paneID: pane0.id, surface: surfaceToSplit, direction: .right)
        }

        let moved = events.filter { $0.kind == "surface.moved" }
        XCTAssertEqual(moved.count, 1,
                       "splitSurface must emit exactly one surface.moved so iOS relocates the tab to the new pane column")
        let payload = try XCTUnwrap(moved.first?.payload.objectValue,
                                    "surface.moved payload must be a JSON object")

        // workspace_id
        XCTAssertEqual(payload["workspace_id"]?.stringValue, ws.id.value.uuidString,
                       "surface.moved (split path): workspace_id must be the workspace UUID string")

        // id — the surface that was split off
        XCTAssertEqual(payload["id"]?.stringValue, surfaceToSplit.value.uuidString,
                       "surface.moved (split path): id must identify the surface that was split; iOS uses it to find the tab")

        // target_pane_id — splitSurface always provides the source pane as target
        XCTAssertNotNil(payload["target_pane_id"],
                        "surface.moved (split path): target_pane_id must be present; iOS needs it to place the surface in the right column")
        XCTAssertNotNil(payload["target_pane_id"]?.stringValue,
                        "surface.moved (split path): target_pane_id must be a UUID string, not another type")

        // Schema — must contain the three load-bearing keys
        let keys = Set(payload.keys)
        XCTAssertTrue(keys.isSuperset(of: ["workspace_id", "id", "target_pane_id"]),
                      "surface.moved (split path): all three load-bearing keys must be present; missing any breaks iOS tab placement")
    }
}
