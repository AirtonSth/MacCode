import XCTest
@testable import SocketServer
import CoreModel
import Persistence
import AgentRuntime

final class FakeRouter: CommandRouting {
    var workspaces: [Workspace] = []
    var window = AppWindow()

    func listWorkspaces() throws -> [Workspace] { workspaces }
    func currentWindow() throws -> AppWindow { window }
    func createWorkspace(name: String, cwd: String) throws -> Workspace {
        let ws = Workspace.empty(name: name, cwd: cwd)
        workspaces.append(ws); window.workspaces.append(ws.id); window.selectedWorkspaceID = ws.id
        return ws
    }
    func selectWorkspace(_ id: WorkspaceID) throws { window.selectedWorkspaceID = id }
    func closeWorkspace(_ id: WorkspaceID) throws { workspaces.removeAll { $0.id == id } }
    func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws {}
    func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: type, title: title ?? type.rawValue)
    }
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: surfaceType, title: title ?? surfaceType.rawValue)
    }
    func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func sendText(surface: SurfaceID, text: String) throws {}
    func readText(surface: SurfaceID) throws -> String { "" }
    func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: .agentApp, title: "Agent App")
    }
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] { [] }
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String) throws -> AgentThread {
        AgentThread(workspaceId: workspace, title: title, provider: provider, model: model)
    }
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?) async throws -> AgentRunID { AgentRunID() }
    func stopAgentRun(thread: AgentThreadID) throws {}
    func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "x", label: "X", provider: provider)]
    }
    func browserNavigate(surface: SurfaceID, url: String) throws {}
    func browserBack(surface: SurfaceID) throws {}
    func browserForward(surface: SurfaceID) throws {}
    func browserReload(surface: SurfaceID) throws {}
    func browserURL(surface: SurfaceID) throws -> String { "about:blank" }
    func browserEval(surface: SurfaceID, script: String) async throws -> String { "null" }
    func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String { savePath ?? "/tmp/x.png" }
}

final class DispatcherTests: XCTestCase {
    func test_ping_returnsPong() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.ping", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        XCTAssertEqual(o["pong"], .bool(true))
    }

    func test_capabilities_listsRemoteCode2() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        XCTAssertEqual(o["app"], .string("remotecode2"))
    }

    func test_methodNotFound_returnsError() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "does.not.exist", params: nil))
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, -32601)
    }

    func test_unsupportedDeferredMethod_returnsTypedError() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "browser.click", params: nil))
        XCTAssertEqual(resp.error?.code, -32004)
    }

    func test_createWorkspace_returnsWorkspace() async {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let params: [String: JSONValue] = ["name": .string("foo"), "cwd": .string("/tmp")]
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "workspace.create", params: params))
        XCTAssertNil(resp.error)
        XCTAssertEqual(router.workspaces.count, 1)
    }
}
