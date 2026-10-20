import XCTest
@testable import AppShell
@testable import CoreModel
import Surfaces

/// WHY: the owner (2026-10-20) wants each workspace's Conversations, Bots and
/// VMs sections hideable, and the choice must survive closing MacCode; Bots
/// and VMs must also open as workspace tabs.
@MainActor
final class SidebarWorkspaceSectionsTests: XCTestCase {
    private var directory: String!

    override func setUp() {
        directory = NSTemporaryDirectory() + "RC2SidebarSections-" + UUID().uuidString
        UserDefaults.standard.removeObject(forKey: SidebarViewModel.collapsedWorkspaceSectionsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: SidebarViewModel.collapsedWorkspaceSectionsKey)
        try? FileManager.default.removeItem(atPath: directory)
    }

    func test_hiddenSectionPersistsPerWorkspaceAndSectionAcrossRelaunch() throws {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let a = WorkspaceID(), b = WorkspaceID()
        let vm = SidebarViewModel(context: context, router: router, operationErrorPresenter: { _, _ in })
        vm.toggleWorkspaceSection(a, .bots)
        XCTAssertTrue(vm.isWorkspaceSectionCollapsed(a, .bots))
        XCTAssertFalse(vm.isWorkspaceSectionCollapsed(a, .conversations), "only the tapped section hides")
        XCTAssertFalse(vm.isWorkspaceSectionCollapsed(b, .bots), "other workspaces keep their own choice")

        let relaunched = SidebarViewModel(context: context, router: router, operationErrorPresenter: { _, _ in })
        XCTAssertTrue(relaunched.isWorkspaceSectionCollapsed(a, .bots), "the choice survives reopening MacCode")
        relaunched.toggleWorkspaceSection(a, .bots)
        XCTAssertFalse(SidebarViewModel(context: context, router: router, operationErrorPresenter: { _, _ in })
            .isWorkspaceSectionCollapsed(a, .bots), "showing it again also persists")
    }

    func test_expandingAWorkspaceCollapsesEveryOther() throws {
        // WHY: the owner wants only one workspace expanded at a time.
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let vm = SidebarViewModel(context: context, router: router, operationErrorPresenter: { _, _ in })
        let a = WorkspaceID(), b = WorkspaceID()
        vm.toggleWorkspaceExpanded(a)
        vm.toggleWorkspaceExpanded(b)
        XCTAssertEqual(vm.expandedWorkspaceIDs, [b])
        vm.toggleWorkspaceExpanded(b)
        XCTAssertTrue(vm.expandedWorkspaceIDs.isEmpty, "collapsing the open one leaves none open")
    }

    func test_botsAndVMsTabsOpenAsTheirToolAndRestoreAsIt() throws {
        let context = try AppContext(channel: .debug, appSupportOverride: directory)
        let router = AppCommandRouter(context: context)
        context.router = router
        let cwd = directory + "/ws"
        try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
        let workspace = try router.createWorkspace(name: "WS", cwd: cwd)
        for tool in WorkspaceTool.allCases {
            let desc = try router.createSurface(workspace: workspace.id, type: .rightSidebarTool, paneID: nil, title: tool.title)
            XCTAssertEqual(desc.metadata["tool"], tool.rawValue, "the descriptor records the tool so restore reopens it, not Git")
            XCTAssertTrue(SurfaceRegistry.shared.surface(desc.id) is WorkspaceToolSurface)
            XCTAssertEqual(PaneTabsView.symbol(for: desc), tool.symbol)
        }
        let git = try router.createSurface(workspace: workspace.id, type: .rightSidebarTool, paneID: nil, title: "Git")
        XCTAssertNil(WorkspaceTool.from(metadata: git.metadata, title: git.title), "Git stays the diff panel")
        XCTAssertEqual(PaneTabsView.menuChoice("rightSidebarTool#VMs")?.1, "VMs")
    }
}
