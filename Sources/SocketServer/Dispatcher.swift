import Foundation
import CoreModel
import Persistence
import AgentRuntime

public protocol CommandRouting: AnyObject {
    // window/workspace/pane/surface
    func listWorkspaces() throws -> [Workspace]
    func currentWindow() throws -> AppWindow
    func createWorkspace(name: String, cwd: String) throws -> Workspace
    func selectWorkspace(_ id: WorkspaceID) throws
    func closeWorkspace(_ id: WorkspaceID) throws
    func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws
    func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor
    func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws
    func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws
    func sendText(surface: SurfaceID, text: String) throws
    func readText(surface: SurfaceID) throws -> String
    // agent
    func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread]
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String) throws -> AgentThread
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?) async throws -> AgentRunID
    func stopAgentRun(thread: AgentThreadID) throws
    func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor]
}

public final class JSONRPCDispatcher {
    let router: CommandRouting
    public init(router: CommandRouting) { self.router = router }

    public func dispatch(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        let id = req.id
        let params = req.params ?? [:]
        do {
            switch req.method {
            case "system.ping":
                return .init(id: id, result: .object(["pong": .bool(true), "ts": .number(Date().timeIntervalSince1970)]))
            case "system.capabilities":
                return .init(id: id, result: .object([
                    "app": .string("remotecode2"),
                    "api_version": .string("2"),
                    "surface_types": .array([.string("terminal"), .string("browser"), .string("agentApp")]),
                    "agent": .object([
                        "providers": .array([.string("codex"), .string("claude")]),
                        "supports_stream_events": .bool(true),
                        "supports_resume": .bool(true)
                    ])
                ]))
            case "system.identify":
                return .init(id: id, result: .object([
                    "app": .string("remotecode2"),
                    "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))
                ]))
            case "workspace.list":
                let ws = try router.listWorkspaces()
                return .init(id: id, result: encode(ws))
            case "workspace.current":
                let w = try router.currentWindow()
                return .init(id: id, result: encode(w))
            case "workspace.create":
                let name = params["name"]?.stringValue ?? "workspace"
                let cwd = params["cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath
                let ws = try router.createWorkspace(name: name, cwd: cwd)
                return .init(id: id, result: encode(ws))
            case "workspace.select":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try router.selectWorkspace(wid)
                return .init(id: id, result: .bool(true))
            case "workspace.close":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try router.closeWorkspace(wid)
                return .init(id: id, result: .bool(true))
            case "workspace.rename":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let name = params["name"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.renameWorkspace(wid, name)
                return .init(id: id, result: .bool(true))
            case "surface.create":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let tStr = params["type"]?.stringValue,
                      let type = SurfaceType(rawValue: normalizeSurfaceTypeString(tStr)) else { throw JSONRPCError.invalidParams }
                let pid: PaneID? = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let title = params["title"]?.stringValue
                let s = try router.createSurface(workspace: wid, type: type, paneID: pid, title: title)
                return .init(id: id, result: encode(s))
            case "surface.split":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init),
                      let dirStr = params["direction"]?.stringValue,
                      let dir = SplitDirection(rawValue: dirStr),
                      let tStr = params["type"]?.stringValue,
                      let type = SurfaceType(rawValue: normalizeSurfaceTypeString(tStr)) else { throw JSONRPCError.invalidParams }
                let title = params["title"]?.stringValue
                let s = try router.splitPane(workspace: wid, paneID: pid, direction: dir, surfaceType: type, title: title)
                return .init(id: id, result: encode(s))
            case "surface.close":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.closeSurface(workspace: wid, surface: sid)
                return .init(id: id, result: .bool(true))
            case "surface.focus":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.focusSurface(workspace: wid, surface: sid)
                return .init(id: id, result: .bool(true))
            case "surface.send_text":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.sendText(surface: sid, text: text)
                return .init(id: id, result: .bool(true))
            case "surface.read_text":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let text = try router.readText(surface: sid)
                return .init(id: id, result: .string(text))
            case "agent.open":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let s = try router.openAgentApp(workspace: wid)
                return .init(id: id, result: encode(s))
            case "agent.thread.list":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let threads = try router.listAgentThreads(workspace: wid)
                return .init(id: id, result: encode(threads))
            case "agent.thread.create":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let title = params["title"]?.stringValue ?? "New thread"
                let provider = AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex
                let model = params["model"]?.stringValue ?? "fake-model"
                let t = try router.createAgentThread(workspace: wid, title: title, provider: provider, model: model)
                return .init(id: id, result: encode(t))
            case "agent.message.send":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let provider = params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = params["model"]?.stringValue
                let runId = try await router.sendAgentMessage(thread: tid, text: text, provider: provider, model: model)
                return .init(id: id, result: .object(["run_id": .string(runId.value.uuidString)]))
            case "agent.run.stop":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                try router.stopAgentRun(thread: tid)
                return .init(id: id, result: .bool(true))
            case "agent.models.list":
                let provider = AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex
                let models = await router.listAgentModels(provider: provider)
                return .init(id: id, result: encode(models))
            case "agent.state.current":
                let w = try router.currentWindow()
                return .init(id: id, result: .object([
                    "selected_workspace_id": w.selectedWorkspaceID.map { .string($0.value.uuidString) } ?? .null
                ]))
            // V1 deferred families return a typed unsupported error.
            case "window.list", "window.create", "window.focus", "window.close",
                 "pane.list", "pane.resize", "pane.swap", "pane.break", "pane.join",
                 "browser.eval", "browser.snapshot", "browser.click", "browser.fill", "browser.type",
                 "browser.screenshot", "browser.navigate", "browser.back", "browser.forward", "browser.reload", "browser.wait",
                 "notification.create", "notification.list", "notification.dismiss":
                throw JSONRPCError.notSupported(req.method)
            default:
                throw JSONRPCError.methodNotFound
            }
        } catch let e as JSONRPCError {
            return .init(id: id, error: e)
        } catch {
            return .init(id: id, error: JSONRPCError(code: -32000, message: String(describing: error)))
        }
    }

    private func normalizeSurfaceTypeString(_ s: String) -> String {
        switch s {
        case "agent", "agent_app", "agentapp", "agentApp": return "agentApp"
        default: return s
        }
    }

    private func encode<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue.from(any)
    }
}
