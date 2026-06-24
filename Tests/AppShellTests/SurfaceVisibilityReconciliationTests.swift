import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces

@MainActor
final class SurfaceVisibilityReconciliationTests: XCTestCase {
    override func tearDown() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
        SurfaceRegistry.shared.setVisibleSurfaceIDs([])
        super.tearDown()
    }

    func test_reconciliationKeepsSelectedSurfacesVisibleAcrossLiveWindows() throws {
        let (ctx, router) = try makeContext()
        let primaryWindowID = ctx.state.window.id
        let firstWorkspace = try router.createWorkspace(name: "first", cwd: NSTemporaryDirectory())
        let firstSurfaceID = try selectedSurfaceID(firstWorkspace)
        let secondWorkspace = try router.createWorkspace(name: "second", cwd: NSTemporaryDirectory())
        let secondSurfaceID = try selectedSurfaceID(secondWorkspace)

        let secondaryWindow = try router.createWindow(title: "secondary")
        try router.moveWorkspaceToWindow(workspace: firstWorkspace.id, target: secondaryWindow.id)
        try router.focusWindow(primaryWindowID)
        try router.selectWorkspace(secondWorkspace.id)
        router.reconcileSurfaceVisibility()

        let visible = SurfaceRegistry.shared.visibleSurfaceIDsSnapshot()
        XCTAssertTrue(visible.contains(firstSurfaceID),
                      "a terminal visible in a secondary live window must stay registry-visible even when the primary window selects another workspace")
        XCTAssertTrue(visible.contains(secondSurfaceID),
                      "the focused primary window selected terminal must also remain registry-visible")
    }

    func test_reconciliationDropsSurfacesFromClosedWindowSelection() throws {
        let (ctx, router) = try makeContext()
        let primaryWindowID = ctx.state.window.id
        let firstWorkspace = try router.createWorkspace(name: "first", cwd: NSTemporaryDirectory())
        let firstSurfaceID = try selectedSurfaceID(firstWorkspace)
        let secondWorkspace = try router.createWorkspace(name: "second", cwd: NSTemporaryDirectory())
        let secondSurfaceID = try selectedSurfaceID(secondWorkspace)
        let secondaryWindow = try router.createWindow(title: "secondary")
        try router.moveWorkspaceToWindow(workspace: firstWorkspace.id, target: secondaryWindow.id)
        try router.focusWindow(primaryWindowID)
        try router.selectWorkspace(secondWorkspace.id)

        try router.closeWindow(secondaryWindow.id)

        let visible = SurfaceRegistry.shared.visibleSurfaceIDsSnapshot()
        XCTAssertFalse(visible.contains(firstSurfaceID),
                       "closing a secondary window must not leave its old selected terminal marked visible")
        XCTAssertTrue(visible.contains(secondSurfaceID),
                      "closing a secondary window must preserve the remaining selected terminal visibility")
    }

    func test_minimizedSplitPaneHidesSelectedTerminalAndMaximizeRestoresIt() throws {
        let (ctx, router) = try makeContext()
        let workspace = try router.createWorkspace(name: "split", cwd: NSTemporaryDirectory())
        let firstSurfaceID = try selectedSurfaceID(workspace)
        let firstPaneID = try XCTUnwrap(ctx.state.workspaces[workspace.id]?.layout.paneIDs().first)
        let secondSurface = try router.splitPane(
            workspace: workspace.id,
            paneID: firstPaneID,
            direction: .down,
            surfaceType: .terminal,
            title: "bottom"
        )
        let split = try rootSplit(in: ctx.state.workspaces[workspace.id]?.layout)

        try router.paneResize(workspace: workspace.id, splitID: split.id, ratios: [0.04, 0.96])

        var visible = SurfaceRegistry.shared.visibleSurfaceIDsSnapshot()
        XCTAssertFalse(
            visible.contains(firstSurfaceID),
            "a minimized split pane must hide its selected terminal surface so Ghostty receives didBecomeHidden before the pane is visually collapsed"
        )
        XCTAssertTrue(
            visible.contains(secondSurface.id),
            "the non-minimized sibling terminal must remain visible while the first pane is minimized"
        )

        try router.paneResize(workspace: workspace.id, splitID: split.id, ratios: [0.5, 0.5])

        visible = SurfaceRegistry.shared.visibleSurfaceIDsSnapshot()
        XCTAssertTrue(
            visible.contains(firstSurfaceID),
            "maximizing/restoring the pane must mark the terminal visible again so the existing PTY/Ghostty surface resumes instead of appearing dead"
        )
        XCTAssertTrue(visible.contains(secondSurface.id))
    }

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "RC2VisibilityTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    private func selectedSurfaceID(_ workspace: Workspace) throws -> SurfaceID {
        guard case .pane(let pane) = workspace.layout,
              let surfaceID = pane.selectedSurfaceID ?? pane.surfaces.first?.id else {
            throw XCTSkip("expected single-pane workspace")
        }
        return surfaceID
    }

    private func rootSplit(in node: LayoutNode?) throws -> SplitNode {
        guard case .split(let split) = node else {
            throw XCTSkip("expected split layout")
        }
        return split
    }
}
