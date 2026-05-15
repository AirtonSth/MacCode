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
                        surface = BrowserSurface(workspaceID: wid, initialURL: nil, title: title)
                    case .agentApp:
                        surface = AgentAppSurface(workspaceID: wid, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, title: title)
                    case .markdown:
                        surface = MarkdownSurface(workspaceID: wid, filePath: desc.metadata["path"], title: title)
                    case .filePreview:
                        surface = FilePreviewSurface(workspaceID: wid, filePath: desc.metadata["path"], title: title)
                    case .rightSidebarTool:
                        surface = DiffPanelSurface(workspaceID: wid, cwd: cwd, title: title)
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
        return ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
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
        guard let id = ctx.state.window.selectedWorkspaceID, let ws = ctx.state.workspaces[id] else { throw LayoutError.workspaceNotFound }
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
        return t
    }

    public func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?) async throws -> AgentRunID {
        guard let ctx = context else { throw LayoutError.workspaceNotFound }
        guard let t = try ctx.threadRepo.get(id: thread) else { throw LayoutError.workspaceNotFound }
        let prov = provider ?? t.provider
        let m = model ?? t.model
        let cwd = ctx.state.workspaces.first { $0.value.id == t.workspaceId }?.value.cwd ?? FileManager.default.currentDirectoryPath
        let req = AgentRunRequest(
            threadId: thread,
            provider: prov,
            model: m,
            cwd: cwd,
            prompt: text,
            providerThreadId: t.providerThreadId
        )
        return try await ctx.coordinator.startRun(req)
    }

    public func stopAgentRun(thread: AgentThreadID) throws {
        // We don't track thread->run map; cancel any active run for that thread by scanning observer state.
        // V1 simplification: rely on UI-tracked currentRunId; CLI stop targets thread id.
        // Best effort: nothing here; the AgentAppViewModel keeps live runs.
    }

    public func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor] {
        let runner: AgentProviderRunner = provider == .codex ? CodexRunner() : ClaudeRunner()
        return await runner.listModels()
    }

    private func browserSurface(_ id: SurfaceID) throws -> BrowserSurface {
        guard let s = SurfaceRegistry.shared.surface(id) as? BrowserSurface else { throw LayoutError.surfaceNotFound }
        return s
    }

    public func browserNavigate(surface: SurfaceID, url: String) throws {
        let b = try browserSurface(surface)
        if !b.navigate(string: url) { throw LayoutError.invalidLayout }
    }
    public func browserBack(surface: SurfaceID) throws { try browserSurface(surface).goBackAction() }
    public func browserForward(surface: SurfaceID) throws { try browserSurface(surface).goForwardAction() }
    public func browserReload(surface: SurfaceID) throws { try browserSurface(surface).reloadAction() }
    public func browserURL(surface: SurfaceID) throws -> String { try browserSurface(surface).currentURL() }

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
        return ws.layout.paneIDs().map { pid in
            let count = (ws.layout.find(paneID: pid)?.surfaces.count) ?? 0
            return [
                "id": .string(pid.value.uuidString),
                "surface_count": .number(Double(count))
            ]
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
                surface = BrowserSurface(workspaceID: workspace, initialURL: nil, title: baseTitle)
            case .agentApp:
                guard let ctx = context else { return descriptor }
                surface = AgentAppSurface(workspaceID: workspace, cwd: cwd, coordinator: ctx.coordinator, threadRepo: ctx.threadRepo, messageRepo: ctx.messageRepo, title: baseTitle)
            case .markdown:
                let path = title // optional: pass file path via title for now
                surface = MarkdownSurface(workspaceID: workspace, filePath: path, title: baseTitle)
            case .filePreview:
                surface = FilePreviewSurface(workspaceID: workspace, filePath: title, title: baseTitle)
            case .rightSidebarTool:
                // V1 right-sidebar tool: diff panel.
                surface = DiffPanelSurface(workspaceID: workspace, cwd: cwd, title: baseTitle)
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
}
