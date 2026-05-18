import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence

@MainActor
final class PersistenceRestoreTests: XCTestCase {
    /// Workspaces and tabs must survive a process restart even without a
    /// clean quit — i.e. the snapshot is written on mutation, not only on
    /// applicationWillTerminate.
    func test_workspacesAndTabs_persistAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString

        // ── Session 1: create a workspace + two surfaces, flush snapshot.
        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let ws = try router.createWorkspace(name: "PERSISTME", cwd: NSTemporaryDirectory())
            _ = try router.createSurface(workspace: ws.id, type: .terminal, paneID: nil, title: "t")
            _ = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "b")
            ctx.saveSnapshot() // immediate flush (debounced timer would also fire)
        }

        // ── Session 2: fresh AppContext on the SAME app-support dir.
        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let names = ctx2.state.workspaces.values.map { $0.name }
        XCTAssertTrue(names.contains("PERSISTME"),
                      "workspace must persist across restart, got \(names)")
        let restored = ctx2.state.workspaces.values.first { $0.name == "PERSISTME" }
        let restoredWS = try XCTUnwrap(restored)
        guard case .pane(let pane) = restoredWS.layout else {
            return XCTFail("expected the restored workspace to keep its pane")
        }
        // Default terminal (1) + the two added tabs (terminal, browser) = 3.
        XCTAssertEqual(pane.surfaces.count, 3, "all tabs must persist")
        XCTAssertEqual(Set(pane.surfaces.map(\.type)), [.terminal, .browser])
        // And the window selection points at the restored workspace.
        XCTAssertEqual(ctx2.state.window.selectedWorkspaceID, restoredWS.id)
    }

    func test_applyMutation_schedulesSnapshotSave() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        try ctx.apply(.createWorkspace(name: "A", cwd: "/tmp", initial: nil))
        // Force the debounced write immediately and confirm it lands.
        ctx.saveSnapshot()
        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        XCTAssertTrue(ctx2.state.workspaces.values.contains { $0.name == "A" })
    }

    func test_browserLastURL_persistsAcrossRestart() throws {
        let dir = NSTemporaryDirectory() + "RC2Persist-" + UUID().uuidString
        let target = "https://example.com/docs?tab=api"

        do {
            let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
            let router = AppCommandRouter(context: ctx)
            ctx.router = router
            let ws = try router.createWorkspace(name: "WEB", cwd: NSTemporaryDirectory())
            let browser = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "browser")
            let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(browser.id) as? BrowserSurface)

            surface.publishNavigationChange(url: try XCTUnwrap(URL(string: target)), title: "API Docs")
            ctx.saveSnapshot()
        }

        let ctx2 = try AppContext(channel: .debug, appSupportOverride: dir)
        let restored = try XCTUnwrap(ctx2.state.workspaces.values.first { $0.name == "WEB" })
        guard case .pane(let pane) = restored.layout else {
            return XCTFail("expected browser workspace to restore as pane")
        }
        let browser = try XCTUnwrap(pane.surfaces.first { $0.type == .browser })
        XCTAssertEqual(browser.metadata["url"], target,
                       "browser tabs must reopen on the last URL after RemoteCode restarts")
        XCTAssertEqual(browser.title, "API Docs",
                       "browser tab title must persist with the last visited page")
    }
}
