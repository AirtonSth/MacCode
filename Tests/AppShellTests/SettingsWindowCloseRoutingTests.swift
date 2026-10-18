import AppKit
import XCTest
@testable import AppShell
import CoreModel
import Surfaces

@MainActor
final class SettingsWindowCloseRoutingTests: XCTestCase {
    func test_closeShortcutClosesKeySettingsWithoutClosingFocusedSurface() throws {
        let directory = NSTemporaryDirectory() + "RC2SettingsClose-\(UUID().uuidString)"
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "settings-close", cwd: directory)
        let browser = try router.createSurface(
            workspace: workspace.id,
            type: .browser,
            paneID: nil,
            title: "Browser"
        )
        try router.focusSurface(workspace: workspace.id, surface: browser.id)

        let main = MainWindowController(context: context, router: router)
        router.windowController = main
        let settings = SettingsWindowController(
            context: context
        )
        let delegate = AppDelegate(channel: .debug, appSupportOverride: directory)
        delegate.context = context
        delegate.router = router
        delegate.windowController = main
        delegate.settings = settings
        delegate.keyWindowProviderForTests = { settings.window }
        defer {
            settings.close()
            main.window.orderOut(nil)
            SurfaceRegistry.shared.all().forEach { $0.close() }
        }

        main.window.animationBehavior = .none
        settings.window.animationBehavior = .none
        settings.show(attachedTo: main.window)
        let layoutBefore = try XCTUnwrap(context.state.workspaces[workspace.id]?.layout)
        let surfaceIDsBefore = surfaceDescriptors(in: layoutBefore).map(\.id)
        let selectedBefore = selectedSurfaceID(in: workspace.id, context: context)

        XCTAssertTrue(
            NSApp.sendAction(NSSelectorFromString("closeActiveTabOrWindow"), to: delegate, from: nil),
            "The built-in Cmd+W action must be reachable through the AppDelegate responder."
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(main.window.attachedSheet, "Cmd+W must dismiss Settings when Settings is the key window.")
        XCTAssertEqual(
            context.state.workspaces[workspace.id].map { surfaceDescriptors(in: $0.layout).map(\.id) },
            surfaceIDsBefore,
            "Closing Settings must not close any workspace surface."
        )
        XCTAssertEqual(
            selectedSurfaceID(in: workspace.id, context: context),
            selectedBefore,
            "Closing Settings must preserve the focused surface."
        )
    }

    private func selectedSurfaceID(in workspaceID: WorkspaceID, context: AppContext) -> SurfaceID? {
        guard let workspace = context.state.workspaces[workspaceID],
              let paneID = workspace.focusedPaneID else { return nil }
        return workspace.layout.find(paneID: paneID)?.selectedSurfaceID
    }

    private func surfaceDescriptors(in node: LayoutNode) -> [SurfaceDescriptor] {
        switch node {
        case .pane(let pane):
            return pane.surfaces
        case .split(let split):
            return split.children.flatMap(surfaceDescriptors(in:))
        }
    }
}
