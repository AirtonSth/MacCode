import Foundation
import CoreModel
import Persistence
import AgentRuntime

@MainActor
public protocol CommandRouting: AnyObject {
    // window/workspace/pane/surface
    func listWorkspaces() throws -> [Workspace]
    func currentWindow() throws -> AppWindow
    func listWindows() throws -> [AppWindow]
    func createWindow(title: String?) throws -> AppWindow
    func focusWindow(_ id: WindowID) throws
    func closeWindow(_ id: WindowID) throws
    func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws
    func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws
    func createWorkspace(name: String, cwd: String) throws -> Workspace
    func selectWorkspace(_ id: WorkspaceID) throws
    func closeWorkspace(_ id: WorkspaceID) throws
    func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws
    func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws
    func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws
    func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws
    func reorderWorkspace(_ id: WorkspaceID, position: Int) throws
    func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor
    func splitSurface(workspace: WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection) throws
    func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws
    func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws
    func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws
    func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws
    func sendText(surface: SurfaceID, text: String) throws
    func readText(surface: SurfaceID) throws -> String
    func readTerminalHistory(surface: SurfaceID, beforeChunkID: Int64?, maxBytes: Int) throws -> TerminalOutputWindow
    func surfaceHealth(surface: SurfaceID) -> Bool
    func surfaceClearHistory(surface: SurfaceID)
    // SSH
    func sshHostList() throws -> [SSHHostProfile]
    func sshHostUpsert(_ profile: SSHHostProfile) throws -> SSHHostProfile
    func sshHostDelete(_ id: SSHHostID) throws
    func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor
    func sshDisconnect(surface: SurfaceID) throws
    func sshTransferUpload(surface: SurfaceID, localPath: String, remotePath: String) throws -> JSONValue
    func sshTransferDownload(surface: SurfaceID, remotePath: String, localPath: String) throws -> JSONValue
    func sshFilesLocalList(path: String?) throws -> JSONValue
    func sshFilesRemoteList(surface: SurfaceID, path: String?) throws -> JSONValue
    // agent
    func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread]
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort) throws -> AgentThread
    func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?) throws -> AgentThread
    func selectAgentThread(thread: AgentThreadID) throws
    func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage]
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?) async throws -> AgentRunID
    func stopAgentRun(thread: AgentThreadID) throws
    func deleteAgentThread(thread: AgentThreadID) throws
    func deleteAgentThreads(_ threads: [AgentThreadID]) throws
    func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread
    func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread
    func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread
    func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread]
    func markAgentThreadRead(thread: AgentThreadID) throws
    func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor]
    // git
    func gitStatus(workspace: WorkspaceID) throws -> GitSummary
    func gitBranches(workspace: WorkspaceID) throws -> GitBranches
    func gitCheckout(workspace: WorkspaceID, branch: String) throws -> GitActionResult
    func gitCreateBranch(workspace: WorkspaceID, name: String) throws -> GitActionResult
    func gitCommit(workspace: WorkspaceID, message: String) throws -> GitActionResult
    func gitLog(workspace: WorkspaceID, limit: Int) throws -> [GitCommit]
    func gitDiff(workspace: WorkspaceID, path: String?, ignoreWhitespace: Bool) throws -> String
    func gitPush(workspace: WorkspaceID) throws -> GitActionResult
    func gitPullRequestURL(workspace: WorkspaceID) throws -> String?
    // project scripts / open-in-editor (RC2-069)
    func projectScripts(workspace: WorkspaceID) throws -> [ProjectScript]
    func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor
    func projectOpenInEditor(workspace: WorkspaceID) throws -> String
    // browser P0
    func browserNavigate(surface: SurfaceID, url: String) throws
    func browserBack(surface: SurfaceID) throws
    func browserForward(surface: SurfaceID) throws
    func browserReload(surface: SurfaceID) throws
    func browserURL(surface: SurfaceID) throws -> String
    func browserMirrorURL(surface: SurfaceID) throws -> [String: JSONValue]
    func browserEval(surface: SurfaceID, script: String) async throws -> String
    func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String
    func browserSnapshot(surface: SurfaceID) async throws -> String
    func browserAction(surface: SurfaceID, kind: String, ref: String, value: String?) async throws -> String
    func browserWait(surface: SurfaceID, selector: String, timeoutMs: Int) async throws -> String
    // pane / window
    func paneList(workspace: WorkspaceID) throws -> [[String: JSONValue]]
    func paneSurfaces(pane: PaneID, workspace: WorkspaceID) throws -> [SurfaceDescriptor]
    func paneResize(workspace: WorkspaceID, splitID: UUID, ratios: [Double]) throws
    func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws
    func surfaceReorder(workspace: WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int) throws
    // notifications
    func notificationCreate(workspaceId: WorkspaceID?, title: String, body: String?, category: String?) throws -> String
    func notificationList(workspaceId: WorkspaceID?, unreadOnly: Bool) throws -> [[String: JSONValue]]
    func notificationMarkRead(id: String) throws
    func notificationDismiss(id: String) throws
    // settings
    func settingsGet(keys: [String]) throws -> [String: String]
    func settingsSet(key: String, value: String) throws
    // workspace Files surface
    func filesStateGet(surface: SurfaceID) throws -> JSONValue
    func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue
    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue
    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue
    func fsWorkspacePreviewURL(workspace: WorkspaceID, path: String) throws -> JSONValue
    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue
    func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue
    func filesEditSave(sessionID: String) throws -> JSONValue
    func filesEditDiscard(sessionID: String) throws -> JSONValue
    func filesEditClose(sessionID: String) throws -> JSONValue
}

