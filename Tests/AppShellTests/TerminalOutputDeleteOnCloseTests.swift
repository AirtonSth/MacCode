import XCTest
@testable import AppShell
@testable import CoreModel
import Persistence
@testable import Surfaces

/// Verify that closing a surface (or workspace) deletes its persisted
/// terminal_output_chunks rows, and that a live surface retains its chunks.
///
/// WHY this matters: TerminalOutputRepository.delete(surfaceID:) had zero
/// production callers before this fix; the table grew unbounded. These tests
/// pin the invariant that closeSurface / closeWorkspace are the delete triggers.
@MainActor
final class TerminalOutputDeleteOnCloseTests: XCTestCase {

    // MARK: - Setup helpers

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "RC2TermDeleteTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    /// Insert a few chunks so there is measurable stored data for `surfaceID`.
    private func seedChunks(repo: TerminalOutputRepository, surfaceID: String, count: Int = 3) throws {
        for i in 0..<count {
            try repo.append(surfaceID: surfaceID, workspaceID: nil,
                            chunkIndex: Int64(i), data: Data("chunk\(i)".utf8))
        }
    }

    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        super.tearDown()
    }

    // MARK: - closeSurface deletes chunks

    func test_closeSurface_deletesTerminalChunksForClosedSurface() throws {
        // WHY: the closed surface's history has no owner once removed from the
        // layout; keeping it leaks storage proportional to usage lifetime.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())

        // The workspace opens with one terminal surface by default.
        guard case .pane(let pane) = ctx.state.workspaces[ws.id]?.layout,
              let descriptor = pane.surfaces.first else {
            return XCTFail("expected initial terminal surface")
        }
        let surfaceID = descriptor.id.value.uuidString
        let repo = ctx.terminalOutputRepo

        try seedChunks(repo: repo, surfaceID: surfaceID)
        XCTAssertGreaterThan(try repo.totalBytes(surfaceID: surfaceID), 0,
                             "pre-condition: chunks must be present before close")

        try router.closeSurface(workspace: ws.id, surface: descriptor.id)

        XCTAssertEqual(try repo.totalBytes(surfaceID: surfaceID), 0,
                       "closeSurface must delete all terminal_output_chunks for the closed surface")
    }

    // MARK: - closeSurface does not delete chunks for other surfaces

    func test_closeSurface_doesNotDeleteChunksForLiveSurface() throws {
        // WHY: deleting another surface's history would silently erase scrollback
        // that is still visible in the app.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())

        // Open a second terminal surface.
        let desc2 = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "t2")
        guard case .pane(let pane) = ctx.state.workspaces[ws.id]?.layout,
              let desc1 = pane.surfaces.first(where: { $0.id != desc2.id }) else {
            return XCTFail("expected two surfaces")
        }

        let repo = ctx.terminalOutputRepo
        let sid1 = desc1.id.value.uuidString
        let sid2 = desc2.id.value.uuidString

        try seedChunks(repo: repo, surfaceID: sid1)
        try seedChunks(repo: repo, surfaceID: sid2)

        // Close only the first surface.
        try router.closeSurface(workspace: ws.id, surface: desc1.id)

        XCTAssertEqual(try repo.totalBytes(surfaceID: sid1), 0,
                       "closed surface chunks must be deleted")
        XCTAssertGreaterThan(try repo.totalBytes(surfaceID: sid2), 0,
                             "live surface chunks must not be deleted when a different surface is closed")
    }

    // MARK: - closeWorkspace deletes chunks for all its surfaces

    func test_closeWorkspace_deletesChunksForAllSurfacesInWorkspace() throws {
        // WHY: closing the workspace removes all its surfaces from the layout at
        // once; each surface's history must be cleaned up just as if each was
        // individually closed.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())

        // Add a second surface so the workspace has two surfaces to delete.
        let desc2 = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "t2")
        guard case .pane(let pane) = ctx.state.workspaces[ws.id]?.layout,
              let desc1 = pane.surfaces.first(where: { $0.id != desc2.id }) else {
            return XCTFail("expected two surfaces")
        }

        let repo = ctx.terminalOutputRepo
        let sid1 = desc1.id.value.uuidString
        let sid2 = desc2.id.value.uuidString

        try seedChunks(repo: repo, surfaceID: sid1)
        try seedChunks(repo: repo, surfaceID: sid2)

        try router.closeWorkspace(ws.id)

        XCTAssertEqual(try repo.totalBytes(surfaceID: sid1), 0,
                       "closeWorkspace must delete chunks for every surface it contained")
        XCTAssertEqual(try repo.totalBytes(surfaceID: sid2), 0,
                       "closeWorkspace must delete chunks for every surface it contained")
    }

    // MARK: - live surface keeps chunks while another is closed

    func test_liveWorkspaceSurface_retainsChunksWhenOtherWorkspaceClosed() throws {
        // WHY: deleting chunks scoped to the wrong workspace would silently
        // destroy history for open surfaces the user can still see.
        let (ctx, router) = try makeContext()
        let ws1 = try router.createWorkspace(name: "ws1", cwd: NSTemporaryDirectory())
        let ws2 = try router.createWorkspace(name: "ws2", cwd: NSTemporaryDirectory())

        guard case .pane(let pane1) = ctx.state.workspaces[ws1.id]?.layout,
              let desc1 = pane1.surfaces.first,
              case .pane(let pane2) = ctx.state.workspaces[ws2.id]?.layout,
              let desc2 = pane2.surfaces.first else {
            return XCTFail("expected one surface per workspace")
        }

        let repo = ctx.terminalOutputRepo
        let sid1 = desc1.id.value.uuidString
        let sid2 = desc2.id.value.uuidString

        try seedChunks(repo: repo, surfaceID: sid1)
        try seedChunks(repo: repo, surfaceID: sid2)

        // Close ws2 only.
        try router.closeWorkspace(ws2.id)

        XCTAssertGreaterThan(try repo.totalBytes(surfaceID: sid1), 0,
                             "ws1 surface chunks must survive when ws2 is closed")
        XCTAssertEqual(try repo.totalBytes(surfaceID: sid2), 0,
                       "ws2 surface chunks must be deleted when ws2 is closed")
    }
}
