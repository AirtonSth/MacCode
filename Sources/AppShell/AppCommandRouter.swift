import Foundation
import AppKit
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces

/// Bridges the JSON-RPC dispatcher to the in-process domain state plus the
/// concrete Surface views. Lives on the main actor because it mutates UI.
@MainActor
public final class AppCommandRouter: CommandRouting {
    public weak var context: AppContext?
    public weak var windowController: MainWindowController?

    public init(context: AppContext) {
        self.context = context
    }

    /// Walk the restored layout state and instantiate fresh Surface
    /// views for every descriptor. Surfaces are rebuilt with new IDs
    /// (their old IDs were owned by surfaces that no longer exist), so
    /// we rewrite the layout state to refer to the new IDs and update
    /// selectedSurfaceID per pane.
    public func reinstantiateRestoredSurfaces() {
        guard let ctx = context else { return }
        var idMap: [SurfaceID: SurfaceID] = [:]
        for (wid, ws) in ctx.state.workspaces {
            forEachSurface(in: ws.layout) { desc in
                let cwd = ws.cwd
                let title = desc.title
                do {
                    let surface: Surface
                    switch desc.type {
                    case .terminal:
                        surface = try TerminalSurface(workspaceID: wid, cwd: cwd, title: title)
                    case .browser:
                        surface = configureBrowserSurface(BrowserSurface(workspaceID: wid, initialURL: restoredBrowserURL(from: desc), title: title))
                    case .agentApp:
                        let agent = AgentAppSurface(workspaceID: wid, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, title: title)
                        let token = EventBus.shared.subscribe(since: nil) { [weak agent] ev in
                            guard ev.kind.hasPrefix("agent.thread.") else { return }
                            DispatchQueue.main.async { agent?.viewModel.reloadThreads() }
                        }
                        agent.subscriptionToken = AnyHashable(token)
                        agent.viewModel.onReviewRequested = { [weak self] in
                            _ = try? self?.createSurface(workspace: wid, type: .rightSidebarTool, paneID: nil, title: "Git")
                        }
                        agent.viewModel.onRunStateChange = { [weak self] in
                            self?.windowController?.refreshFromState()
                        }
                        surface = agent
                    case .markdown:
                        surface = MarkdownSurface(workspaceID: wid, filePath: desc.metadata["path"], title: title)
                    case .filePreview:
                        surface = FilePreviewSurface(workspaceID: wid, filePath: desc.metadata["path"], title: title)
                    case .rightSidebarTool:
                        surface = DiffPanelSurface(workspaceID: wid, cwd: cwd, title: title, settings: SettingsStore(db: ctx.db))
                    }
                    idMap[desc.id] = surface.descriptor.id
                    SurfaceRegistry.shared.register(surface)
                } catch {
                    // skip
                }
            }
        }
        guard !idMap.isEmpty else { return }
        for (wid, ws) in ctx.state.workspaces {
            var copy = ws
            copy.layout = remapIDs(in: copy.layout, idMap: idMap)
            ctx.state.workspaces[wid] = copy
        }
    }

    private func forEachSurface(in node: LayoutNode, _ visit: (SurfaceDescriptor) -> Void) {
        switch node {
        case .pane(let p): for s in p.surfaces { visit(s) }
        case .split(let s): for c in s.children { forEachSurface(in: c, visit) }
        }
    }

    private func remapIDs(in node: LayoutNode, idMap: [SurfaceID: SurfaceID]) -> LayoutNode {
        switch node {
        case .pane(var p):
            p.surfaces = p.surfaces.map { d in
                let new = idMap[d.id] ?? d.id
                return SurfaceDescriptor(id: new, type: d.type, title: d.title, iconName: d.iconName,
                                          isDirty: d.isDirty, hasUnreadActivity: d.hasUnreadActivity, metadata: d.metadata)
            }
            if let sel = p.selectedSurfaceID { p.selectedSurfaceID = idMap[sel] ?? sel }
            return .pane(p)
        case .split(var s):
            s.children = s.children.map { remapIDs(in: $0, idMap: idMap) }
            return .split(s)
        }
    }