@MainActor
public final class JSONRPCDispatcher {
    let router: CommandRouting
    public init(router: CommandRouting) { self.router = router }

    /// Translate symbolic key names (cmux v2 contract) into raw bytes
    /// the PTY-backed terminal understands. Anything we don't recognize
    /// passes through verbatim.
    private func encodeKey(_ key: String) -> String {
        switch key {
        case "enter", "return", "Enter", "Return": return "\r"
        case "tab", "Tab": return "\t"
        case "escape", "Escape", "esc", "Esc": return "\u{1B}"
        case "backspace", "Backspace": return "\u{7F}"
        case "space", "Space": return " "
        case "ctrl-c", "C-c": return "\u{03}"
        case "ctrl-d", "C-d": return "\u{04}"
        case "ctrl-z", "C-z": return "\u{1A}"
        case "ctrl-l", "C-l": return "\u{0C}"
        case "up", "Up", "ArrowUp": return "\u{1B}[A"
        case "down", "Down", "ArrowDown": return "\u{1B}[B"
        case "right", "Right", "ArrowRight": return "\u{1B}[C"
        case "left", "Left", "ArrowLeft": return "\u{1B}[D"
        case "home", "Home": return "\u{1B}[H"
        case "end", "End": return "\u{1B}[F"
        case "page-up", "PageUp": return "\u{1B}[5~"
        case "page-down", "PageDown": return "\u{1B}[6~"
        default: return key
        }
    }

