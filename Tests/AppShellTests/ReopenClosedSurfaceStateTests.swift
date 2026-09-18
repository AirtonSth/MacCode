import XCTest
@testable import AppShell
import CoreModel
import Surfaces
import Persistence

/// ⌘⇧T must reopen a closed tab with the state it had at close time, not a
/// blank replacement: the browser tab at its URL, the Files tab at its
/// selection/state, and a connected SSH tab as the live connection it was.
@MainActor
final class ReopenClosedSurfaceStateTests: XCTestCase {
    private func makeHarness() throws -> (AppContext, AppCommandRouter, String) {
        let directory = NSTemporaryDirectory() + "RC2ReopenClosedTab-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        return (context, router, directory)
    }

    private func tearDown(context: AppContext, directory: String) {
        for workspace in context.state.workspaces.values {
            for descriptor in surfaceDescriptors(in: workspace.layout) {
                SurfaceRegistry.shared.surface(descriptor.id)?.close()
                SurfaceRegistry.shared.unregister(descriptor.id)
            }
        }
        try? FileManager.default.removeItem(atPath: directory)
    }

    private func surfaceDescriptors(in node: LayoutNode) -> [SurfaceDescriptor] {
        switch node {
        case .pane(let pane):
            return pane.surfaces
        case .split(let split):
            return split.children.flatMap { surfaceDescriptors(in: $0) }
        }
    }

    func test_reopenClosedBrowserTab_restoresTheClosedURL() throws {
        // WHY: the closed descriptor is the only carrier of the tab's target;
        // dropping it reopens the tab on the start page and (through the
        // connection snapshot) tells iOS the tab has no URL.
        let (context, router, directory) = try makeHarness()
        defer { tearDown(context: context, directory: directory) }
        let workspace = try router.createWorkspace(name: "W", cwd: NSTemporaryDirectory())
        let target = "https://example.test/docs/guide"

        let browser = try router.createSurface(workspace: workspace.id, type: .browser, paneID: nil, title: "browser")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(browser.id) as? BrowserSurface)
        surface.publishNavigationChange(url: try XCTUnwrap(URL(string: target)), title: "Guide")

        try router.closeSurface(workspace: workspace.id, surface: browser.id)
        let reopened = try XCTUnwrap(try router.reopenClosedSurface(workspace: workspace.id))

        XCTAssertEqual(reopened.metadata["url"], target,
                       "⌘⇧T must keep the closed tab's URL on the reopened descriptor")
        XCTAssertTrue(SurfaceRegistry.shared.surface(reopened.id) is BrowserSurface,
                      "the reopened tab must be a browser surface")
    }

    func test_reopenClosedBrowserTab_keepsTheBotBinding() throws {
        // WHY: bot tabs live on the bot's own WKWebView data store (cookies and
        // session). Reopening without bot_id would silently move the tab onto
        // the workspace store and stop persisting the bot browser target.
        let (context, router, directory) = try makeHarness()
        defer { tearDown(context: context, directory: directory) }
        let workspace = try router.createWorkspace(name: "W", cwd: NSTemporaryDirectory())
        let botID = BotID()

        var descriptor = SurfaceDescriptor(
            type: .browser,
            title: "bot browser",
            metadata: [
                "workspace": workspace.id.value.uuidString,
                "bot_id": botID.value.uuidString,
                "url": "https://example.test/bot",
            ]
        )
        descriptor.metadata["cwd"] = workspace.cwd
        try context.apply(.addSurface(workspace.id, paneID: nil, descriptor: descriptor))
        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)

        let reopened = try XCTUnwrap(try router.reopenClosedSurface(workspace: workspace.id))
        XCTAssertEqual(reopened.metadata["bot_id"]?.lowercased(), botID.value.uuidString.lowercased(),
                       "a reopened bot tab must stay bound to its bot data store")
        XCTAssertEqual(reopened.metadata["url"], "https://example.test/bot")
    }

    func test_reopenClosedFilesTab_restoresStateAndSelection() throws {
        // WHY: Files state (directory, selection, revision) is persisted on the
        // descriptor and is what the surface reads on mount; a fresh descriptor
        // reopens the tab at the workspace root with an empty selection.
        let (context, router, directory) = try makeHarness()
        defer { tearDown(context: context, directory: directory) }
        let workspace = try router.createWorkspace(name: "W", cwd: NSTemporaryDirectory())

        let files = try router.createSurface(workspace: workspace.id, type: .files, paneID: nil, title: "Files")
        let updated = try router.filesStateUpdate(
            surface: files.id,
            patch: [
                "current_directory": .string("Sources"),
                "selected_path": .string("Sources/App.swift"),
            ],
            baseRevision: nil,
            deviceID: "mac-host"
        )
        let persistRevision = try XCTUnwrap(updated.objectValue?["revision"]?.intValue)
        let closedState = try XCTUnwrap(
            surfaceDescriptors(in: try XCTUnwrap(context.state.workspaces[workspace.id]).layout)
                .first { $0.id == files.id }?.metadata["files_state"]
        )

        try router.closeSurface(workspace: workspace.id, surface: files.id)
        let reopened = try XCTUnwrap(try router.reopenClosedSurface(workspace: workspace.id))

        XCTAssertEqual(reopened.metadata["files_state"], closedState,
                       "the reopened Files tab must carry the closed tab's state blob")
        XCTAssertEqual(reopened.metadata["selected_path"], "Sources/App.swift",
                       "the reopened Files tab must keep the selected path")
        let state = try XCTUnwrap(try router.filesStateGet(surface: reopened.id).objectValue)
        XCTAssertEqual(state["selected_path"]?.stringValue, "Sources/App.swift")
        XCTAssertEqual(state["current_directory"]?.stringValue, "Sources")
        XCTAssertEqual(state["revision"]?.intValue, persistRevision,
                       "the state revision must not reset, or paired devices see a stale state as newer")
    }

    func test_reopenClosedSshTab_restoresTheLiveConnection() throws {
        // WHY: a connected SSH tab carries its profile in metadata. Reopening it
        // as the profile picker (the plain create path) loses the connection
        // the user had, so ⌘⇧T must rebuild the live ssh terminal instead.
        let (context, router, directory) = try makeHarness()
        defer { tearDown(context: context, directory: directory) }
        let workspace = try router.createWorkspace(name: "W", cwd: NSTemporaryDirectory())

        var descriptor = SurfaceDescriptor(
            type: .ssh,
            title: "prod",
            metadata: [
                "workspace": workspace.id.value.uuidString,
                "cwd": workspace.cwd,
                "ssh_profile_id": SSHHostID().value.uuidString,
                // Refused instantly: the test asserts the restored identity,
                // never a reachable host.
                "ssh_destination": "127.0.0.1",
                "ssh_port": "1",
                "ssh_label": "prod",
                "ssh_status": "connected",
            ]
        )
        descriptor.metadata["ssh_identity_file"] = "/tmp/rc-reopen-closed-tab-test-key"
        try context.apply(.addSurface(workspace.id, paneID: nil, descriptor: descriptor))
        try router.closeSurface(workspace: workspace.id, surface: descriptor.id)

        let reopened = try XCTUnwrap(try router.reopenClosedSurface(workspace: workspace.id))
        XCTAssertEqual(reopened.metadata["ssh_destination"], "127.0.0.1",
                       "the reopened tab must keep the closed tab's ssh destination")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(reopened.id))
        XCTAssertTrue(surface is TerminalSurface,
                      "a connected ssh tab must reopen as its live ssh terminal, not the profile picker")
        XCTAssertEqual(surface.descriptor.type, .ssh)
    }
}