    public func listWorkspaces() throws -> [Workspace] {
        guard let ctx = context else { return [] }
        return ctx.state.window.workspaces.compactMap { id in
            guard var ws = ctx.state.workspaces[id] else { return nil }
            let surfaceBusy = ws.layout.paneIDs().contains { pid in
                (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                    SurfaceRegistry.shared.surface($0.id)?.isBusy == true
                }
            }
            let threadBusy = ((try? ctx.threadRepo.list(workspaceId: id)) ?? []).contains { $0.status == .running }
            let busy = surfaceBusy || threadBusy
            if busy { ws.metadata["busy"] = "true" }
            else { ws.metadata.removeValue(forKey: "busy") }
            return ws
        }
    }

    public func currentWindow() throws -> AppWindow {
        context?.state.window ?? AppWindow()
    }

    public func listWindows() throws -> [AppWindow] {
        context?.state.windows ?? []
    }

    public func createWindow(title: String?) throws -> AppWindow {
        try context?.apply(.createWindow(title: title))
        let w = try currentWindow()
        windowController?.openAdditionalWindow(for: w)
        return w
    }

    public func focusWindow(_ id: WindowID) throws {
        try context?.apply(.focusWindow(id))
        windowController?.refreshFromState()
    }

    public func closeWindow(_ id: WindowID) throws {
        try context?.apply(.closeWindow(id))
        windowController?.refreshFromState()
    }

    public func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws {
        try context?.apply(.moveWorkspaceToWindow(workspace, target))
        windowController?.refreshFromState()
    }

    public func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws {
        try context?.apply(.swapPanes(workspace, a, b))
        windowController?.refreshFromState()
    }

    public func createWorkspace(name: String, cwd: String) throws -> Workspace {
        guard let ctx = context else { throw NSError(domain: "rc2", code: 0) }
        try ctx.apply(.createWorkspace(name: name, cwd: cwd, initial: nil))
        guard let id = ctx.state.window.selectedWorkspaceID else { throw LayoutError.workspaceNotFound }
        // A new workspace opens with a terminal by default (cmux model).
        let term = makeSurface(type: .terminal, title: defaultTitle(for: .terminal), workspace: id, cwd: cwd)
        try ctx.apply(.addSurface(id, paneID: nil, descriptor: term))
        guard let ws = ctx.state.workspaces[id] else { throw LayoutError.workspaceNotFound }
        windowController?.refreshFromState()
        return ws
    }

    public func selectWorkspace(_ id: WorkspaceID) throws {
        try context?.apply(.selectWorkspace(id))
        windowController?.refreshFromState()
    }

    public func closeWorkspace(_ id: WorkspaceID) throws {
        try context?.apply(.closeWorkspace(id))
        windowController?.refreshFromState()
    }

    public func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws {
        try context?.apply(.renameWorkspace(id, newName))
        windowController?.refreshFromState()
    }

    public func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws {
        try context?.apply(.setWorkspaceDescription(id, text))
        windowController?.refreshFromState()
    }

    public func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws {
        try context?.apply(.setWorkspaceColor(id, color))
        windowController?.refreshFromState()
    }

    public func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws {
        try context?.apply(.setWorkspacePinned(id, pinned))
        windowController?.refreshFromState()
    }

    public func reorderWorkspace(_ id: WorkspaceID, position: Int) throws {
        try context?.apply(.reorderWorkspace(id, position: position))
        windowController?.refreshFromState()
    }

    public func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws {
        try context?.apply(.renameSurface(wid, sid, title))
        windowController?.refreshFromState()
    }

    public func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws {
        try context?.apply(.setSurfaceColor(wid, sid, color))
        windowController?.refreshFromState()
    }

