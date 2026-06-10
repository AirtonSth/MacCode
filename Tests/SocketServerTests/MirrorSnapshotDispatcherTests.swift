import XCTest
@testable import SocketServer
import CoreModel
import Persistence
import AgentRuntime

/// cross-platform.md item 34 (host side): `mirror.snapshot` collapses the iOS
/// load() per-pane `pane.surfaces` N round-trips into ONE network call.
///
/// The wire contract REQUIRES that the aggregated payload be byte-shape-identical
/// to the existing `pane.list` and `pane.surfaces` results, because iOS reuses
/// its existing `pane.list` decoder for `panes` and its `[SurfaceDescriptor]`
/// decoder for each `surfaces` array. These tests therefore assert equality
/// against the live `pane.list` / `pane.surfaces` dispatches on the SAME router,
/// so any drift in the aggregated sub-shapes fails the suite.
@MainActor
final class MirrorSnapshotFakeRouter: FakeRouter {
    // Pane.list rows as the real router would emit them: a "pane" row carries
    // kind=="pane" and id==<pane uuid>; the snapshot case derives pane ids from
    // exactly these rows, so we mirror that contract here.
    var paneRows: [[String: JSONValue]] = []
    var surfacesByPane: [PaneID: [SurfaceDescriptor]] = [:]

    override func paneList(workspace: WorkspaceID) throws -> [[String: JSONValue]] {
        paneRows
    }
    override func paneSurfaces(pane: PaneID, workspace: WorkspaceID) throws -> [SurfaceDescriptor] {
        surfacesByPane[pane] ?? []
    }
}

final class MirrorSnapshotDispatcherTests: XCTestCase {

    @MainActor
    private func makePopulatedRouter(workspace wid: WorkspaceID) -> (MirrorSnapshotFakeRouter, [PaneID]) {
        let router = MirrorSnapshotFakeRouter()
        let paneA = PaneID()
        let paneB = PaneID()
        // A non-pane row (e.g. a split container) must be ignored when deriving
        // pane ids -- proves the snapshot uses the same kind=="pane" filter as
        // the pane.surfaces else-branch and does not over-collect.
        router.paneRows = [
            ["kind": .string("split"), "id": .string(UUID().uuidString)],
            ["kind": .string("pane"), "id": .string(paneA.value.uuidString)],
            ["kind": .string("pane"), "id": .string(paneB.value.uuidString)]
        ]
        router.surfacesByPane = [
            paneA: [SurfaceDescriptor(type: .terminal, title: "A0"),
                    SurfaceDescriptor(type: .files, title: "A1")],
            paneB: [SurfaceDescriptor(type: .agentApp, title: "B0")]
        ]
        return (router, [paneA, paneB])
    }

    /// (a) The result object exposes EXACTLY the two contract keys. A stray or
    /// missing key would break the iOS decoder that keys on these names.
    @MainActor
    func test_mirrorSnapshot_resultHasExactlyPanesAndPaneSurfacesKeys() async {
        let wid = WorkspaceID()
        let (router, _) = makePopulatedRouter(workspace: wid)
        let d = JSONRPCDispatcher(router: router)
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "mirror.snapshot", params: ["workspace_id": .string(wid.value.uuidString)]))
        guard case .object(let body) = resp.result else { return XCTFail("mirror.snapshot must return an object") }
        XCTAssertEqual(Set(body.keys), ["panes", "pane_surfaces"],
                       "mirror.snapshot result keys must be exactly panes + pane_surfaces so iOS reuses its decoders")
    }

    /// (b) `panes` is the verbatim pane.list encoding. We compare against the
    /// live pane.list dispatch on the SAME router: if the snapshot re-encoded
    /// panes differently, iOS's reused pane.list decoder would break.
    @MainActor
    func test_mirrorSnapshot_panesEqualsPaneListForSameWorkspace() async {
        let wid = WorkspaceID()
        let (router, _) = makePopulatedRouter(workspace: wid)
        let d = JSONRPCDispatcher(router: router)

        let snap = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "mirror.snapshot", params: ["workspace_id": .string(wid.value.uuidString)]))
        let list = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "pane.list", params: ["workspace_id": .string(wid.value.uuidString)]))

        guard case .object(let body) = snap.result else { return XCTFail("missing panes") }
        XCTAssertEqual(body["panes"], list.result,
                       "mirror.snapshot panes must be byte-shape-identical to pane.list output")
    }

    /// (c) Each pane_surfaces entry carries pane_id + surfaces, and the surfaces
    /// for a pane equal the live pane.surfaces dispatch for that pane id. This is
    /// the load-bearing assertion: iOS reuses [SurfaceDescriptor] decoding on
    /// each surfaces array, so it must match pane.surfaces exactly.
    @MainActor
    func test_mirrorSnapshot_eachEntryMatchesPaneSurfacesForThatPane() async {
        let wid = WorkspaceID()
        let (router, paneIDs) = makePopulatedRouter(workspace: wid)
        let d = JSONRPCDispatcher(router: router)

        let snap = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "mirror.snapshot", params: ["workspace_id": .string(wid.value.uuidString)]))
        guard case .object(let body) = snap.result,
              case .array(let perPane) = body["pane_surfaces"] else { return XCTFail("missing pane_surfaces array") }

        // One entry per "pane" row, in order, and no entry for the non-pane row.
        XCTAssertEqual(perPane.count, paneIDs.count,
                       "pane_surfaces must contain one entry per pane row (non-pane rows excluded)")

        for (index, pid) in paneIDs.enumerated() {
            guard case .object(let entry) = perPane[index] else { return XCTFail("entry not an object") }
            XCTAssertEqual(Set(entry.keys), ["pane_id", "surfaces"],
                           "each pane_surfaces entry must expose exactly pane_id + surfaces")
            XCTAssertEqual(entry["pane_id"], JSONValue.string(pid.value.uuidString),
                           "pane_id must be the pane uuid string")

            let ps = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(100 + index), method: "pane.surfaces", params: [
                "workspace_id": .string(wid.value.uuidString),
                "id": .string(pid.value.uuidString)
            ]))
            XCTAssertEqual(entry["surfaces"], ps.result,
                           "surfaces for a pane must be byte-shape-identical to pane.surfaces for that pane id")
        }
    }

    /// (d) A workspace with zero panes returns empty arrays for both keys -- the
    /// snapshot must not error or omit keys when there is nothing to mirror.
    @MainActor
    func test_mirrorSnapshot_emptyWorkspaceReturnsEmptyArrays() async {
        let wid = WorkspaceID()
        // Base FakeRouter returns [] for both paneList and paneSurfaces.
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "mirror.snapshot", params: ["workspace_id": .string(wid.value.uuidString)]))
        guard case .object(let body) = resp.result else { return XCTFail("must return object even when empty") }
        XCTAssertEqual(body["panes"], JSONValue.array([]), "panes must be [] for a workspace with no panes")
        XCTAssertEqual(body["pane_surfaces"], JSONValue.array([]), "pane_surfaces must be [] for a workspace with no panes")
    }
}
