import XCTest
@testable import AppShell
@testable import CoreModel
@testable import Surfaces
import Persistence
import SocketServer
import AgentRuntime

@MainActor
final class PaneActionTests: XCTestCase {
    private final class FakeSSHPasswordStore: SSHPasswordStoring {
        var values: [String: String] = [:]
        var savedAccounts: [String] = []
        var loadedAccounts: [String] = []
        var deletedAccounts: [String] = []

        func save(account: String, password: String) {
            savedAccounts.append(account)
            values[account] = password
        }

        func load(account: String) -> String? {
            loadedAccounts.append(account)
            return values[account]
        }

        func delete(account: String) {
            deletedAccounts.append(account)
            values.removeValue(forKey: account)
        }
    }

    private func closeAndUnregisterAllSurfaces() {
        let surfaces = SurfaceRegistry.shared.all()
        surfaces.forEach { $0.close() }
        surfaces.forEach { SurfaceRegistry.shared.unregister($0.descriptor.id) }
    }

    private func closeAllTestWindows() {
        let windows = Array(NSApplication.shared.windows)
        for window in windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            if let parent = window.sheetParent {
                parent.endSheet(window)
            }
        }
        for window in windows {
            window.orderOut(nil)
        }
    }

    override func tearDown() {
        closeAllTestWindows()
        closeAndUnregisterAllSurfaces()
        super.tearDown()
    }

    private func makeContext(sshPasswordStore: SSHPasswordStoring = KeychainSSHPasswordStore()) throws -> (AppContext, AppCommandRouter) {
        let tmp = NSTemporaryDirectory() + "RC2PaneTest-" + UUID().uuidString
        let ctx = try AppContext(channel: .debug, appSupportOverride: tmp)
        let router = AppCommandRouter(context: ctx, sshPasswordStore: sshPasswordStore)
        ctx.router = router
        return (ctx, router)
    }

    private func drainMainQueue(seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 1, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            drainMainQueue(seconds: 0.02)
        }
        XCTAssertTrue(condition(), message)
    }

    private func makePaneWithTabCount(_ count: Int, name: String) throws -> (AppContext, AppCommandRouter, WorkspaceID, PaneNode) {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: name, cwd: NSTemporaryDirectory())
        guard case .pane(let initialPane) = ws.layout else {
            throw NSError(domain: "PaneActionTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "expected single pane workspace"
            ])
        }
        let view = PaneTabsView(pane: initialPane, router: router)
        for index in 1..<count {
            XCTAssertNotNil(view.performAdd(.browser, title: "tab-\(index)"))
        }
        return (ctx, router, ws.id, try currentPane(ctx, workspace: ws.id, paneID: initialPane.id))
    }

    private func currentPane(_ ctx: AppContext, workspace: WorkspaceID, paneID: PaneID) throws -> PaneNode {
        let ws = try XCTUnwrap(ctx.state.workspaces[workspace])
        return try XCTUnwrap(ws.layout.find(paneID: paneID))
    }

    func test_newWorkspace_opensAgentAppByDefault_andAddCreatesAnother() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "w", cwd: NSTemporaryDirectory())
        // A new workspace opens with Agent App as the default selected tab.
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        XCTAssertEqual(pane.surfaces.count, 1)
        XCTAssertEqual(pane.surfaces.first?.type, .agentApp)
        XCTAssertEqual(pane.selectedSurfaceID, pane.surfaces.first?.id)
        XCTAssertEqual(pane.surfaces.first?.title, "Agent App")

        let ptv = PaneTabsView(pane: pane, router: router)
        let desc = ptv.performAdd(.terminal, title: "terminal")
        XCTAssertNotNil(desc, "performAdd should return a descriptor")

        let updated = ctx.state.workspaces[ws.id]!
        guard case .pane(let p2) = updated.layout else { return XCTFail() }
        XCTAssertEqual(p2.surfaces.count, 2)
        XCTAssertEqual(p2.surfaces.map(\.type), [.agentApp, .terminal])
        XCTAssertNotNil(SurfaceRegistry.shared.surface(p2.surfaces[0].id))
        XCTAssertNotNil(SurfaceRegistry.shared.surface(p2.surfaces[1].id))
    }

    func test_feedPanelIgnoresBacklogPublishedBeforeOpen() throws {
        let (_, router) = try makeContext()
        let staleTitle = "feed-stale-\(UUID().uuidString)"
        EventBus.shared.publish(kind: "feed.test.stale", payload: .object(["title": .string(staleTitle)]))
        let ws = try router.createWorkspace(name: "feed-open-\(UUID().uuidString)", cwd: NSTemporaryDirectory())

        let desc = try router.createSurface(workspace: ws.id, type: .rightSidebarTool, paneID: nil, title: "Feed")
        let feed = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? FeedPanelSurface)
        drainMainQueue()

        XCTAssertFalse(feed.readText().contains(staleTitle),
                       "opening Feed must not replay retained EventBus backlog from before the panel existed")
        XCTAssertFalse(feed.readText().contains(ws.name),
                       "workspace events published before Feed opens must not appear as if they were live activity")

        let freshTitle = "feed-fresh-\(UUID().uuidString)"
        EventBus.shared.publish(kind: "feed.test.fresh", payload: .object(["title": .string(freshTitle)]))
        waitUntil("Feed should still stream events published after it opens") {
            feed.readText().contains(freshTitle)
        }
    }

    func test_focusingAnotherTabUnloadsHiddenFilePreviewSurface() throws {
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "preview-memory", cwd: NSTemporaryDirectory())
        guard case .pane(let initialPane) = ws.layout,
              let defaultSurfaceID = initialPane.surfaces.first?.id else {
            return XCTFail("expected default Agent App surface")
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-preview-memory-\(UUID().uuidString).txt")
        try String(repeating: "123456789\n", count: 50_000).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let previewDesc = try router.createSurface(workspace: ws.id, type: .filePreview, paneID: nil, title: file.path)
        let preview = try XCTUnwrap(SurfaceRegistry.shared.surface(previewDesc.id) as? FilePreviewSurface)
        XCTAssertFalse(preview.view.subviews.isEmpty, "selected preview tab should render the file while visible")
        waitUntil("visible preview must finish its off-main text load before lifecycle accounting") {
            preview.textCache.retainedPayloadBytesForTesting > 0
        }

        try router.focusSurface(workspace: ws.id, surface: defaultSurfaceID)

        XCTAssertTrue(preview.view.subviews.isEmpty,
                      "switching away must unload heavyweight preview views so hidden tabs do not retain image/PDF/text content")
        XCTAssertEqual(preview.textCache.retainedPayloadBytesForTesting, 0,
                       "router-driven hide must release the loaded text and UTF-16 line index")
        XCTAssertEqual(preview.pdfCache.entryCountForTesting, 0)
        XCTAssertEqual(preview.filePath, file.path,
                       "heavy-content purge must preserve lightweight reopen metadata")
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

    func test_sidebarWorkspaceRowsDoNotSynchronouslyReadRunningThreads() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "busy", cwd: NSTemporaryDirectory())
        var thread = AgentThread(workspaceId: ws.id, title: "Long task", provider: .codex, model: "gpt-5.5")
        thread.status = .running
        try ctx.threadRepo.upsert(thread)

        let vm = SidebarViewModel(context: ctx, router: router)
        vm.reload()

        XCTAssertNil(vm.workspaces.first(where: { $0.id == ws.id })?.metadata["busy"],
                     "local workspace listing must not synchronously read durable thread state")
        XCTAssertFalse(vm.isWorkspaceBusy(vm.workspaces.first(where: { $0.id == ws.id })!),
                       "durable status alone must not bypass the live in-memory runtime projection")
    }

    func test_agentSurfaceBusyRollsUpRunningThreadForTabSpinner() async throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "tab-busy", cwd: NSTemporaryDirectory())
        let desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent App")
        let agent = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? AgentAppSurface)
        let thread = AgentThread(workspaceId: ws.id, title: "Long task", provider: .codex, model: "gpt-5.5")
        try ctx.threadRepo.upsert(thread)
        ctx.coordinator.replaceProvider(.codex, runner: PaneBlockingRunner())

        _ = try await ctx.coordinator.startRun(AgentRunRequest(
            threadId: thread.id,
            provider: .codex,
            model: "gpt-5.5",
            cwd: NSTemporaryDirectory(),
            prompt: "keep tab busy"
        ))

        agent.viewModel.reloadThreads()

        // Per-tab spinner (not workspace-wide roll-up): a tab that is NOT bound to the
        // running thread must not spin just because the coordinator owns an active run.
        // This is the semantics test_agentTabBusyUsesBoundThreadNotWholeWorkspace encodes.
        XCTAssertFalse(agent.isBusy,
                       "an Agent tab must not spin for a running thread it does not own")

        // A scheduled task uses exactly this unbound/headless shape. Per-tab chrome
        // stays idle, but the workspace aggregate must match an interactively
        // started run so the sidebar shows its spinner.
        for _ in 0..<50 {
            if ctx.hasActiveAgentRun(in: ws.id) { break }
            await Task.yield()
        }
        XCTAssertTrue(ctx.hasActiveAgentRun(in: ws.id),
                      "a coordinator-owned unbound run must enter the workspace projection")
        XCTAssertTrue(router.isWorkspaceBusy(ws.id),
                      "scheduled/headless and user-started runs must drive the same workspace busy state")
        XCTAssertEqual(try router.listWorkspaces().first(where: { $0.id == ws.id })?.metadata["busy"], "true")

        let sidebar = SidebarViewModel(context: ctx, router: router)
        let sidebarWorkspace = try XCTUnwrap(sidebar.workspaces.first(where: { $0.id == ws.id }))
        XCTAssertTrue(sidebar.isWorkspaceBusy(sidebarWorkspace))
        XCTAssertEqual(sidebar.busyTooltip(for: sidebarWorkspace),
                       "Agent run in thread \"Long task\"")

        // Bind this tab to the running thread → it now owns a real active run identity.
        agent.viewModel.selectThread(thread.id)
        XCTAssertTrue(agent.isBusy,
                      "the tab strip must spin while THIS tab owns a real active run identity")
        ctx.coordinator.stopRun(threadId: thread.id)
        for _ in 0..<50 {
            if !ctx.hasActiveAgentRun(in: ws.id) { break }
            await Task.yield()
        }
        XCTAssertFalse(ctx.hasActiveAgentRun(in: ws.id),
                       "terminal lifecycle must clear the workspace projection")
        XCTAssertFalse(router.isWorkspaceBusy(ws.id))
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

    func test_sshHostListDoesNotReadSavedPasswordStorageOnOpen() throws {
        let store = FakeSSHPasswordStore()
        let (_, router) = try makeContext(sshPasswordStore: store)
        let workspace = try router.createWorkspace(name: "ssh-keychain-open", cwd: NSTemporaryDirectory())

        let saved = try router.sshHostUpsert(SSHHostProfile(label: "Prompt Once",
                                                            destination: "prompt.example.invalid",
                                                            password: "saved-secret"),
                                             workspace: workspace.id)
        XCTAssertEqual(store.savedAccounts, [saved.id.value.uuidString],
                       "saving the host must store the password once in secure storage")

        store.loadedAccounts = []
        let listed = try router.sshHostList(workspace: workspace.id)

        XCTAssertTrue(store.loadedAccounts.isEmpty,
                      "opening RemoteCode or listing SSH hosts must not read the saved password because that triggers the macOS Keychain prompt")
        XCTAssertNil(listed.first?.password,
                     "the host list should carry metadata only; the secret is needed when connecting, not when drawing the saved-host sidebar")
    }

    func test_sshHostForConnectionLoadsSavedPasswordOnlyWhenConnecting() throws {
        let store = FakeSSHPasswordStore()
        let (_, router) = try makeContext(sshPasswordStore: store)
        let workspace = try router.createWorkspace(name: "ssh-keychain-connect", cwd: NSTemporaryDirectory())

        let saved = try router.sshHostUpsert(SSHHostProfile(label: "Connect Once",
                                                            destination: "connect.example.invalid",
                                                            password: "saved-secret"),
                                             workspace: workspace.id)
        store.loadedAccounts = []
        let listed = try router.sshHostList(workspace: workspace.id)
        let listedHost = try XCTUnwrap(listed.first)

        let resolved = try router.sshHostForConnection(listedHost, workspace: workspace.id)

        XCTAssertEqual(store.loadedAccounts, [saved.id.value.uuidString],
                       "the saved password should be read exactly when the user connects, not while opening the app")
        XCTAssertEqual(resolved.password, "saved-secret",
                       "one-tap reconnect must still answer the SSH password prompt after list/open stops reading Keychain")
        XCTAssertTrue(resolved.hasSavedPassword)
    }

    func test_legacySSHHostWithoutSavedPasswordMetadataStillLoadsPasswordOnConnect() throws {
        let store = FakeSSHPasswordStore()
        let (ctx, router) = try makeContext(sshPasswordStore: store)
        let workspace = try router.createWorkspace(name: "ssh-legacy-keychain", cwd: NSTemporaryDirectory())
        let legacyID = SSHHostID()
        try ctx.settingsRepo.set("ssh.hosts.\(workspace.id.value.uuidString)", """
        [{"id":{"value":"\(legacyID.value.uuidString)"},"label":"Legacy SSH","destination":"legacy.example.invalid"}]
        """)
        store.values[legacyID.value.uuidString] = "legacy-secret"

        let listed = try router.sshHostList(workspace: workspace.id)
        let listedHost = try XCTUnwrap(listed.first)

        XCTAssertTrue(store.loadedAccounts.isEmpty,
                      "reading older saved-host settings must not probe Keychain during app open")
        XCTAssertNil(listedHost.password)
        XCTAssertTrue(listedHost.hasSavedPassword,
                      "older saved-host rows predate the metadata flag, so they must stay eligible for connect-time Keychain loading")

        let resolved = try router.sshHostForConnection(listedHost, workspace: workspace.id)

        XCTAssertEqual(store.loadedAccounts, [legacyID.value.uuidString])
        XCTAssertEqual(resolved.password, "legacy-secret")
    }

    func test_sshOpenNewConnectionUsesCurrentSurfaceThenCreatesNewTabWhenActive() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ssh-new-connection", cwd: NSTemporaryDirectory())
        let desc = try router.createSurface(workspace: ws.id, type: .ssh, paneID: nil, title: "SSH")
        let surface = try XCTUnwrap(SurfaceRegistry.shared.surface(desc.id) as? SSHSurface)
        let host = try router.sshHostUpsert(SSHHostProfile(label: "Example SSH", destination: "example.invalid"), workspace: ws.id)

        surface.openNewConnectionForTesting(host)
        waitUntil("first SSH open-new-connection must finish its async connect phase", timeout: 8) {
            surface.snapshot()["ssh_status"] == "connected"
        }

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
        waitUntil("new SSH tab must finish its async connect phase", timeout: 8) {
            newSurface.snapshot()["ssh_status"] == "connected"
        }
        XCTAssertEqual(newSurface.view.subviews.count, 5,
                       "new active SSH connections must open the full SSH tab chrome with hosts, terminal, and transfer sidebar")
        XCTAssertEqual(newSurface.sshTransferProfile?.id, host.id,
                       "the connected host row must be highlighted in the newly opened SSH tab")
        XCTAssertGreaterThan(newSurface.transferSidebarWidthForTesting, 0,
                             "new active SSH tabs must also reveal the file-transfer sidebar")
        XCTAssertEqual(newSurface.snapshot()["ssh_status"], "connected")
    }

    func test_agentTabBusyUsesBoundThreadNotWholeWorkspace() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "tab-repo-busy", cwd: NSTemporaryDirectory())
        let idleDesc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Idle Agent")
        var runningThread = AgentThread(workspaceId: ws.id, title: "Long task", provider: .codex, model: "gpt-5.5")
        runningThread.status = .running
        try ctx.threadRepo.upsert(runningThread)
        var idleThread = AgentThread(workspaceId: ws.id, title: "Idle", provider: .codex, model: "gpt-5.5")
        idleThread.status = .completed
        try ctx.threadRepo.upsert(idleThread)

        // Unbound idle tab must NOT spin just because another thread is running.
        XCTAssertFalse(PaneTabsView.isSurfaceBusy(idleDesc, router: router),
                       "an Agent App tab without a bound running thread must not spin for sibling threads")

        // A stale/unregistered descriptor must not synchronously query SQLite to
        // infer busy state. The live SurfaceRegistry owns this display signal.
        let unregisteredDesc = SurfaceDescriptor(
            type: .agentApp,
            title: "Stale Agent",
            iconName: "sparkles",
            metadata: [
                "workspace": ws.id.value.uuidString,
                "selected_thread": runningThread.id.value.uuidString
            ]
        )
        XCTAssertNil(SurfaceRegistry.shared.surface(unregisteredDesc.id))
        XCTAssertFalse(PaneTabsView.isSurfaceBusy(unregisteredDesc, router: router),
                       "an unregistered surface must not infer busy by synchronously reading SQLite")

        // Bound to an idle thread → no spinner even if another workspace thread runs.
        var idleBoundDesc = idleDesc
        idleBoundDesc.metadata["selected_thread"] = idleThread.id.value.uuidString
        XCTAssertFalse(PaneTabsView.isSurfaceBusy(idleBoundDesc, router: router),
                       "a tab bound to an idle thread must not spin for other running workspace threads")
    }

    func test_terminalBusySurfaceRollsUpToTabAndWorkspaceBusyState() throws {
        let (ctx, router) = try makeContext()
        try ctx.apply(.createWorkspace(name: "terminal-busy", cwd: NSTemporaryDirectory(), initial: nil))
        let workspaceID = try XCTUnwrap(ctx.state.window.selectedWorkspaceID)
        let descriptor = SurfaceDescriptor(
            type: .terminal,
            title: "terminal",
            iconName: "terminal",
            metadata: ["workspace": workspaceID.value.uuidString]
        )
        let surface = TestBusySurface(descriptor: descriptor)
        SurfaceRegistry.shared.register(surface)
        try ctx.apply(.addSurface(workspaceID, paneID: nil, descriptor: descriptor))

        XCTAssertFalse(PaneTabsView.isSurfaceBusy(descriptor, router: router),
                       "an idle terminal prompt must not show a tab spinner")
        XCTAssertNil(try router.listWorkspaces().first(where: { $0.id == workspaceID })?.metadata["busy"],
                     "an idle terminal prompt must not show a workspace spinner")

        surface.isBusy = true

        XCTAssertTrue(PaneTabsView.isSurfaceBusy(descriptor, router: router),
                      "tab rendering must show a spinner while the terminal surface reports a foreground job")
        XCTAssertEqual(try router.listWorkspaces().first(where: { $0.id == workspaceID })?.metadata["busy"], "true",
                       "workspace rows must show the same spinner while any terminal in the workspace has a foreground job")

        surface.isBusy = false

        XCTAssertFalse(PaneTabsView.isSurfaceBusy(descriptor, router: router),
                       "tab rendering must clear the spinner after the terminal returns to the prompt")
        XCTAssertNil(try router.listWorkspaces().first(where: { $0.id == workspaceID })?.metadata["busy"],
                     "workspace rows must drop the spinner after the terminal returns to the prompt")
    }

    func test_terminalBusyRuntimeRefreshUpdatesTabSpinnerWithoutRebuildingPane() throws {
        let (ctx, router) = try makeContext()
        try ctx.apply(.createWorkspace(name: "terminal-tab-busy", cwd: NSTemporaryDirectory(), initial: nil))
        let workspaceID = try XCTUnwrap(ctx.state.window.selectedWorkspaceID)
        let descriptor = SurfaceDescriptor(
            type: .terminal,
            title: "terminal",
            iconName: "terminal",
            metadata: ["workspace": workspaceID.value.uuidString]
        )
        let surface = TestBusySurface(descriptor: descriptor)
        SurfaceRegistry.shared.register(surface)
        try ctx.apply(.addSurface(workspaceID, paneID: nil, descriptor: descriptor))
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        drainMainQueue()
        let paneRoot = {
            controller.window.contentView?.layoutSubtreeIfNeeded()
            return self.allSubviews(of: controller.window.contentView ?? NSView()).first { $0 is PaneRootView }
        }
        waitUntil("main window must install the pane root before runtime refresh assertions") {
            paneRoot() != nil
        }
        let rootBefore = try XCTUnwrap(paneRoot())

        XCTAssertTrue(tabProgressIndicators(in: controller, surfaceID: descriptor.id).isEmpty,
                      "idle terminal tabs must render the normal terminal icon instead of a spinner")

        surface.isBusy = true
        controller.refreshSurfaceRuntimeState()
        waitUntil("busy runtime refresh must update the existing tab spinner") {
            controller.window.contentView?.layoutSubtreeIfNeeded()
            return !tabProgressIndicators(in: controller, surfaceID: descriptor.id).isEmpty
        }
        let rootAfter = try XCTUnwrap(paneRoot())

        XCTAssertFalse(tabProgressIndicators(in: controller, surfaceID: descriptor.id).isEmpty,
                       "a terminal busy-state change must update the existing tab header without waiting for a layout rebuild")
        XCTAssertTrue(rootBefore === rootAfter,
                      "runtime spinner updates must not rebuild the terminal pane because reattaching the terminal view can make input and Ctrl-C unreliable")
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
        XCTAssertEqual(PaneTabsView.surfaceChoices.map(\.0), ["Terminal", "SSH", "Browser", "Agent App", "Files", "Git"],
                       "split-panel menus must expose the same choices as the tab + menu instead of defaulting straight to Terminal")
        XCTAssertTrue(types.contains(.terminal))
        XCTAssertTrue(types.contains(.ssh))
        XCTAssertTrue(types.contains(.browser))
        XCTAssertTrue(types.contains(.agentApp))
        XCTAssertTrue(types.contains(.files))
        XCTAssertTrue(types.contains(.rightSidebarTool),
                      "Git must be available as a normal tab surface option")
    }

    func test_focusSurface_switchesSelectedTab() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "s", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let defaultSurfaceID = pane0.surfaces.first!.id    // default Agent App
        let v = PaneTabsView(pane: pane0, router: router)
        let browser = v.performAdd(.browser, title: "Browser")!
        // Adding selects the new tab.
        guard case .pane(let p1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p1.selectedSurfaceID, browser.id)
        // Clicking the default tab must switch the selection back.
        try router.focusSurface(workspace: ws.id, surface: defaultSurfaceID)
        guard case .pane(let p2) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p2.selectedSurfaceID, defaultSurfaceID,
                       "focusing another tab must change the visible surface")
    }

    func test_paneListExposesSelectedSurfaceForIOSWorkspaceOpen() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "ios-visible-tab", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let defaultSurfaceID = pane0.surfaces.first!.id
        let view = PaneTabsView(pane: pane0, router: router)
        _ = view.performAdd(.browser, title: "Browser")
        try router.focusSurface(workspace: ws.id, surface: defaultSurfaceID)
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
        let defaultSurfaceID = pane0.surfaces.first!.id
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
        XCTAssertEqual(split.children.first?.find(paneID: pane1.id)?.surfaces.map(\.id), [defaultSurfaceID],
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

    func test_performSplitSurface_movesDraggedTabIntoVerticalSplitOfAnotherPane() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "drag-split-other-pane-down", cwd: NSTemporaryDirectory())
        guard case .pane(let pane0) = ws.layout else { return XCTFail() }
        let defaultSurfaceID = pane0.surfaces.first!.id
        let view = PaneTabsView(pane: pane0, router: router)
        let browser = try XCTUnwrap(view.performSplit(.right, type: .browser, title: "browser"))

        let splitWorkspace = ctx.state.workspaces[ws.id]!
        let sourcePaneID = try XCTUnwrap(splitWorkspace.layout.paneIDs().first {
            splitWorkspace.layout.find(paneID: $0)?.surfaces.contains(where: { $0.id == browser.id }) == true
        })
        let dragView = PaneTabsView(pane: try XCTUnwrap(splitWorkspace.layout.find(paneID: sourcePaneID)), router: router)

        XCTAssertTrue(dragView.performSplitSurface(browser.id, targetPane: pane0.id, direction: .down),
                      "dragging a tab onto another pane's lower drop zone must split that target pane vertically")

        guard case .split(let split) = ctx.state.workspaces[ws.id]!.layout else {
            return XCTFail("expected a vertical split after dragging a tab into another pane")
        }
        XCTAssertEqual(split.orientation, .vertical)
        XCTAssertEqual(split.children.first?.paneIDs().compactMap { split.children.first?.find(paneID: $0)?.surfaces.first?.id }, [defaultSurfaceID])
        XCTAssertEqual(split.children.last?.paneIDs().compactMap { split.children.last?.find(paneID: $0)?.surfaces.first?.id }, [browser.id])
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
        // Workspace already has a default Agent App tab (1); add two more (3).
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

    func test_nativeSurfaceMutationsPublishMirrorLifecycleEvents() throws {
        let before = EventBus.shared.snapshot().lastSeq
        let (_, router) = try makeContext()
        let ws = try router.createWorkspace(name: "mirror-events", cwd: NSTemporaryDirectory())

        let added = try router.createSurface(workspace: ws.id, type: .browser, paneID: nil, title: "Mirror Created")
        try router.focusSurface(workspace: ws.id, surface: added.id)
        try router.closeSurface(workspace: ws.id, surface: added.id)

        let events = EventBus.shared.recentEvents(since: before, maxBytes: nil).events

        XCTAssertTrue(events.contains { event in
            let payload = event.payload.objectValue
            return event.kind == "surface.created"
                && payload?["workspace_id"]?.stringValue == ws.id.value.uuidString
                && payload?["surface"]?.objectValue?["title"]?.stringValue == "Mirror Created"
        }, "macOS-created tabs must publish surface.created so iOS opens the same tab without manual refresh")
        XCTAssertTrue(events.contains { event in
            let payload = event.payload.objectValue
            return event.kind == "surface.focused"
                && payload?["workspace_id"]?.stringValue == ws.id.value.uuidString
                && payload?["id"]?.stringValue == added.id.value.uuidString
        }, "macOS tab focus must publish surface.focused so iOS selects the same visible tab")
        XCTAssertTrue(events.contains { event in
            let payload = event.payload.objectValue
            return event.kind == "surface.closed"
                && payload?["workspace_id"]?.stringValue == ws.id.value.uuidString
                && payload?["id"]?.stringValue == added.id.value.uuidString
        }, "macOS tab close must publish surface.closed so iOS removes stale tabs")
    }

    func test_tabContextMenu_exposesBulkCloseActions() throws {
        let (_, router, _, pane) = try makePaneWithTabCount(4, name: "tab-menu")
        let view = PaneTabsView(pane: pane, router: router)
        let targetID = pane.surfaces[1].id
        let tab = try XCTUnwrap(allSubviews(of: view.view).compactMap { $0 as? PaneTabButton }
            .first { $0.surfaceIDForTesting == targetID })

        let menu = tab.contextMenuForTesting()
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)

        XCTAssertEqual(Array(titles.prefix(3)), ["Close all others", "Close all to left", "Close all to right"],
                       "right-clicking a tab must expose bulk close actions before cosmetic tab actions")
        XCTAssertTrue(menu.item(withTitle: "Close all others")?.isEnabled == true)
        XCTAssertTrue(menu.item(withTitle: "Close all to left")?.isEnabled == true)
        XCTAssertTrue(menu.item(withTitle: "Close all to right")?.isEnabled == true)
        XCTAssertTrue(titles.contains("Rename…"))
        XCTAssertTrue(titles.contains("Color"))
    }

    func test_tabBulkCloseActionsRespectClickedTabAndSide() throws {
        do {
            let (ctx, router, wsID, pane) = try makePaneWithTabCount(4, name: "close-others")
            let targetID = pane.surfaces[2].id

            XCTAssertTrue(PaneTabsView(pane: pane, router: router).performCloseAllOthers(around: targetID),
                          "Close all others must keep the clicked tab and close every sibling in the pane")

            XCTAssertEqual(try currentPane(ctx, workspace: wsID, paneID: pane.id).surfaces.map(\.id), [targetID])
        }

        do {
            let (ctx, router, wsID, pane) = try makePaneWithTabCount(4, name: "close-left")
            let targetIndex = 2
            let targetID = pane.surfaces[targetIndex].id
            let expected = pane.surfaces[targetIndex...].map(\.id)

            XCTAssertTrue(PaneTabsView(pane: pane, router: router).performCloseToLeft(of: targetID),
                          "Close all to left must remove only tabs before the clicked tab")

            XCTAssertEqual(try currentPane(ctx, workspace: wsID, paneID: pane.id).surfaces.map(\.id), Array(expected))
        }

        do {
            let (ctx, router, wsID, pane) = try makePaneWithTabCount(4, name: "close-right")
            let targetIndex = 1
            let targetID = pane.surfaces[targetIndex].id
            let expected = pane.surfaces[...targetIndex].map(\.id)

            XCTAssertTrue(PaneTabsView(pane: pane, router: router).performCloseToRight(of: targetID),
                          "Close all to right must remove only tabs after the clicked tab")

            XCTAssertEqual(try currentPane(ctx, workspace: wsID, paneID: pane.id).surfaces.map(\.id), Array(expected))
        }
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

    func test_tabHeaderScrollHelperMovesHorizontalViewport() {
        let scrollView = HorizontalTabScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 34))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 34))
        scrollView.documentView = document
        scrollView.layoutSubtreeIfNeeded()

        scrollView.scrollHorizontally(by: 90)

        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.x, 0,
                             "wheel movement over a crowded tab header should move the horizontal tab viewport")
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
        controller.flushPendingRefresh()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        let content = try XCTUnwrap(controller.window.contentView)
        let visibleButtons = visibleSubviews(of: content)
            .compactMap { $0 as? NSButton }
        let visibleTooltips = visibleButtons.compactMap(\.toolTip)

        XCTAssertFalse(visibleTooltips.contains("New workspace"),
                       "when the sidebar is visible, workspace creation belongs in the sidebar row, not a global + button")
        XCTAssertTrue(visibleTooltips.contains("Open in Finder"),
                      "the workspace title band needs a direct Finder affordance for the active workspace folder")
        XCTAssertTrue(visibleTooltips.contains("Open in New Window"),
                      "attached workspaces need a header affordance to detach the current workspace")

        let titleLabels = visibleSubviews(of: content).compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == "visible" }
        XCTAssertFalse(titleLabels.isEmpty,
                       "the visible-sidebar chrome must still show the selected workspace title over the workspace area")

        let columns = try XCTUnwrap(
            allSubviews(of: content).first { $0.accessibilityIdentifier() == "shell.columns" }
        )
        XCTAssertEqual(columns.frame.maxY, content.bounds.maxY, accuracy: 0.1,
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
        XCTAssertTrue(visibleTooltips.contains("Open in Finder"),
                      "detached status must not remove the active workspace's Finder shortcut")
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
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.1))

        let content = try XCTUnwrap(controller.window.contentView)
        let buttons = allSubviews(of: content).compactMap { $0 as? NSButton }
        let toggle = try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == "shell.collapsed.toggleSidebar" },
            "collapsed header must expose a left-side sidebar toggle"
        )
        let plus = try XCTUnwrap(
            buttons.first { $0.accessibilityIdentifier() == "shell.collapsed.newWorkspace" },
            "collapsed header must keep the workspace + on the right"
        )
        let toggleFrame = toggle.convert(toggle.bounds, to: content)
        let plusFrame = plus.convert(plus.bounds, to: content)

        XCTAssertLessThan(toggleFrame.minX, 130,
                          "the collapsed-header toggle should sit near the left edge, not drift toward the center")
        XCTAssertGreaterThan(plusFrame.minX, content.bounds.width - 60,
                             "the collapsed-header + should remain on the right edge")
        XCTAssertLessThan(toggleFrame.maxX, plusFrame.minX,
                          "toggle and + must stay on opposite sides of the hidden-sidebar header")

        let columns = try XCTUnwrap(
            allSubviews(of: content).first { $0.accessibilityIdentifier() == "shell.columns" }
        )
        XCTAssertEqual(content.bounds.maxY - columns.frame.maxY, 34, accuracy: 0.1,
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
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.1))
        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.1))

        let content = try XCTUnwrap(controller.window.contentView)
        let columns = try XCTUnwrap(
            allSubviews(of: content).first { $0.accessibilityIdentifier() == "shell.columns" }
        )
        let sidebar = try XCTUnwrap(
            allSubviews(of: content).first { $0.accessibilityIdentifier() == "shell.sidebar" },
            "restoring the sidebar must keep the glass panel in the columns host"
        )
        let columnsFrame = columns.convert(columns.bounds, to: content)
        let sidebarFrame = sidebar.convert(sidebar.bounds, to: content)

        XCTAssertFalse(sidebar.isHidden,
                       "showing the sidebar again must unhide the glass sidebar view")
        XCTAssertGreaterThanOrEqual(
            sidebarFrame.width,
            ShellSidebarToggleMotion.minimumSidebarWidth,
            "restoring the sidebar must return a usable width, not a 0pt column that ate the toggle"
        )
        XCTAssertEqual(columnsFrame.minY, content.bounds.minY, accuracy: 0.5,
                       "the columns host must remain pinned to the window bottom after hide/show")
        XCTAssertEqual(sidebarFrame.minY, content.bounds.minY, accuracy: 0.5,
                       "the restored sidebar glass must reach the bottom instead of leaving a black strip")
        XCTAssertEqual(sidebarFrame.height, columnsFrame.height, accuracy: 0.5,
                       "the restored sidebar material must cover the columns height")
    }

    func test_sidebarToggleRemainsReachableAcrossRepeatedHideShowCycles_becauseTransparentHeaderCannotInterceptClicks() throws {
        // WHY: the collapsed header spans the full title row. Fading it to
        // alpha zero without hiding it leaves an invisible hit-test layer over
        // the restored sidebar controls, so the next toggle click does nothing.
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "repeat-toggle", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(controller.window.contentView)

        for cycle in 1...2 {
            NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.1))

            let restore = try XCTUnwrap(
                allSubviews(of: content).compactMap { $0 as? NSButton }
                    .first { $0.accessibilityIdentifier() == "shell.collapsed.toggleSidebar" }
            )
            let collapsedHeader = try XCTUnwrap(restore.superview)
            XCTAssertFalse(collapsedHeader.isHidden)

            restore.performClick(nil)
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.1))

            XCTAssertTrue(collapsedHeader.isHidden,
                          "restored cycle \(cycle) must remove the transparent collapsed header from hit testing")
            XCTAssertNil(collapsedHeader.hitTest(
                NSPoint(x: collapsedHeader.bounds.midX, y: collapsedHeader.bounds.midY)
            ))
        }
    }

    func test_sidebarSeamStaysSeamlessAndExactAcrossToggleCycle_becauseDriftDrewAStrayLine() throws {
        // WHY: the old NSSplitView toggle drew a 1px near-black divider
        // strip (the reported "strange line") and landed off target after
        // hide/show (439.5 for 444) — a half-pixel seam that antialiased
        // into a blurry line and drifted the user's width every toggle.
        // The slide rewrite must keep the glass touching the content and
        // land back exactly where it started, on a whole pixel.
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "seam", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        drainMainQueue(seconds: 0.3)

        let content = try XCTUnwrap(controller.window.contentView)
        let sidebar = try XCTUnwrap(
            allSubviews(of: content).first { $0.accessibilityIdentifier() == "shell.sidebar" }
        )
        let workspace = try XCTUnwrap(sidebar.superview?.subviews.first { view in
            view !== sidebar && view.frame.width > 100
        })

        XCTAssertEqual(workspace.frame.minX - sidebar.frame.maxX, 0, accuracy: 0.01,
                       "the glass sidebar must touch the content — a divider strip reads as a stray border")
        let freshWidth = sidebar.frame.width
        XCTAssertEqual(freshWidth, freshWidth.rounded(), accuracy: 0.01,
                       "the sidebar edge must sit on a whole pixel or the seam antialiases")

        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.15))
        XCTAssertLessThanOrEqual(sidebar.frame.maxX, 0.01,
                                 "hidden = the panel parked fully outside the leading edge")
        XCTAssertEqual(workspace.frame.minX, 0, accuracy: 0.01,
                       "with the panel parked outside, the content column owns the full width")

        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.4))

        XCTAssertEqual(workspace.frame.minX - sidebar.frame.maxX, 0, accuracy: 0.01,
                       "hide/show must not open a divider strip in the seam")
        XCTAssertEqual(sidebar.frame.width, freshWidth, accuracy: 0.01,
                       "hide/show must restore the exact pre-hide width, not a drifted half-pixel one")
        XCTAssertEqual(sidebar.frame.minX, 0, accuracy: 0.01,
                       "the restored panel must land exactly on the leading edge")
    }

    func test_collapsedSidebarToggleRestoresUsableWidth_becauseZeroWidthLeavesNoEscape() throws {
        // WHY: the SwiftUI header (toggle / bug / settings / account) lives
        // in the sidebar. Collapse hides that cluster. The 34pt bar is the
        // only restore control. Clicking it used to flip sidebarCollapsed,
        // hide the bar, and leave the split at 0pt — no sidebar, no toggle.
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "restore", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        controller.window.contentView?.layoutSubtreeIfNeeded()

        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.1))

        let content = try XCTUnwrap(controller.window.contentView)
        let toggle = try XCTUnwrap(
            allSubviews(of: content).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "shell.collapsed.toggleSidebar" },
            "collapsed chrome must keep a restore control after the sidebar header is gone"
        )
        XCTAssertFalse(toggle.isHidden)
        toggle.performClick(nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.15))

        let sidebar = try XCTUnwrap(
            allSubviews(of: content).first { $0.accessibilityIdentifier() == "shell.sidebar" }
        )
        XCTAssertGreaterThanOrEqual(
            sidebar.frame.width,
            ShellSidebarToggleMotion.minimumSidebarWidth,
            "the collapsed toggle must open a usable sidebar, not a 0pt column"
        )
        XCTAssertGreaterThanOrEqual(sidebar.frame.minX, -0.01,
                                    "the restored panel must slide back inside the window")
        XCTAssertFalse(sidebar.isHidden)
        XCTAssertGreaterThan(sidebar.alphaValue, 0.5)
    }

    func test_botsCollapsedSidebarToggleRestoresUsableWidth_becauseDeskAteTheEscape() throws {
        // WHY: Bots hides the shell workspace header. Collapse then only
        // has the 34pt bar. The same 0pt expand bug left Desk full-bleed
        // with no way back to Agentic / Bots / Settings.
        let (ctx, router) = try makeContext()
        _ = try router.createWorkspace(name: "bots-restore", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller
        controller.window.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 720), display: false)
        controller.presentBotsInMainContent()
        controller.window.contentView?.layoutSubtreeIfNeeded()

        NotificationCenter.default.post(name: .rc2ToggleSidebar, object: nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.1))

        let content = try XCTUnwrap(controller.window.contentView)
        let toggle = try XCTUnwrap(
            allSubviews(of: content).compactMap { $0 as? NSButton }
                .first { $0.accessibilityIdentifier() == "shell.collapsed.toggleSidebar" },
            "Bots still needs the 34pt restore bar when the sidebar header is gone"
        )
        toggle.performClick(nil)
        controller.window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(ShellSidebarToggleMotion.duration + 0.15))

        let sidebar = try XCTUnwrap(
            allSubviews(of: content).first { $0.accessibilityIdentifier() == "shell.sidebar" }
        )
        XCTAssertGreaterThanOrEqual(
            sidebar.frame.width,
            ShellSidebarToggleMotion.minimumSidebarWidth,
            "restoring from Bots must bring the sidebar back, not leave Desk full-bleed"
        )
        XCTAssertGreaterThanOrEqual(sidebar.frame.minX, -0.01,
                                    "restoring from Bots must slide the panel back inside the window")
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
        // Agent App embeds its own HSplitView; only the window chrome must stay
        // free of the main sidebar NSSplitView (a direct content child).
        XCTAssertNil(content.subviews.first { $0 is NSSplitView },
                     "the new workspace window should not include the main sidebar split view")
    }

    func test_focusSurfaceReconcilesDetachedWorkspaceWindowTabs() throws {
        let (ctx, router) = try makeContext()
        let detached = try router.createWorkspace(name: "detached-focus", cwd: NSTemporaryDirectory())
        guard case .pane(let initialPane) = detached.layout,
              let firstSurfaceID = initialPane.surfaces.first?.id else {
            return XCTFail("expected a single-pane workspace with a default surface")
        }
        let second = try router.createSurface(
            workspace: detached.id,
            type: .terminal,
            paneID: initialPane.id,
            title: "terminal-proof"
        )
        try router.focusSurface(workspace: detached.id, surface: second.id)
        _ = try router.createWorkspace(name: "main-focus", cwd: NSTemporaryDirectory())
        let controller = MainWindowController(context: ctx, router: router)
        router.windowController = controller

        controller.openWorkspaceInNewWindow(detached.id)
        defer { controller.workspaceWindow(for: detached.id)?.orderOut(nil) }
        let detachedWindow = try XCTUnwrap(controller.workspaceWindow(for: detached.id))
        detachedWindow.contentView?.layoutSubtreeIfNeeded()

        try router.focusSurface(workspace: detached.id, surface: firstSurfaceID)
        drainMainQueue()

        let content = try XCTUnwrap(detachedWindow.contentView)
        let firstTab = try XCTUnwrap(tabButton(in: content, surfaceID: firstSurfaceID))
        let secondTab = try XCTUnwrap(tabButton(in: content, surfaceID: second.id))
        let firstSurfaceView = try XCTUnwrap(SurfaceRegistry.shared.surface(firstSurfaceID)?.view)
        let secondSurfaceView = try XCTUnwrap(SurfaceRegistry.shared.surface(second.id)?.view)

        XCTAssertTrue(firstTab.selectedForTesting,
                      "a tab click in a detached workspace routes through focusSurface; the detached window must repaint the newly selected tab after that single click")
        XCTAssertFalse(secondTab.selectedForTesting,
                       "the previously selected detached-window tab must clear its selected state without requiring a second click")
        XCTAssertTrue(firstSurfaceView.isDescendant(of: content),
                      "the detached workspace window must mount the newly selected surface content after one tab click")
        XCTAssertFalse(secondSurfaceView.isDescendant(of: content),
                       "the previously selected surface content must be removed from the detached workspace window after one tab click")
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

    func test_aaa_settingsController_presentsSettingsAsModalSheet() throws {
        let (ctx, _) = try makeContext()
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let settings = SettingsWindowController(context: ctx)
        parent.animationBehavior = .none
        settings.window.animationBehavior = .none
        settings.show(attachedTo: parent)

        XCTAssertTrue(parent.attachedSheet === settings.window,
                      "Settings must open as a modal sheet attached to the main window, not as another floating preferences window")
        settings.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertNil(parent.attachedSheet,
                     "Settings must expose a close path that dismisses the modal sheet")
        parent.orderOut(nil)
    }

    func test_settingsViewModel_persistsAllUserTunableAppSettings() throws {
        let (ctx, _) = try makeContext()
        let vm = SettingsViewModel(context: ctx)

        vm.setDiffWordWrap(true)
        vm.setDiffIgnoreWhitespace(true)
        vm.setCodexPath("/usr/bin/env")
        vm.setClaudePath("/usr/bin/env")
        AgentCustomModelStore(repo: ctx.settingsRepo).add("gpt-5.5-experimental", provider: .codex)
        vm.reload()
        vm.setCustomModel(provider: .codex, index: 0, value: "gpt-5.5-custom")

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
        XCTAssertEqual(reloaded.customModelsByProvider[.codex], ["gpt-5.5-custom"],
                       "Settings must edit custom model IDs saved from the Agent model menu so they persist until explicitly removed")

        reloaded.removeCustomModel(provider: .codex, index: 0)
        XCTAssertEqual(SettingsViewModel(context: ctx).customModelsByProvider[.codex], [],
                       "Settings must remove custom model IDs instead of leaving stale rows in future Agent model menus")
    }

    func test_aab_settingsViewModel_runsProviderUpdateFromConfiguredPath() async throws {
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

    private func tabButton(in view: NSView, surfaceID: SurfaceID) -> PaneTabButton? {
        allSubviews(of: view)
            .compactMap { $0 as? PaneTabButton }
            .first { $0.surfaceIDForTesting == surfaceID }
    }

    private func tabProgressIndicators(in controller: MainWindowController, surfaceID: SurfaceID) -> [NSProgressIndicator] {
        guard let tab = allSubviews(of: controller.window.contentView ?? NSView()).first(where: {
            $0.accessibilityIdentifier() == "pane.tab.\(surfaceID.value.uuidString)"
        }) else { return [] }
        return allSubviews(of: tab).compactMap { $0 as? NSProgressIndicator }
    }

    func test_closeSurfaces_batch_removesAllGivenSurfacesInOneCall() throws {
        // Verifies that closeSurfaces(workspace:surfaces:) removes every listed
        // surface and leaves only the unlisted one, proving the batch method
        // applies all mutations without skipping any surface.
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "batch-close", cwd: NSTemporaryDirectory())
        guard case .pane(let pane) = ws.layout else { return XCTFail("expected single pane") }
        let ptv = PaneTabsView(pane: pane, router: router)
        let b = try XCTUnwrap(ptv.performAdd(.browser, title: "b"))
        let c = try XCTUnwrap(ptv.performAdd(.browser, title: "c"))
        guard case .pane(let p0) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        let keepID = p0.surfaces.first!.id
        XCTAssertEqual(p0.surfaces.count, 3)

        try router.closeSurfaces(workspace: ws.id, surfaces: [b.id, c.id])

        guard case .pane(let p1) = ctx.state.workspaces[ws.id]!.layout else { return XCTFail() }
        XCTAssertEqual(p1.surfaces.map(\.id), [keepID],
                       "batch close must remove exactly the requested surfaces and leave the rest")
        XCTAssertNil(SurfaceRegistry.shared.surface(b.id), "b must be unregistered after batch close")
        XCTAssertNil(SurfaceRegistry.shared.surface(c.id), "c must be unregistered after batch close")
    }

    // PERF: batch isSurfaceBusy overload must match the per-tab path. Busy is
    // per-surface (bound selected_thread / live surface isBusy), not workspace-wide.
    func test_batchIsSurfaceBusy_matchesPerTabResult() throws {
        let (ctx, router) = try makeContext()
        let ws = try router.createWorkspace(name: "batch-busy", cwd: NSTemporaryDirectory())
        var desc = try router.createSurface(workspace: ws.id, type: .agentApp, paneID: nil, title: "Agent")

        // No running bound thread: both paths must agree -- not busy.
        let runningEmpty = PaneTabsView.runningWorkspaceIDs(for: [desc], router: router)
        XCTAssertFalse(
            PaneTabsView.isSurfaceBusy(desc, runningWorkspaceIDs: runningEmpty, router: router),
            "batch path must agree with per-tab: not busy when no bound thread is running"
        )
        XCTAssertFalse(
            PaneTabsView.isSurfaceBusy(desc, router: router),
            "per-tab original must also report not busy when no bound thread is running"
        )

        // Unrelated running thread must not busy this tab.
        var other = AgentThread(workspaceId: ws.id, title: "other", provider: .codex, model: "m")
        other.status = .running
        try ctx.threadRepo.upsert(other)
        let runningFull = PaneTabsView.runningWorkspaceIDs(for: [desc], router: router)
        XCTAssertFalse(
            PaneTabsView.isSurfaceBusy(desc, runningWorkspaceIDs: runningFull, router: router),
            "batch path must not mark a tab busy for an unbound sibling running thread"
        )
        XCTAssertFalse(
            PaneTabsView.isSurfaceBusy(desc, router: router),
            "per-tab path must not mark a tab busy for an unbound sibling running thread"
        )

        // A durable running row alone is not enough to synchronously infer UI
        // busy state. The live surface/coordinator event must own that signal.
        desc.metadata["selected_thread"] = other.id.value.uuidString
        XCTAssertFalse(
            PaneTabsView.isSurfaceBusy(desc, runningWorkspaceIDs: runningFull, router: router),
            "batch path must not query SQLite to busy a stale surface descriptor"
        )
        XCTAssertFalse(
            PaneTabsView.isSurfaceBusy(desc, router: router),
            "per-tab path must not query SQLite to busy a stale surface descriptor"
        )
    }
}

