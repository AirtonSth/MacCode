import Foundation
import AppKit
import Security
import os
import CoreModel
import Persistence
import AgentRuntime
import SocketServer
import Surfaces

private let appRouterLog = Logger(subsystem: "io.remotecode.appshell", category: "router")

private struct AgentProviderInstanceConfig: Decodable, Equatable {
    var id: String
    var provider: AgentProvider
    var displayName: String?
    var binaryPath: String?
    var homePath: String?
    var accentColor: String?
    var enabled: Bool?
    var env: [String: String]?
}

private struct ProviderProbeCacheKey: Hashable {
    var provider: AgentProvider
    var binaryPath: String
    var environment: [String]

    init(provider: AgentProvider, binaryPath: String, environment: [String: String]) {
        self.provider = provider
        self.binaryPath = binaryPath
        self.environment = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }
}

private struct ProviderProbeCapabilities {
    var version: String?
    var authenticated: Bool?
    var accountLabel: String?
    var accountAuthMethod: String?
    var updateState: String?
    var advisory: String?
    var slashCommands: [String]
    var skills: [String]
    var capturedAt: Date
}

/// Bridges the JSON-RPC dispatcher to the in-process domain state plus the
/// concrete Surface views. Lives on the main actor because it mutates UI.
@MainActor
public final class AppCommandRouter: CommandRouting, TerminalCommandRouting, LayoutEventSuppressionRouting {
    typealias SSHCommandRunner = @Sendable (String, [String], String?) throws -> (exitCode: Int32, output: String)

    private static let minimizedPaneVisibilityThreshold = 0.08

    public weak var context: AppContext?
    public weak var windowController: MainWindowController?
    var destinationWindowIsKeyForTests: ((NSWindow) -> Bool)?
    private let sshPasswordStore: SSHPasswordStoring
    private let sshCommandRunner: SSHCommandRunner
    private var providerProbeCache: [ProviderProbeCacheKey: ProviderProbeCapabilities] = [:]
    private var providerUpdateLocks = Set<ProviderProbeCacheKey>()
    private let providerProbeCacheTTL: TimeInterval = 30
    private var suppressedLayoutEventDepth = 0
    private var closedTabBuffer = ClosedTabRingBuffer(capacity: 10)
    /// Descriptors that failed to reinstantiate during session restore.
    /// Populated by `reinstantiateRestoredSurfaces`; readable by tests and diagnostics.
    public private(set) var restoreFailedSurfaceIDs: [SurfaceID] = []

    public convenience init(context: AppContext) {
        self.init(context: context, sshPasswordStore: KeychainSSHPasswordStore())
    }

    init(
        context: AppContext,
        sshPasswordStore: SSHPasswordStoring,
        sshCommandRunner: @escaping SSHCommandRunner = { executable, arguments, password in
            try AppCommandRouter.runCommandBlocking(executable: executable, arguments: arguments, password: password)
        }
    ) {
        self.context = context
        self.sshPasswordStore = sshPasswordStore
        self.sshCommandRunner = sshCommandRunner
    }

    private func publishAgentThreadUpdated(_ thread: AgentThread) {
        EventBus.shared.publish(kind: "agent.thread.updated", payload: agentThreadPayload(thread))
    }

    private func publishAgentPlanNotesUpdated(thread: AgentThreadID, notes: String) {
        EventBus.shared.publish(kind: "agent.plan.notes.updated", payload: .object([
            "thread_id": .string(thread.value.uuidString),
            "notes": .string(notes)
        ]))
    }

    private func publishAgentThreadRead(_ threadID: AgentThreadID) {
        EventBus.shared.publish(kind: "agent.thread.read", payload: .object([
            "thread_id": .string(threadID.value.uuidString)
        ]))
    }

