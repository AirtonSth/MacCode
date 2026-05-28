import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence

@MainActor
final class PaneActionTests: XCTestCase {
    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    override func tearDown() {
        closeAndUnregisterAllSurfaces()
        super.tearDown()
    }

    private func makeContext() throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "RC2PaneTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx)
        ctx.router = router
        return (ctx, router)
    }

    func test_newWorkspace_opensTerminalByDefault_andAddCreatesAnother() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        // A new workspace opens with a terminal by default.
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        XCTAssertEqual(pane.surfaces.count, 1)
        XCTAssertEqual(pane.surfaces.first?.type, .terminal)

        let ptv = PaneTabsView(pane: pane, router: router)
        let desc = ptv.performAdd(.terminal, title: "terminal")
        XCTAssertNotNil(desc, "performAdd should return a descriptor")

        let updated = ctx.state.workspaces[ws.id]!
        guard case .pane(let p2) = updated.layout else { return XCTFail() }
        XCTAssertEqual(p2.surfaces.count, 2)
        XCTAssertTrue(p2.surfaces.allSatisfy { $0.type == .terminal })
        XCTAssertNotNil(SurfaceRegistry.shared.surface(p2.surfaces[0].id))
        XCTAssertNotNil(SurfaceRegistry.shared.surface(p2.surfaces[1].id))
    }

    func test_focusingAnotherTabUnloadsHiddenFilePreviewSurface() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "preview-memory", cwd: NSTemporaryDirectory())
        guard case .pane(let initialPane) = ws.layout,
              let terminalID = initialPane.surfaces.first?.id else { return XCTFail("expected default terminal") }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-preview-memory-\(UUID().uuidString).txt")
        try String(repeating: "preview\n", count: 200).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let previewDesc = try router.createSurface(workspace: ws.id, type: .filePreview, paneID: nil, title: file.path)
        let preview = try XCTUnwrap(SurfaceRegistry.shared.surface(previewDesc.id) as? FilePreviewSurface)
        XCTAssertFalse(preview.view.subviews.isEmpty, "selected preview tab should render the file while visible")

        try router.focusSurface(workspace: ws.id, surface: terminalID)

        XCTAssertTrue(preview.view.subviews.isEmpty,
                      "switching away must unload heavyweight preview views so hidden tabs do not retain image/PDF/text content")
    }

    func test_addAgent_then_splitRight_buildsSplitTree() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        let ptv = PaneTabsView(pane: pane, router: router)
        XCTAssertNotNil(ptv.performAdd(.agentApp, title: "Agent App"))
        XCTAssertNotNil(ptv.performSplit(.right, type: .browser, title: "browser"))
        let updated = ctx.state.workspaces[ws.id]!
        guard case .split(let s) = updated.layout else { return XCTFail("expected split after splitRight") }
        XCTAssertEqual(s.children.count, 2)
        XCTAssertEqual(updated.layout.paneIDs().count, 2)
    }

    func test_sidebarWorkspaceRowsRollUpRunningThreads() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "busy", cwd: NSTemporaryDirectory())
        var thread = AgentThread(workspaceId: ws.id, title: "Long task", provider: .codex, model: "gpt-5.5")
        thread.status = .running
        try ctx.threadRepo.upsert(thread)

        let vm = SidebarViewModel(context: ctx, router: router)
        vm.reload()

        XCTAssertEqual(vm.workspaces.first(where: { $0.id == ws.id })?.metadata["busy"], "true",
                       "a running agent thread must put the same spinner state on the workspace row, even before the Agent tab is rebuilt")
        XCTAssertTrue(vm.isWorkspaceBusy(vm.workspaces.first(where: { $0.id == ws.id })!),
                      "workspace row rendering must read the router's busy metadata, not only live SurfaceRegistry state")
    }

    func test_agentSurfaceBusyRollsUpRunningThreadForTabSpinner() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "tab-busy", cwd: NSTemporaryDirectory())
        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        let agent = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)
        var thread = AgentThread(workspaceId: ws.id, title: "Long task", provider: .codex, model: "gpt-5.5")
        thread.status = .running
        try ctx.threadRepo.upsert(thread)

        agent.viewModel.reloadThreads()

        XCTAssertTrue(agent.isBusy,
                      "the tab strip reads AgentAppSurface.isBusy, so running threads must turn the Agent App tab into a spinner")
    }

    func test_sshSurfaceCreatesSavedHostSidebarInsteadOfDisconnectedTerminalPlaceholder() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ssh", cwd: NSTemporaryDirectory())

        let desc = try router.createSurface(workspace: ws.id, type: .ssh, paneID: nil, title: "SSH")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? SSHSurface)

        XCTAssertEqual(surface.view.subviews.count, 5,
                       "an SSH tab must render hosts, resize handle, terminal, and transfer sidebar chrome instead of a blank terminal placeholder")
        XCTAssertNil(surface.sshTransferProfile,
                     "a new SSH tab starts disconnected until a saved host row is selected")
        XCTAssertEqual(surface.transferSidebarWidthForTesting, 0,
                       "file transfer controls must stay out of the way until an SSH connection is active")
        XCTAssertEqual(surface.snapshot()["ssh_status"], "disconnected")
    }

    func test_sshHostSidebarWidthPersistsGloballyAfterUserResize() throws {
        UserDefaults.standard.removeObject(forKey: SSHSurface.hostSidebarWidthDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: SSHSurface.hostSidebarWidthDefaultsKey) }
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ssh-width", cwd: NSTemporaryDirectory())
        let firstDesc = try router.createSurface(workspace: ws.id, type: .ssh, paneID: nil, title: "SSH")
        let first = try XCTUnwrap(SurfaceRegistry.shared.surface(firstDesc.id) as? SSHSurface)

        first.setHostSidebarWidthForTesting(376)
        let secondDesc = try router.createSurface(workspace: ws.id, type: .ssh, paneID: nil, title: "SSH")
        let second = try XCTUnwrap(SurfaceRegistry.shared.surface(secondDesc.id) as? SSHSurface)

        XCTAssertEqual(second.hostSidebarWidthForTesting, 376, accuracy: 1,
                       "after the user resizes the SSH hosts sidebar, later SSH tabs must restore the global width")
    }

    func test_sshHostsAreScopedToWorkspace() throws {
        let (_, router) = try makeContext()
        let first = try router.createWorkspace(name: "ssh-a", cwd: NSTemporaryDirectory())
        let second = try router.createWorkspace(name: "ssh-b", cwd: NSTemporaryDirectory())

        let host = try router.sshHostUpsert(SSHHostProfile(label: "Workspace A SSH", destination: "a.example.invalid"),
                                            workspace: first.id)

        XCTAssertEqual(try router.sshHostList(workspace: first.id).map(\.id), [host.id],
                       "workspace A must keep the SSH host it saved for one-tap reconnect")
        XCTAssertTrue(try router.sshHostList(workspace: second.id).isEmpty,
                      "workspace B must not inherit SSH hosts saved in another workspace")
    }

    func test_sshOpenNewConnectionUsesCurrentSurfaceThenCreatesNewTabWhenActive() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ssh-new-connection", cwd: NSTemporaryDirectory())
        let desc = try router.createSurface(workspace: ws.id, type: .ssh, paneID: nil, title: "SSH")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? SSHSurface)
        let host = try router.sshHostUpsert(SSHHostProfile(label: "Example SSH", destination: "example.invalid"), workspace: ws.id)

        surface.openNewConnectionForTesting(host)

        var updated = try XCTUnwrap(ctx.state.workspaces[ws.id])
        let paneID = try XCTUnwrap(updated.layout.paneIDs().first)
        var pane = try XCTUnwrap(updated.layout.find(paneID: paneID))
        XCTAssertEqual(pane.surfaces.count, 2,
                       "the first open-new-connection starts in the existing disconnected SSH tab without adding a second tab")
        XCTAssertEqual(surface.snapshot()["ssh_status"], "connected")
        XCTAssertEqual(surface.sshTransferProfile?.id, host.id,
                       "the connected host row must be highlighted in the existing SSH tab")
        XCTAssertGreaterThan(surface.transferSidebarWidthForTesting, 0,
                             "connecting through SSH must reveal the collapsible file-transfer sidebar")

        surface.openNewConnectionForTesting(host)

        updated = try XCTUnwrap(ctx.state.workspaces[ws.id])
        pane = try XCTUnwrap(updated.layout.find(paneID: paneID))
        XCTAssertEqual(pane.surfaces.count, 3,
                       "when an SSH connection is already active, Open New Connection must create a new SSH tab")
        XCTAssertEqual(pane.selectedSurfaceID, pane.surfaces.last?.id,
                       "the new SSH tab should become the selected tab so it is visible immediately")
        let newSurfaceID = try XCTUnwrap(pane.surfaces.last?.id)
        let newSurface = try XCTUnwrap(SurfaceRegistry.shared.surface(newSurfaceID) as? SSHSurface)
        XCTAssertEqual(newSurface.view.subviews.count, 5,
                       "new active SSH connections must open the full SSH tab chrome with hosts, terminal, and transfer sidebar")
        XCTAssertEqual(newSurface.sshTransferProfile?.id, host.id,
                       "the connected host row must be highlighted in the newly opened SSH tab")
        XCTAssertGreaterThan(newSurface.transferSidebarWidthForTesting, 0,
                             "new active SSH tabs must also reveal the file-transfer sidebar")
        XCTAssertEqual(newSurface.snapshot()["ssh_status"], "connected")
    }

    func test_agentTabBusyRollsUpRunningThreadFromRepository() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "tab-repo-busy", cwd: NSTemporaryDirectory())
        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        var thread = AgentThread(workspaceId: ws.id, title: "Long task", provider: .codex, model: "gpt-5.5")
        thread.status = .running
        try ctx.threadRepo.upsert(thread)

        XCTAssertTrue(PaneTabsView.isSurfaceBusy(desc, router: router),
                      "tab rendering must show a spinner when any thread in that Agent App workspace is running, even if the live surface VM has stale thread state")
    }

    func test_splitHorizontal_and_splitVertical_orientations() throws {
        let (ctx, router) = try makeContext()
        // Horizontal split → side-by-side (orientation .horizontal)
        let ws1 = try router.createWorkspace(name: "h", cwd: NSTemporaryDirectory())
        guard case .pane(let p1) = ws1.layout else { return XCTFail() }
        let v1 = PaneTabsView(pane: p1, router: router)
        XCTAssertNotNil(v1.performAdd(.terminal, title: "t"))
        XCTAssertNotNil(v1.performSplit(.right, type: .agentApp, title: "Agent App"))
        guard case .split(let sH) = ctx.state.workspaces[ws1.id]!.layout else { return XCTFail() }
        XCTAssertEqual(sH.orientation, .horizontal)

        // Vertical split → stacked (orientation .vertical)
        let ws2 = try router.createWorkspace(name: "v", cwd: NSTemporaryDirectory())
        guard case .pane(let p2) = ws2.layout else { return XCTFail() }
        let v2 = PaneTabsView(pane: p2, router: router)
        XCTAssertNotNil(v2.performAdd(.terminal, title: "t"))
        XCTAssertNotNil(v2.performSplit(.down, type: .agentApp, title: "Agent App"))
        guard case .split(let sV) = ctx.state.workspaces[ws2.id]!.layout else { return XCTFail() }
        XCTAssertEqual(sV.orientation, .vertical)
    }

    func test_togglePaneMinimized_hidesCurrentPaneContent_thenRestoresSplit() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "minimize", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }

        let root = PaneTabsView(pane: pane, router: router)
        XCTAssertNotNil(root.performSplit(.right, type: .browser, title: "browser"))
        guard case .split(let split) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }

        let leftPane = try XCTUnwrap(split.children.first?.find(paneID: pane.id))
        let minimize = PaneTabsView(
            pane: leftPane,
            router: router,
            splitContext: PaneSplitContext(splitID: split.id, paneIndex: 0, ratios: split.ratios)
        )
        XCTAssertTrue(minimize.performTogglePaneMinimized(),
                      "minimizing a pane must resize the owning split, not create a new surface")

        guard case .split(let minimized) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertLessThan(minimized.ratios[0], 0.1)
        XCTAssertGreaterThan(minimized.ratios[1], 0.9)

        let restore = PaneTabsView(
            pane: leftPane,
            router: router,
            splitContext: PaneSplitContext(splitID: minimized.id, paneIndex: 0, ratios: minimized.ratios)
        )
        XCTAssertTrue(restore.performTogglePaneMinimized(),
                      "clicking the minimized pane control must restore a usable split")

        guard case .split(let restored) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(restored.ratios[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(restored.ratios[1], 0.5, accuracy: 0.0001)
    }

    func test_togglePaneRatios_encodesMinimizeAndRestoreIntent() {
        let minimized = PaneTabsView.toggledPaneMinimizedRatios(paneIndex: 1, ratios: [0.25, 0.25, 0.5])
        XCTAssertLessThan(minimized[1], 0.1,
                          "minimizing one pane should leave it as a tab strip while siblings keep the usable content area")
        XCTAssertGreaterThan(minimized[0], 0.1)
        XCTAssertGreaterThan(minimized[2], 0.1)

        let restored = PaneTabsView.toggledPaneMinimizedRatios(paneIndex: 1, ratios: minimized)
        XCTAssertEqual(restored, [1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0],
                       "restoring a minimized pane should return the split to usable equal panes")
    }

    func test_paneListMobileGroups_mergeHorizontalPanesForIOS() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ios-h", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        _ = try router.splitPane(workspace: ws.id, paneID: pane.id, direction: .right, surfaceType: .browser, title: "browser")

        let groups = try router.paneList(workspace: ws.id)
            .filter { $0["kind"]?.stringValue == "pane" }
            .compactMap { $0["mobile_group"]?.intValue }
        XCTAssertEqual(groups, [0, 0],
                       "iOS must merge desktop side-by-side panes into one mobile panel")
    }

    func test_paneListMobileGroups_capVerticalPanesAtTwoForIOS() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ios-v", cwd: NSTemporaryDirectory())
        guard case .pane(let rootPane) = ws.layout else { return XCTFail() }
        _ = try router.splitPane(workspace: ws.id, paneID: rootPane.id, direction: .down, surfaceType: .browser, title: "browser")

        let afterFirst = ctx.state.workspaces[ws.id]!
        let secondPane = try XCTUnwrap(afterFirst.layout.paneIDs().last)
        _ = try router.splitPane(workspace: ws.id, paneID: secondPane, direction: .down, surfaceType: .agentApp, title: "Agent App")

        let groups = try router.paneList(workspace: ws.id)
            .filter { $0["kind"]?.stringValue == "pane" }
            .compactMap { $0["mobile_group"]?.intValue }
        XCTAssertEqual(groups, [0, 1, 1],
                       "iOS supports only one vertical split; extra desktop vertical panes merge into the second mobile panel")
    }

    func test_horizontalMinimizedPane_usesCompactRestoreRail() throws {
        let (_, router) = try makeContext()
        let pane = PaneNode(surfaces: [SurfaceDescriptor(type: .terminal, title: "terminal")])
        let ptv = PaneTabsView(
            pane: pane,
            router: router,
            splitContext: PaneSplitContext(splitID: UUID(), paneIndex: 0, ratios: [0.04, 0.96], orientation: .horizontal)
        )

        let buttonTooltips = allSubviews(of: ptv.view)
            .compactMap { ($0 as? NSButton)?.toolTip }
        XCTAssertEqual(buttonTooltips, ["Maximize pane"],
                       "a minimized side-by-side pane should become a compact restore rail, not a cramped full toolbar")
    }

    func test_surfaceChoices_haveSixDistinctTypes() {
        let types = PaneTabsView.surfaceChoices.map { $0.1 }
        XCTAssertEqual(Set(types).count, types.count)
        XCTAssertTrue(types.contains(.terminal))
        XCTAssertTrue(types.contains(.browser))
        XCTAssertTrue(types.contains(.agentApp))
        XCTAssertTrue(types.contains(.rightSidebarTool),
                      "Git must be available as a normal tab surface option")
    }

    func test_focusSurface_switchesSelectedTab() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "s", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let termID = pane0.surfaces.first!.id              // default terminal
        let v = PaneTabsView(pane: pane0, router: router)
        let agent = v.performAdd(.agentApp, title: "Agent App")!
        // Adding selects the new tab.
        guard case .pane(let p1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p1.selectedSurfaceID, agent.id)
        // Clicking the terminal tab must switch the selection back.
        try router.focusSurface(workspace: ws.id, surface: termID)
        guard case .pane(let p2) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p2.selectedSurfaceID, termID,
                       "focusing another tab must change the visible surface")
    }

    func test_paneListExposesSelectedSurfaceForIOSWorkspaceOpen() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ios-visible-tab", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let termID = pane0.surfaces.first!.id
        let view = PaneTabsView(pane: pane0, router: router)
        _ = view.performAdd(.browser, title: "Browser")
        try router.focusSurface(workspace: ws.id, surface: termID)
        let selected = try XCTUnwrap(ctx.state.workspaces[ws.id]?.layout.find(paneID: pane0.id)?.selectedSurfaceID)

        let pane = try XCTUnwrap(try router.paneList(workspace: ws.id).first { $0["kind"]?.stringValue == "pane" })

        XCTAssertEqual(pane["selected_surface_id"]?.stringValue, selected.value.uuidString,
                       "pane.list must expose the visible macOS tab so iOS opens the same tab when entering a workspace")
    }

    func test_performReorderSurface_movesTabBeforeTargetInSamePane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "drag", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let first = pane0.surfaces.first!.id
        let v = PaneTabsView(pane: pane0, router: router)
        let second = try XCTUnwrap(v.performAdd(.browser, title: "browser"))

        guard case .pane(let pane1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        let dragView = PaneTabsView(pane: pane1, router: router)
        XCTAssertTrue(dragView.performReorderSurface(second.id, toPane: pane1.id, position: 0),
                      "dragging a tab before another tab must change the host-visible pane order")

        guard case .pane(let pane2) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(pane2.surfaces.map(\.id), [second.id, first])
    }

    func test_performReorderSurface_movesTabAcrossSplitPanes() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "split-drag", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let sourceSurface = pane0.surfaces.first!.id
        let v = PaneTabsView(pane: pane0, router: router)
        let right = try XCTUnwrap(v.performSplit(.right, type: .browser, title: "browser"))

        let updated = ctx.state.workspaces[ws.id]!
        let targetPane = try XCTUnwrap(updated.layout.paneIDs().first {
            updated.layout.find(paneID: $0)?.surfaces.contains(where: { $0.id == right.id }) == true
        })
        let dragView = PaneTabsView(pane: updated.layout.find(paneID: pane0.id)!, router: router)
        XCTAssertTrue(dragView.performReorderSurface(sourceSurface, toPane: targetPane, position: 0),
                      "dragging a tab into another split pane must move ownership, not only local order")

        let final = ctx.state.workspaces[ws.id]!
        XCTAssertEqual(final.layout.find(paneID: targetPane)?.surfaces.first?.id, sourceSurface)
    }

    func test_performSplitSurface_movesDraggedTabIntoNewSidePane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "drag-split-right", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let terminal = pane0.surfaces.first!.id
        let view = PaneTabsView(pane: pane0, router: router)
        let browser = try XCTUnwrap(view.performAdd(.browser, title: "browser"))

        guard case .pane(let pane1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        let dragView = PaneTabsView(pane: pane1, router: router)
        XCTAssertTrue(dragView.performSplitSurface(browser.id, direction: .right),
                      "dragging an existing tab to the side must move that tab into a new split pane, not create a blank duplicate")

        guard case .split(let split) = ctx.state.workspaces[ws.id]!.layout else {
            return XCTFail("expected a split after dragging a tab to the side")
        }
        XCTAssertEqual(split.orientation, .horizontal)
        XCTAssertEqual(split.children.count, 2)
        XCTAssertEqual(split.children.first?.find(paneID: pane1.id)?.surfaces.map(\.id), [terminal],
                       "the source pane should keep the remaining tabs after the dragged tab is split out")
        XCTAssertEqual(split.children.last?.paneIDs().compactMap { split.children.last?.find(paneID: $0)?.surfaces.first?.id }, [browser.id],
                       "the dragged tab should become the selected surface of the new side pane")
    }

    func test_performSplitSurface_movesDraggedTabIntoNewLowerPane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "drag-split-down", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let view = PaneTabsView(pane: pane0, router: router)
        let browser = try XCTUnwrap(view.performAdd(.browser, title: "browser"))

        guard case .pane(let pane1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        let dragView = PaneTabsView(pane: pane1, router: router)
        XCTAssertTrue(dragView.performSplitSurface(browser.id, direction: .down),
                      "dragging an existing tab downward must create a stacked split with the dragged tab in the lower pane")

        guard case .split(let split) = ctx.state.workspaces[ws.id]!.layout else {
            return XCTFail("expected a split after dragging a tab downward")
        }
        XCTAssertEqual(split.orientation, .vertical)
        XCTAssertEqual(split.children.count, 2)
    }

    func test_performSplitSurface_singleTabDoesNotCreateEmptyPane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "single-tab", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        let only = pane.surfaces.first!.id
        let view = PaneTabsView(pane: pane, router: router)

        XCTAssertFalse(view.performSplitSurface(only, direction: .right),
                       "a single-tab pane should not split itself into an empty source pane plus the same tab")
        guard case .pane(let unchanged) = ctx.state.workspaces[ws.id]!.layout else {
            return XCTFail("single-tab split attempts should leave the pane unchanged")
        }
        XCTAssertEqual(unchanged.surfaces.map(\.id), [only])
    }

    func test_closeSurface_removesTabFromPane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "c", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail() }
        // Workspace already has a default terminal (1); add two more (3).
        let v = PaneTabsView(pane: pane, router: router)
        let a = v.performAdd(.terminal, title: "t")
        _ = v.performAdd(.browser, title: "b")
        guard case .pane(let p1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p1.surfaces.count, 3)
        try router.closeSurface(workspace: ws.id, surface: a!.id)
        guard case .pane(let p2) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p2.surfaces.count, 2)
        XCTAssertFalse(p2.surfaces.contains { $0.id == a!.id })
    }

    func test_symbolForType_isDistinctNonEmpty() {
        let syms = SurfaceType.allCases.map { PaneTabsView.symbol(for: $0) }
        XCTAssertTrue(syms.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(syms).count, syms.count)
    }

    func test_buttons_noop_without_workspace() throws {
        let (_, router) = try makeContext()
        // No workspace selected.
        let emptyPane = PaneNode(surfaces: [])
        let ptv = PaneTabsView(pane: emptyPane, router: router)
        XCTAssertNil(ptv.performAdd(.terminal, title: "terminal"),
                     "with no selected workspace performAdd must return nil, not crash")
    }

    func test_tabHeaderControls_doNotBecomeWindowDragTargets() throws {
        let (ctx, router) = try makeContext()
        _ = ctx
        let ws = try router.createWorkspace(name: "controls", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let ptv = PaneTabsView(pane: pane, router: router)

        let buttons = allSubviews(of: ptv.view).compactMap { $0 as? NSButton }
        XCTAssertGreaterThanOrEqual(buttons.count, 4, "pane header should expose add/split/close controls")
        XCTAssertTrue(buttons.allSatisfy { !$0.mouseDownCanMoveWindow },
                      "tab add and close buttons live in the titlebar band, so they must receive clicks instead of starting a window drag")
    }

    func test_crowdedTabHeader_usesHorizontalScrollerWithoutScrollingPaneControls() throws {
        let (_, router) = try makeContext()
        let surfaces = (0..<14).map {
            SurfaceDescriptor(type: .terminal, title: "terminal-\($0)-wide-title", iconName: "terminal")
        }
        let pane = PaneNode(surfaces: surfaces, selectedSurfaceID: surfaces.last?.id)
        let ptv = PaneTabsView(pane: pane, router: router)
        ptv.view.setFrameSize(NSSize(width: 360, height: 240))
        ptv.view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(
            allSubviews(of: ptv.view).first { $0 is HorizontalTabScrollView } as? HorizontalTabScrollView,
            "crowded tab headers must use a horizontal scroll container so tabs are reachable instead of clipped"
        )
        let tabStrip = try XCTUnwrap(scrollView.documentView as? PaneTabDropStack)
        let scrolledButtons = allSubviews(of: tabStrip).compactMap { $0 as? NSButton }
        let scrolledTooltips = scrolledButtons.compactMap(\.toolTip)
        let fixedTooltips = allSubviews(of: ptv.view)
            .compactMap { $0 as? NSButton }
            .filter { !$0.isDescendant(of: tabStrip) }
            .compactMap(\.toolTip)

        XCTAssertTrue(scrollView.hasHorizontalScroller)
        XCTAssertFalse(scrollView.hasVerticalScroller)
        XCTAssertGreaterThanOrEqual(scrolledButtons.count, surfaces.count,
                                    "every tab button must remain inside the scrollable document")
        XCTAssertTrue(scrolledTooltips.contains("New surface"))
        XCTAssertTrue(fixedTooltips.contains("Split right (side by side)"))
        XCTAssertTrue(fixedTooltips.contains("Split down (stacked)"))
    }

    func test_secondaryPaneHeader_onlyShowsPaneLocalControls() throws {
        let (ctx, router) = try makeContext()
        _ = ctx
        let ws = try router.createWorkspace(name: "secondary", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let ptv = PaneTabsView(pane: pane, router: router, showsWorkspaceControls: false)

        let tooltips = allSubviews(of: ptv.view)
            .compactMap { ($0 as? NSButton)?.toolTip }
        XCTAssertFalse(tooltips.contains("Toggle sidebar"),
                       "sidebar toggling belongs in the sidebar header, not pane tabs")
        XCTAssertFalse(tooltips.contains("Open Git (changed files & diff)"),
                       "Git is created from the + menu as a tab, not from a persistent pane header button")
        XCTAssertFalse(tooltips.contains("Minimize pane"),
                       "pane zoom is shown only for panes that are inside a split")
        XCTAssertTrue(tooltips.contains("Split right (side by side)"))
        XCTAssertTrue(tooltips.contains("Split down (stacked)"))
    }

    func test_visibleSidebar_usesRightSideTitleBandAndNoGlobalPlus() throws {
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "visible", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(controller.window.contentView)
        let visibleButtons = visibleSubviews(of: content)
            .compactMap { $0 as? NSButton }
        let visibleTooltips = visibleButtons.compactMap(\.toolTip)

        XCTAssertFalse(visibleTooltips.contains("New workspace"),
                       "when the sidebar is visible, workspace creation belongs in the sidebar row, not a global + button")
        XCTAssertTrue(visibleTooltips.contains("Open in New Window"),
                      "attached workspaces need a header affordance to detach the current workspace")

        let titleLabels = visibleSubviews(of: content).compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == "visible" }
        XCTAssertFalse(titleLabels.isEmpty,
                       "the visible-sidebar chrome must still show the selected workspace title over the workspace area")

        let split = try XCTUnwrap(allSubviews(of: content).first { $0 is NSSplitView } as? NSSplitView)
        let splitTop = try XCTUnwrap(content.constraints.first {
            ($0.firstItem as? NSSplitView) === split && $0.firstAttribute == .top && $0.secondAttribute == .top
        })
        XCTAssertEqual(splitTop.constant, 0, accuracy: 0.1,
                       "the sidebar background must reach the top edge while the workspace area handles its own title inset")

        let rootPane = try XCTUnwrap(allSubviews(of: content).first { $0 is PaneRootView } as? PaneRootView)
        let rootFrame = rootPane.convert(rootPane.bounds, to: content)
        XCTAssertLessThanOrEqual(rootFrame.maxY, content.bounds.maxY - 33,
                                 "visible-sidebar mode keeps tabs below the right-side title band")
    }

    func test_visibleSidebar_hidesOpenInNewWindowButtonForDetachedWorkspace() throws {
        let (ctx, router) = try makeContext()
        let workspace = try router.createWorkspace(name: "detached", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.openWorkspaceInNewWindow(workspace.id)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        defer { controller.workspaceWindow(for: workspace.id)?.orderOut(nil) }

        let content = try XCTUnwrap(controller.window.contentView)
        let visibleTooltips = visibleSubviews(of: content)
            .compactMap { ($0 as? NSButton)?.toolTip }

        XCTAssertFalse(visibleTooltips.contains("Open in New Window"),
                       "a workspace that is already detached must not offer a duplicate detached-window action")
    }

    func test_sidebarViewModel_listsWindowWorkspacesAndSelectedWorkspaceForSidebarBody() throws {
        let (ctx, router) = try makeContext()
        let first = try router.createWorkspace(name: "alpha", cwd: NSTemporaryDirectory())
        let second = try router.createWorkspace(name: "beta", cwd: NSTemporaryDirectory())

        let vm = SidebarViewModel(context: ctx, router: router)
        vm.reload()

        XCTAssertEqual(vm.workspaces.map(\.name), ["alpha", "beta"],
                       "the visible sidebar Workspaces section must render the current window workspaces in order")
        XCTAssertEqual(vm.selectedWorkspaceID, second.id,
                       "the workspace row highlight must follow the router's selected workspace")

        try router.selectWorkspace(first.id)
        vm.reload()
        XCTAssertEqual(vm.selectedWorkspaceID, first.id,
                       "selecting a workspace must update the model that drives the sidebar row selection")
    }

    func test_collapsedSidebar_usesFullWidthHeaderWithToggleLeftPlusRightAndTabsBelow() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "collapsed", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let extra = PaneTabsView(pane: pane, router: router)
        XCTAssertNotNil(extra.performAdd(.terminal, title: "Terminal"))

        let controller = MainWindowController(context: ctx, router: router)
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(controller.window.contentView)
        let buttons = visibleSubviews(of: content).compactMap { $0 as? NSButton }
        let toggle = try XCTUnwrap(buttons.first { $0.toolTip == "Toggle sidebar" },
                                   "collapsed header must expose a left-side sidebar toggle")
        let plus = try XCTUnwrap(buttons.first { $0.toolTip == "New workspace" },
                                 "collapsed header must keep the workspace + on the right")
        let toggleFrame = toggle.convert(toggle.bounds, to: content)
        let plusFrame = plus.convert(plus.bounds, to: content)

        XCTAssertLessThan(toggleFrame.minX, 130,
                          "the collapsed-header toggle should sit near the left edge, not drift toward the center")
        XCTAssertGreaterThan(plusFrame.minX, content.bounds.width - 60,
                             "the collapsed-header + should remain on the right edge")
        XCTAssertLessThan(toggleFrame.maxX, plusFrame.minX,
                          "toggle and + must stay on opposite sides of the hidden-sidebar header")

        let split = try XCTUnwrap(allSubviews(of: content).first { $0 is NSSplitView } as? NSSplitView)
        let splitTop = try XCTUnwrap(content.constraints.first {
            ($0.firstItem as? NSSplitView) === split && $0.firstAttribute == .top && $0.secondAttribute == .top
        })
        XCTAssertEqual(splitTop.constant, 34, accuracy: 0.1,
                       "collapsed mode still needs a full-width header so the user can restore the sidebar")
    }

    func test_sidebarHideShowRestoresFullHeightSidebarWithoutBottomGap() throws {
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "glass-gap", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(controller.window.contentView)
        let split = try XCTUnwrap(allSubviews(of: content).first { $0 is NSSplitView } as? NSSplitView)
        let sidebar = try XCTUnwrap(split.subviews.first,
                                    "restoring the sidebar must keep the sidebar arranged inside the split view")
        let splitFrame = split.convert(split.bounds, to: content)
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: content)

        XCTAssertFalse(sidebar.isHidden,
                       "showing the sidebar again must unhide the glass sidebar view")
        XCTAssertEqual(splitFrame.minY, content.bounds.minY, accuracy: 0.5,
                       "the split view must remain pinned to the window bottom after hide/show")
        XCTAssertEqual(sidebarFrame.minY, content.bounds.minY, accuracy: 0.5,
                       "the restored sidebar glass must reach the bottom instead of leaving a black strip")
        XCTAssertEqual(sidebarFrame.height, splitFrame.height, accuracy: 0.5,
                       "the restored sidebar material must cover the split height")
    }

    func test_openWorkspaceInNewWindow_usesSidebarlessHeaderWithBackButton() throws {
        let (ctx, router) = try makeContext()
        let detached = try router.createWorkspace(name: "detached", cwd: NSTemporaryDirectory())
        _ = try router.createWorkspace(name: "main", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)

        controller.openWorkspaceInNewWindow(detached.id)

        let detachedWindow = try XCTUnwrap(controller.workspaceWindow(for: detached.id))
        detachedWindow.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(detachedWindow.contentView)
        let tooltips = visibleSubviews(of: content).compactMap { ($0 as? NSButton)?.toolTip }

        XCTAssertTrue(controller.isWorkspaceOpenInNewWindow(detached.id))
        XCTAssertTrue(tooltips.contains("Back to sidebar"),
                      "a workspace-only window needs an explicit return path to the sidebar")
        XCTAssertFalse(tooltips.contains("Toggle sidebar"),
                       "workspace-only windows open without a sidebar, so the header button must not be the sidebar toggle")
        XCTAssertNil(allSubviews(of: content).first { $0 is NSSplitView },
                     "the new workspace window should not include the main sidebar split view")
    }

    func test_backButtonFromWorkspaceWindowReturnsToMainSidebarWithoutClosingAppWindow() throws {
        let (ctx, router) = try makeContext()
        let detached = try router.createWorkspace(name: "detached-back", cwd: NSTemporaryDirectory())
        _ = try router.createWorkspace(name: "main-back", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller

        controller.openWorkspaceInNewWindow(detached.id)
        let detachedWindow = try XCTUnwrap(controller.workspaceWindow(for: detached.id))
        let back = try XCTUnwrap(allSubviews(of: try XCTUnwrap(detachedWindow.contentView))
            .compactMap { $0 as? NSButton }
            .first { $0.toolTip == "Back to sidebar" })

        back.performClick(nil)

        XCTAssertFalse(controller.isWorkspaceOpenInNewWindow(detached.id),
                       "Back to sidebar should close only the detached workspace window")
        XCTAssertEqual(ctx.state.window.selectedWorkspaceID, detached.id,
                       "Back to sidebar should reselect the workspace in the main sidebar window")
        XCTAssertTrue(controller.window.isVisible,
                      "returning a workspace must leave the main app window open so macOS does not treat the detached close as last-window quit")
    }

    func test_sidebarViewModel_toggleSidebarPostsSharedNotification() throws {
        let (ctx, router) = try makeContext()
        let vm = SidebarViewModel(context: ctx, router: router)
        let exp = expectation(forNotification: .rc2ToggleSidebar, object: nil)

        vm.toggleSidebar()

        wait(for: [exp], timeout: 0.2)
    }

    func test_sidebarUpdateControlReflectsSparkleStateAndRunsUpdaterAction() throws {
        let (ctx, router) = try makeContext()
        let updater = RecordingAppUpdateChecker(availability: .available)
        let vm = SidebarViewModel(context: ctx, router: router, updateChecker: updater)

        XCTAssertTrue(vm.showsUpdateControl,
                      "the sidebar must expose the Sparkle update/check row above New Workspace when auto-update is configured")
        XCTAssertEqual(vm.updateActionTitle, "Update Available",
                       "a found Sparkle update must be presented as an installable update, not as a manual DMG download")
        XCTAssertTrue(vm.updateActionHighlighted,
                      "an installable update must be visually highlighted so it is not just another sidebar row")

        vm.checkForUpdates()

        XCTAssertEqual(updater.checks, 1,
                       "clicking the sidebar update row must route to Sparkle's updater action")
        XCTAssertEqual(vm.updateActionTitle, "Checking for Updates",
                       "the sidebar must reflect Sparkle progress so repeated clicks do not stack checks")

        updater.availability = .upToDate
        XCTAssertEqual(vm.updateActionTitle, "Up to Date",
                       "Sparkle no-update feedback must stay visible instead of silently hiding the control")
        XCTAssertFalse(vm.updateActionHighlighted,
                       "the update highlight must clear once Sparkle reports there is no installable update")
    }

    func test_appDelegateChecksForUpdatesAfterOpeningApp() throws {
        let delegate = AppDelegate()
        let updater = RecordingAppUpdateChecker(availability: .unknown)
        delegate.updater = updater

        delegate.checkForUpdatesAfterOpeningApp()

        XCTAssertEqual(updater.checks, 1,
                       "opening the macOS app must run the same Sparkle update check as the sidebar control")
        XCTAssertEqual(updater.availability, .checking,
                       "startup update checks must drive the visible checking state instead of staying idle")
    }

    func test_settingsController_presentsSettingsAsModalSheet() throws {
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "settings", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let settings = SettingsWindowController(context: ctx)
        settings.show(attachedTo: controller.window)

        XCTAssertTrue(controller.window.attachedSheet === settings.window,
                      "Settings must open as a modal sheet attached to the main window, not as another floating preferences window")
        settings.close()
        XCTAssertNil(controller.window.attachedSheet,
                     "Settings must expose a close path that dismisses the modal sheet")
    }

    func test_settingsViewModel_persistsAllUserTunableAppSettings() throws {
        let (ctx, _) = try makeContext()
        let vm = SettingsViewModel(context: ctx)

        vm.setDiffWordWrap(true)
        vm.setDiffIgnoreWhitespace(true)
        vm.setCodexPath("/usr/bin/env")
        vm.setClaudePath("/usr/bin/env")

        let reloaded = SettingsViewModel(context: ctx)
        XCTAssertTrue(reloaded.appSettings.diffWordWrap,
                      "Settings must expose and persist the diff word-wrap preference used by the diff surface")
        XCTAssertTrue(reloaded.appSettings.diffIgnoreWhitespace,
                      "Settings must expose and persist the diff ignore-whitespace preference used by the diff surface")
        XCTAssertEqual(reloaded.codexPath, "/usr/bin/env",
                       "Settings must expose and persist the executable path used to launch Codex")
        XCTAssertEqual(reloaded.claudePath, "/usr/bin/env",
                       "Settings must expose and persist the executable path used to launch Claude")
        XCTAssertTrue(reloaded.codexAvailable && reloaded.claudeAvailable,
                      "valid configured CLI paths must be reflected in diagnostics")
    }

    func test_settingsViewModel_runsProviderUpdateFromConfiguredPath() async throws {
        let (ctx, _) = try makeContext()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fakeClaude = dir.appendingPathComponent("claude")
        try """
        #!/bin/sh
        if [ "$1" = "update" ]; then
          printf 'updated from settings\\n'
          exit 0
        fi
        exit 7
        """.write(to: fakeClaude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeClaude.path)

        let vm = SettingsViewModel(context: ctx)
        vm.setClaudePath(fakeClaude.path)

        await vm.updateProvider(.claude)

        XCTAssertEqual(vm.providerUpdateMessages[.claude], "updated from settings",
                       "Settings must run the provider-native update action through the configured Claude path instead of only surfacing stale update state")
        XCTAssertFalse(vm.updatingProviders.contains(.claude),
                       "Settings must clear provider update progress after completion so users can retry after a failure")
    }

    func test_ratioSplit_laysOutSideBySideWithoutFreeSpace() {
        let split = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 901, height: 300))
        split.isVertical = true
        split.ratios = [0.5, 0.5]
        let left = NSView()
        let right = NSView()
        split.addSubview(left)
        split.addSubview(right)

        split.relayoutNow()

        XCTAssertEqual(left.frame.minX, 0)
        XCTAssertEqual(left.frame.height, split.bounds.height)
        XCTAssertEqual(right.frame.maxX, split.bounds.width)
        XCTAssertEqual(right.frame.minX, left.frame.maxX + split.dividerThickness,
                       "side-by-side splits must allocate every pixel except the single divider")
    }

    func test_ratioSplit_laysOutStackedTopToBottomWithoutFreeSpace() {
        let split = RatioSplitView(frame: NSRect(x: 0, y: 0, width: 500, height: 601))
        split.isVertical = false
        split.ratios = [0.5, 0.5]
        let top = NSView()
        let bottom = NSView()
        split.addSubview(top)
        split.addSubview(bottom)

        split.relayoutNow()

        XCTAssertEqual(top.frame.maxY, split.bounds.height)
        XCTAssertEqual(top.frame.width, split.bounds.width)
        XCTAssertEqual(bottom.frame.minY, 0)
        XCTAssertEqual(top.frame.minY, bottom.frame.maxY + split.dividerThickness,
                       "stacked splits must allocate every pixel except the single divider, with the original pane on top")
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    private func visibleSubviews(of view: NSView) -> [NSView] {
        allSubviews(of: view).filter { isVisibleInTree($0) }
    }

    private func isVisibleInTree(_ view: NSView) -> Bool {
        var current: NSView? = view
        while let candidate = current {
            if candidate.isHidden { return false }
            current = candidate.superview
        }
        return true
    }
}

@MainActor
private final class RecordingAppUpdateChecker: AppUpdateChecking {
    var availability: AppUpdateAvailability {
        didSet { onAvailabilityChanged?(availability) }
    }
    var onAvailabilityChanged: ((AppUpdateAvailability) -> Void)?
    private(set) var checks = 0

    init(availability: AppUpdateAvailability) {
        self.availability = availability
    }

    func checkForUpdates() {
        checks += 1
        availability = .checking
    }
}