private final class PaneBlockingRunner: AgentProviderRunner, @unchecked Sendable {
    let provider: AgentProvider = .codex

    func listModels() async -> [AgentModelDescriptor] { [] }

    func startRun(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        onEvent(.status(.running))
        return AgentRunHandle(runId: request.runId, process: nil) {
            onEvent(.status(.cancelled))
            onEvent(.finished(.cancelled, finalMessage: nil, providerThreadId: nil))
        }
    }
}

@MainActor
private final class RecordingAppUpdateChecker: AppUpdateChecking {
    var availability: AppUpdateAvailability {
        didSet { onAvailabilityChanged?(availability) }
    }
    var onAvailabilityChanged: ((AppUpdateAvailability) -> Void)?
    var onWillInstallUpdate: (() -> Void)?
    private(set) var checks = 0

    init(availability: AppUpdateAvailability) {
        self.availability = availability
    }

    func checkForUpdates() {
        checks += 1
        availability = .checking
    }
}

@MainActor
private final class TestBusySurface: Surface {
    var descriptor: SurfaceDescriptor
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
    var isBusy = false

    init(descriptor: SurfaceDescriptor) {
        self.descriptor = descriptor
    }

    func focus() {}
    func unfocus() {}
    func close() {}
    func sendText(_ text: String) {}
    func readText() -> String { "" }
    func snapshot() -> [String: String] { [:] }
}