    /// Full thread payload for host-UI-driven thread mirror events. Shape is
    /// IDENTICAL to Dispatcher.threadPayload so iOS decodes RPC-driven and
    /// mac-UI-driven mutations with one code path. provider_locked derives
    /// best-effort from the message repo (false on error).
    private func agentThreadPayload(_ thread: AgentThread) -> JSONValue {
        let locked = !((try? listAgentMessages(thread: thread.id, limit: 1)) ?? []).isEmpty
        var payload: [String: JSONValue] = [
            "thread_id": .string(thread.id.value.uuidString),
            "workspace_id": thread.workspaceId.map { .string($0.value.uuidString) } ?? .null,
            "title": .string(thread.title),
            "display_title": .string(AgentThreadTitle.display(thread.title)),
            "displayTitle": .string(AgentThreadTitle.display(thread.title)),
            "provider": .string(thread.provider.rawValue),
            "provider_instance_id": thread.providerInstanceId.map { .string($0) } ?? .null,
            "providerInstanceId": thread.providerInstanceId.map { .string($0) } ?? .null,
            "model": .string(thread.model),
            "provider_locked": .bool(locked),
            "providerLocked": .bool(locked),
            "permission_mode": .string(thread.permissionMode.rawValue),
            "reasoning_effort": .string(thread.reasoningEffort.rawValue),
            "service_tier": .string(thread.serviceTier.rawValue),
            "model_selection": jsonValue(thread.modelSelection),
            "execution_mode": .string(thread.executionMode.rawValue)
        ]
        payload["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        payload["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        payload["color"] = thread.color.map { .string($0) } ?? .null
        payload["pinned"] = .bool(thread.pinned)
        payload["sort_order"] = .number(Double(thread.sortOrder))
        return .object(payload)
    }

    /// Mirrors macOS-UI thread lifecycle mutations (AgentAppViewModel
    /// onThreadLifecycle) onto the EventBus with the same event kinds the
    /// RPC paths publish, so connected mirrors stay live for mac-side CRUD.
    private func publishAgentThreadLifecycle(_ event: AgentThreadLifecycleEvent) {
        switch event {
        case .created(let thread):
            EventBus.shared.publish(kind: "agent.thread.created", payload: agentThreadPayload(thread))
        case .updated(let thread):
            EventBus.shared.publish(kind: "agent.thread.updated", payload: agentThreadPayload(thread))
        case .reordered(let workspaceId, let order):
            EventBus.shared.publish(kind: "agent.thread.reordered", payload: .object([
                "workspace_id": .string(workspaceId.value.uuidString),
                "order": .array(order.map { .string($0.value.uuidString) })
            ]))
        case .deleted(let ids):
            if ids.count > 1 {
                EventBus.shared.publish(kind: "agent.thread.deleted_many", payload: .object([
                    "thread_ids": .array(ids.map { .string($0.value.uuidString) })
                ]))
            } else if let id = ids.first {
                EventBus.shared.publish(kind: "agent.thread.deleted", payload: .object([
                    "thread_id": .string(id.value.uuidString)
                ]))
            }
        }
    }

    private func publishQueuedMessage(kind: String, _ message: AgentQueuedMessage) {
        var payload: [String: JSONValue] = [
            "id": .string(message.id.value.uuidString),
            "queued_message_id": .string(message.id.value.uuidString),
            "thread_id": .string(message.threadId.value.uuidString),
            "text": .string(message.text),
            "attachments": jsonValue(message.attachments),
            "interaction_mode": .string(message.interactionMode.rawValue),
            "position": .number(Double(message.position)),
            "created_at": .string(ISO8601DateFormatter().string(from: message.createdAt)),
            "updated_at": .string(ISO8601DateFormatter().string(from: message.updatedAt))
        ]
        if let thread = try? context?.threadRepo.get(id: message.threadId),
           let workspaceId = thread.workspaceId {
            payload["workspace_id"] = .string(workspaceId.value.uuidString)
        }
        EventBus.shared.publish(kind: kind, payload: .object(payload))
    }

    private func jsonValue<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return .null }
        return json
    }

    public func withSuppressedLayoutEvents<T>(_ body: () throws -> T) rethrows -> T {
        suppressedLayoutEventDepth += 1
        defer { suppressedLayoutEventDepth -= 1 }
        return try body()
    }

    private var shouldPublishLayoutEvents: Bool {
        suppressedLayoutEventDepth == 0
    }

    private func refreshAgentSurfaces(thread: AgentThreadID, workspace: WorkspaceID? = nil, select: Bool = false) {
        let resolvedWorkspace: WorkspaceID?
        if let workspace {
            resolvedWorkspace = workspace
        } else if let thread = try? context?.threadRepo.get(id: thread) {
            resolvedWorkspace = thread.workspaceId
        } else {
            resolvedWorkspace = nil
        }
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface,
                  resolvedWorkspace == nil || agent.viewModel.workspaceID == resolvedWorkspace! else { continue }
            agent.viewModel.reloadThreads()
            agent.viewModel.reloadQueuedMessages()
            if select { agent.viewModel.selectThread(thread) }
        }
        windowController?.refreshFromState()
    }

    /// Walk the restored layout state and instantiate fresh Surface
    /// views for every descriptor. Surfaces are rebuilt with new IDs
    /// (their old IDs were owned by surfaces that no longer exist), so
    /// we rewrite the layout state to refer to the new IDs and update
    /// selectedSurfaceID per pane.
    public func reinstantiateRestoredSurfaces() {
        guard let ctx = context else { return }
        let terminalFontSize = SettingsStore(db: ctx.db).load().terminalFontSize
        var idMap: [SurfaceID: SurfaceID] = [:]
        for (wid, ws) in ctx.state.workspaces {
            forEachSurface(in: ws.layout) { desc in
                let cwd = ws.cwd
                let title = desc.title
                do {
                    let surface: Surface
                    switch desc.type {
                    case .terminal:
                        surface = try TerminalSurface(workspaceID: wid, title: title, launch: .shell(cwd: cwd), restoredSurfaceID: desc.id, historyRepo: ctx.terminalOutputRepo, settingsRepo: ctx.settingsRepo, terminalFontSize: terminalFontSize)
                    case .ssh:
                        if let profile = sshProfile(from: desc) {
                            surface = try TerminalSurface(workspaceID: wid, title: title, launch: .ssh(profile: profile, cwd: cwd), restoredSurfaceID: desc.id, historyRepo: ctx.terminalOutputRepo, settingsRepo: ctx.settingsRepo, terminalFontSize: terminalFontSize)
                        } else {
                            surface = try SSHSurface(workspaceID: wid, cwd: cwd, title: title, router: self, settingsRepo: ctx.settingsRepo, terminalFontSize: terminalFontSize)
                        }
                    case .browser:
                        surface = configureBrowserSurface(BrowserSurface(workspaceID: wid, initialURL: restoredBrowserURL(from: desc), title: title))
                    case .agentApp:
                        // Per-surface thread binding restore: prefer the persisted
                        // `selected_thread`. Legacy surfaces (saved before binding
                        // existed) have no metadata — fall back ONCE to the
                        // workspace's first thread so the tab isn't blank, then
                        // future selections self-persist. New tabs that were never
                        // bound restore to the fresh-composer state (nil).
                        let restoredThreadId: AgentThreadID? = {
                            if let raw = desc.metadata["selected_thread"], let uuid = UUID(uuidString: raw) {
                                return AgentThreadID(uuid)
                            }
                            if desc.metadata["selected_thread"] == nil {
                                return (try? ctx.threadRepo.list(workspaceId: wid))?.first?.id
                            }
                            return nil
                        }()
                        let agent = AgentAppSurface(workspaceID: wid, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, queuedMessageRepo: ctx.queuedMessageRepo, pendingCallbackRepo: ctx.providerPendingCallbackRepo, proposedPlanRepo: ctx.proposedPlanRepo, checkpointRepo: ctx.turnCheckpointRepo, promptHistoryStore: PromptHistoryStore(db: ctx.db), customModelStore: AgentCustomModelStore(repo: ctx.settingsRepo), planNotesStore: PlanNotesStore(db: ctx.db), title: title, initialThreadId: restoredThreadId)
                        agent.viewModel.onSelectedThreadChanged = { [weak self, weak agent] threadID in
                            guard let self, let agent else { return }
                            self.persistAgentSelectedThread(surfaceID: agent.descriptor.id, threadID: threadID)
                        }
                        agent.viewModel.markThreadRead = { [weak self] threadID in
                            guard let self else { throw LayoutError.workspaceNotFound }
                            try self.markAgentThreadRead(thread: threadID)
                        }
                        let token = EventBus.shared.subscribe(since: nil) { [weak agent] ev in
                            guard ev.kind.hasPrefix("agent.thread.") || ev.kind.hasPrefix("agent.message.queue") || ev.kind == "agent.message.queued" else { return }
                            DispatchQueue.main.async {
                                agent?.viewModel.reloadThreads()
                                agent?.viewModel.reloadQueuedMessages()
                            }
                        }
                        agent.subscriptionToken = AnyHashable(token)
                        agent.onClose = { EventBus.shared.unsubscribe(token) }
                        agent.viewModel.providerSnapshotLoader = { [weak self] in
                            await self?.listAgentProviderSnapshots() ?? []
                        }
                        agent.viewModel.refreshProviderSnapshotsInBackground()
                        agent.viewModel.providerLaunchConfig = { [weak self] provider, instanceId in
                            (
                                self?.providerBinary(provider: provider, instanceId: instanceId),
                                self?.providerEnvironment(provider: provider, instanceId: instanceId) ?? [:]
                            )
                        }
                        agent.viewModel.providerRecoveryAction = { [weak self] provider, instanceId in
                            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
                            let result = try await self.updateAgentProvider(provider: provider, providerInstanceId: instanceId)
                            return result.objectValue?["stdout"]?.stringValue ?? ""
                        }
                        agent.viewModel.pullRequestThreadPreparer = { [weak self] url, provider, model, permission, reasoning, serviceTier, modelSelection, providerInstanceId in
                            guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
                            return try self.prepareAgentThreadForPullRequest(workspace: wid, url: url, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
                        }
                        agent.viewModel.onReviewRequested = { [weak self] in
                            _ = try? self?.createSurface(workspace: wid, type: .rightSidebarTool, paneID: nil, title: "Git")
                        }
                        // UX-MAC_AGENT-OPEN-SPLIT: clicked file mentions / links open
                        // (or reuse) a split panel to the right of this agent surface.
                        agent.viewModel.onOpenFileInSplit = { [weak self, weak agent] path in
                            guard let self, let agent else { return }
                            self.openFileInAdjacentSplit(workspace: wid, sourceSurface: agent.descriptor.id, absolutePath: path)
                        }
                        agent.viewModel.onOpenURLInSplit = { [weak self, weak agent] url in
                            guard let self, let agent else { return }
                            self.openURLInAdjacentSplit(workspace: wid, sourceSurface: agent.descriptor.id, url: url)
                        }
                        agent.viewModel.onRunStateChange = { [weak self] in
                            guard let self else { return }
                            if !self.promoteWorkspaceIfBusy(wid) {
                                self.windowController?.refreshSurfaceRuntimeState()
                            }
                        }
                        agent.viewModel.onRunCompleted = { [weak self] in
                            self?.promoteWorkspaceAfterCompletedRun(wid)
                        }
                        agent.viewModel.onThreadConfigPersisted = { [weak self] thread in
                            self?.publishAgentThreadUpdated(thread)
                        }
                        agent.viewModel.onThreadLifecycle = { [weak self] event in
                            self?.publishAgentThreadLifecycle(event)
                        }
                        agent.viewModel.onPlanNotesPersisted = { [weak self] thread, notes in
                            self?.publishAgentPlanNotesUpdated(thread: thread, notes: notes)
                        }
                        agent.viewModel.onQueuedMessageEvent = { [weak self] kind, message in
                            self?.publishQueuedMessage(kind: kind, message)
                        }
                        surface = agent
                    case .files:
                        surface = FilesSurface(workspaceID: wid, cwd: cwd, title: title, router: self, initialState: desc.metadata["files_state"], selectedPath: desc.metadata["selected_path"] ?? desc.metadata["selected_relative_path"])
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
                    appRouterLog.error("surface.restore.failed id=\(desc.id, privacy: .public) type=\(String(describing: desc.type), privacy: .public) error=\(String(describing: error), privacy: .public)")
                    restoreFailedSurfaceIDs.append(desc.id)
                }
            }
        }
        guard !idMap.isEmpty else { return }
        for (wid, ws) in ctx.state.workspaces {
            var copy = ws
            copy.layout = remapIDs(in: copy.layout, idMap: idMap)
            ctx.state.workspaces[wid] = copy
        }
        reconcileSurfaceVisibility()
    }

    private func forEachSurface(in node: LayoutNode, _ visit: (SurfaceDescriptor) -> Void) {
        switch node {
        case .pane(let p): for s in p.surfaces { visit(s) }
        case .split(let s): for c in s.children { forEachSurface(in: c, visit) }
        }
    }

    public func reconcileSurfaceVisibility() {
        guard let ctx = context else {
            SurfaceRegistry.shared.setVisibleSurfaceIDs([])
            return
        }
        var workspaceIDs = Set(ctx.state.windows.compactMap(\.selectedWorkspaceID))
        if let detached = windowController?.detachedVisibleWorkspaceIDsForSurfaceReconciliation() {
            workspaceIDs.formUnion(detached)
        }
        let visibleIDs = workspaceIDs.reduce(into: Set<SurfaceID>()) { ids, workspaceID in
            guard let ws = ctx.state.workspaces[workspaceID] else { return }
            ids.formUnion(selectedSurfaceIDs(in: ws.layout))
        }
        SurfaceRegistry.shared.setVisibleSurfaceIDs(visibleIDs)
    }

    private func selectedSurfaceIDs(in node: LayoutNode) -> Set<SurfaceID> {
        selectedSurfaceIDs(in: node, paneVisible: true)
    }

    private func selectedSurfaceIDs(in node: LayoutNode, paneVisible: Bool) -> Set<SurfaceID> {
        switch node {
        case .pane(let pane):
            guard paneVisible else { return [] }
            if let selected = pane.selectedSurfaceID ?? pane.surfaces.first?.id {
                return [selected]
            }
            return []
        case .split(let split):
            let ratios = SplitNode.normalize(split.ratios)
            return split.children.enumerated().reduce(into: Set<SurfaceID>()) { ids, item in
                let ratio = ratios.indices.contains(item.offset) ? ratios[item.offset] : 0
                let childVisible = paneVisible && ratio > Self.minimizedPaneVisibilityThreshold
                ids.formUnion(selectedSurfaceIDs(in: item.element, paneVisible: childVisible))
            }
        }
    }

    private func focusedSelectedSurfaceID(in workspace: Workspace) -> SurfaceID? {
        if let focusedPaneID = workspace.focusedPaneID,
           let pane = workspace.layout.find(paneID: focusedPaneID) {
            return pane.selectedSurfaceID ?? pane.surfaces.first?.id
        }
        return selectedSurfaceIDs(in: workspace.layout).first
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
        let ids = ctx.state.window.workspaces
        // PERF-008: batch thread-busy check -- one query for all workspace ids
        // instead of one threadRepo.list(workspaceId:) call per workspace.
        let runningSet = (try? ctx.threadRepo.runningWorkspaceIds(in: ids)) ?? []
        return ids.compactMap { id in
            guard var ws = ctx.state.workspaces[id] else { return nil }
            let surfaceBusy = ws.layout.paneIDs().contains { pid in
                (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                    isWorkspaceActivitySurface($0)
                }
            }
            let busy = surfaceBusy || runningSet.contains(id)
            if busy { ws.metadata["busy"] = "true" }
            else { ws.metadata.removeValue(forKey: "busy") }
            return ws
        }
    }

    public func isWorkspaceBusy(_ id: WorkspaceID) -> Bool {
        guard let ctx = context,
              let ws = ctx.state.workspaces[id] else { return false }
        let surfaceBusy = ws.layout.paneIDs().contains { pid in
            (ws.layout.find(paneID: pid)?.surfaces ?? []).contains {
                isWorkspaceActivitySurface($0)
            }
        }
        let threadBusy = ((try? ctx.threadRepo.list(workspaceId: id)) ?? []).contains { $0.status == .running }
        return surfaceBusy || threadBusy
    }

    private func isWorkspaceActivitySurface(_ descriptor: SurfaceDescriptor) -> Bool {
        guard SurfaceRegistry.shared.surface(descriptor.id)?.isBusy == true else { return false }
        switch descriptor.type {
        case .terminal, .agentApp:
            return true
        case .ssh, .browser, .files, .markdown, .filePreview, .rightSidebarTool:
            return false
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
        reconcileSurfaceVisibility()
        return w
    }

    public func focusWindow(_ id: WindowID) throws {
        try context?.apply(.focusWindow(id))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        windowController?.repairSelectedTerminalFocus(reason: "window_focus")
    }

    public func closeWindow(_ id: WindowID) throws {
        try context?.apply(.closeWindow(id))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
    }

    public func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws {
        try context?.apply(.moveWorkspaceToWindow(workspace, target))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
    }

    public func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws {
        try context?.apply(.swapPanes(workspace, a, b))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
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
        reconcileSurfaceVisibility()
        publishWorkspaceCreated(ws)
        return ws
    }

    public func createWorkspace(fromFolder url: URL) throws -> Workspace {
        let folder = url.standardizedFileURL
        var isDirectory = ObjCBool(false)
        guard folder.isFileURL,
              FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw LayoutError.workspaceNotFound
        }
        return try createWorkspace(name: folder.lastPathComponent, cwd: folder.path)
    }

    public func selectWorkspace(_ id: WorkspaceID) throws {
        if context?.state.window.selectedWorkspaceID == id {
            return
        }
        try context?.apply(.selectWorkspace(id))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        windowController?.repairSelectedTerminalFocus(reason: "workspace_select")
    }

    public func closeWorkspace(_ id: WorkspaceID, publishEvent: Bool = true) throws {
        // Collect surface IDs before the layout is mutated so we can purge their
        // terminal history after the workspace is removed. Guard: only surfaces that
        // belong to this workspace are collected; live surfaces in other workspaces
        // are never touched.
        var surfaceIDsToDelete: [String] = []
        if let ws = context?.state.workspaces[id] {
            forEachSurface(in: ws.layout) { desc in
                surfaceIDsToDelete.append(desc.id.value.uuidString)
            }
        }
        try context?.apply(.closeWorkspace(id))
        if let ctx = context {
            try? PromptHistoryStore(db: ctx.db).delete(workspaceID: id)
            let repo = ctx.terminalOutputRepo
            for sid in surfaceIDsToDelete {
                try? repo.delete(surfaceID: sid)
            }
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        if publishEvent {
            publishWorkspaceClosed(id)
        }
    }

    public func closeWorkspaces(_ ids: [WorkspaceID]) throws {
        guard let ctx = context else { throw NSError(domain: "rc2", code: 0) }
        var seen: Set<WorkspaceID> = []
        let uniqueIds = ids.filter { seen.insert($0).inserted }
        guard !uniqueIds.isEmpty else { return }
        guard uniqueIds.allSatisfy({ ctx.state.workspaces[$0] != nil }) else { throw LayoutError.workspaceNotFound }
        // Collect surface IDs before the layout is mutated.
        var surfaceIDsToDelete: [String] = []
        for id in uniqueIds {
            if let ws = ctx.state.workspaces[id] {
                forEachSurface(in: ws.layout) { desc in
                    surfaceIDsToDelete.append(desc.id.value.uuidString)
                }
            }
        }
        for id in uniqueIds {
            try ctx.apply(.closeWorkspace(id))
        }
        let store = PromptHistoryStore(db: ctx.db)
        uniqueIds.forEach { try? store.delete(workspaceID: $0) }
        let repo = ctx.terminalOutputRepo
        for sid in surfaceIDsToDelete {
            try? repo.delete(surfaceID: sid)
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        uniqueIds.forEach(publishWorkspaceClosed)
    }

    public func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws {
        try context?.apply(.renameWorkspace(id, newName))
        windowController?.refreshFromState()
        publishWorkspaceRenamed(id, newName)
    }

    public func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws {
        try context?.apply(.setWorkspaceDescription(id, text))
        windowController?.refreshFromState()
        publishWorkspaceUpdated(id, metadata: ["description": .string(text)])
    }

    public func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws {
        try context?.apply(.setWorkspaceColor(id, color))
        windowController?.refreshFromState()
        publishWorkspaceUpdated(id, metadata: ["color": .string(color)])
    }

    private func publishWorkspaceClosed(_ id: WorkspaceID) {
        EventBus.shared.publish(kind: "workspace.closed", payload: .object([
            "workspace_id": .string(id.value.uuidString)
        ]))
    }

    // P1: publish workspace.created/renamed/updated/reordered from the router's
    // own mutation paths so iOS mirrors mac-local sidebar edits live. The
    // payloads below must match the Dispatcher schema exactly (Dispatcher.swift
    // workspace.* cases) so iOS consumes router- and dispatcher-originated
    // events through the same reducer. Builders are pure + nonisolated so they
    // can be unit-tested without the main actor.
    nonisolated static func workspaceCreatedPayload(_ workspace: Workspace) -> JSONValue {
        // Mirrors Dispatcher's `encode(ws)` byte-for-byte: JSONEncoder ->
        // JSONSerialization -> JSONValue.from (NOT JSONValue's own Decodable,
        // which structures the object differently and dropped the top-level id).
        guard let data = try? JSONEncoder().encode(workspace),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return .null }
        return JSONValue.from(any)
    }

    nonisolated static func workspaceRenamedPayload(id: WorkspaceID, name: String) -> JSONValue {
        .object([
            "workspace_id": .string(id.value.uuidString),
            "name": .string(name)
        ])
    }

    nonisolated static func workspaceUpdatedPayload(id: WorkspaceID, metadata: [String: JSONValue]) -> JSONValue {
        .object([
            "workspace_id": .string(id.value.uuidString),
            "metadata": .object(metadata)
        ])
    }

    nonisolated static func workspaceReorderedPayload(id: WorkspaceID, position: Int?, order: [WorkspaceID]) -> JSONValue {
        var payload: [String: JSONValue] = [
            "workspace_id": .string(id.value.uuidString),
            "order": .array(order.map { .string($0.value.uuidString) })
        ]
        if let position {
            payload["position"] = .number(Double(position))
        }
        return .object(payload)
    }

    private func publishWorkspaceCreated(_ workspace: Workspace) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "workspace.created", payload: Self.workspaceCreatedPayload(workspace))
    }

    private func publishWorkspaceRenamed(_ id: WorkspaceID, _ name: String) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "workspace.renamed", payload: Self.workspaceRenamedPayload(id: id, name: name))
    }

    private func publishWorkspaceUpdated(_ id: WorkspaceID, metadata: [String: JSONValue]) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "workspace.updated", payload: Self.workspaceUpdatedPayload(id: id, metadata: metadata))
    }

    private func publishWorkspaceReordered(_ id: WorkspaceID, position: Int?) {
        guard shouldPublishLayoutEvents else { return }
        let order = context?.state.window.workspaces ?? []
        EventBus.shared.publish(kind: "workspace.reordered", payload: Self.workspaceReorderedPayload(id: id, position: position, order: order))
    }

    public func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws {
        try context?.apply(.setWorkspacePinned(id, pinned))
        windowController?.refreshFromState()
        publishWorkspaceUpdated(id, metadata: ["pinned": pinned ? .string("true") : .string("")])
        publishWorkspaceReordered(id, position: nil)
    }

    public func reorderWorkspace(_ id: WorkspaceID, position: Int) throws {
        try context?.apply(.reorderWorkspace(id, position: position))
        windowController?.refreshFromState()
        publishWorkspaceReordered(id, position: position)
    }

    public func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws {
        try context?.apply(.renameSurface(wid, sid, title))
        windowController?.refreshFromState()
    }

    public func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws {
        try context?.apply(.setSurfaceColor(wid, sid, color))
        windowController?.refreshFromState()
    }

    private func publishSurfaceCreated(workspace: WorkspaceID, surface: SurfaceDescriptor) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "surface.created", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface": jsonValue(surface)
        ]))
    }

    private func publishPaneSplit(workspace: WorkspaceID, surface: SurfaceDescriptor) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "pane.split", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface": jsonValue(surface)
        ]))
    }

    private func publishSurfaceClosed(workspace: WorkspaceID, surface: SurfaceID) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "surface.closed", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString)
        ]))
    }

    private func publishSurfaceFocused(workspace: WorkspaceID, surface: SurfaceID) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "surface.focused", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString)
        ]))
    }

    private func publishSurfaceMoved(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID? = nil) {
        guard shouldPublishLayoutEvents else { return }
        var payload: [String: JSONValue] = [
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString)
        ]
        if let targetPane {
            payload["target_pane_id"] = .string(targetPane.value.uuidString)
        }
        EventBus.shared.publish(kind: "surface.moved", payload: .object(payload))
    }

    private func publishSurfaceReordered(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID, position: Int) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "surface.reordered", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "id": .string(surface.value.uuidString),
            "target_pane_id": .string(targetPane.value.uuidString),
            "position": .number(Double(position))
        ]))
    }

    private func publishPaneResized(workspace: WorkspaceID, splitID: UUID) {
        guard shouldPublishLayoutEvents else { return }
        EventBus.shared.publish(kind: "pane.resized", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "split_id": .string(splitID.uuidString)
        ]))
    }

    public func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let desc = makeSurface(type: type, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.addSurface(workspace, paneID: paneID, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        return desc
    }

    public func ensureGitSurface(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        guard let ctx = context,
              let workspaceState = ctx.state.workspaces[workspace] else {
            throw LayoutError.workspaceNotFound
        }
        var existing: SurfaceDescriptor?
        forEachSurface(in: workspaceState.layout) { descriptor in
            guard existing == nil,
                  descriptor.type == .rightSidebarTool,
                  descriptor.metadata["tool"] == "diff" else { return }
            existing = descriptor
        }
        if let existing { return existing }

        let targetPaneID = workspaceState.focusedPaneID ?? workspaceState.layout.paneIDs().first
        let previousSurfaceID = targetPaneID.flatMap {
            workspaceState.layout.find(paneID: $0)?.selectedSurfaceID
        }
        let descriptor = makeSurface(
            type: .rightSidebarTool,
            title: "Git",
            workspace: workspace,
            cwd: workspaceState.cwd
        )
        try ctx.apply(.addSurface(workspace, paneID: targetPaneID, descriptor: descriptor))
        if let previousSurfaceID {
            try ctx.apply(.focusSurface(workspace, previousSurfaceID))
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: descriptor)
        return descriptor
    }

    public func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let desc = makeSurface(type: surfaceType, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.splitPane(workspace, paneID: paneID, direction: direction, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
        return desc
    }

    public func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { throw LayoutError.workspaceNotFound }
        let info = try fileTabInfo(workspace: workspace, path: path)
        let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
        let targetPane = paneID ?? sourceSurface.flatMap { paneIDContaining(surface: $0, in: ws.layout) }
        try ctx.apply(.addSurface(workspace, paneID: targetPane, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        return desc
    }

    public func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else { throw LayoutError.workspaceNotFound }
        let info = try fileTabInfo(workspace: workspace, path: path)
        let targetPane = paneID ?? sourceSurface.flatMap { paneIDContaining(surface: $0, in: ws.layout) } ?? ws.focusedPaneID ?? ws.layout.paneIDs().first
        guard let targetPane else { throw LayoutError.paneNotFound }
        let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
        try ctx.apply(.splitPane(workspace, paneID: targetPane, direction: direction, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
        return desc
    }

    // MARK: Agent App "open in adjacent split" (UX-MAC_AGENT-OPEN-SPLIT)
    // A clicked file mention / link in the Agent App transcript opens in a split
    // panel to the RIGHT of the agent surface. Reuse order: an existing
    // Files/Browser surface in the right-neighbor pane is navigated + focused; a
    // right-neighbor pane without one gets a new tab; no right neighbor creates
    // a right split from the agent's pane.

    public func openFileInAdjacentSplit(workspace: WorkspaceID, sourceSurface: SurfaceID, absolutePath: String) {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace],
              let info = workspaceRelativeTarget(workspace: workspace, path: absolutePath) else {
            // Outside the workspace root the root-scoped Files panel can't show
            // it — hand the (already validated to exist) path to the system.
            NSWorkspace.shared.open(URL(fileURLWithPath: absolutePath))
            return
        }
        let sourcePane = paneIDContaining(surface: sourceSurface, in: ws.layout)
        if let sourcePane, let neighbor = ws.layout.rightNeighborPane(of: sourcePane) {
            if let filesDesc = neighbor.surfaces.first(where: { $0.type == .files }),
               let files = SurfaceRegistry.shared.surface(filesDesc.id) as? FilesSurface {
                files.reveal(relativePath: info.relativePath)
                updateSurfaceDescriptor(workspace: workspace, surface: filesDesc.id) { descriptor in
                    descriptor.title = info.title
                    descriptor.metadata["selected_path"] = info.relativePath
                    descriptor.metadata["selected_relative_path"] = info.relativePath
                }
                try? ctx.apply(.focusSurface(workspace, filesDesc.id))
                windowController?.refreshFromState()
                reconcileSurfaceVisibility()
                return
            }
            let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
            try? ctx.apply(.addSurface(workspace, paneID: neighbor.id, descriptor: desc))
            windowController?.refreshFromState()
            reconcileSurfaceVisibility()
            publishSurfaceCreated(workspace: workspace, surface: desc)
            return
        }
        guard let targetPane = sourcePane ?? ws.focusedPaneID ?? ws.layout.paneIDs().first else { return }
        let desc = makeFilesSurface(workspace: workspace, cwd: ws.cwd, title: info.title, selectedPath: info.relativePath)
        try? ctx.apply(.splitPane(workspace, paneID: targetPane, direction: .right, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
    }

    public func openURLInAdjacentSplit(workspace: WorkspaceID, sourceSurface: SurfaceID, url: URL) {
        guard let ctx = context, let ws = ctx.state.workspaces[workspace] else {
            NSWorkspace.shared.open(url)
            return
        }
        let title = url.host ?? "browser"
        let sourcePane = paneIDContaining(surface: sourceSurface, in: ws.layout)
        if let sourcePane, let neighbor = ws.layout.rightNeighborPane(of: sourcePane) {
            if let browserDesc = neighbor.surfaces.first(where: { $0.type == .browser }),
               let browser = SurfaceRegistry.shared.surface(browserDesc.id) as? BrowserSurface {
                browser.navigate(to: url)
                persistBrowserNavigation(surfaceID: browserDesc.id, url: url.absoluteString, title: nil)
                try? ctx.apply(.focusSurface(workspace, browserDesc.id))
                windowController?.refreshFromState()
                reconcileSurfaceVisibility()
                return
            }
            let desc = makeBrowserSurface(workspace: workspace, url: url, title: title)
            try? ctx.apply(.addSurface(workspace, paneID: neighbor.id, descriptor: desc))
            windowController?.refreshFromState()
            reconcileSurfaceVisibility()
            publishSurfaceCreated(workspace: workspace, surface: desc)
            return
        }
        guard let targetPane = sourcePane ?? ws.focusedPaneID ?? ws.layout.paneIDs().first else {
            NSWorkspace.shared.open(url)
            return
        }
        let desc = makeBrowserSurface(workspace: workspace, url: url, title: title)
        try? ctx.apply(.splitPane(workspace, paneID: targetPane, direction: .right, newSurface: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishPaneSplit(workspace: workspace, surface: desc)
    }

    /// Workspace-relative path + tab title for an absolute target. Files resolve
    /// via `fileTabInfo`; directories (which `read` rejects) via `list`.
    private func workspaceRelativeTarget(workspace: WorkspaceID, path: String) -> (relativePath: String, title: String)? {
        if let info = try? fileTabInfo(workspace: workspace, path: path) { return info }
        guard let cwd = try? workspaceCwd(workspace),
              let listed = try? WorkspaceFileService().list(root: cwd, path: path).objectValue,
              let relativePath = listed["relative_path"]?.stringValue else { return nil }
        let title = (relativePath as NSString).lastPathComponent
        return (relativePath, title.isEmpty ? "Files" : title)
    }

    /// Layout-descriptor mutation (title/metadata) for an existing surface,
    /// mirroring persistBrowserNavigation's persistence path.
    private func updateSurfaceDescriptor(workspace: WorkspaceID, surface: SurfaceID, _ mutate: (inout SurfaceDescriptor) -> Void) {
        guard let ctx = context, var ws = ctx.state.workspaces[workspace] else { return }
        let result = updateSurface(in: ws.layout, surfaceID: surface, mutate)
        guard result.changed else { return }
        ws.layout = result.node
        ws.updatedAt = Date()
        ctx.state.workspaces[workspace] = ws
        ctx.scheduleSnapshotSave()
    }

    private func makeBrowserSurface(workspace: WorkspaceID, url: URL, title: String) -> SurfaceDescriptor {
        let browser = configureBrowserSurface(BrowserSurface(workspaceID: workspace, initialURL: url, title: title))
        SurfaceRegistry.shared.register(browser)
        var desc = browser.descriptor
        // Persist the target up front so an app restart before the first
        // navigation callback still restores this tab to its URL.
        desc.metadata["url"] = url.absoluteString
        return desc
    }

    public func splitSurface(workspace: WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection) throws {
        try context?.apply(.splitSurface(workspace, paneID: paneID, surface: surface, direction: direction))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceMoved(workspace: workspace, surface: surface, targetPane: paneID)
    }

    public func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        // Capture the descriptor before removing it from the layout so
        // reopenClosedSurface can re-create the tab with cwd restored.
        let closedDescriptor = (try? locateSurface(surface))?.descriptor
            ?? SurfaceRegistry.shared.surface(surface)?.descriptor
        let workspaceCwdForReopen = context?.state.workspaces[workspace]?.cwd ?? ""
        try context?.apply(.closeSurface(workspace, surface))
        if let s = SurfaceRegistry.shared.surface(surface) {
            s.close()
            SurfaceRegistry.shared.unregister(surface)
        }
        SurfaceOutputBus.shared.remove(surfaceId: surface)
        // Guard: surface is no longer in the layout (apply(.closeSurface) succeeded),
        // so it is genuinely removed. Delete its persisted terminal history now; rows
        // have no other owner once the surface is gone.
        try? context?.terminalOutputRepo.delete(surfaceID: surface.value.uuidString)
        if let desc = closedDescriptor {
            let entry = ClosedTabEntry(descriptor: desc, workspaceCwd: workspaceCwdForReopen)
            closedTabBuffer.push(entry, for: workspace)
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceClosed(workspace: workspace, surface: surface)
    }

    /// Close multiple surfaces in one batch, applying a single refreshFromState
    /// and reconcileSurfaceVisibility after all mutations instead of one per surface.
    /// Per-surface side effects (registry unregister, output-bus remove, closed-tab
    /// buffer push, event publish) are still performed individually, in order.
    public func closeSurfaces(workspace: WorkspaceID, surfaces: [SurfaceID]) throws {
        guard !surfaces.isEmpty else { return }
        let workspaceCwd = context?.state.workspaces[workspace]?.cwd ?? ""
        for surface in surfaces {
            let closedDescriptor = (try? locateSurface(surface))?.descriptor
                ?? SurfaceRegistry.shared.surface(surface)?.descriptor
            try context?.apply(.closeSurface(workspace, surface))
            if let s = SurfaceRegistry.shared.surface(surface) {
                s.close()
                SurfaceRegistry.shared.unregister(surface)
            }
            SurfaceOutputBus.shared.remove(surfaceId: surface)
            // Guard: surface removed from layout; delete its persisted terminal history.
            try? context?.terminalOutputRepo.delete(surfaceID: surface.value.uuidString)
            if let desc = closedDescriptor {
                let entry = ClosedTabEntry(descriptor: desc, workspaceCwd: workspaceCwd)
                closedTabBuffer.push(entry, for: workspace)
            }
            publishSurfaceClosed(workspace: workspace, surface: surface)
        }
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
    }

    /// Reopen the most-recently-closed tab in `workspace`, restoring its cwd.
    /// Returns the new descriptor, or nil when the closed-tab buffer is empty.
    @discardableResult
    public func reopenClosedSurface(workspace: WorkspaceID) throws -> SurfaceDescriptor? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let entry = closedTabBuffer.pop(for: workspace) else { return nil }
        let cwd = entry.workspaceCwd.isEmpty
            ? (ctx.state.workspaces[workspace]?.cwd ?? "/")
            : entry.workspaceCwd
        // Restore the agent tab's bound thread so reopen-closed-tab returns to
        // the same conversation rather than a fresh composer.
        let reopenThreadId: AgentThreadID? = entry.descriptor.type == .agentApp
            ? entry.descriptor.metadata["selected_thread"].flatMap(UUID.init).map(AgentThreadID.init)
            : nil
        let desc = makeSurface(type: entry.descriptor.type, title: entry.descriptor.title,
                               workspace: workspace, cwd: cwd, initialThreadId: reopenThreadId)
        try ctx.apply(.addSurface(workspace, paneID: nil, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        return desc
    }

    /// Replaces a dead terminal surface with a fresh shell in the same pane
    /// and the same working directory. No-ops if the surface is not a
    /// restartable local terminal (SSH, wrong type, cwd missing).
    public func restartSurface(_ surfaceID: SurfaceID) {
        guard let ctx = context,
              let located = try? locateSurface(surfaceID),
              let (cwd, title) = TerminalRestartDecision.spawnRequest(from: located.descriptor) else { return }
        let workspaceID = located.workspaceID
        let paneID = ctx.state.workspaces[workspaceID]
            .flatMap { paneIDContaining(surface: surfaceID, in: $0.layout) }
        // Close the old surface first so its PTY/FD is cleaned up before the
        // new one is spawned (avoids a brief double-ownership window).
        try? closeSurface(workspace: workspaceID, surface: surfaceID)
        let newDesc = makeSurface(type: .terminal, title: title, workspace: workspaceID, cwd: cwd)
        try? ctx.apply(.addSurface(workspaceID, paneID: paneID, descriptor: newDesc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspaceID, surface: newDesc)
    }

    public func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        if let ws = context?.state.workspaces[workspace],
           let paneID = ws.layout.paneIDs().first(where: { paneID in
               ws.layout.find(paneID: paneID)?.surfaces.contains(where: { $0.id == surface }) == true
           }),
           ws.focusedPaneID == paneID,
           ws.layout.find(paneID: paneID)?.selectedSurfaceID == surface {
            // Already the focused surface in the focused pane -- no state mutation needed.
            windowController?.focusSurface(surface)
            publishSurfaceFocused(workspace: workspace, surface: surface)
            return
        }
        try context?.apply(.focusSurface(workspace, surface))
        // PERF-MAC_SHELL_WINDOW-125: focus/tab selection changes only the
        // selected-surface and focused-pane fields -- the structural signature
        // (pane id set, surface id set, order) is unchanged. Use the in-place
        // fast path instead of a full teardown/rebuild.
        reconcileSurfaceVisibility()
        windowController?.applyFocusChangeInPlace(surfaceToFocus: surface)
        publishSurfaceFocused(workspace: workspace, surface: surface)
    }

    /// Focus-follows-click: route a pane-content mouseDown to make the clicked
    /// pane the focused one so Cmd+W/Cmd+D act on the pane the user is typing in.
    public func focusPane(workspace: WorkspaceID, pane: PaneID) throws {
        try context?.apply(.focusPane(workspace, pane))
        // PERF-MAC_SHELL_WINDOW-125: pane focus changes only focusedPaneID --
        // structural signature unchanged. Reconcile in place (no rebuild).
        reconcileSurfaceVisibility()
        windowController?.applyFocusChangeInPlace(surfaceToFocus: nil)
    }

    public func repairSelectedTerminalFocus(reason: String) {
        guard let ctx = context else { return }
        var workspaceIDs = Set(ctx.state.windows.compactMap(\.selectedWorkspaceID))
        if let detached = windowController?.detachedVisibleWorkspaceIDsForSurfaceReconciliation() {
            workspaceIDs.formUnion(detached)
        }
        for workspaceID in workspaceIDs {
            repairSelectedTerminalFocus(workspace: workspaceID, reason: reason)
        }
    }

    public func repairSelectedTerminalFocus(workspace workspaceID: WorkspaceID, reason: String) {
        guard let ws = context?.state.workspaces[workspaceID],
              let surfaceID = focusedSelectedSurfaceID(in: ws),
              SurfaceRegistry.shared.isVisible(surfaceID),
              let terminal = SurfaceRegistry.shared.surface(surfaceID) as? TerminalSurface else { return }
        terminal.repairTerminalFocus(reason: reason)
    }

    public func sendText(surface: SurfaceID, text: String) throws {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        s.sendText(text)
    }

    public func sendTextResult(surface: SurfaceID, text: String) throws -> JSONValue {
        guard let s = SurfaceRegistry.shared.surface(surface) else {
            return terminalInputStatusJSON(.surfaceNotFound)
        }
        if let terminal = s as? TerminalSurface {
            return terminalInputStatusJSON(terminal.sendTextStatus(text))
        }
        s.sendText(text)
        return terminalInputStatusJSON(.accepted)
    }

    public func readText(surface: SurfaceID) throws -> String {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        return s.readText()
    }

    public func readTextSnapshot(surface: SurfaceID) throws -> JSONValue {
        guard let s = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        if let terminal = s as? TerminalSurface {
            return terminalSnapshotJSON(terminal.readTextSnapshot())
        }
        return .object([
            "text": .string(s.readText()),
            "complete": .bool(true),
            "partial": .bool(false),
            "source": .string("surface_read_text"),
            "timestamp": .number(Date().timeIntervalSince1970),
            "pending_bytes": .number(0)
        ])
    }

    public func readTerminalHistory(surface: SurfaceID, beforeChunkID: Int64?, maxBytes: Int) throws -> TerminalOutputWindow {
        guard let surfaceObject = SurfaceRegistry.shared.surface(surface) else { throw LayoutError.surfaceNotFound }
        (surfaceObject as? TerminalSurface)?.flushPersistedHistory()
        SurfaceOutputBus.shared.flushNow(surface)
        guard let repo = context?.terminalOutputRepo else { throw LayoutError.surfaceNotFound }
        return try repo.readWindow(surfaceID: surface.value.uuidString, beforeChunkID: beforeChunkID, maxBytes: maxBytes)
    }

    public func surfaceHealth(surface: SurfaceID) -> Bool {
        SurfaceRegistry.shared.surface(surface) != nil
    }

    public func surfaceHealthDetails(surface: SurfaceID) -> JSONValue {
        guard let s = SurfaceRegistry.shared.surface(surface) else {
            return .object([
                "alive": .bool(false),
                "process_alive": .bool(false),
                "pty_open": .bool(false),
                "input_accepting": .bool(false),
                "terminal_dead_reason": .string(TerminalInputStatus.surfaceNotFound.rawValue)
            ])
        }
        guard let terminal = s as? TerminalSurface else {
            return .object([
                "alive": .bool(true),
                "surface_type": .string(s.descriptor.type.rawValue)
            ])
        }
        return terminalHealthJSON(terminal.runtimeHealth())
    }

    public func surfaceClearHistory(surface: SurfaceID) {
        // Terminal-specific: clear persisted scrollback, then replace the live
        // terminal viewport by sending the clear shortcut. Browser/agent
        // surfaces ignore.
        if let s = SurfaceRegistry.shared.surface(surface), s.descriptor.type == .terminal || s.descriptor.type == .ssh {
            (s as? TerminalSurface)?.flushPersistedHistory()
            try? context?.terminalOutputRepo.delete(surfaceID: surface.value.uuidString)
            s.sendText("\u{0C}") // ctrl-L
        }
    }

    public func sshHostList(workspace: WorkspaceID) throws -> [SSHHostProfile] {
        guard let ctx = context else { return [] }
        try requireWorkspace(workspace, in: ctx)
        return try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
    }

    public func sshHostUpsert(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try requireWorkspace(workspace, in: ctx)
        var hosts = try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
        var saved = profile
        saved.updatedAt = Date()
        if let index = hosts.firstIndex(where: { $0.id == saved.id }) {
            saved.createdAt = hosts[index].createdAt
            if saved.password?.isEmpty == false {
                saved.hasSavedPassword = true
            } else {
                saved.password = nil
                saved.hasSavedPassword = hosts[index].hasSavedPassword
            }
            hosts[index] = saved
        } else {
            saved.hasSavedPassword = saved.password?.isEmpty == false
            hosts.append(saved)
        }
        try writeSSHHosts(hosts, workspace: workspace, to: ctx.settingsRepo)
        return saved
    }

    func sshHostForConnection(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile {
        let saved = try sshHostUpsert(profile, workspace: workspace)
        return sshHostWithPasswordForConnection(saved)
    }

    public func sshHostDelete(_ id: SSHHostID, workspace: WorkspaceID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try requireWorkspace(workspace, in: ctx)
        var hosts = try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
        hosts.removeAll { $0.id == id }
        sshPasswordStore.delete(account: id.value.uuidString)
        try writeSSHHosts(hosts, workspace: workspace, to: ctx.settingsRepo)
    }

    public func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try requireWorkspace(workspace, in: ctx)
        let hosts = try readSSHHosts(workspace: workspace, from: ctx.settingsRepo)
        let resolved: SSHHostProfile
        if let profileID, let found = hosts.first(where: { $0.id == profileID }) {
            resolved = sshHostWithPasswordForConnection(found)
        } else if let profile {
            resolved = try sshHostForConnection(profile, workspace: workspace)
        } else {
            throw LayoutError.surfaceNotFound
        }
        let desc = try makeSSHSurface(profile: resolved, title: title, workspace: workspace, cwd: ctx.state.workspaces[workspace]?.cwd ?? "/")
        try ctx.apply(.addSurface(workspace, paneID: paneID, descriptor: desc))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceCreated(workspace: workspace, surface: desc)
        if shouldPublishLayoutEvents {
            EventBus.shared.publish(kind: "ssh.session.updated", payload: .object([
                "surface_id": .string(desc.id.value.uuidString),
                "status": .string(desc.metadata["ssh_status"] ?? "connected"),
                "destination": .string(desc.metadata["ssh_destination"] ?? "")
            ]))
        }
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

    /// Open one exact agent thread in a concrete Agent App surface.
    ///
    /// This is the canonical deep-link path for system notifications and other
    /// attention surfaces. It deliberately keeps `selectAgentThread`'s nil-target
    /// behavior unchanged: remote mark-read/list refreshes must not yank an
    /// arbitrary macOS tab. A user-initiated open instead resolves one surface,
    /// focuses it, binds the thread to that surface ID, verifies the binding, and
    /// only then clears unread state when requested.
    @discardableResult
    public func openAgentThread(thread threadID: AgentThreadID, markRead: Bool = false) throws -> SurfaceDescriptor {
        guard let ctx = context,
              let thread = try ctx.threadRepo.get(id: threadID),
              let workspaceID = thread.workspaceId,
              ctx.state.workspaces[workspaceID] != nil else {
            throw LayoutError.workspaceNotFound
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        let destinationWindow: NSWindow?
        if let detachedWindow = windowController?.workspaceWindow(for: workspaceID) {
            detachedWindow.makeKeyAndOrderFront(nil)
            destinationWindow = detachedWindow
        } else {
            windowController?.show()
            try selectWorkspace(workspaceID)
            destinationWindow = windowController?.window
        }
        guard let destinationWindow else {
            throw LayoutError.surfaceNotFound
        }

        let surface: AgentAppSurface
        if let existing = preferredAgentAppSurface(in: workspaceID) {
            surface = existing
        } else {
            let descriptor = try openAgentApp(workspace: workspaceID)
            guard let created = SurfaceRegistry.shared.surface(descriptor.id) as? AgentAppSurface else {
                throw LayoutError.surfaceNotFound
            }
            surface = created
        }

        try focusSurface(workspace: workspaceID, surface: surface.descriptor.id)
        try selectAgentThread(
            thread: threadID,
            surfaceID: surface.descriptor.id,
            markReadOnSelection: false
        )
        windowController?.flushPendingRefresh()
        guard surface.viewModel.selectedThreadId == threadID else {
            throw LayoutError.surfaceNotFound
        }
        destinationWindow.contentView?.layoutSubtreeIfNeeded()
        destinationWindow.makeKeyAndOrderFront(nil)
        guard destinationWindow.isVisible,
              destinationWindow.isMiniaturized == false else {
            throw LayoutError.surfaceNotFound
        }
        if markRead,
           (!destinationWindowIsKey(destinationWindow) || surface.view.window !== destinationWindow) {
            throw LayoutError.surfaceNotFound
        }

        if markRead {
            try markAgentThreadRead(thread: threadID)
        }
        return surface.descriptor
    }

    /// Prefer the currently focused Agent App tab, then layout order. This makes
    /// an explicit deep link deterministic without changing any sibling surface.
    private func preferredAgentAppSurface(in workspaceID: WorkspaceID) -> AgentAppSurface? {
        guard let workspace = context?.state.workspaces[workspaceID] else { return nil }
        let candidates = SurfaceRegistry.shared.all().compactMap { $0 as? AgentAppSurface }
            .filter { $0.viewModel.workspaceID == workspaceID }
        guard !candidates.isEmpty else { return nil }

        if let focusedPaneID = workspace.focusedPaneID,
           let selectedID = workspace.layout.find(paneID: focusedPaneID)?.selectedSurfaceID,
           let focused = candidates.first(where: { $0.descriptor.id == selectedID }) {
            return focused
        }

        for paneID in workspace.layout.paneIDs() {
            for descriptor in workspace.layout.find(paneID: paneID)?.surfaces ?? [] {
                if let candidate = candidates.first(where: { $0.descriptor.id == descriptor.id }) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func destinationWindowIsKey(_ window: NSWindow) -> Bool {
        destinationWindowIsKeyForTests?(window) ?? window.isKeyWindow
    }

    public func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] {
        guard let ctx = context else { return [] }
        return try ctx.threadRepo.list(workspaceId: workspace)
    }

    public func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier = .auto, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil, surfaceID: SurfaceID? = nil) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let t = AgentThread(workspaceId: workspace, title: title, provider: provider,
                            providerInstanceId: normalizedProviderInstanceId(provider: provider, requested: providerInstanceId),
                            model: model,
                            permissionMode: permissionMode, reasoningEffort: reasoningEffort,
                            serviceTier: serviceTier,
                            modelSelection: modelSelection ?? AgentModelSelection(provider: provider, modelId: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier))
        try ctx.threadRepo.upsert(t)
        // Only bind/select the new thread on the requesting surface (if any).
        // Without a surfaceID this just refreshes rails — a thread created from
        // one client no longer hijacks every other open agent tab.
        try selectAgentThread(thread: t.id, surfaceID: surfaceID)
        return t
    }

    public func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier? = nil, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard var t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        let started = !((try? ctx.messageRepo.listRecent(threadId: thread, limit: 1)) ?? []).isEmpty
        if let provider, provider != t.provider {
            // A1 (iOS+macOS parity): the provider is fixed once the
            // thread has a conversation. Only model/effort stay
            // changeable after that. Enforced host-side so no client
            // can bypass the UI lock.
            guard !started else {
                throw JSONRPCError(code: -32010,
                    message: "Provider is locked once the thread has started; only model and effort can change.")
            }
            t.provider = provider
            t.providerInstanceId = normalizedProviderInstanceId(provider: provider, requested: providerInstanceId)
            t.providerThreadId = nil
        } else if let providerInstanceId {
            let normalized = normalizedProviderInstanceId(provider: t.provider, requested: providerInstanceId)
            if normalized != t.providerInstanceId {
                guard !started else {
                    throw JSONRPCError(code: -32013,
                        message: "Provider instance is locked once the thread has started.")
                }
                t.providerInstanceId = normalized
                t.providerThreadId = nil
            }
        }
        if let model, model != t.model {
            let canSwitchModelInSession = t.provider == .claude && t.providerThreadId?.isEmpty == false
            t.model = model
            if !canSwitchModelInSession {
                t.providerThreadId = nil
            }
        }
        if let permissionMode {
            t.permissionMode = permissionMode
        }
        if let reasoningEffort {
            t.reasoningEffort = reasoningEffort
        }
        if let serviceTier {
            t.serviceTier = serviceTier
        }
        let persistedCustomModel = t.modelSelection.customModelId == t.model ? t.modelSelection.customModelId : nil
        t.modelSelection = modelSelection ?? AgentModelSelection(
            provider: t.provider,
            modelId: t.model,
            customModelId: persistedCustomModel,
            reasoningEffort: t.reasoningEffort,
            serviceTier: t.serviceTier
        )
        t.updatedAt = Date()
        try ctx.threadRepo.upsert(t)
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            if agent.viewModel.selectedThreadId == thread {
                if let provider { agent.viewModel.provider = provider }
                if let model { agent.viewModel.model = model }
                if let permissionMode { agent.viewModel.permissionMode = permissionMode }
                if let reasoningEffort { agent.viewModel.reasoningEffort = reasoningEffort }
                if let serviceTier { agent.viewModel.serviceTier = serviceTier }
            }
            agent.viewModel.reloadThreads()
        }
        windowController?.refreshFromState()
        return t
    }

    public func configureAgentThreadExecution(thread: AgentThreadID, executionMode: AgentExecutionMode, baseBranch: String?) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard var t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        let started = !((try? ctx.messageRepo.listRecent(threadId: thread, limit: 1)) ?? []).isEmpty
        guard !started else {
            throw JSONRPCError(code: -32011, message: "Execution mode is locked once the thread has started.")
        }
        if executionMode == .worktree {
            let branch = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !branch.isEmpty else {
                throw JSONRPCError(code: -32012, message: "Worktree mode requires a base branch before the first agent prompt.")
            }
            t.baseBranch = branch
        } else {
            t.baseBranch = nil
            t.worktreePath = nil
        }
        t.executionMode = executionMode
        t.updatedAt = Date()
        try ctx.threadRepo.upsert(t)
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            agent.viewModel.reloadThreads()
        }
        windowController?.refreshFromState()
        return t
    }

    public func prepareAgentThreadForPullRequest(workspace: WorkspaceID, url: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let cwd = try workspaceCwd(workspace)
        let prep = GitDiff.preparePullRequestWorktree(in: cwd, urlString: url)
        guard prep.result.ok else {
            throw JSONRPCError(code: -32050, message: prep.result.message.isEmpty ? "Failed to prepare pull request worktree." : prep.result.message)
        }
        var thread = AgentThread(
            workspaceId: workspace,
            title: "PR #\(prep.ref.number): \(prep.ref.repositoryPath)",
            provider: provider,
            providerInstanceId: normalizedProviderInstanceId(provider: provider, requested: providerInstanceId),
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            executionMode: .worktree,
            baseBranch: prep.branch,
            worktreePath: prep.worktreePath,
            serviceTier: serviceTier,
            modelSelection: modelSelection ?? AgentModelSelection(provider: provider, modelId: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier)
        )
        thread.updatedAt = Date()
        try ctx.threadRepo.upsert(thread)
        // Rail refresh only across surfaces; the initiating macOS surface (if
        // local) selects the PR thread through its own view-model path.
        try selectAgentThread(thread: thread.id)
        return thread
    }

    /// Reflect a thread selection across agent surfaces.
    ///
    /// Selection is PER-SURFACE: by default this only refreshes every agent
    /// surface's rail and selects the thread on the one surface identified by
    /// `surfaceID`. Passing `surfaceID == nil` performs a rail refresh only and
    /// selects nothing — so a thread created/selected by one client (or a
    /// mark-read) no longer force-switches every other macOS agent tab (the
    /// global fan-out that made iOS actions disturb macOS).
    public func selectAgentThread(thread: AgentThreadID, surfaceID: SurfaceID? = nil) throws {
        try selectAgentThread(thread: thread, surfaceID: surfaceID, markReadOnSelection: true)
    }

    private func selectAgentThread(
        thread: AgentThreadID,
        surfaceID: SurfaceID?,
        markReadOnSelection: Bool
    ) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            agent.viewModel.reloadThreads()
            if let surfaceID, agent.descriptor.id == surfaceID {
                agent.viewModel.selectThread(thread, markRead: markReadOnSelection)
            }
        }
        windowController?.refreshFromState()
    }

    public func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.listRecent(threadId: thread, limit: max(0, min(limit, 500)))
    }

    public func threadIdsWithMessages() throws -> Set<AgentThreadID> {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.threadIdsWithMessages()
    }

    public func listAgentMessagesPage(thread: AgentThreadID, limit: Int, before: AgentMessageCursor?, after: AgentMessageCursor? = nil) throws -> AgentMessagePage {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.listPage(threadId: thread, limit: max(0, min(limit, 500)), before: before, after: after)
    }

    public func getAgentMessage(id: AgentMessageID) throws -> AgentMessage? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.messageRepo.get(id: id)
    }

    public func listAgentQueuedMessages(thread: AgentThreadID) throws -> [AgentQueuedMessage] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.queuedMessageRepo.list(threadId: thread)
    }

    public func updateAgentQueuedMessage(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) throws -> AgentQueuedMessage {
        guard let ctx = context,
              let updated = try ctx.queuedMessageRepo.update(id: id, text: text, attachments: attachments) else {
            throw JSONRPCError.invalidParams
        }
        publishQueuedMessage(kind: "agent.message.queue.updated", updated)
        refreshAgentSurfaces(thread: updated.threadId)
        return updated
    }

    public func cancelAgentQueuedMessage(id: AgentQueuedMessageID) throws -> AgentQueuedMessage {
        guard let ctx = context,
              let cancelled = try ctx.queuedMessageRepo.delete(id: id) else {
            throw JSONRPCError.invalidParams
        }
        publishQueuedMessage(kind: "agent.message.queue.cancelled", cancelled)
        refreshAgentSurfaces(thread: cancelled.threadId)
        return cancelled
    }

    public func forceAgentQueuedMessageNow(id: AgentQueuedMessageID) async throws -> AgentMessageSendResult {
        guard let ctx = context,
              let queued = try ctx.queuedMessageRepo.get(id: id),
              let thread = try ctx.threadRepo.get(id: queued.threadId) else {
            throw JSONRPCError.invalidParams
        }
        if thread.status == .running {
            guard let promoted = try ctx.queuedMessageRepo.promoteToFront(id: id) else {
                throw JSONRPCError.invalidParams
            }
            for message in try ctx.queuedMessageRepo.list(threadId: queued.threadId) {
                publishQueuedMessage(kind: "agent.message.queue.updated", message)
            }
            refreshAgentSurfaces(thread: queued.threadId)
            // Force = run now: interrupt the in-flight turn so the just-promoted
            // front-of-queue message starts immediately. stopRun resolves to a
            // .cancelled finish, which onRunFinished (AppContext) treats as
            // drain-eligible -> drainNextQueuedAgentMessage sends this message.
            // The synchronous result stays .queued; the new run begins via the
            // run-lifecycle events that follow.
            ctx.coordinator.stopRun(threadId: queued.threadId)
            return AgentMessageSendResult(status: .queued, queuedMessage: promoted)
        }
        _ = try ctx.queuedMessageRepo.delete(id: queued.id)
        publishQueuedMessage(kind: "agent.message.queue.drained", queued)
        for message in try ctx.queuedMessageRepo.list(threadId: queued.threadId) {
            publishQueuedMessage(kind: "agent.message.queue.updated", message)
        }
        refreshAgentSurfaces(thread: queued.threadId)
        return try await sendAgentMessage(
            thread: queued.threadId,
            text: queued.text,
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            interactionMode: queued.interactionMode,
            modelSelection: nil,
            providerInstanceId: nil,
            attachments: queued.attachments
        )
    }

    /// Mirror-path equivalent of AgentAppViewModel.reorderQueuedMessage: moves
    /// the queued message to `position` (0-based target index, clamped) and
    /// renumbers every message in the thread's queue. Publishes
    /// agent.message.queue.updated for EVERY queued message so mirrors that
    /// upsert-by-id and sort-by-position converge on the new order.
    public func reorderAgentQueuedMessage(thread: AgentThreadID, id: AgentQueuedMessageID, position: Int) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let queue = try ctx.queuedMessageRepo.list(threadId: thread)
        guard let fromIndex = queue.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        let dest = max(0, min(position, queue.count - 1))
        let reordered = AgentAppViewModel.reorderQueue(queue, from: fromIndex, to: dest)
        let now = Date()
        for (index, var message) in reordered.enumerated() {
            message.position = index + 1
            message.updatedAt = now
            try ctx.queuedMessageRepo.upsert(message)
        }
        for message in try ctx.queuedMessageRepo.list(threadId: thread) {
            publishQueuedMessage(kind: "agent.message.queue.updated", message)
        }
        refreshAgentSurfaces(thread: thread)
    }

    public func agentPlanNotes(thread: AgentThreadID) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try PlanNotesStore(db: ctx.db).load(threadId: thread)
    }

    public func saveAgentPlanNotes(thread: AgentThreadID, notes: String) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try PlanNotesStore(db: ctx.db).save(notes, threadId: thread)
        // HC-5 spirit: a mirror-driven mutation must be visible on the Mac
        // immediately — refresh any open surface bound to this thread.
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.selectedThreadId == thread else { continue }
            agent.viewModel.applyMirroredPlanNotes(notes, threadId: thread)
        }
        publishAgentPlanNotesUpdated(thread: thread, notes: notes)
    }

    public func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier? = nil, interactionMode: AgentInteractionMode? = nil, modelSelection: AgentModelSelection? = nil, providerInstanceId: String? = nil, attachments: [AgentAttachment] = []) async throws -> AgentMessageSendResult {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        if let existing = try ctx.threadRepo.get(id: thread),
           existing.status == .running {
            let queued = try ctx.queuedMessageRepo.enqueue(
                threadId: thread,
                text: text,
                attachments: attachments,
                interactionMode: interactionMode ?? .default
            )
            publishQueuedMessage(kind: "agent.message.queued", queued)
            refreshAgentSurfaces(thread: thread)
            return AgentMessageSendResult(status: .queued, queuedMessage: queued)
        }
        // A message-send is not a provider-change gesture. The provider INSTANCE
        // is immutable once the thread has started (A1 parity), so never forward it
        // into configureAgentThread on a started thread: a mirror client that
        // re-derives its instance id from the provider snapshot list can carry an id
        // that no longer matches the thread's locked instance, and configureAgentThread
        // would otherwise reject the send with -32013 ("Provider instance is locked")
        // — leaving the user unable to send. Provider itself is still forwarded so a
        // genuine provider mismatch stays a loud -32010 rather than silently mutating
        // model/session state. The explicit agent.thread.configure RPC keeps enforcing
        // both locks for the UI's change-provider gesture.
        let alreadyStarted = !((try? ctx.messageRepo.listRecent(threadId: thread, limit: 1)) ?? []).isEmpty
        var t = try configureAgentThread(thread: thread, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: alreadyStarted ? nil : providerInstanceId)
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
        let cwd = try prepareAgentExecutionCwd(thread: &t)
        let req = AgentRunRequest(
            threadId: thread,
            provider: prov,
            providerInstanceId: t.providerInstanceId,
            model: m,
            cwd: cwd,
            prompt: text,
            attachments: attachments,
            providerThreadId: t.providerThreadId,
            permissionMode: t.permissionMode,
            reasoningEffort: t.reasoningEffort,
            serviceTier: t.serviceTier,
            interactionMode: interactionMode ?? .default,
            providerBinary: providerBinary(provider: prov, instanceId: t.providerInstanceId),
            environment: providerEnvironment(provider: prov, instanceId: t.providerInstanceId)
        )
        let runId = try await ctx.coordinator.startRun(req)
        // HC-5 (R1): a message sent from the mobile mirror must be
        // visible on the Mac. Route it into the live Agent surface for
        // this workspace exactly like a local action — select the
        // thread + reload so the just-persisted user message and the
        // streaming turn render in the macOS window, not only over the
        // wire.
        refreshAgentSurfaces(thread: thread, workspace: t.workspaceId, select: true)
        return AgentMessageSendResult(status: .started, runId: runId)
    }

    public func drainNextQueuedAgentMessage(thread: AgentThreadID) async throws {
        guard let ctx = context,
              let queued = try ctx.queuedMessageRepo.first(threadId: thread),
              let threadState = try ctx.threadRepo.get(id: thread),
              threadState.status != .running,
              threadState.status != .pending else { return }
        _ = try ctx.queuedMessageRepo.delete(id: queued.id)
        publishQueuedMessage(kind: "agent.message.queue.drained", queued)
        refreshAgentSurfaces(thread: thread)
        _ = try await sendAgentMessage(
            thread: thread,
            text: queued.text,
            provider: nil,
            model: nil,
            permissionMode: nil,
            reasoningEffort: nil,
            serviceTier: nil,
            interactionMode: queued.interactionMode,
            modelSelection: nil,
            providerInstanceId: nil,
            attachments: queued.attachments
        )
    }

    private func prepareAgentExecutionCwd(thread: inout AgentThread) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let workspaceCwd = ctx.state.workspaces.first { $0.value.id == thread.workspaceId }?.value.cwd ?? FileManager.default.currentDirectoryPath
        guard thread.executionMode == .worktree else { return workspaceCwd }
        if let path = thread.worktreePath, FileManager.default.fileExists(atPath: path) {
            return path
        }
        let base = thread.baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !base.isEmpty else {
            throw JSONRPCError(code: -32012, message: "Worktree mode requires a base branch before the first agent prompt.")
        }
        let root = URL(fileURLWithPath: workspaceCwd)
        let parent = root.deletingLastPathComponent()
        let name = root.lastPathComponent.isEmpty ? "workspace" : root.lastPathComponent
        let shortId = String(thread.id.value.uuidString.prefix(8)).lowercased()
        let path = parent.appendingPathComponent("\(name)-agent-worktrees").appendingPathComponent(shortId).path
        let branch = "rc-agent/\(shortId)"
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let result = GitDiff.createWorktree(in: workspaceCwd, path: path, branch: branch, baseBranch: base)
        guard result.ok || FileManager.default.fileExists(atPath: path) else {
            throw JSONRPCError(code: -32013, message: result.message.isEmpty ? "Failed to create agent worktree." : result.message)
        }
        thread.worktreePath = path
        thread.updatedAt = Date()
        try ctx.threadRepo.upsert(thread)
        return path
    }

    public func implementAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, newThread: Bool, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier? = nil, modelSelection: AgentModelSelection? = nil) async throws -> (runId: AgentRunID, implementationThreadId: AgentThreadID) {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let source = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        let storedMarkdown: String?
        if let planMarkdown {
            storedMarkdown = planMarkdown
        } else {
            storedMarkdown = try ctx.proposedPlanRepo.list(threadId: thread).last(where: { $0.plan.id == planId })?.plan.markdown
        }
        let markdown = storedMarkdown
        guard let markdown, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONRPCError(code: -32030, message: "Proposed plan not found.")
        }
        let implementationThread: AgentThread
        if newThread {
            implementationThread = try createAgentThread(
                workspace: source.workspaceId,
                title: "Implement plan",
                provider: provider ?? source.provider,
                model: model ?? source.model,
                permissionMode: permissionMode ?? source.permissionMode,
                reasoningEffort: reasoningEffort ?? source.reasoningEffort,
                serviceTier: serviceTier ?? source.serviceTier,
                modelSelection: modelSelection ?? source.modelSelection,
                providerInstanceId: source.providerInstanceId
            )
        } else {
            implementationThread = source
        }
        let sendResult = try await sendAgentMessage(
            thread: implementationThread.id,
            text: AgentPlanImplementationPrompt.make(markdown: markdown),
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: .default,
            modelSelection: modelSelection,
            providerInstanceId: source.providerInstanceId,
            attachments: []
        )
        guard let runId = sendResult.runId else {
            throw JSONRPCError(code: -32032, message: "Plan implementation was queued because the thread is already running.")
        }
        try? ctx.proposedPlanRepo.markImplemented(threadId: thread, planId: planId, implementationThreadId: implementationThread.id)
        return (runId, implementationThread.id)
    }

    public func saveAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, relativePath: String?) throws -> (path: String, relativePath: String) {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let source = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        let storedMarkdown = try ctx.proposedPlanRepo.list(threadId: thread).last(where: { $0.plan.id == planId })?.plan.markdown
        guard let markdown = planMarkdown ?? storedMarkdown,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JSONRPCError(code: -32030, message: "Proposed plan not found.")
        }
        let workspaceCwd = ctx.state.workspaces.first { $0.value.id == source.workspaceId }?.value.cwd
        guard let workspaceCwd, !workspaceCwd.isEmpty else { throw LayoutError.workspaceNotFound }
        let rootURL = URL(fileURLWithPath: workspaceCwd).standardizedFileURL
        let requestedRelative = relativePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeRelative = requestedRelative?.isEmpty == false
            ? requestedRelative!
            : ".remotecode/plans/\(AssistantProposedPlan(id: planId, turnId: nil, markdown: markdown).exportFileName)"
        guard !safeRelative.hasPrefix("/") && !safeRelative.split(separator: "/").contains("..") else {
            throw JSONRPCError(code: -32031, message: "Plan save path must stay inside the workspace.")
        }
        let targetURL = rootURL.appendingPathComponent(safeRelative).standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard targetURL.path == rootURL.path || targetURL.path.hasPrefix(rootPath) else {
            throw JSONRPCError(code: -32031, message: "Plan save path must stay inside the workspace.")
        }
        try FileManager.default.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try markdown.write(to: targetURL, atomically: true, encoding: .utf8)
        let resolvedRelative = String(targetURL.path.dropFirst(rootPath.count))
        return (targetURL.path, resolvedRelative)
    }

    public func commandReceipt(method: String, clientRequestId: String) -> JSONValue? {
        guard let ctx = context,
              let json = try? ctx.commandReceiptRepo.get(method: method, clientRequestId: clientRequestId),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func recordCommandReceipt(method: String, clientRequestId: String, result: JSONValue) {
        guard let ctx = context,
              let data = try? JSONEncoder().encode(result),
              let json = String(data: data, encoding: .utf8) else { return }
        try? ctx.commandReceiptRepo.record(method: method, clientRequestId: clientRequestId, resultJSON: json)
    }

    public func respondAgentRequest(thread: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let state: AssistantRequestState = {
            switch response {
            case .approve, .approveForSession: return .approved
            case .decline: return .declined
            case .cancel: return .cancelled
            }
        }()
        do {
            try await ctx.coordinator.respondToRequest(threadId: thread, requestId: requestId, response: response)
            try? ctx.providerPendingCallbackRepo.resolve(threadId: thread, requestId: requestId, kind: .approval, state: state)
            EventBus.shared.publish(kind: "agent.request.resolved", payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "state": .string(state.rawValue)
            ]))
            if response == .approveForSession {
                let updated = try configureAgentThread(
                    thread: thread,
                    provider: nil,
                    model: nil,
                    permissionMode: .fullAccess,
                    reasoningEffort: nil,
                    serviceTier: nil,
                    modelSelection: nil,
                    providerInstanceId: nil
                )
                publishAgentThreadUpdated(updated)
            }
        } catch {
            let reason = "Provider approval response failed: \(error)"
            try? ctx.providerPendingCallbackRepo.markStale(threadId: thread, requestId: requestId, kind: .approval, reason: reason)
            EventBus.shared.publish(kind: "agent.request.resolved", payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "state": .string(AssistantRequestState.stale.rawValue),
                "error": .string(reason)
            ]))
            throw error
        }
    }

    public func respondAgentUserInput(thread: AgentThreadID, requestId: String, text: String) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        do {
            try await ctx.coordinator.respondToUserInput(threadId: thread, requestId: requestId, text: text)
            try? ctx.providerPendingCallbackRepo.resolve(threadId: thread, requestId: requestId, kind: .userInput, state: .resolved)
            EventBus.shared.publish(kind: "agent.user_input.resolved", payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "answer": .string(text)
            ]))
        } catch {
            let reason = "Provider user-input response failed: \(error)"
            try? ctx.providerPendingCallbackRepo.markStale(threadId: thread, requestId: requestId, kind: .userInput, reason: reason)
            EventBus.shared.publish(kind: "agent.user_input.resolved", payload: .object([
                "thread_id": .string(thread.value.uuidString),
                "request_id": .string(requestId),
                "state": .string(AssistantRequestState.stale.rawValue),
                "error": .string(reason)
            ]))
            throw error
        }
    }

    public func listAgentPendingCallbacks(thread: AgentThreadID) throws -> AssistantPendingCallbacksSnapshot {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        let decoder = JSONDecoder()
        var requests: [AssistantPendingRequest] = []
        var userInputs: [AssistantUserInputRequest] = []
        for callback in try ctx.providerPendingCallbackRepo.listVisible(threadId: thread) {
            guard let data = callback.payloadJSON.data(using: .utf8) else { continue }
            switch callback.kind {
            case .approval:
                guard var request = try? decoder.decode(AssistantPendingRequest.self, from: data) else { continue }
                request.state = callback.state
                request.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                if callback.state == .stale, let reason = callback.staleReason {
                    request.detail = [request.detail, reason].compactMap { $0 }.joined(separator: "\n")
                }
                requests.append(request)
            case .userInput:
                guard var input = try? decoder.decode(AssistantUserInputRequest.self, from: data) else { continue }
                input.state = callback.state
                input.resolvedAtMs = callback.resolvedAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                if callback.state == .stale, let reason = callback.staleReason, input.answer == nil {
                    input.answer = reason
                }
                userInputs.append(input)
            }
        }
        return AssistantPendingCallbacksSnapshot(requests: requests, userInputs: userInputs)
    }

    public func readAgentThreadEvents(thread: AgentThreadID) async throws -> [AssistantEvent] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try await ctx.coordinator.readThread(threadId: thread)
    }

    public func readAgentThreadMirrorSnapshot(
        thread: AgentThreadID
    ) async throws -> AgentThreadMirrorSnapshot {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.coordinator.withMirrorEventSnapshot(threadId: thread) { events in
            AgentThreadMirrorSnapshot(
                events: events,
                eventWatermark: EventBus.shared.currentSeq
            )
        }
    }

    public func rollbackAgentThread(thread: AgentThreadID, toTurnId: String) async throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        try await ctx.coordinator.rollbackThread(threadId: thread, toTurnId: toTurnId)
    }

    public func listAgentThreadCheckpoints(thread: AgentThreadID) throws -> [AgentTurnCheckpointSummary] {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        return try ctx.turnCheckpointRepo.list(threadId: thread)
    }

    public func agentCheckpointDiff(thread: AgentThreadID, checkpointTurnCount: Int, path: String?) throws -> String {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let checkpoint = try ctx.turnCheckpointRepo.get(threadId: thread, checkpointTurnCount: checkpointTurnCount) else {
            throw LayoutError.workspaceNotFound
        }
        if let path {
            return checkpoint.fileDiffs.first(where: { $0.path == path })?.patch ?? ""
        }
        return checkpoint.diffPatch ?? checkpoint.fileDiffs.map(\.patch).joined(separator: "\n")
    }

    public func revertAgentThreadToCheckpoint(thread: AgentThreadID, checkpointTurnCount: Int) async throws -> AgentTurnCheckpointSummary {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let agentThread = try ctx.threadRepo.get(id: thread),
              let workspaceId = agentThread.workspaceId else { throw LayoutError.workspaceNotFound }
        return try await ctx.coordinator.revertThreadToCheckpoint(
            threadId: thread,
            checkpointTurnCount: checkpointTurnCount,
            cwd: try workspaceCwd(workspaceId)
        )
    }

    public func stopAgentRun(thread: AgentThreadID) throws {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        ctx.coordinator.stopRun(threadId: thread)
    }

    public func activeAgentRun(thread: AgentThreadID) throws -> AgentActiveRunSnapshot? {
        guard let ctx = context,
              let runId = ctx.coordinator.activeRunId(threadId: thread),
              let startedAt = try ctx.coordinator.runStartedAt(runId: runId) else {
            return nil
        }
        return AgentActiveRunSnapshot(runId: runId, startedAt: startedAt)
    }

    /// UX-MAC_AGENT-CONTINUE parity for mirror clients: resume a
    /// relaunch-interrupted thread exactly like the mac Continue button
    /// (AgentAppViewModel.continueInterruptedThread) — an empty prompt routes
    /// through the coordinator's recoverableResumeContext path, which picks up
    /// the saved resume cursor without persisting a new user message.
    public func continueAgentRun(thread: AgentThreadID) async throws -> AgentRunID? {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        if let existing = try ctx.threadRepo.get(id: thread), existing.status == .running {
            throw JSONRPCError(code: -32000, message: "Thread already has an active run.")
        }
        let result = try await sendAgentMessage(thread: thread, text: "", provider: nil, model: nil, permissionMode: nil, reasoningEffort: nil)
        return result.runId
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
        let didMarkRead = t.hasUnread
        if didMarkRead {
            t.hasUnread = false
            try ctx.threadRepo.upsert(t)
        }
        // Marking a thread read must NOT select it. Previously this called
        // selectAgentThread, so an iOS client opening an old thread (which
        // auto-marks it read) force-switched every macOS agent tab to that
        // thread (the "iOS bugs macOS" report). Just refresh the rails so the
        // unread badge clears everywhere; selection stays per-surface.
        for s in SurfaceRegistry.shared.all() {
            guard let agent = s as? AgentAppSurface, agent.viewModel.workspaceID == t.workspaceId else { continue }
            agent.viewModel.reloadThreads()
        }
        if didMarkRead {
            publishAgentThreadRead(thread)
        }
    }

    public func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor] {
        let binary = configuredProviderBinary(provider)
        let runner: AgentProviderRunner
        switch provider {
        case .codex:
            runner = CodexRunner(binaryNameOverride: binary)
        case .claude:
            runner = ClaudeRunner(binaryNameOverride: binary)
        case .grok:
            runner = GrokRunner(binaryNameOverride: binary)
        }
        return await runner.listModels()
    }

    public func listAgentProviderSnapshots() async -> [AgentProviderSnapshot] {
        var snapshots: [AgentProviderSnapshot] = []
        let configuredInstances = providerInstanceConfigs()
        if !configuredInstances.isEmpty {
            for instance in configuredInstances {
                let binary = providerBinary(instance: instance) ?? instance.provider.rawValue
                let binaryPath = ProcessLocator.resolve(binary) ?? ""
                let env = providerEnvironment(provider: instance.provider, instanceId: instance.id)
                let capabilities = providerProbeCapabilities(provider: instance.provider, binaryPath: binaryPath, environment: env)
                let models = await listAgentModels(
                    provider: instance.provider,
                    installedVersion: capabilities.version,
                    binaryPath: binaryPath,
                    environment: env
                )
                snapshots.append(AgentProviderSnapshotFactory.snapshot(
                    provider: instance.provider,
                    models: models,
                    binaryPath: binaryPath,
                    version: capabilities.version,
                    authenticated: capabilities.authenticated,
                    accountLabel: capabilities.accountLabel,
                    accountAuthMethod: capabilities.accountAuthMethod,
                    updateState: capabilities.updateState,
                    advisory: capabilities.advisory,
                    slashCommands: capabilities.slashCommands,
                    skills: capabilities.skills,
                    id: instance.id,
                    displayName: instance.displayName,
                    accentColor: instance.accentColor,
                    enabled: instance.enabled ?? true,
                    homePath: instance.homePath,
                    // This snapshot surfaces per-instance ISOLATION keys (HOME/CODEX_HOME/
                    // REMOTE_CODE_INSTANCE). REMOTE_CODE_AGENT_PROVIDER is a constant attribution
                    // tag (same for every instance of a provider), not isolation — exclude it
                    // from the snapshot while it remains in the actual run environment.
                    environmentKeys: env.keys.filter { $0 != "REMOTE_CODE_AGENT_PROVIDER" }.sorted()
                ))
            }
            return snapshots
        }
        for provider in AgentProvider.allCases {
            let binary = configuredProviderBinary(provider) ?? provider.rawValue
            let binaryPath = ProcessLocator.resolve(binary) ?? ""
            let capabilities = providerProbeCapabilities(provider: provider, binaryPath: binaryPath, environment: [:])
            let models = await listAgentModels(
                provider: provider,
                installedVersion: capabilities.version,
                binaryPath: binaryPath,
                environment: [:]
            )
            snapshots.append(AgentProviderSnapshotFactory.snapshot(
                provider: provider,
                models: models,
                binaryPath: binaryPath,
                version: capabilities.version,
                authenticated: capabilities.authenticated,
                accountLabel: capabilities.accountLabel,
                accountAuthMethod: capabilities.accountAuthMethod,
                updateState: capabilities.updateState,
                advisory: capabilities.advisory,
                slashCommands: capabilities.slashCommands,
                skills: capabilities.skills
            ))
        }
        return snapshots
    }

    private func listAgentModels(
        provider: AgentProvider,
        installedVersion: String?,
        binaryPath: String,
        environment: [String: String]
    ) async -> [AgentModelDescriptor] {
        switch provider {
        case .codex:
            if !binaryPath.isEmpty {
                let cwd = context?.state.workspaces.values.first?.cwd ?? NSHomeDirectory()
                let appServerModels = await CodexAppServerModelDiscovery.listModels(binary: binaryPath, cwd: cwd, environment: environment)
                if !appServerModels.isEmpty {
                    return appServerModels
                }
            }
            return await listAgentModels(provider: provider)
        case .claude:
            let apiModels = await AnthropicModelDiscovery.listModels(environment: environment)
            return apiModels.isEmpty ? ClaudeRunner.listModels(installedVersion: installedVersion) : apiModels
        case .grok:
            return GrokRunner.listModels(installedVersion: installedVersion)
        }
    }

    private func providerProbeCapabilities(provider: AgentProvider, binaryPath: String, environment: [String: String]) -> ProviderProbeCapabilities {
        let key = ProviderProbeCacheKey(provider: provider, binaryPath: binaryPath, environment: environment)
        let now = Date()
        if let cached = providerProbeCache[key],
           now.timeIntervalSince(cached.capturedAt) < providerProbeCacheTTL {
            return cached
        }
        let auth = ProviderCLIProbe.authStatus(provider: provider, binaryPath: binaryPath, environment: environment)
        let version = ProviderCLIProbe.versionStatus(binaryPath: binaryPath, environment: environment)
        let capabilities = ProviderProbeCapabilities(
            version: version.version,
            authenticated: auth.authenticated,
            accountLabel: auth.accountLabel,
            accountAuthMethod: auth.accountAuthMethod,
            updateState: version.updateState,
            advisory: version.advisory,
            slashCommands: ProviderCLIProbe.slashCommands(provider: provider, binaryPath: binaryPath, environment: environment),
            skills: providerSkills(provider: provider, environment: environment),
            capturedAt: now
        )
        providerProbeCache[key] = capabilities
        return capabilities
    }

    private func providerSkills(provider: AgentProvider, environment: [String: String]) -> [String] {
        let home: String
        switch provider {
        case .codex:
            home = environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        case .claude:
            home = environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        case .grok:
            home = environment["GROK_HOME"]
                ?? environment["HOME"]
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        }
        let skillsRoot: URL
        switch provider {
        case .codex:
            skillsRoot = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("skills", isDirectory: true)
        case .claude:
            skillsRoot = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".claude/skills", isDirectory: true)
        case .grok:
            skillsRoot = URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".grok/skills", isDirectory: true)
        }
        return Self.discoverSkillNames(in: skillsRoot)
    }

    private static func discoverSkillNames(in root: URL) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let names = entries.compactMap { url -> String? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            let skillFile = url.appendingPathComponent("SKILL.md")
            guard FileManager.default.fileExists(atPath: skillFile.path) else { return nil }
            return url.lastPathComponent
        }
        return Array(Set(names)).sorted()
    }

    public func updateAgentProvider(provider: AgentProvider, providerInstanceId: String?) async throws -> JSONValue {
        let binary = providerBinary(provider: provider, instanceId: providerInstanceId) ?? provider.rawValue
        let binaryPath = ProcessLocator.resolve(binary) ?? ""
        guard !binaryPath.isEmpty else {
            throw JSONRPCError(code: -32040, message: "\(provider.rawValue) CLI binary is unavailable.")
        }
        let env = providerEnvironment(provider: provider, instanceId: providerInstanceId)
        let key = ProviderProbeCacheKey(provider: provider, binaryPath: binaryPath, environment: env)
        guard !providerUpdateLocks.contains(key) else {
            throw JSONRPCError(code: -32041, message: "\(provider.rawValue) update is already running.")
        }
        providerUpdateLocks.insert(key)
        defer { providerUpdateLocks.remove(key) }

        let result = await Task.detached(priority: .utility) {
            ProviderCLIProbe.update(provider: provider, binaryPath: binaryPath, environment: env)
        }.value
        providerProbeCache.removeValue(forKey: key)
        let response = JSONValue.object([
            "provider": .string(provider.rawValue),
            "provider_instance_id": providerInstanceId.map { .string($0) } ?? .null,
            "binary_path": .string(binaryPath),
            "ok": .bool(result.ok),
            "status": .number(Double(result.status)),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr)
        ])
        EventBus.shared.publish(kind: "agent.provider.updated", payload: .object([
            "provider": .string(provider.rawValue),
            "ok": .bool(result.ok),
            "status": .number(Double(result.status))
        ]))
        return response
    }

    public func agentPromptHistory(workspace: WorkspaceID?, limit: Int) throws -> [String] {
        guard let ctx = context else { throw NSError(domain: "rc2", code: 0) }
        // Resolve workspace: prefer explicit param, fall back to the currently
        // selected workspace. If neither is available (no workspace open yet),
        // return an empty list -- do not error, matching the iOS client's
        // empty-history graceful-fallback behaviour.
        let wid = workspace ?? ctx.state.window.selectedWorkspaceID
        guard let wid else { return [] }
        let store = PromptHistoryStore(db: ctx.db)
        let history = store.load(workspaceID: wid)
        // store.load returns oldest-first (chronological append order).
        // iOS expects most-recent-first (newest at index 0).
        let capped = Array(history.suffix(limit))
        return capped.reversed()
    }

    private func providerInstanceConfigs() -> [AgentProviderInstanceConfig] {
        guard let raw = try? context?.settingsRepo.get("agent.provider.instances")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AgentProviderInstanceConfig].self, from: data) else {
            return []
        }
        var seen = Set<String>()
        return decoded.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0.id).inserted }
    }

    private func providerInstanceConfig(id: String?, provider: AgentProvider) -> AgentProviderInstanceConfig? {
        let instances = providerInstanceConfigs().filter { $0.provider == provider }
        guard !instances.isEmpty else { return nil }
        if let id, let exact = instances.first(where: { $0.id == id }) { return exact }
        return instances.first { $0.enabled != false } ?? instances.first
    }

    private func normalizedProviderInstanceId(provider: AgentProvider, requested: String?) -> String {
        providerInstanceConfig(id: requested, provider: provider)?.id ?? provider.rawValue
    }

    private func providerBinary(instance: AgentProviderInstanceConfig) -> String? {
        let configured = instance.binaryPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty { return configured }
        return configuredProviderBinary(instance.provider)
    }

    private func providerBinary(provider: AgentProvider, instanceId: String?) -> String? {
        if let instance = providerInstanceConfig(id: instanceId, provider: provider) {
            return providerBinary(instance: instance)
        }
        return configuredProviderBinary(provider)
    }

    func providerEnvironment(provider: AgentProvider, instanceId: String?) -> [String: String] {
        let instance = providerInstanceConfig(id: instanceId, provider: provider)
        var env = instance?.env ?? [:]
        let home = instance?.homePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !home.isEmpty {
            switch provider {
            case .codex:
                env["CODEX_HOME"] = env["CODEX_HOME"] ?? home
            case .claude:
                env["HOME"] = env["HOME"] ?? home
            case .grok:
                env["HOME"] = env["HOME"] ?? home
            }
        }
        // VITAL for the savings report: tag the agent's environment with the provider so the
        // local `distill` CLI attributes Token Saver command-output savings to claude/codex
        // instead of "unknown". This env flows into request.environment, which every adapter
        // (streaming CLI, SDK-bridge tool-exec env, session) uses for the agent's bash tools
        // that spawn `cmd | distill`. Set unconditionally — even with no instance config.
        env["REMOTE_CODE_AGENT_PROVIDER"] = provider.rawValue
        if let context {
            // Token Saver env (distill hint + Claude-only PostToolUse state). Shared with the
            // session-recovery path so a resumed run keeps piping/speaking distill; see
            // AppContext.tokenSaverAgentEnvironment. Empty when Token Saver is off.
            let tokenSaverEnv = context.tokenSaverAgentEnvironment(provider: provider)
            env.merge(tokenSaverEnv) { _, new in new }
            if !tokenSaverEnv.isEmpty {
                env["PATH"] = Self.providerPathWithManagedWrappers(
                    currentPath: env["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "",
                    managedBin: AgentSkillInstaller.defaultManagedCLIBinDirectory().path
                )
            }
        }
        return env
    }

    static func providerPathWithManagedWrappers(currentPath: String, managedBin: String) -> String {
        let trimmed = managedBin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return currentPath }
        let parts = currentPath
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0 != trimmed }
        return ([trimmed] + parts).joined(separator: ":")
    }

    private func configuredProviderBinary(_ provider: AgentProvider) -> String? {
        let key: String
        switch provider {
        case .codex: key = "cli.codex.path"
        case .claude: key = "cli.claude.path"
        case .grok: key = "cli.grok.path"
        }
        guard let value = try? context?.settingsRepo.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    // MARK: git (socket/CLI parity — same engine the diff panel uses)

    private func workspaceCwd(_ id: WorkspaceID) throws -> String {
        guard let cwd = context?.state.workspaces[id]?.cwd else { throw LayoutError.workspaceNotFound }
        return cwd
    }

    private func fileTabInfo(workspace: WorkspaceID, path: String) throws -> (relativePath: String, title: String) {
        let read = try WorkspaceFileService().read(root: try workspaceCwd(workspace), path: path, maxBytes: 0)
        guard let object = read.objectValue,
              let relativePath = object["relative_path"]?.stringValue else {
            throw JSONRPCError(code: -32602, message: "file path unavailable", data: .string(path))
        }
        let title = (relativePath as NSString).lastPathComponent
        return (relativePath, title.isEmpty ? "Files" : title)
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
    public func gitDeliveryPlan(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryPlan {
        GitDiff.deliveryPlan(in: try workspaceCwd(workspace), copy: copy)
    }
    public func gitDeliver(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryResult {
        GitDiff.deliver(in: try workspaceCwd(workspace), copy: copy, environment: nil)
    }

    public func uploadAgentAttachment(workspace: WorkspaceID, filename: String, mimeType: String?, dataBase64: String) throws -> AgentAttachmentUploadResult {
        guard let data = Data(base64Encoded: dataBase64), !data.isEmpty else {
            throw JSONRPCError(code: -32602, message: "Invalid attachment data.")
        }
        let root = URL(fileURLWithPath: try workspaceCwd(workspace)).standardizedFileURL
        let dir = root.appendingPathComponent(".remotecode", isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = Self.safeAttachmentFilename(filename)
        let fileURL = dir.appendingPathComponent("\(UUID().uuidString)-\(safeName)", isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])
        let ext = fileURL.pathExtension.lowercased()
        let kind: AgentAttachmentKind = ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff", "heic", "webp", "svg", "avif"].contains(ext) ? .image : .file
        return AgentAttachmentUploadResult(path: fileURL.path, displayName: safeName, kind: kind, mimeType: mimeType, sizeBytes: data.count)
    }

    private static func safeAttachmentFilename(_ filename: String) -> String {
        let raw = URL(fileURLWithPath: filename).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = raw.isEmpty ? "attachment" : raw
        let safe = fallback.map { char in
            char.isLetter || char.isNumber || ".-_ ".contains(char) ? char : "-"
        }
        let result = String(safe).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "attachment" : String(result.prefix(120))
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
        guard let context, let terminal = SurfaceRegistry.shared.surface(desc.id) as? TerminalSurface else {
            throw LayoutError.surfaceNotFound
        }
        context.projectScriptRuns.register(workspaceID: workspace, surfaceID: desc.id, name: name)
        EventBus.shared.publish(kind: "project.script_started", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface_id": .string(desc.id.value.uuidString),
            "name": .string(name)
        ]))
        terminal.sendText(Self.projectScriptTerminalInput(command: script.command))
        return desc
    }

    static func projectScriptTerminalInput(command: String) -> String {
        "exec \(command)\n"
    }

    public func projectOpenInEditor(workspace: WorkspaceID) throws -> String {
        try ProjectScripts.openInEditor(cwd: try workspaceCwd(workspace))
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

    /// Persist a per-surface agent thread binding into the surface descriptor
    /// metadata (`selected_thread`), mirroring the browser-URL persistence path.
    /// This is what makes app restart restore each agent tab to its OWN thread
    /// instead of every tab converging on threads.first.
    func persistAgentSelectedThread(surfaceID: SurfaceID, threadID: AgentThreadID?) {
        guard let ctx = context else { return }
        for (wid, var ws) in ctx.state.workspaces {
            let result = updateSurface(in: ws.layout, surfaceID: surfaceID) { descriptor in
                if let threadID {
                    descriptor.metadata["selected_thread"] = threadID.value.uuidString
                } else {
                    descriptor.metadata.removeValue(forKey: "selected_thread")
                }
            }
            guard result.changed else { continue }
            ws.layout = result.node
            ctx.state.workspaces[wid] = ws
            ctx.scheduleSnapshotSave()
            // Mirror the rebind: layout metadata mutations publish no event of
            // their own, so a mounted remote mirror of this surface would never
            // follow the mac-side thread selection. Shape matches the
            // surface.set_color emitter (Dispatcher "surface.updated"); an
            // empty selected_thread clears the binding on the client.
            EventBus.shared.publish(kind: "surface.updated", payload: .object([
                "workspace_id": .string(wid.value.uuidString),
                "id": .string(surfaceID.value.uuidString),
                "surface_id": .string(surfaceID.value.uuidString),
                "metadata": .object(["selected_thread": .string(threadID?.value.uuidString ?? "")])
            ]))
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
            let pane = ws.layout.find(paneID: pid)
            let count = pane?.surfaces.count ?? 0
            return [
                "kind": .string("pane"),
                "id": .string(pid.value.uuidString),
                "surface_count": .number(Double(count)),
                "surface_ids": .array((pane?.surfaces ?? []).map { .string($0.id.value.uuidString) }),
                "selected_surface_id": pane?.selectedSurfaceID.map { .string($0.value.uuidString) } ?? .null,
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
        reconcileSurfaceVisibility()
        publishPaneResized(workspace: workspace, splitID: splitID)
    }

    public func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws {
        try context?.apply(.moveSurfaceToPane(workspace, surface: surface, targetPane: targetPane))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceMoved(workspace: workspace, surface: surface, targetPane: targetPane)
    }

    public func surfaceReorder(workspace: WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int) throws {
        try context?.apply(.reorderSurface(workspace, surface: surface, toPane: toPane, position: position))
        windowController?.refreshFromState()
        reconcileSurfaceVisibility()
        publishSurfaceReordered(workspace: workspace, surface: surface, targetPane: toPane, position: position)
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
        var eventPayload: [String: JSONValue] = ["id": .string(n.id)]
        if let workspaceId { eventPayload["workspace_id"] = .string(workspaceId.value.uuidString) }
        if let category { eventPayload["category"] = .string(category) }
        EventBus.shared.publish(kind: "notification.created", payload: .object(eventPayload))
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
        EventBus.shared.publish(kind: "notification.read", payload: .object(["id": .string(id)]))
    }

    public func notificationDismiss(id: String) throws {
        guard let ctx = context else { return }
        try NotificationRepository(db: ctx.db).dismiss(id: id)
        EventBus.shared.publish(kind: "notification.dismissed", payload: .object(["id": .string(id)]))
    }

    public func privatePushTokenUpdate(pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceID: String?) throws -> JSONValue {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        PrivatePushTargetStore(repo: ctx.settingsRepo).save(
            pushToken: pushToken,
            pushTokenType: pushTokenType,
            liveActivityToken: liveActivityToken,
            deviceId: deviceID
        )
        return .object([
            "ok": .bool(true),
            "push_token_type": .string(pushTokenType)
        ])
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

    public func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue {
        try WorkspaceFileService().createFile(root: try workspaceCwd(workspace), path: path, content: content)
    }

    public func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue {
        try WorkspaceFileService().rename(root: try workspaceCwd(workspace), path: path, newName: newName)
    }

    public func fsWorkspaceDelete(workspace: WorkspaceID, paths: [String]) throws -> JSONValue {
        try WorkspaceFileService().delete(root: try workspaceCwd(workspace), paths: paths)
    }

    public func fsWorkspaceCreateDirectory(workspace: WorkspaceID, path: String) throws -> JSONValue {
        try WorkspaceFileService().createDirectory(root: try workspaceCwd(workspace), path: path)
    }

    public func fsWorkspaceMoveItem(workspace: WorkspaceID, sourcePath: String, destinationDirectoryPath: String) throws -> JSONValue {
        try WorkspaceFileService().moveItem(root: try workspaceCwd(workspace), sourcePath: sourcePath, destinationDirectoryPath: destinationDirectoryPath)
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

    private func makeSurface(type: SurfaceType, title: String?, workspace: WorkspaceID, cwd: String, initialThreadId: AgentThreadID? = nil) -> SurfaceDescriptor {
        let baseTitle = title ?? defaultTitle(for: type)
        let descriptor = SurfaceDescriptor(type: type, title: baseTitle, iconName: type.rawValue, metadata: ["workspace": workspace.value.uuidString, "cwd": cwd])
        let terminalFontSize = context.map { SettingsStore(db: $0.db).load().terminalFontSize } ?? 0
        // build concrete surface object now and register
        do {
            let surface: Surface
            switch type {
            case .terminal:
                let terminal = try TerminalSurface(workspaceID: workspace, title: baseTitle, launch: .shell(cwd: cwd), historyRepo: context?.terminalOutputRepo, settingsRepo: context?.settingsRepo, terminalFontSize: terminalFontSize)
                terminal.onRestartRequested = { [weak self, weak terminal] in
                    guard let self, let terminal else { return }
                    self.restartSurface(terminal.descriptor.id)
                }
                surface = terminal
            case .ssh:
                surface = try SSHSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, router: self, settingsRepo: context?.settingsRepo, terminalFontSize: terminalFontSize)
            case .browser:
                surface = configureBrowserSurface(BrowserSurface(workspaceID: workspace, initialURL: nil, title: baseTitle))
            case .agentApp:
                guard let ctx = context else { return descriptor }
                let agent = AgentAppSurface(workspaceID: workspace, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, queuedMessageRepo: ctx.queuedMessageRepo, pendingCallbackRepo: ctx.providerPendingCallbackRepo, proposedPlanRepo: ctx.proposedPlanRepo, checkpointRepo: ctx.turnCheckpointRepo, promptHistoryStore: PromptHistoryStore(db: ctx.db), customModelStore: AgentCustomModelStore(repo: ctx.settingsRepo), planNotesStore: PlanNotesStore(db: ctx.db), title: baseTitle, initialThreadId: initialThreadId)
                // Per-surface thread binding: persist this surface's selected
                // thread into its descriptor metadata so app restart restores it.
                agent.viewModel.onSelectedThreadChanged = { [weak self, weak agent] threadID in
                    guard let self, let agent else { return }
                    self.persistAgentSelectedThread(surfaceID: agent.descriptor.id, threadID: threadID)
                }
                agent.viewModel.markThreadRead = { [weak self] threadID in
                    guard let self else { throw LayoutError.workspaceNotFound }
                    try self.markAgentThreadRead(thread: threadID)
                }
                // Socket-driven thread mutations (create/rename/delete/read)
                // refresh this already-open surface — fixes the stale-VM gap.
                let token = EventBus.shared.subscribe(since: nil) { [weak agent] ev in
                    guard ev.kind.hasPrefix("agent.thread.") || ev.kind.hasPrefix("agent.message.queue") || ev.kind == "agent.message.queued" else { return }
                    DispatchQueue.main.async {
                        agent?.viewModel.reloadThreads()
                        agent?.viewModel.reloadQueuedMessages()
                    }
                }
                agent.subscriptionToken = AnyHashable(token)
                agent.onClose = { EventBus.shared.unsubscribe(token) }
                agent.viewModel.providerSnapshotLoader = { [weak self] in
                    await self?.listAgentProviderSnapshots() ?? []
                }
                agent.viewModel.refreshProviderSnapshotsInBackground()
                agent.viewModel.providerLaunchConfig = { [weak self] provider, instanceId in
                    (
                        self?.providerBinary(provider: provider, instanceId: instanceId),
                        self?.providerEnvironment(provider: provider, instanceId: instanceId) ?? [:]
                    )
                }
                agent.viewModel.providerRecoveryAction = { [weak self] provider, instanceId in
                    guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
                    let result = try await self.updateAgentProvider(provider: provider, providerInstanceId: instanceId)
                    return result.objectValue?["stdout"]?.stringValue ?? ""
                }
                agent.viewModel.pullRequestThreadPreparer = { [weak self] url, provider, model, permission, reasoning, serviceTier, modelSelection, providerInstanceId in
                    guard let self else { throw JSONRPCError(code: -32000, message: "App router is not ready.") }
                    return try self.prepareAgentThreadForPullRequest(workspace: workspace, url: url, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
                }
                agent.viewModel.onReviewRequested = { [weak self] in
                    _ = try? self?.createSurface(workspace: workspace, type: .rightSidebarTool, paneID: nil, title: "Git")
                }
                // UX-MAC_AGENT-OPEN-SPLIT: clicked file mentions / links open
                // (or reuse) a split panel to the right of this agent surface.
                agent.viewModel.onOpenFileInSplit = { [weak self, weak agent] path in
                    guard let self, let agent else { return }
                    self.openFileInAdjacentSplit(workspace: workspace, sourceSurface: agent.descriptor.id, absolutePath: path)
                }
                agent.viewModel.onOpenURLInSplit = { [weak self, weak agent] url in
                    guard let self, let agent else { return }
                    self.openURLInAdjacentSplit(workspace: workspace, sourceSurface: agent.descriptor.id, url: url)
                }
                agent.viewModel.onRunStateChange = { [weak self] in
                    guard let self else { return }
                    if !self.promoteWorkspaceIfBusy(workspace) {
                        self.windowController?.refreshSurfaceRuntimeState()
                    }
                }
                agent.viewModel.onRunCompleted = { [weak self] in
                    self?.promoteWorkspaceAfterCompletedRun(workspace)
                }
                agent.viewModel.onThreadConfigPersisted = { [weak self] thread in
                    self?.publishAgentThreadUpdated(thread)
                }
                agent.viewModel.onThreadLifecycle = { [weak self] event in
                    self?.publishAgentThreadLifecycle(event)
                }
                agent.viewModel.onPlanNotesPersisted = { [weak self] thread, notes in
                    self?.publishAgentPlanNotesUpdated(thread: thread, notes: notes)
                }
                agent.viewModel.onQueuedMessageEvent = { [weak self] kind, message in
                    self?.publishQueuedMessage(kind: kind, message)
                }
                surface = agent
            case .files:
                surface = FilesSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, router: self, initialState: nil, selectedPath: nil)
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
                    // Start after the current seq so opening Feed does not
                    // replay retained backlog as if it were live activity.
                    let token = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { [weak feed] ev in
                        guard feed != nil else { return }
                        let kind = ev.kind
                        let payload = JSONValue.object(ev.payload.objectValue ?? [:])
                        let summary = Self.summary(of: payload)
                        DispatchQueue.main.async { [weak feed] in
                            feed?.viewModel.receive(seq: ev.seq, kind: kind, title: summary, ts: ev.ts)
                        }
                    }
                    feed.subscriptionToken = AnyHashable(token)
                    // Release the subscription when the surface is torn down so the
                    // panel/VM/NSHostingView don't leak for the app's lifetime.
                    feed.onClose = { EventBus.shared.unsubscribe(token) }
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

    private func makeFilesSurface(workspace: WorkspaceID, cwd: String, title: String, selectedPath: String) -> SurfaceDescriptor {
        let surface = FilesSurface(workspaceID: workspace, cwd: cwd, title: title, router: self, initialState: nil, selectedPath: selectedPath)
        SurfaceRegistry.shared.register(surface)
        return surface.descriptor
    }

    private func defaultTitle(for type: SurfaceType) -> String {
        type.displayLabel.lowercased() == "agent app" ? "Agent App" : type.displayLabel.lowercased()
    }

    private func makeSSHSurface(profile: SSHHostProfile, title: String?, workspace: WorkspaceID, cwd: String) throws -> SurfaceDescriptor {
        let baseTitle = title ?? profile.label
        let terminalFontSize = context.map { SettingsStore(db: $0.db).load().terminalFontSize } ?? 0
        let surface = try SSHSurface(workspaceID: workspace, cwd: cwd, title: baseTitle, router: self, settingsRepo: context?.settingsRepo, terminalFontSize: terminalFontSize)
        surface.connectForRouter(profile)
        SurfaceRegistry.shared.register(surface)
        return surface.descriptor
    }

    private func requireWorkspace(_ workspace: WorkspaceID, in context: AppContext) throws {
        guard context.state.workspaces[workspace] != nil else { throw LayoutError.workspaceNotFound }
    }

    private func sshHostsKey(workspace: WorkspaceID) -> String {
        "ssh.hosts.\(workspace.value.uuidString)"
    }

    private func readSSHHosts(workspace: WorkspaceID, from repo: SettingsRepository) throws -> [SSHHostProfile] {
        guard let raw = try repo.get(sshHostsKey(workspace: workspace)),
              let data = raw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SSHHostProfile].self, from: data)) ?? []
    }

    private func writeSSHHosts(_ hosts: [SSHHostProfile], workspace: WorkspaceID, to repo: SettingsRepository) throws {
        // Persist secrets in the Keychain, not as plaintext JSON on disk.
        let stripped: [SSHHostProfile] = hosts.map { host in
            var h = host
            if let pw = host.password, !pw.isEmpty {
                sshPasswordStore.save(account: host.id.value.uuidString, password: pw)
                h.hasSavedPassword = true
            } else if !host.hasSavedPassword {
                sshPasswordStore.delete(account: host.id.value.uuidString)
            } else {
                h.hasSavedPassword = true
            }
            h.password = nil
            return h
        }
        let data = try JSONEncoder().encode(stripped)
        try repo.set(sshHostsKey(workspace: workspace), String(data: data, encoding: .utf8) ?? "[]")
    }

    private func sshHostWithPasswordForConnection(_ host: SSHHostProfile) -> SSHHostProfile {
        var resolved = host
        if (resolved.password == nil || resolved.password?.isEmpty == true), host.hasSavedPassword {
            resolved.password = sshPasswordStore.load(account: host.id.value.uuidString)
        }
        resolved.hasSavedPassword = resolved.hasSavedPassword || (resolved.password?.isEmpty == false)
        return resolved
    }

    private struct SSHTransferLifecycle {
        let workspaceID: WorkspaceID
        let surfaceID: SurfaceID
        let transferID: String
        let direction: String
        let startedAt: Date
    }

    private func beginSSHTransfer(surface: SurfaceID, direction: String) throws -> SSHTransferLifecycle {
        let workspaceID = try locateSurface(surface).workspaceID
        let lifecycle = SSHTransferLifecycle(
            workspaceID: workspaceID,
            surfaceID: surface,
            transferID: UUID().uuidString,
            direction: direction,
            startedAt: Date()
        )
        EventBus.shared.publish(kind: "ssh.transfer.started", payload: .object([
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surface.value.uuidString),
            "transfer_id": .string(lifecycle.transferID),
            "direction": .string(direction)
        ]))
        return lifecycle
    }

    private func finishSSHTransfer(_ lifecycle: SSHTransferLifecycle, exitCode: Int32?) {
        let succeeded = exitCode == 0
        let durationMilliseconds = max(0, Int64(Date().timeIntervalSince(lifecycle.startedAt) * 1_000))
        EventBus.shared.publish(kind: succeeded ? "ssh.transfer.completed" : "ssh.transfer.failed", payload: .object([
            "workspace_id": .string(lifecycle.workspaceID.value.uuidString),
            "surface_id": .string(lifecycle.surfaceID.value.uuidString),
            "transfer_id": .string(lifecycle.transferID),
            "direction": .string(lifecycle.direction),
            "exit_code": exitCode.map { .number(Double($0)) } ?? .null,
            "duration_ms": .number(Double(durationMilliseconds)),
            "result": .string(succeeded ? "success" : "failure")
        ]))
    }

    private func runSSHTransfer(surface: SurfaceID, upload: Bool, localPath: String, remotePath: String) throws -> JSONValue {
        let kind = upload ? "upload" : "download"
        let lifecycle = try beginSSHTransfer(surface: surface, direction: kind)
        do {
            let (profile, appendOutput) = try sshTransferProfileAndOutput(for: surface)
            let args = upload
                ? SSHCommandBuilder.scpUploadArguments(profile: profile, localPath: localPath, remotePath: remotePath)
                : SSHCommandBuilder.scpDownloadArguments(profile: profile, remotePath: remotePath, localPath: localPath)
            appendOutput("\n[ssh \(kind) started]\n")
            let result = try runCommand(executable: "/usr/bin/scp", arguments: args, password: profile.password)
            if !result.output.isEmpty { appendOutput(result.output) }
            let ok = result.exitCode == 0
            appendOutput("[ssh \(kind) \(ok ? "completed" : "failed")]\n")
            finishSSHTransfer(lifecycle, exitCode: result.exitCode)
            return .object([
                "ok": .bool(ok),
                "exit_code": .number(Double(result.exitCode)),
                "output": .string(result.output)
            ])
        } catch {
            finishSSHTransfer(lifecycle, exitCode: nil)
            throw error
        }
    }

    /// Async transfer: resolves actor state on the main actor, runs the scp
    /// process off the main run loop, then marshals results/output back. Used
    /// by the macOS SSH surface so transfers never freeze the UI.
    func sshTransferUploadAsync(surface: SurfaceID, localPath: String, remotePath: String) async throws -> JSONValue {
        try await runSSHTransferAsync(surface: surface, upload: true, localPath: localPath, remotePath: remotePath)
    }

    func sshTransferDownloadAsync(surface: SurfaceID, remotePath: String, localPath: String) async throws -> JSONValue {
        try await runSSHTransferAsync(surface: surface, upload: false, localPath: localPath, remotePath: remotePath)
    }

    private func runSSHTransferAsync(surface: SurfaceID, upload: Bool, localPath: String, remotePath: String) async throws -> JSONValue {
        let kind = upload ? "upload" : "download"
        let lifecycle = try beginSSHTransfer(surface: surface, direction: kind)
        do {
            let (profile, appendOutput) = try sshTransferProfileAndOutput(for: surface)
            let args = upload
                ? SSHCommandBuilder.scpUploadArguments(profile: profile, localPath: localPath, remotePath: remotePath)
                : SSHCommandBuilder.scpDownloadArguments(profile: profile, remotePath: remotePath, localPath: localPath)
            appendOutput("\n[ssh \(kind) started]\n")
            let password = profile.password
            let commandRunner = sshCommandRunner
            let result = try await Task.detached {
                try commandRunner("/usr/bin/scp", args, password)
            }.value
            if !result.output.isEmpty { appendOutput(result.output) }
            let ok = result.exitCode == 0
            appendOutput("[ssh \(kind) \(ok ? "completed" : "failed")]\n")
            finishSSHTransfer(lifecycle, exitCode: result.exitCode)
            return .object([
                "ok": .bool(ok),
                "exit_code": .number(Double(result.exitCode)),
                "output": .string(result.output)
            ])
        } catch {
            finishSSHTransfer(lifecycle, exitCode: nil)
            throw error
        }
    }

    /// Async remote listing: spawns the remote shell off the main run loop.
    func sshFilesRemoteListAsync(surface: SurfaceID, path: String?) async throws -> JSONValue {
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
        let password = profile.password
        let result = try await Task.detached {
            try Self.runCommandBlocking(executable: "/usr/bin/ssh", arguments: args, password: password)
        }.value
        guard result.exitCode == 0 else {
            throw JSONRPCError(code: -32020, message: "remote list failed", data: .string(result.output))
        }
        return makeRemoteSSHFileListing(output: result.output, requestedPath: requested)
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
        try sshCommandRunner(executable, arguments, password)
    }

    /// Off-actor process execution. Pure local work (no actor state), so it is
    /// safe to invoke from a detached task to keep blocking scp/ssh waits off
    /// the main run loop. The synchronous RPC path keeps calling `runCommand`.
    nonisolated static func runCommandBlocking(executable: String, arguments: [String], password: String?) throws -> (exitCode: Int32, output: String) {
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

    private func paneIDContaining(surface surfaceID: SurfaceID, in node: LayoutNode) -> PaneID? {
        switch node {
        case .pane(let pane):
            return pane.surfaces.contains { $0.id == surfaceID } ? pane.id : nil
        case .split(let split):
            return split.children.compactMap { paneIDContaining(surface: surfaceID, in: $0) }.first
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
        dirtyPaths = filesDirtyPathsAfterMutation(existing: dirtyPaths, path: path, dirty: dirty)
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

    @discardableResult
    public func promoteWorkspaceIfBusy(_ id: WorkspaceID) -> Bool {
        guard isWorkspaceBusy(id) else { return false }
        return promoteWorkspaceForActivity(id)
    }

    @discardableResult
    public func promoteWorkspaceContainingBusySurface(_ surfaceID: SurfaceID) -> Bool {
        guard let located = try? locateSurface(surfaceID),
              isWorkspaceActivitySurface(located.descriptor) else {
            return false
        }
        return promoteWorkspaceForActivity(located.workspaceID)
    }

    @discardableResult
    public func promoteWorkspaceAfterCompletedRun(_ id: WorkspaceID) -> Bool {
        promoteWorkspaceForActivity(id)
    }

    @discardableResult
    private func promoteWorkspaceForActivity(_ id: WorkspaceID) -> Bool {
        guard let ctx = context else { return false }
        let before = ctx.state.window.workspaces
        try? ctx.apply(.promoteWorkspace(id))
        let order = ctx.state.window.workspaces
        guard order != before else { return false }
        EventBus.shared.publish(kind: "workspace.reordered", payload: .object([
            "workspace_id": .string(id.value.uuidString),
            "order": .array(order.map { .string($0.value.uuidString) })
        ]))
        windowController?.refreshFromState()
        return true
    }
}

private extension Optional {
    func orThrow(_ error: Error) throws -> Wrapped {
        guard let value = self else { throw error }
        return value
    }
}

private func terminalInputStatusJSON(_ status: TerminalInputStatus) -> JSONValue {
    .object([
        "status": .string(status.rawValue),
        "accepted": .bool(status == .accepted)
    ])
}

private func terminalHealthJSON(_ health: TerminalRuntimeHealth) -> JSONValue {
    .object([
        "alive": .bool(health.alive),
        "process_alive": .bool(health.processAlive),
        "child_pid": health.childPID.map { .number(Double($0)) } ?? .null,
        "exit_status": health.exitStatus.map { .number(Double($0)) } ?? .null,
        "termination_signal": health.terminationSignal.map { .number(Double($0)) } ?? .null,
        "pty_open": .bool(health.ptyOpen),
        "input_accepting": .bool(health.inputAccepting),
        "terminal_dead_reason": health.terminalDeadReason.map { .string($0) } ?? .null,
        "last_output_at": health.lastOutputAt.map { .number($0.timeIntervalSince1970) } ?? .null,
        "output_partial": .bool(health.outputPartial),
        "output_pending_bytes": .number(Double(health.outputPendingBytes)),
        "history_write_failures": .number(Double(health.historyWriteFailures)),
        "dropped_output_bytes": .number(Double(health.droppedOutputBytes)),
        "rows": .number(Double(health.rows)),
        "cols": .number(Double(health.cols)),
        "render_diagnostics": health.renderDiagnostics.map(terminalRenderDiagnosticsJSON) ?? .null
    ])
}

func terminalSnapshotJSON(_ snapshot: TerminalTextSnapshot) -> JSONValue {
    var fields: [String: JSONValue] = [
        "text": .string(snapshot.text),
        "ansi_text": snapshot.ansiText.map { .string($0) } ?? .null,
        "complete": .bool(snapshot.complete),
        "partial": .bool(!snapshot.complete),
        "source": .string(snapshot.source),
        "timestamp": .number(snapshot.timestamp.timeIntervalSince1970),
        "partial_reason": snapshot.partialReason.map { .string($0) } ?? .null,
        "pending_bytes": .number(Double(snapshot.pendingBytes)),
        "rows": .number(Double(snapshot.rows)),
        "cols": .number(Double(snapshot.cols)),
        "render_diagnostics": snapshot.renderDiagnostics.map(terminalRenderDiagnosticsJSON) ?? .null
    ]
    // Emit null for the default theme so mirrors can clear a previously cached
    // custom palette on the same surface instead of keeping stale colors.
    fields["ansi_palette"] = snapshot.ansiPalette.map { palette in
        .array(palette.map { .string($0) })
    } ?? .null
    return .object(fields)
}

func filesDirtyPathsAfterMutation(existing: [String], path: String, dirty: Bool) -> [String] {
    var next = existing
    if dirty {
        if !next.contains(path) { next.append(path) }
    } else {
        next.removeAll { $0 == path }
    }
    return next
}

private func terminalRenderDiagnosticsJSON(_ diagnostics: TerminalRenderDiagnostics) -> JSONValue {
    .object([
        "logical_visible": .bool(diagnostics.logicalVisible),
        "registry_visible": .bool(diagnostics.registryVisible),
        "draining_hidden_backlog": .bool(diagnostics.drainingHiddenBacklog),
        "window_attached": .bool(diagnostics.windowAttached),
        "parked": .bool(diagnostics.parked),
        "has_usable_bounds": .bool(diagnostics.hasUsableBounds),
        "hidden_ancestor": .bool(diagnostics.hiddenAncestor),
        "can_render": .bool(diagnostics.canRender),
        "blocked_reason": diagnostics.blockedReason.map { .string($0) } ?? .null
    ])
}

/// Keychain-backed storage for SSH passwords so they are never persisted as
/// plaintext in the settings JSON (UX-MAC_SSH-002b). Generic-password items
/// keyed by host profile id. Failures are non-fatal: the in-memory session
/// still works; only durable persistence of the secret is lost.
protocol SSHPasswordStoring {
    func save(account: String, password: String)
    func load(account: String) -> String?
    func delete(account: String)
}

struct KeychainSSHPasswordStore: SSHPasswordStoring {
    private static let service = "com.remotecode.ssh.password"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    func save(account: String, password: String) {
        let data = Data(password.utf8)
        SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
        var add = Self.baseQuery(account: account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    func load(account: String) -> String? {
        var query = Self.baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    func delete(account: String) {
        SecItemDelete(Self.baseQuery(account: account) as CFDictionary)
    }
}