    public func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let desc = makeSurface(type: type, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.addSurface(workspace, paneID: paneID, descriptor: desc))
        windowController?.refreshFromState()
        return desc
    }

    public func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let desc = makeSurface(type: surfaceType, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.splitPane(workspace, paneID: paneID, direction: direction, newSurface: desc))
        windowController?.refreshFromState()
        return desc
    }

    public func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        try context?.apply(.closeSurface(workspace, surface))
        if let s = SurfaceRegistry.shared.surface(surface) {
            s.close()
            SurfaceRegistry.shared.unregister(surface)
        }
        windowController?.refreshFromState()
    }

    public func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        try context?.apply(.focusSurface(workspace, surface))
        // Rebuild the pane so the newly selected tab's surface actually
        // becomes the visible content (the custom tab strip has no
        // built-in content switching like NSTabView did).
        windowController?.refreshFromState()
        windowController?.focusSurface(surface)
    }

    public func sendText(surface: SurfaceID, text: String) throws {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        s.sendText(text)
    }

    public func readText(surface: SurfaceID) throws -> String {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        return s.readText()
    }

    public func surfaceHealth(surface: SurfaceID) -> Bool {
        SurfaceRegistry.shared.surface(surface) != nil
    }

    public func surfaceClearHistory(surface: SurfaceID) {
        // Terminal-specific: replace scrollback by sending the clear
        // shortcut. Browser/agent surfaces ignore.
        if let s = SurfaceRegistry.shared.surface(surface), s.descriptor.type == .terminal {
            s.sendText("\u{0C}") // ctrl-L
        }
    }

    public func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        try createSurface(workspace: workspace, type: .agentApp, paneID: nil, title: "Agent App")
    }

    public func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] {
        guard let ctx = context else { return [] }
        return try ctx.threadRepo.list(workspaceId: workspace)
    }

    public func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let t = AgentThread(workspaceId: workspace, title: title, provider: provider, model: model)
        try ctx.threadRepo.upsert(t)
        try selectAgentThread(thread: t.id)
        return t
    }

    public func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard var t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        if let provider, provider != t.provider {
            // A1 (iOS+macOS parity): the provider is fixed once the
            // thread has a conversation. Only model/effort stay
            // changeable after that. Enforced host-side so no client
            // can bypass the UI lock.
            let started = !((try? ctx.messageRepo.listRecent(threadId: thread, limit: 1)) ?? []).isEmpty
            guard !started else {
                throw JSONRPCError(code: -32010,
                    message: "Provider is locked once the thread has started; only model and effort can change.")
            }
            t.provider = provider
            t.providerThreadId = nil
        }
        if let model, model != t.model {
            t.model = model
            t.providerThreadId = nil
        }
        t.updatedAt = Date()
        try ctx.threadRepo.upsert(t)
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            if agent.viewModel.selectedThreadId == thread {
                if let provider { agent.viewModel.provider = provider }
                if let model { agent.viewModel.model = model }
                if let permissionMode { agent.viewModel.permissionMode = permissionMode }
                if let reasoningEffort { agent.viewModel.reasoningEffort = reasoningEffort }
            }
            agent.viewModel.reloadThreads()
        }
        windowController?.refreshFromState()
        return t
    }

    public func selectAgentThread(thread: AgentThreadID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            agent.viewModel.reloadThreads()
            agent.viewModel.selectThread(thread)
        }
        windowController?.refreshFromState()
    }

    public func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.listRecent(threadId: thread, limit: max(0, min(limit, 500)))
    }

    public func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?) async throws -> AgentRunID {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        var t = try configureAgentThread(thread: thread, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort)
        let prov = provider ?? t.provider
        let m = model ?? t.model
        let cwd = ctx.state.workspaces.first { $0.value.id == t.workspaceId }?.value.cwd ?? FileManager.default.currentDirectoryPath
        let req = AgentRunRequest(
            threadId: thread,
            provider: prov,
            model: m,
            cwd: cwd,
            prompt: text,
            providerThreadId: t.providerThreadId,
            permissionMode: permissionMode ?? .supervised,
            reasoningEffort: reasoningEffort
        )
        let runId = try await ctx.coordinator.startRun(req)
        // HC-5 (R1): a message sent from the mobile mirror must be
        // visible on the Mac. Route it into the live Agent surface for
        // this workspace exactly like a local action — select the
        // thread + reload so the just-persisted user message and the
        // streaming turn render in the macOS window, not only over the
        // wire.
        for s in SurfaceRegistry.shared.all() {
            if let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId {
                agent.viewModel.reloadThreads()
                agent.viewModel.selectThread(thread)
                windowController?.refreshFromState()
            }
        }
        return runId
    }

    public func stopAgentRun(thread: AgentThreadID) throws {
        // We don't track thread->run map; cancel any active run for that thread by scanning observer state.
        // V1 simplification: rely on UI-tracked currentRunId; CLI stop targets thread id.
        // Best effort: nothing here; the AgentAppViewModel keeps live runs.
    }

    public func deleteAgentThread(thread: AgentThreadID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.delete(id: thread)
    }

    public func deleteAgentThreads(_ threads: [AgentThreadID]) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.delete(ids: threads)
    }

    public func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw JSONRPCError.invalidParams }
        guard var t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        t.title = trimmed
        t.updatedAt = Date()
        try ctx.threadRepo.upsert(t)
        return t
    }

    public func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.setPinned(id: thread, pinned: pinned)
        guard let t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            agent.viewModel.reloadThreads()
        }
        windowController?.refreshFromState()
        return t
    }

    public func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try ctx.threadRepo.reorder(id: thread, position: position)
        guard let t = try ctx.threadRepo.get(id: thread), let wid = t.workspaceId else { throw LayoutError.workspaceNotFound }
        let list = try ctx.threadRepo.list(workspaceId: wid)
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == wid else { continue }
            agent.viewModel.reloadThreads()
        }
        windowController?.refreshFromState()
        return list
    }

    public func markAgentThreadRead(thread: AgentThreadID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard var t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        if t.hasUnread { t.hasUnread = false; try ctx.threadRepo.upsert(t) }
        try selectAgentThread(thread: thread)
    }

    public func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor] {
        let runner: AgentProviderRunner = provider == .codex ? CodexRunner() : ClaudeRunner()
        return await runner.listModels()
    }

    // MARK: git (socket/CLI parity — same engine the diff panel uses)

    private func workspaceCwd(_ id: WorkspaceID) throws -> String {
        guard let cwd = context?.state.workspaces[id]?.cwd else { throw LayoutError.workspaceNotFound }
        return cwd
    }

    public func gitStatus(workspace: WorkspaceID) throws -> GitSummary {
        GitDiff.summary(in: try workspaceCwd(workspace))
    }
    public func gitBranches(workspace: WorkspaceID) throws -> GitBranches {
        GitDiff.branches(in: try workspaceCwd(workspace))
    }
    public func gitCheckout(workspace: WorkspaceID, branch: String) throws -> GitActionResult {
        GitDiff.checkout(in: try workspaceCwd(workspace), branch: branch)
    }
    public func gitCreateBranch(workspace: WorkspaceID, name: String) throws -> GitActionResult {
        GitDiff.createBranch(in: try workspaceCwd(workspace), name: name)
    }
    public func gitCommit(workspace: WorkspaceID, message: String) throws -> GitActionResult {
        GitDiff.commit(in: try workspaceCwd(workspace), message: message)
    }
    public func gitLog(workspace: WorkspaceID, limit: Int) throws -> [GitCommit] {
        GitDiff.log(in: try workspaceCwd(workspace), limit: limit)
    }
    public func gitDiff(workspace: WorkspaceID, path: String?, ignoreWhitespace: Bool) throws -> String {
        GitDiff.diff(in: try workspaceCwd(workspace), path: path, ignoreWhitespace: ignoreWhitespace)
    }
    public func gitPush(workspace: WorkspaceID) throws -> GitActionResult {
        GitDiff.push(in: try workspaceCwd(workspace))
    }
    public func gitPullRequestURL(workspace: WorkspaceID) throws -> String? {
        GitDiff.pullRequestURL(in: try workspaceCwd(workspace))
    }

    // MARK: project scripts / open-in-editor (RC2-069)

    public func projectScripts(workspace: WorkspaceID) throws -> [ProjectScript] {
        ProjectScripts.discover(in: try workspaceCwd(workspace))
    }

    public func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor {
        let cwd = try workspaceCwd(workspace)
        guard let script = ProjectScripts.discover(in: cwd).first(where: { $0.name == name }) else {
            throw JSONRPCError(code: -32602, message: "no such script: \(name)")
        }
        // Run it in a fresh terminal surface (t3code ProjectScriptsControl).
        let desc = try createSurface(workspace: workspace, type: .terminal, paneID: nil, title: "Run: \(name)")
        if let term = SurfaceRegistry.shared.surface(desc.id) {
            term.sendText(script.command + "\n")
        }
        return desc
    }

    public func projectOpenInEditor(workspace: WorkspaceID) throws -> String {
        ProjectScripts.openInEditor(cwd: try workspaceCwd(workspace))
    }

    private func browserSurface(_ id: SurfaceID) throws -> BrowserSurface {
        guard let s = SurfaceRegistry.shared.surface(id) as? BrowserSurface else { throw LayoutError.surfaceNotFound }
        return s
    }

    private func configureBrowserSurface(_ browser: BrowserSurface) -> BrowserSurface {
        browser.onNavigationChange = { [weak self] surfaceID, url, title in
            self?.persistBrowserNavigation(surfaceID: surfaceID, url: url, title: title)
            var payload: [String: JSONValue] = [
                "surface_id": .string(surfaceID.value.uuidString),
                "url": .string(url)
            ]
            if let title { payload["title"] = .string(title) }
            EventBus.shared.publish(kind: "surface.browser", payload: .object(payload))
        }
        return browser
    }

    private func restoredBrowserURL(from descriptor: SurfaceDescriptor) -> URL? {
        guard let raw = descriptor.metadata["url"], !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func persistBrowserNavigation(surfaceID: SurfaceID, url: String, title: String?) {
        guard let ctx = context else { return }
        for (wid, var ws) in ctx.state.workspaces {
            let result = updateSurface(in: ws.layout, surfaceID: surfaceID) { descriptor in
                descriptor.metadata["url"] = url
                if let title, !title.isEmpty {
                    descriptor.title = title
                }
            }
            guard result.changed else { continue }
            ws.layout = result.node
            ws.updatedAt = Date()
            ctx.state.workspaces[wid] = ws
            ctx.scheduleSnapshotSave()
            return
        }
    }

    private func updateSurface(in node: LayoutNode,
                               surfaceID: SurfaceID,
                               _ update: (inout SurfaceDescriptor) -> Void) -> (node: LayoutNode, changed: Bool) {
        switch node {
        case .pane(var pane):
            guard let index = pane.surfaces.firstIndex(where: { $0.id == surfaceID }) else {
                return (node, false)
            }
            update(&pane.surfaces[index])
            return (.pane(pane), true)
        case .split(var split):
            var changed = false
            split.children = split.children.map { child in
                guard !changed else { return child }
                let result = updateSurface(in: child, surfaceID: surfaceID, update)
                changed = result.changed
                return result.node
            }
            return (.split(split), changed)
        }
    }

    public func browserNavigate(surface: SurfaceID, url: String) throws {
        let b = try browserSurface(surface)
        if !b.navigate(string: url) { throw LayoutError.invalidLayout }
    }
    public func browserBack(surface: SurfaceID) throws { try browserSurface(surface).goBackAction() }
    public func browserForward(surface: SurfaceID) throws { try browserSurface(surface).goForwardAction() }
    public func browserReload(surface: SurfaceID) throws { try browserSurface(surface).reloadAction() }
    public func browserURL(surface: SurfaceID) throws -> String { try browserSurface(surface).currentURL() }
    public func browserMirrorURL(surface: SurfaceID) throws -> [String: JSONValue] {
        let raw = try browserSurface(surface).currentURL()
        var out: [String: JSONValue] = ["url": .string(raw), "is_file": .bool(false)]
        if let url = URL(string: raw), url.isFileURL,
           let grant = DirectStaticFileRegistry.shared.register(fileURL: url) {
            out["is_file"] = .bool(true)
            out["static_path"] = .string(grant.routePath)
        }
        return out
    }

    public func browserEval(surface: SurfaceID, script: String) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            s.evaluate(script) { result, error in
                if let error = error {
                    cont.resume(returning: "error: \(error.localizedDescription)")
                } else if let result = result {
                    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]),
                       let s = String(data: data, encoding: .utf8) {
                        cont.resume(returning: s)
                    } else {
                        cont.resume(returning: String(describing: result))
                    }
                } else {
                    cont.resume(returning: "")
                }
            }
        }
    }

    public func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String {
        let s = try browserSurface(surface)
        guard let png = s.screenshotPNG() else { throw LayoutError.invalidLayout }
        let path = savePath ?? (NSTemporaryDirectory() + "rc2-screenshot-\(UUID().uuidString).png")
        try png.write(to: URL(fileURLWithPath: path))
        return path
    }

    public func browserSnapshot(surface: SurfaceID) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { cont in
            s.snapshot { json in cont.resume(returning: json) }
        }
    }

    public func browserAction(surface: SurfaceID, kind: String, ref: String, value: String?) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { cont in
            s.performAction(kind, ref: ref, value: value) { json in cont.resume(returning: json) }
        }
    }

    public func paneList(workspace: WorkspaceID) throws -> [[String: JSONValue]] {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { return [] }
        let mobileGroups = mobilePaneGroups(in: ws.layout)
        var mobileGroupByPane: [PaneID: Int] = [:]
        for (index, group) in mobileGroups.enumerated() {
            for paneID in group { mobileGroupByPane[paneID] = index }
        }
        let panes: [[String: JSONValue]] = ws.layout.paneIDs().map { pid in
            let count = (ws.layout.find(paneID: pid)?.surfaces.count) ?? 0
            return [
                "kind": .string("pane"),
                "id": .string(pid.value.uuidString),
                "surface_count": .number(Double(count)),
                "mobile_group": .number(Double(mobileGroupByPane[pid] ?? 0))
            ]
        }
        let splits = splitEntries(in: ws.layout)
        return panes + splits
    }

    private func mobilePaneGroups(in node: LayoutNode) -> [[PaneID]] {
        let groups = uncappedMobilePaneGroups(in: node)
        guard groups.count > 2 else { return groups }
        return [groups[0], groups.dropFirst().flatMap { $0 }]
    }

    private func uncappedMobilePaneGroups(in node: LayoutNode) -> [[PaneID]] {
        switch node {
        case .pane(let pane):
            return [[pane.id]]
        case .split(let split):
            let childGroups = split.children.flatMap { uncappedMobilePaneGroups(in: $0) }
            switch split.orientation {
            case .horizontal:
                return [childGroups.flatMap { $0 }]
            case .vertical:
                return childGroups
            }
        }
    }

    private func splitEntries(in node: LayoutNode) -> [[String: JSONValue]] {
        switch node {
        case .pane:
            return []
        case .split(let split):
            var rows: [[String: JSONValue]] = [[
                "kind": .string("split"),
                "id": .string(split.id.uuidString),
                "orientation": .string(split.orientation.rawValue),
                "ratios": .array(split.ratios.map { .number($0) })
            ]]
            rows.append(contentsOf: split.children.flatMap { splitEntries(in: $0) })
            return rows
        }
    }

    public func paneSurfaces(pane: PaneID, workspace: WorkspaceID) throws -> [SurfaceDescriptor] {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { return [] }
        return ws.layout.find(paneID: pane)?.surfaces ?? []
    }

    public func paneResize(workspace: WorkspaceID, splitID: UUID, ratios: [Double]) throws {
        try context?.apply(.resizeSplit(workspace, splitID: splitID, ratios: ratios))
        windowController?.refreshFromState()
    }

    public func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws {
        try context?.apply(.moveSurfaceToPane(workspace, surface: surface, targetPane: targetPane))
        windowController?.refreshFromState()
    }

    public func surfaceReorder(workspace: WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int) throws {
        try context?.apply(.reorderSurface(workspace, surface: surface, toPane: toPane, position: position))
        windowController?.refreshFromState()
    }

    public func notificationCreate(workspaceId: WorkspaceID?, title: String, body: String?, category: String?) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let repo = NotificationRepository(db: ctx.db)
        let n = AppNotification(workspaceId: workspaceId, title: title, body: body, category: category)
        try repo.insert(n)
        // bump workspace unread + flash
        if let wid = workspaceId, var ws = ctx.state.workspaces[wid] {
            ws.notificationsUnread += 1
            ctx.state.workspaces[wid] = ws
            windowController?.refreshFromState()
        }
        // Mirror into macOS notification center.
        SystemNotifier.shared.post(title: title, body: body, category: category)
        return n.id
    }

    public func notificationList(workspaceId: WorkspaceID?, unreadOnly: Bool) throws -> [[String: JSONValue]] {
        guard let ctx = context else { return [] }
        let repo = NotificationRepository(db: ctx.db)
        let list = try repo.list(workspaceId: workspaceId, unreadOnly: unreadOnly)
        return list.map { n in
            var d: [String: JSONValue] = [
                "id": .string(n.id),
                "title": .string(n.title),
                "created_at": .string(ISO8601DateFormatter().string(from: n.createdAt))
            ]
            if let b = n.body { d["body"] = .string(b) }
            if let c = n.category { d["category"] = .string(c) }
            if let w = n.workspaceId { d["workspace_id"] = .string(w.value.uuidString) }
            if let s = n.surfaceId { d["surface_id"] = .string(s.value.uuidString) }
            if let r = n.readAt { d["read_at"] = .string(ISO8601DateFormatter().string(from: r)) }
            return d
        }
    }

    public func notificationMarkRead(id: String) throws {
        guard let ctx = context else { return }
        try NotificationRepository(db: ctx.db).markRead(id: id)
    }

    public func notificationDismiss(id: String) throws {
        guard let ctx = context else { return }
        try NotificationRepository(db: ctx.db).dismiss(id: id)
    }

    public func settingsGet(keys: [String]) throws -> [String: String] {
        guard let ctx = context else { return [:] }
        var values: [String: String] = [:]
        for key in keys {
            values[key] = (try? ctx.settingsRepo.get(key)) ?? ""
        }
        return values
    }

    public func settingsSet(key: String, value: String) throws {
        guard let ctx = context else { return }
        try ctx.settingsRepo.set(key, value)
    }

    public func browserWait(surface: SurfaceID, selector: String, timeoutMs: Int) async throws -> String {
        let s = try browserSurface(surface)
        return await withCheckedContinuation { cont in
            s.waitFor(selector, timeoutMs: timeoutMs) { json in cont.resume(returning: json) }
        }
    }

    private func makeSurface(type: SurfaceType, title: String?, workspace: WorkspaceID, cwd: String) -> SurfaceDescriptor {
        let baseTitle = title ?? defaultTitle(for: type)
        let descriptor = SurfaceDescriptor(type: type, title: baseTitle, iconName: type.rawValue, metadata: ["workspace": workspace.value.uuidString, "cwd": cwd])
        // build concrete surface object now and register
        do {
            let surface: Surface
            switch type {
            case .terminal:
                surface = try TerminalSurface(workspaceID: workspace, cwd: cwd, title: baseTitle)
            case .browser:
                surface = configureBrowserSurface(BrowserSurface(workspaceID: workspace, initialURL: nil, title: baseTitle))
            case .agentApp:
                guard let ctx = context else { return descriptor }
                let agent = AgentAppSurface(workspaceID: workspace, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, title: baseTitle)
                // Socket-driven thread mutations (create/rename/delete/read)
                // refresh this already-open surface — fixes the stale-VM gap.
                let token = EventBus.shared.subscribe(since: nil) { [weak agent] ev in
                    guard ev.kind.hasPrefix("agent.thread.") else { return }
                    DispatchQueue.main.async { agent?.viewModel.reloadThreads() }
                }
                agent.subscriptionToken = AnyHashable(token)
                agent.viewModel.onReviewRequested = { [weak self] in
                    _ = try? self?.createSurface(workspace: workspace, type: .rightSidebarTool, paneID: nil, title: "Git")
                }
                agent.viewModel.onRunStateChange = { [weak self] in
                    self?.windowController?.refreshFromState()
                }
                surface = agent
            case .markdown:
                let path = title // optional: pass file path via title for now
                surface = MarkdownSurface(workspaceID: workspace, filePath: path, title: baseTitle)
            case .filePreview:
                surface = FilePreviewSurface(workspaceID: workspace, filePath: title, title: baseTitle)
            case .rightSidebarTool:
                // Tool selection is encoded in the title for V1 — keeps
                // the JSON-RPC payload simple. Default is the diff panel.
                let tool = baseTitle.lowercased()
                if tool.contains("feed") {
                    let feed = FeedPanelSurface(workspaceID: workspace, title: baseTitle)
                    // Wire the in-process EventBus to the feed VM so any
                    // dispatcher mutation lights up the panel in real time.
                    let token = EventBus.shared.subscribe(since: 0) { ev in
                        let kind = ev.kind
                        let payload = JSONValue.object(ev.payload.objectValue ?? [:])
                        let summary = Self.summary(of: payload)
                        DispatchQueue.main.async {
                            feed.viewModel.receive(seq: ev.seq, kind: kind, title: summary, ts: ev.ts)
                        }
                    }
                    feed.subscriptionToken = AnyHashable(token)
                    surface = feed
                } else {
                    surface = DiffPanelSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, settings: context.map { SettingsStore(db: $0.db) })
                }
            }
            let finalDescriptor = SurfaceDescriptor(id: surface.descriptor.id, type: type, title: baseTitle, iconName: surface.descriptor.iconName, metadata: surface.descriptor.metadata)
            SurfaceRegistry.shared.register(surface)
            return finalDescriptor
        } catch {
            return descriptor
        }
    }

    private func defaultTitle(for type: SurfaceType) -> String {
        type.displayLabel.lowercased() == "agent app" ? "Agent App" : type.displayLabel.lowercased()
    }

    static func summary(of payload: JSONValue) -> String {
        if case .object(let o) = payload {
            if let s = o["title"]?.stringValue { return s }
            if let s = o["name"]?.stringValue { return s }
            if let s = o["id"]?.stringValue { return s }
        }
        return ""
    }
}
