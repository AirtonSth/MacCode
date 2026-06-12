import XCTest
@testable import AppShell
@testable import CoreModel
@testable import SocketServer
@testable import Surfaces
import Persistence

/// QA :13 — EventBus contract tests for mac-initiated workspace mutations.
///
/// WHY: iOS reducers are tested against `workspace.renamed` / `workspace.reordered`
/// fixtures in `ReducerAndSafetyTests.swift:384-400`. Those iOS tests pass
/// regardless of what the macOS sidebar emits because no host-side test ever
/// drove the mac mutation path and asserted the wire shape.
///
/// This file is the host-side half of that contract:
///   - It drives the REAL AppCommandRouter rename / reorder paths (the same
///     paths a user triggers from the mac sidebar, not the Dispatcher/RPC path).
///   - It asserts the exact field names and types that the iOS ReducerAndSafetyTests
///     fixtures are built around.
///
/// If a field is renamed or removed in the mac emit code these tests fail before
/// iOS ever sees the change, preventing silent reducer breakage.
///
/// iOS fixture schema (ReducerAndSafetyTests.swift:384-400):
///   workspace.renamed  → { "workspace_id": <uuid-string>, "name": <string> }
///   workspace.reordered → { "workspace_id": <uuid-string>, "position": <number>, "order": [<uuid-string>] }
///   workspace.reordered (pin-driven) → { "workspace_id": <uuid-string>, "order": [<uuid-string>] }
@MainActor
final class WorkspaceEventBusContractTests: XCTestCase {

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
        let dir = NSTemporaryDirectory() + "RC2WSContract-" + UUID().uuidString
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

    // MARK: - workspace.renamed contract

    func test_renameWorkspace_macSidebarPath_emitsRenamedWithIOSFixtureFieldNames() throws {
        // WHY: iOS ReducerAndSafetyTests:384 decodes workspace.renamed using the
        // keys "workspace_id" and "name". If the mac sidebar rename path emits
        // different keys the iOS reducer silently does nothing and the rename is
        // lost on paired devices.
        let (_, router) = try make()
        let ws = try router.createWorkspace(name: "original", cwd: NSTemporaryDirectory())

        let events = try capture(kinds: ["workspace.renamed"]) {
            try router.renameWorkspace(ws.id, "updated")
        }

        XCTAssertEqual(events.map(\.kind), ["workspace.renamed"],
                       "renaming a workspace from the mac sidebar must publish exactly one workspace.renamed event so iOS mirrors the change")

        let payload = try XCTUnwrap(events.first?.payload.objectValue,
                                    "workspace.renamed payload must be a JSON object matching the iOS fixture schema")

        // Field: workspace_id — iOS ReducerAndSafetyTests:384 reads this key to
        // find the workspace row to update.
        XCTAssertEqual(payload["workspace_id"]?.stringValue, ws.id.value.uuidString,
                       "workspace.renamed: workspace_id must be the lowercase hyphenated UUID string; iOS uses it to locate the row")

        // Field: name — iOS ReducerAndSafetyTests:384 reads this key for the new label.
        XCTAssertEqual(payload["name"]?.stringValue, "updated",
                       "workspace.renamed: name must carry the new display label; the iOS row would remain stale without it")

        // Schema completeness — iOS fixture has exactly these two keys.
        XCTAssertEqual(Set(payload.keys), ["workspace_id", "name"],
                       "workspace.renamed: payload must have exactly the two keys the iOS fixture schema defines; extra or missing keys indicate contract drift")
    }

    func test_renameWorkspace_macSidebarPath_doesNotEmitReordered() throws {
        // WHY: The iOS reducer for workspace.renamed does not reorder the sidebar.
        // Emitting a spurious workspace.reordered would cause iOS to reorder
        // the list even though nothing moved, corrupting the sidebar sort.
        let (_, router) = try make()
        let ws = try router.createWorkspace(name: "a", cwd: NSTemporaryDirectory())
        _ = try router.createWorkspace(name: "b", cwd: NSTemporaryDirectory())

        let events = try capture(kinds: ["workspace.reordered"]) {
            try router.renameWorkspace(ws.id, "a-renamed")
        }

        XCTAssertTrue(events.isEmpty,
                      "renameWorkspace must not emit workspace.reordered; only the name changes, not the position")
    }

    // MARK: - workspace.reordered contract (drag / explicit position)

