import XCTest
@testable import SocketServer
import CoreModel
import Persistence
import AgentRuntime

@MainActor
final class FakeRouter: CommandRouting {
    var workspaces: [Workspace] = []
    var window = AppWindow()

    func listWorkspaces() throws -> [Workspace] { workspaces }
    func currentWindow() throws -> AppWindow { window }
    func listWindows() throws -> [AppWindow] { [window] }
    func createWindow(title: String?) throws -> AppWindow { AppWindow(title: title ?? "w") }
    func focusWindow(_ id: WindowID) throws {}
    func closeWindow(_ id: WindowID) throws {}
    func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws {}
    func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws {}
    func createWorkspace(name: String, cwd: String) throws -> Workspace {
        let ws = Workspace.empty(name: name, cwd: cwd)
        workspaces.append(ws); window.workspaces.append(ws.id); window.selectedWorkspaceID = ws.id
        return ws
    }
    func selectWorkspace(_ id: WorkspaceID) throws { window.selectedWorkspaceID = id }
    func closeWorkspace(_ id: WorkspaceID) throws { workspaces.removeAll { $0.id == id } }
    func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws {}
    func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws {}
    func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws {}
    func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { throw LayoutError.workspaceNotFound }
        if pinned { workspaces[idx].metadata["pinned"] = "true" }
        else { workspaces[idx].metadata.removeValue(forKey: "pinned") }
        let pinnedItems = workspaces.filter { $0.metadata["pinned"] == "true" }
        let normalItems = workspaces.filter { $0.metadata["pinned"] != "true" }
        workspaces = pinnedItems + normalItems
        window.workspaces = workspaces.map(\.id)
    }
    func reorderWorkspace(_ id: WorkspaceID, position: Int) throws {
        guard let idx = workspaces.firstIndex(where: { $0.id == id }) else { throw LayoutError.workspaceNotFound }
        let item = workspaces.remove(at: idx)
        workspaces.insert(item, at: max(0, min(position, workspaces.count)))
        let pinnedItems = workspaces.filter { $0.metadata["pinned"] == "true" }
        let normalItems = workspaces.filter { $0.metadata["pinned"] != "true" }
        workspaces = pinnedItems + normalItems
        window.workspaces = workspaces.map(\.id)
    }
    func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: type, title: title ?? type.rawValue)
    }
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: surfaceType, title: title ?? surfaceType.rawValue)
    }
    func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws {}
    func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws {}
    func sendText(surface: SurfaceID, text: String) throws {}
    func readText(surface: SurfaceID) throws -> String { "" }
    func surfaceHealth(surface: SurfaceID) -> Bool { true }
    func surfaceClearHistory(surface: SurfaceID) {}
    func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: .agentApp, title: "Agent App")
    }
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] { [] }
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String) throws -> AgentThread {
        AgentThread(workspaceId: workspace, title: title, provider: provider, model: model)
    }
    var lastSendPermission: AgentPermissionMode?
    var lastSendReasoning: AgentReasoningEffort?
    var messageStore: [AgentMessage] = []
    func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        if let provider, provider != threadStore[idx].provider {
            threadStore[idx].provider = provider
            threadStore[idx].providerThreadId = nil
        }
        if let model, model != threadStore[idx].model {
            threadStore[idx].model = model
            threadStore[idx].providerThreadId = nil
        }
        return threadStore[idx]
    }
    var selectedThread: AgentThreadID?
    func selectAgentThread(thread: AgentThreadID) throws {
        guard threadStore.contains(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        selectedThread = thread
    }
    func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        Array(messageStore.filter { $0.threadId == thread }.suffix(max(0, limit)))
    }
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?) async throws -> AgentRunID {
        _ = try configureAgentThread(thread: thread, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort)
        lastSendPermission = permissionMode
        lastSendReasoning = reasoningEffort
        return AgentRunID()
    }
    func stopAgentRun(thread: AgentThreadID) throws {}
    var threadStore: [AgentThread] = []
    func deleteAgentThread(thread: AgentThreadID) throws { threadStore.removeAll { $0.id == thread } }
    func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].title = title
        return threadStore[idx]
    }
    func markAgentThreadRead(thread: AgentThreadID) throws {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].hasUnread = false
        selectedThread = thread
    }
    func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor] {
        [AgentModelDescriptor(id: "x", label: "X", provider: provider)]
    }
    var gitCwd = "/tmp"
    func gitStatus(workspace: WorkspaceID) throws -> GitSummary { GitDiff.summary(in: gitCwd) }
    func gitBranches(workspace: WorkspaceID) throws -> GitBranches { GitDiff.branches(in: gitCwd) }
    func gitCheckout(workspace: WorkspaceID, branch: String) throws -> GitActionResult { GitDiff.checkout(in: gitCwd, branch: branch) }
    func gitCreateBranch(workspace: WorkspaceID, name: String) throws -> GitActionResult { GitDiff.createBranch(in: gitCwd, name: name) }
    func gitCommit(workspace: WorkspaceID, message: String) throws -> GitActionResult { GitDiff.commit(in: gitCwd, message: message) }
    func gitLog(workspace: WorkspaceID, limit: Int) throws -> [GitCommit] { GitDiff.log(in: gitCwd, limit: limit) }
    func gitDiff(workspace: WorkspaceID, path: String?, ignoreWhitespace: Bool) throws -> String { GitDiff.diff(in: gitCwd, path: path, ignoreWhitespace: ignoreWhitespace) }
    func gitPush(workspace: WorkspaceID) throws -> GitActionResult { GitDiff.push(in: gitCwd) }
    func gitPullRequestURL(workspace: WorkspaceID) throws -> String? { GitDiff.pullRequestURL(in: gitCwd) }
    var projectCwd = "/tmp"
    func projectScripts(workspace: WorkspaceID) throws -> [ProjectScript] { ProjectScripts.discover(in: projectCwd) }
    func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor {
        guard ProjectScripts.discover(in: projectCwd).contains(where: { $0.name == name }) else { throw JSONRPCError(code: -32602, message: "no such script") }
        return SurfaceDescriptor(type: .terminal, title: "Run: \(name)")
    }
    func projectOpenInEditor(workspace: WorkspaceID) throws -> String { "Finder" }
    func browserNavigate(surface: SurfaceID, url: String) throws {}
    func browserBack(surface: SurfaceID) throws {}
    func browserForward(surface: SurfaceID) throws {}
    func browserReload(surface: SurfaceID) throws {}
    func browserURL(surface: SurfaceID) throws -> String { "about:blank" }
    func browserEval(surface: SurfaceID, script: String) async throws -> String { "null" }
    func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String { savePath ?? "/tmp/x.png" }
    func browserSnapshot(surface: SurfaceID) async throws -> String { "{\"elements\":[]}" }
    func browserAction(surface: SurfaceID, kind: String, ref: String, value: String?) async throws -> String { "{\"ok\":true}" }
    func browserWait(surface: SurfaceID, selector: String, timeoutMs: Int) async throws -> String { "{\"ok\":true}" }
    var notifs: [String] = []
    func notificationCreate(workspaceId: WorkspaceID?, title: String, body: String?, category: String?) throws -> String {
        let id = UUID().uuidString; notifs.append(id); return id
    }
    func notificationList(workspaceId: WorkspaceID?, unreadOnly: Bool) throws -> [[String: JSONValue]] { [] }
    func notificationMarkRead(id: String) throws {}
    func notificationDismiss(id: String) throws {}
    var settings: [String: String] = [:]
    func settingsGet(keys: [String]) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: keys.map { ($0, settings[$0] ?? "") })
    }
    func settingsSet(key: String, value: String) throws { settings[key] = value }
    func paneList(workspace: WorkspaceID) throws -> [[String: JSONValue]] { [] }
    func paneSurfaces(pane: PaneID, workspace: WorkspaceID) throws -> [SurfaceDescriptor] { [] }
    func paneResize(workspace: WorkspaceID, splitID: UUID, ratios: [Double]) throws {}
    func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws {}
    func surfaceReorder(workspace: WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int) throws {}
}

