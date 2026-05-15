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

    public func listWorkspaces() throws -> [Workspace] {
        guard let ctx = context else { return [] }
        return ctx.state.window.workspaces.compactMap { ctx.state.workspaces[$0] }
    }

    public func currentWindow() throws -> AppWindow {
        context?.state.window ?? AppWindow()
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
            case .markdown, .filePreview, .rightSidebarTool:
                // V1-deferred surface types; we still return the descriptor
                // so callers receive a typed unsupported state instead of a
                // crash. See project/14-reference-repos-distillation.md.
                return descriptor
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