    func test_reorderWorkspace_macSidebarPath_emitsReorderedWithIOSFixtureFieldNames() throws {
        // WHY: iOS ReducerAndSafetyTests:392 decodes workspace.reordered using the
        // keys "workspace_id", "position", and "order". Missing any of these keys
        // means iOS cannot re-sort the sidebar after a mac drag.
        let (ctx, router) = try make()
        _ = try router.createWorkspace(name: "first", cwd: NSTemporaryDirectory())
        let second = try router.createWorkspace(name: "second", cwd: NSTemporaryDirectory())

        let events = try capture(kinds: ["workspace.reordered"]) {
            try router.reorderWorkspace(second.id, position: 0)
        }

        XCTAssertEqual(events.map(\.kind), ["workspace.reordered"],
                       "dragging a workspace row on mac must publish exactly one workspace.reordered so iOS re-sorts the sidebar")

        let payload = try XCTUnwrap(events.first?.payload.objectValue,
                                    "workspace.reordered payload must be a JSON object matching the iOS fixture schema")

        // Field: workspace_id — iOS ReducerAndSafetyTests:392 reads this to identify
        // which workspace moved.
        XCTAssertEqual(payload["workspace_id"]?.stringValue, second.id.value.uuidString,
                       "workspace.reordered: workspace_id must identify the workspace that was moved")

        // Field: position — iOS ReducerAndSafetyTests:392 reads this for the new
        // insertion index in the sidebar.
        XCTAssertEqual(payload["position"]?.intValue, 0,
                       "workspace.reordered: position must be the drop index so iOS inserts the row at the right slot")

        // Field: order — iOS ReducerAndSafetyTests:392 reads this to rebuild the
        // full sidebar sort without requiring a server round-trip.
        let order = try XCTUnwrap(payload["order"]?.arrayValue,
                                  "workspace.reordered: order must be a JSON array of UUID strings")
        XCTAssertFalse(order.isEmpty,
                       "workspace.reordered: order must contain at least one entry")
        XCTAssertTrue(order.allSatisfy { $0.stringValue != nil },
                      "workspace.reordered: every element in order must be a UUID string; iOS decodes them as workspace IDs")
        XCTAssertTrue(order.contains { $0.stringValue == second.id.value.uuidString },
                      "workspace.reordered: order must include the reordered workspace's UUID")

        // Schema completeness — iOS fixture has exactly workspace_id + position + order.
        XCTAssertEqual(Set(payload.keys), ["workspace_id", "position", "order"],
                       "workspace.reordered (drag): payload must have exactly the three keys the iOS fixture schema defines")
    }

    // MARK: - workspace.reordered contract (pin-driven — no position)

    func test_setWorkspacePinned_macSidebarPath_emitsReorderedWithoutPosition() throws {
        // WHY: iOS ReducerAndSafetyTests:400 tests the pin-driven reorder shape
        // which has no "position" key. The iOS reducer must not read a stale/zero
        // position when pinning; the order array alone drives the sort. If "position"
        // were present the iOS reducer might re-insert the row at index 0 instead of
        // respecting the pinned-first ordering encoded in the order array.
        let (_, router) = try make()
        _ = try router.createWorkspace(name: "alpha", cwd: NSTemporaryDirectory())
        let beta = try router.createWorkspace(name: "beta", cwd: NSTemporaryDirectory())

        let reordered = try capture(kinds: ["workspace.reordered"]) {
            try router.setWorkspacePinned(beta.id, true)
        }.filter { $0.kind == "workspace.reordered" }

        XCTAssertEqual(reordered.count, 1,
                       "setWorkspacePinned must emit exactly one workspace.reordered for iOS to re-sort the sidebar")

        let payload = try XCTUnwrap(reordered.first?.payload.objectValue,
                                    "workspace.reordered (pin) payload must be a JSON object")

        // workspace_id must still be present
        XCTAssertEqual(payload["workspace_id"]?.stringValue, beta.id.value.uuidString,
                       "workspace.reordered (pin): workspace_id must identify the workspace that was pinned")

        // order must be present
        let order = try XCTUnwrap(payload["order"]?.arrayValue,
                                  "workspace.reordered (pin): order must be present so iOS can rebuild the full sorted list")
        XCTAssertFalse(order.isEmpty, "workspace.reordered (pin): order must not be empty")

        // position must be absent — iOS ReducerAndSafetyTests:400 fixture has no position key
        XCTAssertNil(payload["position"],
                     "workspace.reordered (pin): position must be absent; iOS fixture for pin-driven reorder has no position key and a spurious one would corrupt the insertion index")
    }
}