final class DispatcherTests: XCTestCase {
    @MainActor
    func test_ping_returnsPong() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.ping", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        XCTAssertEqual(o["pong"], .bool(true))
    }

    @MainActor
    func test_capabilities_listsRemoteCode2() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        XCTAssertEqual(o["app"], .string("remotecode2"))
    }

    @MainActor
    func test_methodNotFound_returnsError() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "does.not.exist", params: nil))
        XCTAssertNotNil(resp.error)
        XCTAssertEqual(resp.error?.code, -32601)
    }

    @MainActor
    func test_unsupportedDeferredMethod_returnsTypedError() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        // pane.break is still V1-deferred
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "pane.break", params: nil))
        XCTAssertEqual(resp.error?.code, -32004)
    }

    @MainActor
    func test_createWorkspace_returnsWorkspace() async {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let params: [String: JSONValue] = ["name": .string("foo"), "cwd": .string("/tmp")]
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "workspace.create", params: params))
        XCTAssertNil(resp.error)
        XCTAssertEqual(router.workspaces.count, 1)
    }

    private func sh(_ a: [String]) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = a
        let pi = Pipe(); p.standardOutput = pi; p.standardError = pi
        try? p.run(); p.waitUntilExit()
    }

    @MainActor
    func test_gitMethods_routeThroughDispatcher() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-git-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        sh(["git", "init", "-q", "-b", "main", dir])
        sh(["git", "-C", dir, "config", "user.email", "t@t.t"])
        sh(["git", "-C", dir, "config", "user.name", "t"])
        try "hi\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        sh(["git", "-C", dir, "add", "a.txt"])
        sh(["git", "-C", dir, "commit", "-q", "-m", "init"])
        let router = FakeRouter(); router.gitCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)

        let status = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "git.status", params: ["workspace_id": wid]))
        guard case .object(let so)? = status.result else { return XCTFail("git.status must return an object") }
        XCTAssertEqual(so["isGitRepo"], .bool(true), "git.status over the socket must report a real repo")

        let log = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "git.log", params: ["workspace_id": wid]))
        guard case .array(let la)? = log.result else { return XCTFail("git.log must return an array") }
        XCTAssertEqual(la.count, 1, "the one seeded commit must round-trip through the socket")

        let br = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "git.create_branch", params: ["workspace_id": wid, "name": .string("feat")]))
        guard case .object(let bo)? = br.result else { return XCTFail("git.create_branch must return a result") }
        XCTAssertEqual(bo["ok"], .bool(true), "create_branch must report success over the wire")
        XCTAssertEqual(GitDiff.branches(in: dir).current, "feat", "the socket call must actually move HEAD")
    }

    @MainActor
    func test_surfaceCreate_normalizesDocumentedTypeTokens() async throws {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let wid = JSONValue.string(UUID().uuidString)
        let cases: [(String, String)] = [
            ("rightsidebartool", "rightSidebarTool"),
            ("diff", "rightSidebarTool"),
            ("agentapp", "agentApp"),
            ("filepreview", "filePreview")
        ]
        for (token, expected) in cases {
            let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.create", params: ["workspace_id": wid, "type": .string(token)]))
            XCTAssertNil(r.error, "documented CLI token '\(token)' must be accepted by surface.create")
            guard case .object(let o)? = r.result, case .string(let ty)? = o["type"] else {
                return XCTFail("surface.create must return a typed descriptor for '\(token)'")
            }
            XCTAssertEqual(ty, expected, "'\(token)' must normalize to SurfaceType.\(expected)")
        }
    }

    @MainActor
    func test_gitStatus_countsEncodeAsNumbersNotBooleans() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-num-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        sh(["git", "init", "-q", "-b", "main", dir])
        sh(["git", "-C", dir, "config", "user.email", "t@t.t"])
        sh(["git", "-C", dir, "config", "user.name", "t"])
        try "l1\n".write(toFile: dir + "/n.txt", atomically: true, encoding: .utf8)
        sh(["git", "-C", dir, "add", "n.txt"])
        sh(["git", "-C", dir, "commit", "-q", "-m", "seed"])
        try "l1\nl2\n".write(toFile: dir + "/n.txt", atomically: true, encoding: .utf8) // +1 line
        let router = FakeRouter(); router.gitCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "git.status", params: ["workspace_id": .string(UUID().uuidString)]))
        guard case .object(let o)? = resp.result else { return XCTFail("git.status must return an object") }
        // Regression: an integer count of 1 must stay a JSON number, never
        // collapse to `true` (NSNumber/Bool bridging bug in JSONValue.from).
        if case .bool = (o["totalAdditions"] ?? .null) {
            XCTFail("totalAdditions encoded as a bool — integer collapsed via NSNumber bridging")
        }
        guard case .number(let n)? = o["totalAdditions"] else {
            return XCTFail("totalAdditions must be a number, got \(String(describing: o["totalAdditions"]))")
        }
        XCTAssertEqual(n, 1, "one added line must serialize as the number 1 over the socket")
    }

    @MainActor
    func test_agentThreadRenameAndDelete_overSocket() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "old", provider: .codex, model: "m")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let tidParam = JSONValue.string(t.id.value.uuidString)

        let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.rename", params: ["thread_id": tidParam, "title": .string("new name")]))
        guard case .object(let o)? = r.result else { return XCTFail("rename must echo the thread") }
        XCTAssertEqual(o["title"], .string("new name"), "rename must persist and echo the new title")

        let del = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.delete", params: ["thread_id": tidParam]))
        XCTAssertEqual(del.result, .bool(true))
        XCTAssertTrue(router.threadStore.isEmpty, "delete over the socket must remove the thread")

        let missing = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.thread.rename", params: ["thread_id": tidParam, "title": .string("x")]))
        XCTAssertNotNil(missing.error, "renaming a deleted thread must fail loudly, not silently succeed")
    }

    @MainActor
    func test_projectScripts_overSocket() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-ps-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{"scripts":{"lint":"eslint .","build":"tsc"}}"#
            .write(toFile: dir + "/package.json", atomically: true, encoding: .utf8)
        let router = FakeRouter(); router.projectCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)
        let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "project.scripts", params: ["workspace_id": wid]))
        guard case .array(let arr)? = r.result else { return XCTFail("project.scripts must return an array") }
        XCTAssertEqual(arr.count, 2, "both package.json scripts must round-trip the socket")
        let ok = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "project.run_script", params: ["workspace_id": wid, "name": .string("build")]))
        XCTAssertNil(ok.error, "running a known script must succeed")
        let bad = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "project.run_script", params: ["workspace_id": wid, "name": .string("nope")]))
        XCTAssertNotNil(bad.error, "running an unknown script must fail loudly")
    }

    @MainActor
    func test_agentThreadMarkRead_overSocket() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "unread", provider: .codex, model: "m")
        t.hasUnread = true
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let r = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.mark_read", params: ["thread_id": .string(t.id.value.uuidString)]))
        XCTAssertEqual(r.result, .bool(true))
        XCTAssertEqual(router.threadStore.first?.hasUnread, false,
                       "mark_read over the socket must clear the unread flag")
    }

    @MainActor
    func test_agentThreadConfigureAndSendCarryModelPermissionAndReasoning() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "cfg", provider: .codex, model: "gpt-5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let tid = JSONValue.string(t.id.value.uuidString)

        let cfg = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.configure", params: [
            "thread_id": tid,
            "provider": .string("claude"),
            "model": .string("claude-sonnet-4-6"),
            "permission_mode": .string("full_access"),
            "reasoning_effort": .string("high")
        ]))
        guard case .object(let cfgObj)? = cfg.result else { return XCTFail("configure must echo the updated host thread") }
        XCTAssertEqual(cfgObj["provider"], .string("claude"))
        XCTAssertEqual(cfgObj["model"], .string("claude-sonnet-4-6"))

        let send = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: [
            "thread_id": tid,
            "text": .string("run on host"),
            "provider": .string("codex"),
            "model": .string("gpt-5.5"),
            "permission_mode": .string("auto_accept_edits"),
            "reasoning_effort": .string("xhigh")
        ]))
        guard case .object(let sendObj)? = send.result else { return XCTFail("send must return host run object") }
        XCTAssertNotNil(sendObj["run_id"]?.stringValue, "send must return host run id")
        XCTAssertEqual(router.threadStore.first?.provider, .codex)
        XCTAssertEqual(router.threadStore.first?.model, "gpt-5.5")
        XCTAssertEqual(router.lastSendPermission, .autoAcceptEdits)
        XCTAssertEqual(router.lastSendReasoning, .xhigh)
    }

    @MainActor
    func test_agentMessageListReturnsPersistedHistoryForSelectedThread() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "history", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        router.messageStore = [
            AgentMessage(threadId: t.id, role: .user, content: "old prompt"),
            AgentMessage(threadId: t.id, role: .assistant, content: "old answer")
        ]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(20)
        ]))

        guard case .array(let messages)? = resp.result,
              case .object(let first)? = messages.first,
              case .object(let last)? = messages.last else { return XCTFail("message list must expose persisted macOS thread history") }
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(first["role"], .string("user"))
        XCTAssertEqual(first["content"], .string("old prompt"))
        XCTAssertEqual(last["role"], .string("assistant"))
        XCTAssertEqual(last["content"], .string("old answer"))
    }

    @MainActor
    func test_agentThreadSelectRoutesSelectionToMacSurface() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "load prior", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.select", params: [
            "thread_id": .string(t.id.value.uuidString)
        ]))

        XCTAssertEqual(resp.result, .bool(true))
        XCTAssertEqual(router.selectedThread, t.id, "selecting an existing iOS thread must select the same macOS Agent App thread")
    }

    @MainActor
    func test_agentThreadConfigureClearsProviderSessionWhenProviderOrModelChanges() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "switch provider", provider: .claude, model: "claude-sonnet-4-6")
        t.providerThreadId = "claude-session"
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.configure", params: [
            "thread_id": .string(t.id.value.uuidString),
            "provider": .string("codex"),
            "model": .string("gpt-5.5")
        ]))

        XCTAssertNil(resp.error)
        XCTAssertNil(router.threadStore.first?.providerThreadId, "changing provider/model must not resume an incompatible provider session")
    }
}
