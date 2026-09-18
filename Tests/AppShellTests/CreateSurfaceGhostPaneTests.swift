import XCTest
@testable import AppShell
@testable import SocketServer
@testable import CoreModel
@testable import Surfaces

// P2 — A surface created into a pane that is not in the layout must be refused,
// not silently accepted.
//
// WHY this matters: `surface.create` / `files.open_tab` take a client-supplied
// `pane_id`. `addSurface` no-ops on a pane id that is not in the layout, so a
// stale id used to end with the router returning a created descriptor, the
// surface runtime registered, and `surface.created` published — a tab the
// paired client paints and the Mac never had, cached by the command receipt.
// The specs below pin the two halves of the contract: the RPC fails with
// paneNotFound and nothing is published, and a valid create still works.
@MainActor
final class CreateSurfaceGhostPaneTests: XCTestCase {
    private func makeRouter(_ dir: String) throws -> (AppContext, AppCommandRouter) {
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    private func temporaryDirectory(_ tag: String) -> String {
        NSTemporaryDirectory() + "RC2CreateSurface-\(tag)-" + UUID().uuidString
    }

    private func captureSurfaceCreatedEvents() -> (events: () -> [EventBus.Event], token: UUID) {
        var captured: [EventBus.Event] = []
        let lock = NSLock()
        let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "surface.created" else { return }
            lock.lock()
            captured.append(event)
            lock.unlock()
        }
        return ({
            lock.lock()
            defer { lock.unlock() }
            return captured
        }, token)
    }

    private func terminalSurfaces(titled title: String) -> [Surface] {
        SurfaceRegistry.shared.all().filter {
            $0.descriptor.type == .terminal && $0.descriptor.title == title
        }
    }

    func test_createSurface_intoUnknownPane_failsWithoutPublishingOrRegistering() throws {
        let dir = temporaryDirectory("ghost")
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "ghost", cwd: NSTemporaryDirectory())
        let pane = try XCTUnwrap(ws.layout.paneIDs().first)
        let surfacesBefore = try router.paneSurfaces(pane: pane, workspace: ws.id).map(\.id)
        let (events, token) = captureSurfaceCreatedEvents()
        defer { EventBus.shared.unsubscribe(token) }

        XCTAssertThrowsError(
            try router.createSurface(workspace: ws.id, type: .terminal, paneID: PaneID(), title: "ghost tab")
        ) { error in
            XCTAssertEqual(error as? LayoutError, .paneNotFound,
                           "a create targeting a pane outside the layout must report paneNotFound, not succeed")
        }

        XCTAssertEqual(try router.paneSurfaces(pane: pane, workspace: ws.id).map(\.id), surfacesBefore,
                       "the failed create must not change the target pane")
        XCTAssertTrue(events().isEmpty,
                      "a create that produced no tab must not publish surface.created — the paired client would paint it")
        XCTAssertTrue(terminalSurfaces(titled: "ghost tab").isEmpty,
                      "no runtime may be registered for a tab the layout refused")
    }

    /// Control leg: the same call into a pane that exists must still create,
    /// register and publish exactly one surface — otherwise the spec above could
    /// pass by breaking create altogether.
    func test_createSurface_intoExistingPane_stillCreatesAndPublishes() throws {
        let dir = temporaryDirectory("valid")
        let (_, router) = try makeRouter(dir)
        let ws = try router.createWorkspace(name: "valid", cwd: NSTemporaryDirectory())
        let pane = try XCTUnwrap(ws.layout.paneIDs().first)
        let surfacesBefore = try router.paneSurfaces(pane: pane, workspace: ws.id).map(\.id)
        let (events, token) = captureSurfaceCreatedEvents()
        defer { EventBus.shared.unsubscribe(token) }

        let created = try router.createSurface(workspace: ws.id, type: .terminal, paneID: pane, title: "valid tab")

        let surfacesAfter = try router.paneSurfaces(pane: pane, workspace: ws.id).map(\.id)
        XCTAssertEqual(surfacesAfter, surfacesBefore + [created.id],
                       "a valid create must add exactly the requested tab to the target pane")
        XCTAssertEqual(events().count, 1,
                       "a valid create publishes exactly one surface.created")
        XCTAssertFalse(terminalSurfaces(titled: "valid tab").isEmpty,
                       "a valid create registers its runtime surface")
        SurfaceRegistry.shared.surface(created.id)?.close()
        SurfaceRegistry.shared.unregister(created.id)
    }
}
