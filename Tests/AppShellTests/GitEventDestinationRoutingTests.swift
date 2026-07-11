import XCTest
@testable import AppShell
import CoreModel
import Surfaces

@MainActor
final class GitEventDestinationRoutingTests: XCTestCase {
    func test_ensureGitSurfaceCreatesInExactWorkspaceWithoutStealingFocusAndReusesIt() throws {
        let directory = NSTemporaryDirectory() + "RC2GitEventDestination-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        defer {
            for workspace in context.state.workspaces.values {
                for descriptor in surfaceDescriptors(in: workspace.layout) {
                    SurfaceRegistry.shared.surface(descriptor.id)?.close()
                    SurfaceRegistry.shared.unregister(descriptor.id)
                }
            }
            try? FileManager.default.removeItem(atPath: directory)
        }

        let targetWorkspace = try router.createWorkspace(
            name: "TARGET",
            cwd: NSTemporaryDirectory()
        )
        let targetSelection = try XCTUnwrap(selectedSurfaceID(in: targetWorkspace.id, context: context))
        let foregroundWorkspace = try router.createWorkspace(
            name: "FOREGROUND",
            cwd: NSTemporaryDirectory()
        )
        let foregroundSelection = try XCTUnwrap(selectedSurfaceID(in: foregroundWorkspace.id, context: context))

        let destination = try router.ensureGitSurface(workspace: targetWorkspace.id)
        let repeated = try router.ensureGitSurface(workspace: targetWorkspace.id)

        XCTAssertEqual(destination.id, repeated.id, "One workspace must reuse one canonical Git destination.")
        XCTAssertEqual(destination.type, .rightSidebarTool)
        XCTAssertEqual(destination.metadata["tool"], "diff")
        XCTAssertTrue(context.state.workspaces[targetWorkspace.id]?.layout.contains(surfaceID: destination.id) == true)
        XCTAssertFalse(context.state.workspaces[foregroundWorkspace.id]?.layout.contains(surfaceID: destination.id) == true)
        XCTAssertEqual(selectedSurfaceID(in: targetWorkspace.id, context: context), targetSelection)
        XCTAssertEqual(selectedSurfaceID(in: foregroundWorkspace.id, context: context), foregroundSelection)
        XCTAssertEqual(context.state.window.selectedWorkspaceID, foregroundWorkspace.id)
        XCTAssertTrue(SurfaceRegistry.shared.surface(destination.id) is DiffPanelSurface)
        XCTAssertEqual(
            surfaceDescriptors(in: try XCTUnwrap(context.state.workspaces[targetWorkspace.id]).layout)
                .filter { $0.type == .rightSidebarTool && $0.metadata["tool"] == "diff" }
                .count,
            1
        )
    }

    func test_ensureGitSurfaceDeterministicallyReusesFirstExistingGitSurface() throws {
        let directory = NSTemporaryDirectory() + "RC2GitEventDestinationExisting-" + UUID().uuidString
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let workspace = try router.createWorkspace(name: "TARGET", cwd: NSTemporaryDirectory())
        defer {
            if let workspace = context.state.workspaces[workspace.id] {
                for descriptor in surfaceDescriptors(in: workspace.layout) {
                    SurfaceRegistry.shared.surface(descriptor.id)?.close()
                    SurfaceRegistry.shared.unregister(descriptor.id)
                }
            }
            try? FileManager.default.removeItem(atPath: directory)
        }
        let first = try router.createSurface(
            workspace: workspace.id,
            type: .rightSidebarTool,
            paneID: nil,
            title: "Git first"
        )
        _ = try router.createSurface(
            workspace: workspace.id,
            type: .rightSidebarTool,
            paneID: nil,
            title: "Git second"
        )

        let destination = try router.ensureGitSurface(workspace: workspace.id)

        XCTAssertEqual(
            destination.id,
            first.id,
            "Multiple Git tabs must resolve by stable layout order instead of current focus or dictionary order."
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
