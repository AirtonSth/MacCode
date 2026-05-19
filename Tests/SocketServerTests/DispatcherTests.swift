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
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread] {
        let list = workspace.map { wid in threadStore.filter { $0.workspaceId == wid } } ?? threadStore
        return list.sorted {
            if $0.pinned != $1.pinned { return $0.pinned && !$1.pinned }
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.updatedAt > $1.updatedAt
        }
    }
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort) throws -> AgentThread {
        let thread = AgentThread(workspaceId: workspace, title: title, provider: provider, model: model,
                                 permissionMode: permissionMode, reasoningEffort: reasoningEffort)
        threadStore.append(thread)
        return thread
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
        if let permissionMode { threadStore[idx].permissionMode = permissionMode }
        if let reasoningEffort { threadStore[idx].reasoningEffort = reasoningEffort }
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
        lastSendPermission = threadStore.first(where: { $0.id == thread })?.permissionMode
        lastSendReasoning = threadStore.first(where: { $0.id == thread })?.reasoningEffort
        return AgentRunID()
    }
    func stopAgentRun(thread: AgentThreadID) throws {}
    var threadStore: [AgentThread] = []
    func deleteAgentThread(thread: AgentThreadID) throws { threadStore.removeAll { $0.id == thread } }
    func deleteAgentThreads(_ threads: [AgentThreadID]) throws {
        threadStore.removeAll { threads.contains($0.id) }
    }
    func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].pinned = pinned
        try normalizeThreadOrder(workspaceId: threadStore[idx].workspaceId)
        return threadStore[idx]
    }
    func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].color = color.isEmpty ? nil : color
        return threadStore[idx]
    }
    func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread] {
        guard let current = threadStore.first(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        let wid = current.workspaceId
        var ordered = try listAgentThreads(workspace: wid)
        guard let idx = ordered.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        let item = ordered.remove(at: idx)
        ordered.insert(item, at: max(0, min(position, ordered.count)))
        for (sortOrder, item) in ordered.enumerated() {
            guard let storeIdx = threadStore.firstIndex(where: { $0.id == item.id }) else { continue }
            threadStore[storeIdx].sortOrder = sortOrder
        }
        return try listAgentThreads(workspace: wid)
    }
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
    private func normalizeThreadOrder(workspaceId: WorkspaceID?) throws {
        let ordered = try listAgentThreads(workspace: workspaceId)
        for (sortOrder, thread) in ordered.enumerated() {
            guard let idx = threadStore.firstIndex(where: { $0.id == thread.id }) else { continue }
            threadStore[idx].sortOrder = sortOrder
        }
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
    var browserURLString = "about:blank"
    func browserMirrorURL(surface: SurfaceID) throws -> [String: JSONValue] {
        ["url": .string(browserURLString), "is_file": .bool(browserURLString.hasPrefix("file://"))]
    }
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
    var filesState: [String: JSONValue] = [:]
    func filesStateGet(surface: SurfaceID) throws -> JSONValue {
        .object(filesState.isEmpty ? [
            "surface_id": .string(surface.value.uuidString),
            "revision": .number(0),
            "dirty_paths": .array([])
        ] : filesState)
    }
    func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue {
        for (key, value) in patch { filesState[key] = value }
        filesState["surface_id"] = .string(surface.value.uuidString)
        filesState["revision"] = .number(Double((filesState["revision"]?.intValue ?? 0) + 1))
        return .object(filesState)
    }
    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue { try WorkspaceFileService().list(root: projectCwd, path: path) }
    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue { try WorkspaceFileService().read(root: projectCwd, path: path, maxBytes: maxBytes) }
    func fsWorkspacePreviewURL(workspace: WorkspaceID, path: String) throws -> JSONValue { try WorkspaceFileService().previewURL(root: projectCwd, path: path) }
    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue { try FileEditSessionStore.shared.open(surfaceID: surface, workspaceID: WorkspaceID(), root: projectCwd, path: path) }
    func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue {
        try FileEditSessionStore.shared.applyPatch(sessionID: sessionID, baseDraftRevision: baseDraftRevision, rangeLocation: rangeLocation, rangeLength: rangeLength, replacement: replacement, deviceID: deviceID)
    }
    func filesEditSave(sessionID: String) throws -> JSONValue { try FileEditSessionStore.shared.save(sessionID: sessionID) }
    func filesEditDiscard(sessionID: String) throws -> JSONValue { try FileEditSessionStore.shared.discard(sessionID: sessionID) }
    func filesEditClose(sessionID: String) throws -> JSONValue { try FileEditSessionStore.shared.close(sessionID: sessionID) }
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
    func test_capabilities_listsRemoteCode() async {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))
        guard case .object(let o) = resp.result! else { return XCTFail() }
        XCTAssertEqual(o["app"], .string("remotecode"))
    }

    @MainActor
    func test_capabilitiesAdvertiseFilesSurfaceForMirrorParity() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))

        guard case .object(let o)? = resp.result,
              case .array(let surfaceTypes)? = o["surface_types"] else {
            return XCTFail("capabilities must expose surface_types so iOS can render the same add-surface menu as macOS")
        }
        XCTAssertTrue(surfaceTypes.contains(.string("files")),
                      "Files must be advertised by the host; otherwise iOS cannot discover or create the mirrored Files tab")
    }

    @MainActor
    func test_surfaceCreateAcceptsFilesType() async throws {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let wid = JSONValue.string(UUID().uuidString)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.create", params: [
            "workspace_id": wid,
            "type": .string("files")
        ]))

        XCTAssertNil(resp.error, "iOS must be able to create a Files tab through the same surface.create RPC as macOS")
        guard case .object(let body)? = resp.result else { return XCTFail("surface.create must return the created Files descriptor") }
        XCTAssertEqual(body["type"], .string("files"))
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

    @MainActor
    func test_browserMirrorURLRoundTripsCurrentHostURL() async {
        let router = FakeRouter()
        router.browserURLString = "http://localhost:3000/demo"
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "browser.mirror_url.get", params: [
            "id": .string(UUID().uuidString)
        ]))

        guard case .object(let body)? = resp.result else { return XCTFail("mirror URL must return render metadata") }
        XCTAssertEqual(body["url"], .string("http://localhost:3000/demo"),
                       "iOS needs the exact host browser URL before it can map localhost to the paired Mac")
        XCTAssertEqual(body["is_file"], .bool(false))
    }

    @MainActor
    func test_agentThreadPinReorderAndBulkDeleteRoundTripThroughDispatcher() async throws {
        let wid = WorkspaceID()
        var a = AgentThread(workspaceId: wid, title: "A", provider: .codex, model: "gpt-5", sortOrder: 0)
        var b = AgentThread(workspaceId: wid, title: "B", provider: .codex, model: "gpt-5", sortOrder: 1)
        let c = AgentThread(workspaceId: wid, title: "C", provider: .codex, model: "gpt-5", sortOrder: 2)
        let router = FakeRouter()
        router.threadStore = [a, b, c]
        let d = JSONRPCDispatcher(router: router)

        let pin = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.set_pinned", params: [
            "thread_id": .string(b.id.value.uuidString),
            "pinned": .bool(true),
        ]))
        XCTAssertNil(pin.error, "pinning a thread must be available over RPC so macOS and iOS can share the same UX")
        b = try XCTUnwrap(router.threadStore.first { $0.id == b.id })
        XCTAssertTrue(b.pinned)
        XCTAssertEqual(try router.listAgentThreads(workspace: wid).map(\.id), [b.id, a.id, c.id],
                       "pinned threads must sort ahead of normal threads")

        let reorder = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.reorder", params: [
            "thread_id": .string(c.id.value.uuidString),
            "position": .number(1),
        ]))
        XCTAssertNil(reorder.error, "drag reorder must be available over RPC for host and mirror parity")
        XCTAssertEqual(try router.listAgentThreads(workspace: wid).map(\.id), [b.id, c.id, a.id])

        let delete = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.thread.delete_many", params: [
            "thread_ids": .array([.string(b.id.value.uuidString), .string(c.id.value.uuidString)]),
        ]))
        XCTAssertNil(delete.error, "shift-select delete must use one bulk delete command instead of racing multiple deletes")
        XCTAssertEqual(router.threadStore.map(\.id), [a.id])
        a = try XCTUnwrap(router.threadStore.first)
        XCTAssertEqual(a.title, "A")
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
        XCTAssertEqual(cfgObj["permissionMode"], .string("full_access"))
        XCTAssertEqual(cfgObj["reasoningEffort"], .string("high"))

        let send = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: [
            "thread_id": tid,
            "text": .string("run on host")
        ]))
        guard case .object(let sendObj)? = send.result else { return XCTFail("send must return host run object") }
        XCTAssertNotNil(sendObj["run_id"]?.stringValue, "send must return host run id")
        XCTAssertEqual(router.threadStore.first?.provider, .claude)
        XCTAssertEqual(router.threadStore.first?.model, "claude-sonnet-4-6")
        XCTAssertEqual(router.lastSendPermission, .fullAccess,
                       "send must use the thread's persisted permission mode when no override is sent")
        XCTAssertEqual(router.lastSendReasoning, .high,
                       "send must use the thread's persisted reasoning effort when no override is sent")
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
    func test_agentThreadListKeepsFullTitleAndAddsDisplayTitleForMirrors() async throws {
        let router = FakeRouter()
        let fullTitle = "git add commit and push all repos here with this long exact wording"
        let thread = AgentThread(workspaceId: nil, title: fullTitle, provider: .claude, model: "fake-model")
        router.threadStore = [thread]
        router.messageStore = [AgentMessage(threadId: thread.id, role: .user, content: "start")]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.list", params: nil))

        guard case .array(let threads)? = resp.result,
              case .object(let first)? = threads.first else { return XCTFail("thread list must return encoded threads") }
        XCTAssertEqual(first["title"], .string(fullTitle),
                       "host APIs must keep the full persisted title for macOS and iOS")
        XCTAssertEqual(first["displayTitle"], .string("git add commit and push all ..."))
        XCTAssertEqual(first["display_title"], .string("git add commit and push all ..."))
        XCTAssertEqual(first["providerLocked"], .bool(true),
                       "iOS mirrors must know when to hide the source picker for existing threads")
        XCTAssertEqual(first["provider_locked"], .bool(true))
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