    public func dispatch(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        let id = req.id
        let params = req.params ?? [:]
        do {
            switch req.method {
            case "rpc.batch":
                guard case .array(let calls) = params["calls"] ?? .null else { throw JSONRPCError.invalidParams }
                var results: [JSONValue] = []
                for (index, callValue) in calls.enumerated() {
                    guard let call = callValue.objectValue,
                          let method = call["method"]?.stringValue else { throw JSONRPCError.invalidParams }
                    guard Self.isReadOnlyBatchMethod(method) else {
                        return .init(id: id, error: JSONRPCError(code: -32602, message: "Batch only supports read-only RPC methods.", data: .string(method)))
                    }
                    let callParams = call["params"]?.objectValue ?? [:]
                    let response = await dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(index), method: method, params: callParams))
                    if let error = response.error {
                        results.append(.object([
                            "error": .object([
                                "code": .number(Double(error.code)),
                                "message": .string(error.message)
                            ])
                        ]))
                    } else {
                        results.append(response.result ?? .null)
                    }
                }
                return .init(id: id, result: .array(results))
            case "system.ping":
                return .init(id: id, result: .object(["pong": .bool(true), "ts": .number(Date().timeIntervalSince1970)]))
            case "system.capabilities":
                return .init(id: id, result: .object([
                    "app": .string("remotecode"),
                    "api_version": .string("2"),
                    "surface_types": .array([.string("terminal"), .string("ssh"), .string("browser"), .string("agentApp"), .string("files"), .string("markdown"), .string("filePreview"), .string("rightSidebarTool")]),
                    "ssh": .object([
                        "methods": .array([
                            .string("ssh.host.list"),
                            .string("ssh.host.upsert"),
                            .string("ssh.host.delete"),
                            .string("ssh.connect"),
                            .string("ssh.disconnect"),
                            .string("ssh.transfer.upload"),
                            .string("ssh.transfer.download"),
                            .string("ssh.files.local.list"),
                            .string("ssh.files.remote.list")
                        ])
                    ]),
                    "agent": .object([
                        "providers": .array([.string("codex"), .string("claude")]),
                        "supports_stream_events": .bool(true),
                        "supports_resume": .bool(true)
                    ]),
                    "browser_automation": .object([
                        "p0": .array([.string("navigate"), .string("back"), .string("forward"), .string("reload"), .string("url.get"), .string("mirror_url.get")]),
                        "p1_unsupported": .bool(false)
                    ]),
                    "git": .object(["read_only": .bool(false)])
                ]))
            case "system.identify":
                return .init(id: id, result: .object([
                    "app": .string("remotecode"),
                    "pid": .number(Double(ProcessInfo.processInfo.processIdentifier))
                ]))
            case "events.recent":
                let sinceSeq = params["since_seq"]?.intValue.map(Int64.init) ?? 0
                let maxBytes = params["max_bytes"]?.intValue
                let result = EventBus.shared.recentEvents(since: sinceSeq, maxBytes: maxBytes)
                let arr: [JSONValue] = result.events.map { ev in
                    .object([
                        "seq": .number(Double(ev.seq)),
                        "kind": .string(ev.kind),
                        "payload": ev.payload,
                        "ts": .number(ev.ts)
                    ])
                }
                return .init(id: id, result: .object([
                    "last_seq": .number(Double(result.lastSeq)),
                    "events": .array(arr),
                    "truncated": .bool(result.truncated),
                    "requires_baseline": .bool(result.requiresBaseline)
                ]))
            case "settings.get":
                let keys: [String]
                if case .array(let arr) = params["keys"] ?? .null {
                    keys = arr.compactMap { $0.stringValue }
                } else {
                    keys = ["theme", "remote_access_enabled", "provider.default", "first_run_completed"]
                }
                let values = try router.settingsGet(keys: keys)
                return .init(id: id, result: .object(values.mapValues { .string($0) }))
            case "settings.set":
                guard let key = params["key"]?.stringValue,
                      let value = params["value"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.settingsSet(key: key, value: value)
                EventBus.shared.publish(kind: "settings.updated", payload: .object([
                    "key": .string(key),
                    "value": .string(value)
                ]))
                return .init(id: id, result: .bool(true))
            case "ssh.host.list":
                return .init(id: id, result: encode(try router.sshHostList()))
            case "ssh.host.upsert":
                let profile = try sshProfile(from: params)
                let saved = try router.sshHostUpsert(profile)
                EventBus.shared.publish(kind: "ssh.host.updated", payload: encode(saved))
                return .init(id: id, result: encode(saved))
            case "ssh.host.delete":
                guard let raw = params["id"]?.stringValue,
                      let uuid = UUID(uuidString: raw) else { throw JSONRPCError.invalidParams }
                try router.sshHostDelete(SSHHostID(uuid))
                EventBus.shared.publish(kind: "ssh.host.deleted", payload: .object(["id": .string(raw)]))
                return .init(id: id, result: .bool(true))
            case "ssh.connect":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let pid: PaneID? = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let profileID = params["profile_id"]?.stringValue.flatMap(UUID.init).map(SSHHostID.init)
                let profile = try optionalSSHProfile(from: params)
                let s = try router.sshConnect(workspace: wid, profileID: profileID, profile: profile, title: params["title"]?.stringValue, paneID: pid)
                EventBus.shared.publish(kind: "surface.created", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(s)
                ]))
                EventBus.shared.publish(kind: "ssh.session.updated", payload: .object([
                    "surface_id": .string(s.id.value.uuidString),
                    "status": .string(s.metadata["ssh_status"] ?? "connected"),
                    "destination": .string(s.metadata["ssh_destination"] ?? "")
                ]))
                return .init(id: id, result: encode(s))
            case "ssh.disconnect":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.sshDisconnect(surface: sid)
                EventBus.shared.publish(kind: "ssh.session.updated", payload: .object([
                    "surface_id": .string(sid.value.uuidString),
                    "status": .string("disconnected")
                ]))
                return .init(id: id, result: .bool(true))
            case "ssh.transfer.upload":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let local = params["local_path"]?.stringValue,
                      let remote = params["remote_path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.sshTransferUpload(surface: sid, localPath: local, remotePath: remote))
            case "ssh.transfer.download":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let remote = params["remote_path"]?.stringValue,
                      let local = params["local_path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.sshTransferDownload(surface: sid, remotePath: remote, localPath: local))
            case "ssh.files.local.list":
                return .init(id: id, result: try router.sshFilesLocalList(path: params["path"]?.stringValue))
            case "ssh.files.remote.list":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) ?? params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.sshFilesRemoteList(surface: sid, path: params["path"]?.stringValue))
            case "fs.roots":
                return .init(id: id, result: .object(["roots": fsRoots()]))
            case "fs.list":
                let raw = params["path"]?.stringValue
                return .init(id: id, result: try fsList(raw))
            case "fs.workspace.list":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.fsWorkspaceList(workspace: wid, path: params["path"]?.stringValue))
            case "fs.workspace.read":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.fsWorkspaceRead(workspace: wid, path: path, maxBytes: params["max_bytes"]?.intValue))
            case "fs.workspace.preview_url":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.fsWorkspacePreviewURL(workspace: wid, path: path))
            case "files.state.get":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesStateGet(surface: sid))
            case "files.state.update":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let patch = params["patch"]?.objectValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesStateUpdate(surface: sid, patch: patch, baseRevision: params["base_revision"]?.intValue, deviceID: params["device_id"]?.stringValue))
            case "files.edit.open":
                guard let sid = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditOpen(surface: sid, path: path))
            case "files.edit.apply_patch":
                guard let sessionID = params["session_id"]?.stringValue,
                      let base = params["base_draft_revision"]?.intValue,
                      let range = params["range_utf16"]?.objectValue,
                      let location = range["location"]?.intValue,
                      let length = range["length"]?.intValue,
                      let replacement = params["replacement"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditApplyPatch(sessionID: sessionID, baseDraftRevision: base, rangeLocation: location, rangeLength: length, replacement: replacement, deviceID: params["device_id"]?.stringValue))
            case "files.edit.save":
                guard let sessionID = params["session_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditSave(sessionID: sessionID))
            case "files.edit.discard":
                guard let sessionID = params["session_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditDiscard(sessionID: sessionID))
            case "files.edit.close":
                guard let sessionID = params["session_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: try router.filesEditClose(sessionID: sessionID))
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
                EventBus.shared.publish(kind: "workspace.created", payload: encode(ws))
                return .init(id: id, result: encode(ws))
            case "workspace.select":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try router.selectWorkspace(wid)
                EventBus.shared.publish(kind: "workspace.selected", payload: .object(["workspace_id": .string(wid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "workspace.close":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try router.closeWorkspace(wid)
                EventBus.shared.publish(kind: "workspace.closed", payload: .object(["workspace_id": .string(wid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "workspace.rename":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let name = params["name"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.renameWorkspace(wid, name)
                EventBus.shared.publish(kind: "workspace.renamed", payload: .object(["workspace_id": .string(wid.value.uuidString), "name": .string(name)]))
                return .init(id: id, result: .bool(true))
            case "workspace.set_description":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let text = params["description"]?.stringValue ?? params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.setWorkspaceDescription(wid, text)
                EventBus.shared.publish(kind: "workspace.updated", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "metadata": .object(["description": .string(text)])
                ]))
                return .init(id: id, result: .bool(true))
            case "workspace.set_color":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let color = params["color"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.setWorkspaceColor(wid, color)
                EventBus.shared.publish(kind: "workspace.updated", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "metadata": .object(["color": .string(color)])
                ]))
                return .init(id: id, result: .bool(true))
            case "workspace.set_pinned":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let pinned = params["pinned"]?.boolValue else { throw JSONRPCError.invalidParams }
                try router.setWorkspacePinned(wid, pinned)
                EventBus.shared.publish(kind: "workspace.updated", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "metadata": .object(["pinned": pinned ? .string("true") : .string("")])
                ]))
                let order = try router.currentWindow().workspaces
                EventBus.shared.publish(kind: "workspace.reordered", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "order": .array(order.map { .string($0.value.uuidString) })
                ]))
                return .init(id: id, result: .bool(true))
            case "workspace.reorder":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                try router.reorderWorkspace(wid, position: pos)
                let order = try router.currentWindow().workspaces
                EventBus.shared.publish(kind: "workspace.reordered", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "position": .number(Double(pos)),
                    "order": .array(order.map { .string($0.value.uuidString) })
                ]))
                return .init(id: id, result: .bool(true))
            case "surface.create":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let tStr = params["type"]?.stringValue,
                      let type = SurfaceType(rawValue: normalizeSurfaceTypeString(tStr)) else { throw JSONRPCError.invalidParams }
                let pid: PaneID? = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let title = params["title"]?.stringValue
                let s = try router.createSurface(workspace: wid, type: type, paneID: pid, title: title)
                EventBus.shared.publish(kind: "surface.created", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(s)
                ]))
                return .init(id: id, result: encode(s))
            case "surface.split":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init),
                      let dirStr = params["direction"]?.stringValue,
                      let dir = SplitDirection(rawValue: dirStr) else { throw JSONRPCError.invalidParams }
                if let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) {
                    try router.splitSurface(workspace: wid, paneID: pid, surface: sid, direction: dir)
                    EventBus.shared.publish(kind: "surface.moved", payload: .object([
                        "workspace_id": .string(wid.value.uuidString),
                        "id": .string(sid.value.uuidString)
                    ]))
                    return .init(id: id, result: .bool(true))
                }
                guard let tStr = params["type"]?.stringValue,
                      let type = SurfaceType(rawValue: normalizeSurfaceTypeString(tStr)) else { throw JSONRPCError.invalidParams }
                let title = params["title"]?.stringValue
                let s = try router.splitPane(workspace: wid, paneID: pid, direction: dir, surfaceType: type, title: title)
                EventBus.shared.publish(kind: "pane.split", payload: .object(["workspace_id": .string(wid.value.uuidString), "surface": encode(s)]))
                return .init(id: id, result: encode(s))
            case "surface.close":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.closeSurface(workspace: wid, surface: sid)
                EventBus.shared.publish(kind: "surface.closed", payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.focus":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.focusSurface(workspace: wid, surface: sid)
                EventBus.shared.publish(kind: "surface.focused", payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.rename":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let title = params["title"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.renameSurface(wid, sid, title)
                EventBus.shared.publish(kind: "surface.renamed", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "id": .string(sid.value.uuidString),
                    "title": .string(title)
                ]))
                return .init(id: id, result: .bool(true))
            case "surface.set_color":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let color = params["color"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.setSurfaceColor(wid, sid, color)
                EventBus.shared.publish(kind: "surface.updated", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "id": .string(sid.value.uuidString),
                    "metadata": .object(["color": .string(color)])
                ]))
                return .init(id: id, result: .bool(true))
            case "surface.send_text":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.sendText(surface: sid, text: text)
                return .init(id: id, result: .bool(true))
            case "surface.send_key":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let key = params["key"]?.stringValue else { throw JSONRPCError.invalidParams }
                let sequence = encodeKey(key)
                try router.sendText(surface: sid, text: sequence)
                return .init(id: id, result: .bool(true))
            case "surface.health":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let alive = router.surfaceHealth(surface: sid)
                return .init(id: id, result: .object(["alive": .bool(alive)]))
            case "surface.clear_history":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                router.surfaceClearHistory(surface: sid)
                return .init(id: id, result: .bool(true))
            case "surface.read_text":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let text = try router.readText(surface: sid)
                return .init(id: id, result: .string(text))
            case "surface.read_history":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let before = params["before_chunk_id"]?.intValue.map(Int64.init)
                let maxBytes = params["max_bytes"]?.intValue ?? (256 * 1024)
                let window = try router.readTerminalHistory(surface: sid, beforeChunkID: before, maxBytes: maxBytes)
                return .init(id: id, result: .object([
                    "text": .string(window.text),
                    "chunks": .array(window.chunks.map { chunk in
                        .object([
                            "id": .number(Double(chunk.id)),
                            "chunk_index": .number(Double(chunk.chunkIndex)),
                            "byte_count": .number(Double(chunk.data.count))
                        ])
                    }),
                    "has_more_older": .bool(window.hasMoreOlder),
                    "next_before_chunk_id": window.nextBeforeChunkID.map { .number(Double($0)) } ?? .null
                ]))
            case "agent.open":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let s = try router.openAgentApp(workspace: wid)
                return .init(id: id, result: encode(s))
            case "agent.thread.list":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let threads = try router.listAgentThreads(workspace: wid)
                return .init(id: id, result: .array(threads.map(encodeThread)))
            case "agent.thread.create":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let title = params["title"]?.stringValue ?? "New thread"
                let provider = AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex
                let model = params["model"]?.stringValue ?? "fake-model"
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init) ?? .supervised
                let reasoning = params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init) ?? .medium
                let t = try router.createAgentThread(workspace: wid, title: title, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning)
                EventBus.shared.publish(kind: "agent.thread.created", payload: threadPayload(t))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.configure":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let provider = params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let t = try router.configureAgentThread(thread: tid, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning)
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "provider": .string(t.provider.rawValue),
                    "model": .string(t.model)
                ]
                payload["permission_mode"] = .string(t.permissionMode.rawValue)
                payload["reasoning_effort"] = .string(t.reasoningEffort.rawValue)
                payload["provider_locked"] = .bool(providerLocked(t))
                payload["providerLocked"] = .bool(providerLocked(t))
                EventBus.shared.publish(kind: "agent.thread.updated", payload: .object(payload))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.select":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                try router.selectAgentThread(thread: tid)
                EventBus.shared.publish(kind: "agent.thread.selected", payload: .object(["thread_id": .string(tid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "agent.message.send":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let provider = params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let runId = try await router.sendAgentMessage(thread: tid, text: text, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning)
                return .init(id: id, result: .object(["run_id": .string(runId.value.uuidString)]))
            case "agent.message.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let limit = params["limit"]?.intValue ?? 200
                return .init(id: id, result: encode(try router.listAgentMessages(thread: tid, limit: limit)))
            case "agent.run.stop":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                try router.stopAgentRun(thread: tid)
                return .init(id: id, result: .bool(true))
            case "agent.thread.delete":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                try router.deleteAgentThread(thread: tid)
                EventBus.shared.publish(kind: "agent.thread.deleted", payload: .object(["thread_id": .string(tid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "agent.thread.delete_many":
                guard case .array(let values) = params["thread_ids"] ?? .null else { throw JSONRPCError.invalidParams }
                let tids = values.compactMap { $0.stringValue.flatMap(UUID.init).map(AgentThreadID.init) }
                guard !tids.isEmpty else { throw JSONRPCError.invalidParams }
                try router.deleteAgentThreads(tids)
                EventBus.shared.publish(kind: "agent.thread.deleted_many", payload: .object([
                    "thread_ids": .array(tids.map { .string($0.value.uuidString) })
                ]))
                return .init(id: id, result: .bool(true))
            case "agent.thread.rename":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let title = params["title"]?.stringValue else { throw JSONRPCError.invalidParams }
                let t = try router.renameAgentThread(thread: tid, title: title)
                EventBus.shared.publish(kind: "agent.thread.renamed", payload: threadPayload(t))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.set_pinned":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let pinned = params["pinned"]?.boolValue else { throw JSONRPCError.invalidParams }
                let t = try router.setAgentThreadPinned(thread: tid, pinned: pinned)
                let order = try router.listAgentThreads(workspace: t.workspaceId).map { $0.id.value.uuidString }
                EventBus.shared.publish(kind: "agent.thread.updated", payload: .object([
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "pinned": .bool(t.pinned),
                    "sort_order": .number(Double(t.sortOrder)),
                    "provider_locked": .bool(providerLocked(t)),
                    "providerLocked": .bool(providerLocked(t))
                ]))
                EventBus.shared.publish(kind: "agent.thread.reordered", payload: .object([
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "order": .array(order.map { .string($0) })
                ]))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.set_color":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let color = params["color"]?.stringValue else { throw JSONRPCError.invalidParams }
                let t = try router.setAgentThreadColor(thread: tid, color: color)
                EventBus.shared.publish(kind: "agent.thread.updated", payload: .object([
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "color": t.color.map { .string($0) } ?? .string(""),
                    "provider_locked": .bool(providerLocked(t)),
                    "providerLocked": .bool(providerLocked(t))
                ]))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.reorder":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                let list = try router.reorderAgentThread(thread: tid, position: pos)
                let wid = list.first(where: { $0.id == tid })?.workspaceId
                EventBus.shared.publish(kind: "agent.thread.reordered", payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "workspace_id": wid.map { .string($0.value.uuidString) } ?? .null,
                    "position": .number(Double(pos)),
                    "order": .array(list.map { .string($0.id.value.uuidString) })
                ]))
                return .init(id: id, result: .bool(true))
            case "agent.thread.mark_read":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                try router.markAgentThreadRead(thread: tid)
                EventBus.shared.publish(kind: "agent.thread.read", payload: .object(["thread_id": .string(tid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "git.status":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.gitStatus(workspace: wid)))
            case "git.branches":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.gitBranches(workspace: wid)))
            case "git.checkout":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let branch = params["branch"]?.stringValue else { throw JSONRPCError.invalidParams }
                let r = try router.gitCheckout(workspace: wid, branch: branch)
                EventBus.shared.publish(kind: "git.checkout", payload: .object(["workspace_id": .string(wid.value.uuidString), "branch": .string(branch), "ok": .bool(r.ok)]))
                return .init(id: id, result: encode(r))
            case "git.create_branch":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let name = params["name"]?.stringValue else { throw JSONRPCError.invalidParams }
                let r = try router.gitCreateBranch(workspace: wid, name: name)
                EventBus.shared.publish(kind: "git.branch_created", payload: .object(["workspace_id": .string(wid.value.uuidString), "name": .string(name), "ok": .bool(r.ok)]))
                return .init(id: id, result: encode(r))
            case "git.commit":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let message = params["message"]?.stringValue else { throw JSONRPCError.invalidParams }
                let r = try router.gitCommit(workspace: wid, message: message)
                EventBus.shared.publish(kind: "git.commit", payload: .object(["workspace_id": .string(wid.value.uuidString), "ok": .bool(r.ok)]))
                return .init(id: id, result: encode(r))
            case "git.log":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let limit = params["limit"]?.intValue ?? 100
                return .init(id: id, result: encode(try router.gitLog(workspace: wid, limit: limit)))
            case "git.diff":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let path = params["path"]?.stringValue
                let iw = params["ignore_whitespace"]?.boolValue ?? false
                return .init(id: id, result: .string(try router.gitDiff(workspace: wid, path: path, ignoreWhitespace: iw)))
            case "git.push":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let r = try router.gitPush(workspace: wid)
                EventBus.shared.publish(kind: "git.push", payload: .object(["workspace_id": .string(wid.value.uuidString), "ok": .bool(r.ok)]))
                return .init(id: id, result: encode(r))
            case "git.pull_request_url":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let url = try router.gitPullRequestURL(workspace: wid)
                return .init(id: id, result: .object(["url": url.map { .string($0) } ?? .null]))
            case "project.scripts":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.projectScripts(workspace: wid)))
            case "project.run_script":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let name = params["name"]?.stringValue else { throw JSONRPCError.invalidParams }
                let s = try router.projectRunScript(workspace: wid, name: name)
                EventBus.shared.publish(kind: "project.script_started", payload: .object(["workspace_id": .string(wid.value.uuidString), "name": .string(name)]))
                return .init(id: id, result: encode(s))
            case "project.open_in_editor":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let app = try router.projectOpenInEditor(workspace: wid)
                return .init(id: id, result: .object(["app": .string(app)]))
            case "agent.models.list":
                let provider = AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex
                let models = await router.listAgentModels(provider: provider)
                return .init(id: id, result: encode(models))
            case "agent.state.current":
                let w = try router.currentWindow()
                return .init(id: id, result: .object([
                    "selected_workspace_id": w.selectedWorkspaceID.map { .string($0.value.uuidString) } ?? .null
                ]))
            case "browser.navigate":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let url = params["url"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.browserNavigate(surface: sid, url: url)
                EventBus.shared.publish(kind: "surface.browser", payload: .object(["surface_id": .string(sid.value.uuidString), "url": .string(url)]))
                return .init(id: id, result: .bool(true))
            case "browser.back":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.browserBack(surface: sid)
                return .init(id: id, result: .bool(true))
            case "browser.forward":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.browserForward(surface: sid)
                return .init(id: id, result: .bool(true))
            case "browser.reload":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try router.browserReload(surface: sid)
                return .init(id: id, result: .bool(true))
            case "browser.url.get":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let url = try router.browserURL(surface: sid)
                return .init(id: id, result: .string(url))
            case "browser.mirror_url.get":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let mirror = try router.browserMirrorURL(surface: sid)
                return .init(id: id, result: .object(mirror))
            case "browser.eval":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let script = params["script"]?.stringValue else { throw JSONRPCError.invalidParams }
                let s = try await router.browserEval(surface: sid, script: script)
                return .init(id: id, result: .string(s))
            case "browser.screenshot":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let path = params["path"]?.stringValue
                let resolved = try router.browserScreenshot(surface: sid, savePath: path)
                return .init(id: id, result: .object(["path": .string(resolved)]))
            case "browser.snapshot":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let json = try await router.browserSnapshot(surface: sid)
                return .init(id: id, result: .string(json))
            case "browser.click", "browser.fill", "browser.type", "browser.focus", "browser.hover", "browser.check", "browser.uncheck", "browser.select":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let ref = params["ref"]?.stringValue else { throw JSONRPCError.invalidParams }
                let kind = String(req.method.dropFirst("browser.".count))
                let value = params["value"]?.stringValue
                let json = try await router.browserAction(surface: sid, kind: kind, ref: ref, value: value)
                return .init(id: id, result: .string(json))
            case "browser.wait":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let sel = params["selector"]?.stringValue else { throw JSONRPCError.invalidParams }
                let timeout = params["timeout_ms"]?.intValue ?? 5000
                let json = try await router.browserWait(surface: sid, selector: sel, timeoutMs: timeout)
                return .init(id: id, result: .string(json))
            case "notification.create":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let title = params["title"]?.stringValue ?? "Notification"
                let body = params["body"]?.stringValue
                let category = params["category"]?.stringValue
                let nid = try router.notificationCreate(workspaceId: wid, title: title, body: body, category: category)
                EventBus.shared.publish(kind: "notification.created", payload: .object([
                    "id": .string(nid),
                    "title": .string(title),
                    "push_policy": .string("background_only")
                ]))
                return .init(id: id, result: .object([
                    "id": .string(nid),
                    "push_policy": .string("background_only")
                ]))
            case "notification.list":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let unread = params["unread_only"]?.boolValue ?? false
                let list = try router.notificationList(workspaceId: wid, unreadOnly: unread)
                return .init(id: id, result: .array(list.map { .object($0) }))
            case "notification.mark_read":
                guard let nid = params["id"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.notificationMarkRead(id: nid)
                EventBus.shared.publish(kind: "notification.read", payload: .object(["id": .string(nid)]))
                return .init(id: id, result: .bool(true))
            case "notification.dismiss":
                guard let nid = params["id"]?.stringValue else { throw JSONRPCError.invalidParams }
                try router.notificationDismiss(id: nid)
                EventBus.shared.publish(kind: "notification.dismissed", payload: .object(["id": .string(nid)]))
                return .init(id: id, result: .bool(true))
            case "pane.list":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let panes = try router.paneList(workspace: wid)
                return .init(id: id, result: .array(panes.map { .object($0) }))
            case "pane.surfaces":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let pid = params["id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                let surfaces = try router.paneSurfaces(pane: pid, workspace: wid)
                return .init(id: id, result: encode(surfaces))
            case "pane.resize":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let split = params["split_id"]?.stringValue.flatMap(UUID.init) else { throw JSONRPCError.invalidParams }
                var ratios: [Double] = []
                if case .array(let arr) = params["ratios"] ?? .null {
                    for v in arr { if case .number(let n) = v { ratios.append(n) } }
                }
                try router.paneResize(workspace: wid, splitID: split, ratios: ratios)
                EventBus.shared.publish(kind: "pane.resized", payload: .object(["workspace_id": .string(wid.value.uuidString), "split_id": .string(split.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.move":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let pid = params["target_pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                try router.surfaceMove(workspace: wid, surface: sid, targetPane: pid)
                EventBus.shared.publish(kind: "surface.moved", payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString), "target_pane_id": .string(pid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.reorder":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let pid = params["target_pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                try router.surfaceReorder(workspace: wid, surface: sid, toPane: pid, position: pos)
                EventBus.shared.publish(kind: "surface.reordered", payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString), "target_pane_id": .string(pid.value.uuidString), "position": .number(Double(pos))]))
                return .init(id: id, result: .bool(true))
            case "window.list":
                let ws = try router.listWindows()
                return .init(id: id, result: encode(ws))
            case "window.current":
                let w = try router.currentWindow()
                return .init(id: id, result: encode(w))
            case "window.create":
                let title = params["title"]?.stringValue
                let w = try router.createWindow(title: title)
                EventBus.shared.publish(kind: "window.created", payload: encode(w))
                return .init(id: id, result: encode(w))
            case "window.focus":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WindowID.init) else { throw JSONRPCError.invalidParams }
                try router.focusWindow(wid)
                return .init(id: id, result: .bool(true))
            case "window.close":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WindowID.init) else { throw JSONRPCError.invalidParams }
                try router.closeWindow(wid)
                return .init(id: id, result: .bool(true))
            case "workspace.move_to_window":
                guard let workspaceId = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let target = params["window_id"]?.stringValue.flatMap(UUID.init).map(WindowID.init) else { throw JSONRPCError.invalidParams }
                try router.moveWorkspaceToWindow(workspace: workspaceId, target: target)
                return .init(id: id, result: .bool(true))
            case "pane.swap":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let a = params["a"]?.stringValue.flatMap(UUID.init).map(PaneID.init),
                      let b = params["b"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                try router.paneSwap(workspace: wid, a: a, b: b)
                EventBus.shared.publish(kind: "pane.swapped", payload: .object(["workspace_id": .string(wid.value.uuidString), "a": .string(a.value.uuidString), "b": .string(b.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            // V1 deferred families return a typed unsupported error.
            case "pane.break", "pane.join":
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

    public static func isReadOnlyBatchMethod(_ method: String) -> Bool {
        method.hasPrefix("system.")
            || method == "workspace.list"
            || method == "workspace.current"
            || method == "events.recent"
            || method == "settings.get"
            || method.hasSuffix(".list")
            || method.hasSuffix(".read")
            || method.hasSuffix(".status")
            || method.hasSuffix(".get")
    }

    /// Accept the lowercased/underscored tokens the CLI documents
    /// (`rightsidebartool`, `filepreview`, …) and map them to the
    /// `SurfaceType` raw values, which are camelCase. Without this the
    /// documented `rc2 new-surface --type rightsidebartool` fails.
    private func normalizeSurfaceTypeString(_ s: String) -> String {
        switch s.lowercased() {
        case "agent", "agent_app", "agentapp": return "agentApp"
        case "rightsidebartool", "right_sidebar_tool", "diff", "git": return "rightSidebarTool"
        case "filepreview", "file_preview": return "filePreview"
        case "files", "file_browser", "filebrowser": return "files"
        case "ssh": return "ssh"
        case "markdown": return "markdown"
        case "terminal": return "terminal"
        case "browser": return "browser"
        default: return s
        }
    }

    /// Top-level entry points the iOS file browser starts from. The app
    /// is not sandboxed, so any of these is fully readable.
    private func fsRoots() -> JSONValue {
        let home = NSHomeDirectory()
        let roots: [(String, String)] = [(home, "Home"), ("/", "Root"), ("/tmp", "/tmp")]
        return .array(roots.map { path, label in
            .object(["id": .string(path), "label": .string(label), "path": .string(path)])
        })
    }

    /// List one directory for the iOS workspace picker. Directories
    /// sort before files, then case-insensitive by name (parity with
    /// the remotecode.io desktop `listPath`). `parent` is null at "/".
    private func fsList(_ raw: String?) throws -> JSONValue {
        let fm = FileManager.default
        let input = (raw?.isEmpty == false) ? raw! : NSHomeDirectory()
        // expandingTildeInPath handles "~"/"~user"; standardizingPath
        // resolves "." / ".." and symlinks to a canonical absolute path.
        let path = ((input as NSString).expandingTildeInPath as NSString).standardizingPath
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw JSONRPCError(code: -32602, message: "not found", data: .string(path))
        }
        guard isDir.boolValue else {
            throw JSONRPCError(code: -32602, message: "not a directory", data: .string(path))
        }
        let names = try fm.contentsOfDirectory(atPath: path)
        let entries = names.map { name -> (Bool, String, JSONValue) in
            let child = (path as NSString).appendingPathComponent(name)
            var childDir: ObjCBool = false
            _ = fm.fileExists(atPath: child, isDirectory: &childDir)
            let isDirectory = childDir.boolValue
            return (isDirectory, name, .object([
                "name": .string(name),
                "path": .string(child),
                "type": .string(isDirectory ? "directory" : "file"),
            ]))
        }
        .sorted { l, r in
            if l.0 != r.0 { return l.0 && !r.0 }   // directories first
            return l.1.localizedCaseInsensitiveCompare(r.1) == .orderedAscending
        }
        .map { $0.2 }
        let parent: JSONValue = path == "/" ? .null
            : .string((path as NSString).deletingLastPathComponent)
        return .object([
            "path": .string(path),
            "parentPath": parent,
            "entries": .array(entries),
        ])
    }

    private func encode<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
              let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return .null
        }
        return JSONValue.from(any)
    }

    private func optionalSSHProfile(from params: [String: JSONValue]) throws -> SSHHostProfile? {
        if params["destination"]?.stringValue == nil,
           params["host"]?.stringValue == nil,
           params["profile"]?.objectValue == nil {
            return nil
        }
        return try sshProfile(from: params)
    }

    private func sshProfile(from params: [String: JSONValue]) throws -> SSHHostProfile {
        let source = params["profile"]?.objectValue ?? params
        guard let destination = source["destination"]?.stringValue ?? source["host"]?.stringValue else {
            throw JSONRPCError.invalidParams
        }
        let id = (source["id"]?.stringValue).flatMap(UUID.init).map(SSHHostID.init) ?? SSHHostID()
        let label = source["label"]?.stringValue ?? source["title"]?.stringValue ?? destination
        let options = source["options"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return SSHHostProfile(
            id: id,
            label: label,
            destination: destination,
            port: source["port"]?.intValue,
            identityFile: source["identity_file"]?.stringValue ?? source["identityFile"]?.stringValue,
            password: source["password"]?.stringValue,
            options: options
        )
    }

    private func encodeThread(_ thread: AgentThread) -> JSONValue {
        guard case .object(var object) = encode(thread) else { return .null }
        let display = AgentThreadTitle.display(thread.title)
        object["displayTitle"] = .string(display)
        object["display_title"] = .string(display)
        let locked = providerLocked(thread)
        object["providerLocked"] = .bool(locked)
        object["provider_locked"] = .bool(locked)
        return .object(object)
    }

    private func threadPayload(_ thread: AgentThread) -> JSONValue {
        let locked = providerLocked(thread)
        var payload: [String: JSONValue] = [
            "thread_id": .string(thread.id.value.uuidString),
            "workspace_id": thread.workspaceId.map { .string($0.value.uuidString) } ?? .null,
            "title": .string(thread.title),
            "display_title": .string(AgentThreadTitle.display(thread.title)),
            "displayTitle": .string(AgentThreadTitle.display(thread.title)),
            "provider": .string(thread.provider.rawValue),
            "model": .string(thread.model),
            "provider_locked": .bool(locked),
            "providerLocked": .bool(locked),
            "permission_mode": .string(thread.permissionMode.rawValue),
            "reasoning_effort": .string(thread.reasoningEffort.rawValue)
        ]
        payload["color"] = thread.color.map { .string($0) } ?? .null
        payload["pinned"] = .bool(thread.pinned)
        payload["sort_order"] = .number(Double(thread.sortOrder))
        return .object(payload)
    }

    private func providerLocked(_ thread: AgentThread) -> Bool {
        !((try? router.listAgentMessages(thread: thread.id, limit: 1)) ?? []).isEmpty
    }
}
