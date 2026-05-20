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
                    case .ssh:
                        if let profile = sshProfile(from: desc) {
                            surface = try TerminalSurface(workspaceID: wid, title: title, launch: .ssh(profile: profile, cwd: cwd))
                        } else {
                            surface = try SSHSurface(workspaceID: wid, cwd: cwd, title: title, router: self)
                        }
                    case .browser:
                        surface = configureBrowserSurface(BrowserSurface(workspaceID: wid, initialURL: restoredBrowserURL(from: desc), title: title))
                    case .agentApp:
                        let agent = AgentAppSurface(workspaceID: wid, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, promptHistoryStore: PromptHistoryStore(db: ctx.db), title: title)
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
                        agent.viewModel.onRunCompleted = { [weak self] in
                            self?.promoteWorkspaceAfterCompletedRun(wid)
                        }
                        surface = agent
                    case .files:
                        surface = FilesSurface(workspaceID: wid, cwd: cwd, title: title, router: self, initialState: desc.metadata["files_state"])
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

    public func splitSurface(workspace: WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection) throws {
        try context?.apply(.splitSurface(workspace, paneID: paneID, surface: surface, direction: direction))
        windowController?.refreshFromState()
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
        if let s = SurfaceRegistry.shared.surface(surface), s.descriptor.type == .terminal || s.descriptor.type == .ssh {
            s.sendText("\u{0C}") // ctrl-L
        }
    }

    public func sshHostList() throws -> [SSHHostProfile] {
        guard let ctx = context else { return [] }
        return try readSSHHosts(from: ctx.settingsRepo)
    }

    public func sshHostUpsert(_ profile: SSHHostProfile) throws -> SSHHostProfile {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        var hosts = try readSSHHosts(from: ctx.settingsRepo)
        var saved = profile
        saved.updatedAt = Date()
        if let index = hosts.firstIndex(where: { $0.id == saved.id }) {
            saved.createdAt = hosts[index].createdAt
            hosts[index] = saved
        } else {
            hosts.append(saved)
        }
        try writeSSHHosts(hosts, to: ctx.settingsRepo)
        return saved
    }

    public func sshHostDelete(_ id: SSHHostID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        var hosts = try readSSHHosts(from: ctx.settingsRepo)
        hosts.removeAll { $0.id == id }
        try writeSSHHosts(hosts, to: ctx.settingsRepo)
    }

    public func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let hosts = try readSSHHosts(from: ctx.settingsRepo)
        let resolved: SSHHostProfile
        if let profileID, let found = hosts.first(where: { $0.id == profileID }) {
            resolved = found
        } else if let profile {
            resolved = try sshHostUpsert(profile)
        } else {
            throw LayoutError.surfaceNotFound
        }
        let desc = try makeSSHSurface(profile: resolved, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.addSurface(workspace, paneID: paneID, descriptor: desc))
        windowController?.refreshFromState()
        return desc
    }

    public func sshDisconnect(surface: SurfaceID) throws {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        s.close()
    }

    public func sshTransferUpload(surface: SurfaceID, localPath: String, remotePath: String) throws -> JSONValue {
        try runSSHTransfer(surface: surface, upload: true, localPath: localPath, remotePath: remotePath)
    }

    public func sshTransferDownload(surface: SurfaceID, remotePath: String, localPath: String) throws -> JSONValue {
        try runSSHTransfer(surface: surface, upload: false, localPath: localPath, remotePath: remotePath)
    }

    public func sshFilesLocalList(path: String?) throws -> JSONValue {
        try makeLocalSSHFileListing(path: path)
    }

    public func sshFilesRemoteList(surface: SurfaceID, path: String?) throws -> JSONValue {
        let profile = try sshTransferProfile(for: surface)
        let requested = (path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? path! : "."
        let script = """
        p=\(shellQuote(requested))
        [ -z "$p" ] && p=.
        cd "$p" 2>/dev/null || exit 2
        pwd
        for f in .. .* *; do
          [ "$f" = "." ] && continue
          [ -e "$f" ] || continue
          if [ -d "$f" ]; then
            kind=directory
            type="File folder"
            size=""
          else
            kind=file
            ext="${f##*.}"
            [ "$ext" = "$f" ] && type="File" || type="$ext file"
            size=$(wc -c < "$f" 2>/dev/null | tr -d ' ')
          fi
          mod=$(date -r "$f" "+%Y-%m-%d %H:%M" 2>/dev/null || stat -c %y "$f" 2>/dev/null | cut -c1-16)
          printf '%s\t%s\t%s\t%s\n' "$f" "$kind" "$size" "$mod"
        done
        """
        let args = SSHCommandBuilder.sshArguments(for: profile) + ["sh", "-lc", script]
        let result = try runCommand(executable: "/usr/bin/ssh", arguments: args, password: profile.password)
        guard result.exitCode == 0 else {
            throw JSONRPCError(code: -32020, message: "remote list failed", data: .string(result.output))
        }
        return makeRemoteSSHFileListing(output: result.output, requestedPath: requested)
    }

    public func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        try createSurface(workspace: workspace, type: .agentApp, paneID: nil, title: "Agent App")
    }

    public func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] {
        guard let ctx = context else { return [] }
        return try ctx.threadRepo.list(workspaceId: workspace)
    }

    public func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let t = AgentThread(workspaceId: workspace, title: title, provider: provider, model: model,
                            permissionMode: permissionMode, reasoningEffort: reasoningEffort)
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
        if let permissionMode {
            t.permissionMode = permissionMode
        }
        if let reasoningEffort {
            t.reasoningEffort = reasoningEffort
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
        if AgentThreadTitle.isPlaceholder(t.title),
           ((try? ctx.messageRepo.listRecent(threadId: thread, limit: 1)) ?? []).isEmpty {
            t.title = AgentThreadTitle.titleFromFirstMessage(text)
            t.updatedAt = Date()
            try ctx.threadRepo.upsert(t)
            EventBus.shared.publish(kind: "agent.thread.renamed", payload: .object([
                "thread_id": .string(t.id.value.uuidString),
                "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                "title": .string(t.title),
                "display_title": .string(AgentThreadTitle.display(t.title)),
                "displayTitle": .string(AgentThreadTitle.display(t.title)),
                "provider_locked": .bool(true),
                "providerLocked": .bool(true)
            ]))
        }
        let prov = t.provider
        let m = t.model
        let cwd = ctx.state.workspaces.first { $0.value.id == t.workspaceId }?.value.cwd ?? FileManager.default.currentDirectoryPath
        let req = AgentRunRequest(
            threadId: thread,
            provider: prov,
            model: m,
            cwd: cwd,
            prompt: text,
            providerThreadId: t.providerThreadId,
            permissionMode: t.permissionMode,
            reasoningEffort: t.reasoningEffort
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

    public func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard var t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        t.color = color.isEmpty ? nil : color
        t.updatedAt = Date()
        try ctx.threadRepo.upsert(t)
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

    public func openWorkspaceInNewWindow(_ workspace: WorkspaceID) {
        windowController?.openWorkspaceInNewWindow(workspace)
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
            d["push_policy"] = .string("background_only")
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

    public func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue {
        try WorkspaceFileService().list(root: try workspaceCwd(workspace), path: path)
    }

    public func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue {
        try WorkspaceFileService().read(root: try workspaceCwd(workspace), path: path, maxBytes: maxBytes)
    }

    public func fsWorkspacePreviewURL(workspace: WorkspaceID, path: String) throws -> JSONValue {
        try WorkspaceFileService().previewURL(root: try workspaceCwd(workspace), path: path)
    }

    public func filesStateGet(surface: SurfaceID) throws -> JSONValue {
        let located = try locateSurface(surface)
        let root = try workspaceCwd(located.workspaceID)
        let state = decodeFilesState(located.descriptor.metadata["files_state"])
            ?? defaultFilesState(surface: surface, workspace: located.workspaceID, root: root, descriptor: located.descriptor)
        return .object(state)
    }

    public func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
        let located = try locateSurface(surface)
        let root = try workspaceCwd(located.workspaceID)
        var state = decodeFilesState(located.descriptor.metadata["files_state"])
            ?? defaultFilesState(surface: surface, workspace: located.workspaceID, root: root, descriptor: located.descriptor)
        let currentRevision = state["revision"]?.intValue ?? 0
        if let baseRevision, baseRevision != currentRevision {
            throw JSONRPCError(code: -32012, message: "files state revision conflict", data: .object(state))
        }
        for (key, value) in patch { state[key] = value }
        let revision = currentRevision + 1
        state["revision"] = .number(Double(revision))
        state["updated_at"] = .number(Date().timeIntervalSince1970)
        state["updated_by_device"] = deviceID.map { .string($0) } ?? .null
        try persistFilesState(surface: surface, workspace: located.workspaceID, state: state)
        EventBus.shared.publish(kind: "files.state.updated", payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "workspace_id": .string(located.workspaceID.value.uuidString),
            "state": .object(state),
            "revision": .number(Double(revision)),
            "updated_by_device": deviceID.map { .string($0) } ?? .null
        ]))
        return .object(state)
    }

    public func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
        let located = try locateSurface(surface)
        let root = try workspaceCwd(located.workspaceID)
        let opened = try FileEditSessionStore.shared.open(surfaceID: surface, workspaceID: located.workspaceID, root: root, path: path)
        if let sessionID = opened.objectValue?["session_id"]?.stringValue {
            let _ = try filesStateUpdate(surface: surface, patch: [
                "selected_path": .string(path),
                "edit_session_id": .string(sessionID)
            ], baseRevision: nil, deviceID: "mac-host")
        }
        return opened
    }

    public func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
        let result = try FileEditSessionStore.shared.applyPatch(sessionID: sessionID, baseDraftRevision: baseDraftRevision, rangeLocation: rangeLocation, rangeLength: rangeLength, replacement: replacement, deviceID: deviceID)
        if let body = result.objectValue,
           let sid = body["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
           let path = body["path"]?.stringValue {
            try updateFilesDirty(surface: sid, path: path, dirty: true)
        }
        return result
    }

    public func filesEditSave(sessionID: String) throws -> JSONValue {
        let result = try FileEditSessionStore.shared.save(sessionID: sessionID)
        if let body = result.objectValue,
           let sid = body["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
           let path = body["path"]?.stringValue {
            try updateFilesDirty(surface: sid, path: path, dirty: false)
        }
        return result
    }

    public func filesEditDiscard(sessionID: String) throws -> JSONValue {
        let result = try FileEditSessionStore.shared.discard(sessionID: sessionID)
        if let body = result.objectValue,
           let sid = body["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
           let path = body["path"]?.stringValue {
            try updateFilesDirty(surface: sid, path: path, dirty: false)
        }
        return result
    }

    public func filesEditClose(sessionID: String) throws -> JSONValue {
        try FileEditSessionStore.shared.close(sessionID: sessionID)
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
            case .ssh:
                surface = try SSHSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, router: self)
            case .browser:
                surface = configureBrowserSurface(BrowserSurface(workspaceID: workspace, initialURL: nil, title: baseTitle))
            case .agentApp:
                guard let ctx = context else { return descriptor }
                let agent = AgentAppSurface(workspaceID: workspace, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, promptHistoryStore: PromptHistoryStore(db: ctx.db), title: baseTitle)
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
                agent.viewModel.onRunCompleted = { [weak self] in
                    self?.promoteWorkspaceAfterCompletedRun(workspace)
                }
                surface = agent
            case .files:
                surface = FilesSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, router: self, initialState: nil)
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

    private func makeSSHSurface(profile: SSHHostProfile, title: String?, workspace: WorkspaceID, cwd: String) throws -> SurfaceDescriptor {
        let baseTitle = title ?? profile.label
        let surface = try SSHSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, router: self)
        surface.connectForRouter(profile)
        SurfaceRegistry.shared.register(surface)
        return surface.descriptor
    }

    private func readSSHHosts(from repo: SettingsRepository) throws -> [SSHHostProfile] {
        guard let raw = try repo.get("ssh.hosts"),
              let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SSHHostProfile].self, from: data)) ?? []
    }

    private func writeSSHHosts(_ hosts: [SSHHostProfile], to repo: SettingsRepository) throws {
        let data = try JSONEncoder().encode(hosts)
        try repo.set("ssh.hosts", String(data: data, encoding: .utf8) ?? "[]")
    }

    private func runSSHTransfer(surface: SurfaceID, upload: Bool, localPath: String, remotePath: String) throws -> JSONValue {
        let (profile, appendOutput) = try sshTransferProfileAndOutput(for: surface)
        let args = upload
            ? SSHCommandBuilder.scpUploadArguments(profile: profile, localPath: localPath, remotePath: remotePath)
            : SSHCommandBuilder.scpDownloadArguments(profile: profile, remotePath: remotePath, localPath: localPath)
        let kind = upload ? "upload" : "download"
        EventBus.shared.publish(kind: "ssh.transfer.started", payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "direction": .string(kind),
            "local_path": .string(localPath),
            "remote_path": .string(remotePath)
        ]))
        appendOutput("\n[ssh \(kind) started]\n")
        let result = try runCommand(executable: "/usr/bin/scp", arguments: args, password: profile.password)
        if !result.output.isEmpty { appendOutput(result.output) }
        let ok = result.exitCode == 0
        appendOutput("[ssh \(kind) \(ok ? "completed" : "failed")]\n")
        EventBus.shared.publish(kind: ok ? "ssh.transfer.completed" : "ssh.transfer.failed", payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "direction": .string(kind),
            "local_path": .string(localPath),
            "remote_path": .string(remotePath),
            "exit_code": .number(Double(result.exitCode))
        ]))
        return .object([
            "ok": .bool(ok),
            "exit_code": .number(Double(result.exitCode)),
            "output": .string(result.output)
        ])
    }

    private func sshTransferProfile(for surface: SurfaceID) throws -> SSHHostProfile {
        try sshTransferProfileAndOutput(for: surface).profile
    }

    private func sshTransferProfileAndOutput(for surface: SurfaceID) throws -> (profile: SSHHostProfile, appendOutput: (String) -> Void) {
        guard let surfaceObject = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        let appendOutput: (String) -> Void
        if let terminal = surfaceObject as? TerminalSurface {
            guard let terminalProfile = sshProfile(from: terminal.descriptor) else { throw LayoutError.surfaceNotFound }
            return (terminalProfile, { terminal.appendSystemText($0) })
        } else if let sshSurface = surfaceObject as? SSHTransferSurface, let transferProfile = sshSurface.sshTransferProfile {
            appendOutput = { sshSurface.appendSystemText($0) }
            return (transferProfile, appendOutput)
        } else {
            throw LayoutError.surfaceNotFound
        }
    }

    private func runCommand(executable: String, arguments: [String], password: String?) throws -> (exitCode: Int32, output: String) {
        let process = Process()
        var expectScriptURL: URL?
        if let password, !password.isEmpty, FileManager.default.fileExists(atPath: "/usr/bin/expect") {
            let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("remotecode-ssh-expect-\(UUID().uuidString).tcl")
            try """
            set timeout -1
            set password $env(RC_SSH_PASSWORD)
            spawn {*}$argv
            expect {
              -re {(?i)(password|passphrase).*:} { send -- "$password\\r"; exp_continue }
              eof
            }
            catch wait result
            exit [lindex $result 3]
            """.write(to: scriptURL, atomically: true, encoding: .utf8)
            expectScriptURL = scriptURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
            process.arguments = [scriptURL.path, executable] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["RC_SSH_PASSWORD"] = password
            process.environment = environment
        } else {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if let expectScriptURL { try? FileManager.default.removeItem(at: expectScriptURL) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private func makeLocalSSHFileListing(path rawPath: String?) throws -> JSONValue {
        let fm = FileManager.default
        let fallback = context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory()
        let input = (rawPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? rawPath! : fallback
        let path = ((input as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "not a directory", data: .string(path))
        }
        let urls = try fm.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey], options: [.skipsPackageDescendants])
        var entries: [JSONValue] = []
        if let parent = makeParentEntry(for: path) { entries.append(parent) }
        let children = urls.map { url -> JSONValue in
            makeLocalEntry(url)
        }.sorted(by: sortSSHEntries)
        return .object([
            "path": .string(path),
            "parent_path": path == "/" ? .null : .string((path as NSString).deletingLastPathComponent),
            "entries": .array(entries + children)
        ])
    }

    private func makeParentEntry(for path: String) -> JSONValue? {
        guard path != "/" else { return nil }
        return .object([
            "name": .string(".."),
            "path": .string((path as NSString).deletingLastPathComponent),
            "kind": .string("directory"),
            "size": .string(""),
            "file_type": .string("File folder"),
            "modified": .string("")
        ])
    }

    private func makeLocalEntry(_ url: URL) -> JSONValue {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let isDirectory = values?.isDirectory == true
        let size = isDirectory ? "" : "\(values?.fileSize ?? 0)"
        let modified = values?.contentModificationDate.map(Self.shortDateFormatter.string(from:)) ?? ""
        let type = isDirectory ? "File folder" : fileType(for: url.lastPathComponent)
        return .object([
            "name": .string(url.lastPathComponent),
            "path": .string(url.path),
            "kind": .string(isDirectory ? "directory" : "file"),
            "size": .string(size),
            "file_type": .string(type),
            "modified": .string(modified)
        ])
    }

    private func makeRemoteSSHFileListing(output: String, requestedPath: String) -> JSONValue {
        var lines = output
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        while let first = lines.first, !first.hasPrefix("/") {
            lines.removeFirst()
        }
        let path = lines.isEmpty ? requestedPath : lines.removeFirst()
        let entries = lines.compactMap { line -> JSONValue? in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4 else { return nil }
            let name = parts[0]
            let kind = parts[1]
            let child = name == ".." ? ((path as NSString).deletingLastPathComponent.isEmpty ? "/" : (path as NSString).deletingLastPathComponent)
                : (path as NSString).appendingPathComponent(name)
            return .object([
                "name": .string(name),
                "path": .string(child),
                "kind": .string(kind),
                "size": .string(parts[2]),
                "file_type": .string(kind == "directory" ? "File folder" : fileType(for: name)),
                "modified": .string(parts[3])
            ])
        }.sorted(by: sortSSHEntries)
        return .object([
            "path": .string(path),
            "parent_path": path == "/" ? .null : .string((path as NSString).deletingLastPathComponent),
            "entries": .array(entries)
        ])
    }

    private func sortSSHEntries(_ lhs: JSONValue, _ rhs: JSONValue) -> Bool {
        let lo = lhs.objectValue ?? [:]
        let ro = rhs.objectValue ?? [:]
        let ln = lo["name"]?.stringValue ?? ""
        let rn = ro["name"]?.stringValue ?? ""
        if ln == ".." { return true }
        if rn == ".." { return false }
        let ld = lo["kind"]?.stringValue == "directory"
        let rd = ro["kind"]?.stringValue == "directory"
        if ld != rd { return ld && !rd }
        return ln.localizedCaseInsensitiveCompare(rn) == .orderedAscending
    }

    private func fileType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : "\(ext.uppercased()) File"
    }

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func sshProfile(from desc: SurfaceDescriptor) -> SSHHostProfile? {
        guard let destination = desc.metadata["ssh_destination"] else { return nil }
        let id = desc.metadata["ssh_profile_id"].flatMap(UUID.init).map(SSHHostID.init) ?? SSHHostID()
        let port = desc.metadata["ssh_port"].flatMap(Int.init)
        let options = desc.metadata["ssh_options"]?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        return SSHHostProfile(id: id, label: desc.metadata["ssh_label"] ?? desc.title, destination: destination, port: port, identityFile: desc.metadata["ssh_identity_file"], options: options)
    }

    static func summary(of payload: JSONValue) -> String {
        if case .object(let o) = payload {
            if let s = o["title"]?.stringValue { return s }
            if let s = o["name"]?.stringValue { return s }
            if let s = o["id"]?.stringValue { return s }
        }
        return ""
    }

    private func locateSurface(_ surfaceID: SurfaceID) throws -> (workspaceID: WorkspaceID, descriptor: SurfaceDescriptor) {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        for (wid, ws) in ctx.state.workspaces {
            if let descriptor = findSurface(surfaceID, in: ws.layout) {
                return (wid, descriptor)
            }
        }
        if let surface = SurfaceRegistry.shared.surface(surfaceID),
           let raw = surface.descriptor.metadata["workspace"],
           let uuid = UUID(uuidString: raw) {
            return (WorkspaceID(uuid), surface.descriptor)
        }
        throw LayoutError.surfaceNotFound
    }

    private func findSurface(_ surfaceID: SurfaceID, in node: LayoutNode) -> SurfaceDescriptor? {
        switch node {
        case .pane(let pane):
            return pane.surfaces.first { $0.id == surfaceID }
        case .split(let split):
            for child in split.children {
                if let found = findSurface(surfaceID, in: child) { return found }
            }
            return nil
        }
    }

    private func defaultFilesState(surface: SurfaceID, workspace: WorkspaceID, root: String, descriptor: SurfaceDescriptor) -> [String: JSONValue] {
        let selected = descriptor.metadata["selected_path"] ?? descriptor.metadata["selected_relative_path"]
        return [
            "surface_id": .string(surface.value.uuidString),
            "workspace_id": .string(workspace.value.uuidString),
            "root": .string(root),
            "current_directory": .string(""),
            "expanded_dirs": .array([]),
            "selected_path": selected.map { .string($0) } ?? .null,
            "search_query": .string(""),
            "show_hidden": .bool(true),
            "sort_key": .string("name"),
            "sort_direction": .string("asc"),
            "reader_mode": .string("source"),
            "word_wrap": .bool(true),
            "preview_zoom": .number(1),
            "edit_session_id": descriptor.metadata["active_edit_session_id"].map { .string($0) } ?? .null,
            "dirty_paths": .array([]),
            "revision": .number(Double(descriptor.metadata["files_state_revision"].flatMap(Int.init) ?? 0)),
            "updated_at": .number(Date().timeIntervalSince1970),
            "updated_by_device": .null
        ]
    }

    private func decodeFilesState(_ raw: String?) -> [String: JSONValue]? {
        guard let raw, let data = raw.data(using: .utf8),
              case .object(let state) = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        return state
    }

    private func encodeFilesState(_ state: [String: JSONValue]) -> String? {
        guard let data = try? JSONEncoder().encode(JSONValue.object(state)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func persistFilesState(surface: SurfaceID, workspace: WorkspaceID, state: [String: JSONValue], refreshWindow: Bool = true) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        var ws = try ctx.state.workspaces[workspace].orThrow(LayoutError.workspaceNotFound)
        let encoded = encodeFilesState(state)
        let result = updateSurface(in: ws.layout, surfaceID: surface) { descriptor in
            if let encoded { descriptor.metadata["files_state"] = encoded }
            descriptor.metadata["files_state_revision"] = "\(state["revision"]?.intValue ?? 0)"
            if let selected = state["selected_path"]?.stringValue {
                descriptor.metadata["selected_path"] = selected
                descriptor.metadata["selected_relative_path"] = selected
            }
            if let session = state["edit_session_id"]?.stringValue {
                descriptor.metadata["active_edit_session_id"] = session
            }
            if case .array(let dirty) = state["dirty_paths"] ?? .array([]) {
                descriptor.metadata["dirty_count"] = "\(dirty.count)"
                descriptor.isDirty = !dirty.isEmpty
            }
        }
        ws.layout = result.node
        ws.updatedAt = Date()
        ctx.state.workspaces[workspace] = ws
        ctx.scheduleSnapshotSave()
        if refreshWindow {
            windowController?.refreshFromState()
        }
    }

    private func updateFilesDirty(surface: SurfaceID, path: String, dirty: Bool) throws {
        let located = try locateSurface(surface)
        var state = try filesStateGet(surface: surface).objectValue ?? [:]
        var dirtyPaths: [String] = []
        if case .array(let values) = state["dirty_paths"] ?? .array([]) {
            dirtyPaths = values.compactMap(\.stringValue)
        }
        if dirty {
            if !dirtyPaths.contains(path) { dirtyPaths.append(path) }
        } else {
            dirtyPaths.removeAll { $0 == path }
        }
        state["dirty_paths"] = .array(dirtyPaths.map { .string($0) })
        state["revision"] = .number(Double((state["revision"]?.intValue ?? 0) + 1))
        state["updated_at"] = .number(Date().timeIntervalSince1970)
        try persistFilesState(surface: surface, workspace: located.workspaceID, state: state, refreshWindow: false)
        EventBus.shared.publish(kind: "files.state.updated", payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "workspace_id": .string(located.workspaceID.value.uuidString),
            "state": .object(state),
            "revision": state["revision"] ?? .number(0),
            "updated_by_device": .string("mac-host")
        ]))
    }

    public func promoteWorkspaceAfterCompletedRun(_ id: WorkspaceID) {
        guard let ctx = context else { return }
        let before = ctx.state.window.workspaces
        try? ctx.apply(.promoteWorkspace(id))
        let order = ctx.state.window.workspaces
        guard order != before else { return }
        EventBus.shared.publish(kind: "workspace.reordered", payload: .object([
            "workspace_id": .string(id.value.uuidString),
            "order": .array(order.map { .string($0.value.uuidString) })
        ]))
        windowController?.refreshFromState()
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}
