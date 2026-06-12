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
    func closeWorkspace(_ id: WorkspaceID, publishEvent: Bool) throws
    func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws
    func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws
    func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws
    func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws
    func reorderWorkspace(_ id: WorkspaceID, position: Int) throws
    func createSurface(workspace: WorkspaceID, type: SurfaceType, paneID: PaneID?, title: String?) throws -> SurfaceDescriptor
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor
    func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor
    func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor
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
    func sshHostList(workspace: WorkspaceID) throws -> [SSHHostProfile]
    func sshHostUpsert(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile
    func sshHostDelete(_ id: SSHHostID, workspace: WorkspaceID) throws
    func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor
    func sshDisconnect(surface: SurfaceID) throws
    func sshTransferUpload(surface: SurfaceID, localPath: String, remotePath: String) throws -> JSONValue
    func sshTransferDownload(surface: SurfaceID, remotePath: String, localPath: String) throws -> JSONValue
    func sshFilesLocalList(path: String?) throws -> JSONValue
    func sshFilesRemoteList(surface: SurfaceID, path: String?) throws -> JSONValue
    // agent
    func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor
    func listAgentThreads(workspace: WorkspaceID?) throws -> [AgentThread]
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread
    func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread
    func configureAgentThreadExecution(thread: AgentThreadID, executionMode: AgentExecutionMode, baseBranch: String?) throws -> AgentThread
    func prepareAgentThreadForPullRequest(workspace: WorkspaceID, url: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread
    func uploadAgentAttachment(workspace: WorkspaceID, filename: String, mimeType: String?, dataBase64: String) throws -> AgentAttachmentUploadResult
    func selectAgentThread(thread: AgentThreadID) throws
    func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage]
    func listAgentMessagesPage(thread: AgentThreadID, limit: Int, before: AgentMessageCursor?, after: AgentMessageCursor?) throws -> AgentMessagePage
    /// PERF-007: returns the set of thread IDs that have at least one message, via a
    /// single SQL query. Used by agent.thread.list to derive provider_locked for every
    /// thread without issuing one query per thread.
    func threadIdsWithMessages() throws -> Set<AgentThreadID>
    func getAgentMessage(id: AgentMessageID) throws -> AgentMessage?
    func listAgentQueuedMessages(thread: AgentThreadID) throws -> [AgentQueuedMessage]
    func updateAgentQueuedMessage(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) throws -> AgentQueuedMessage
    func cancelAgentQueuedMessage(id: AgentQueuedMessageID) throws -> AgentQueuedMessage
    func forceAgentQueuedMessageNow(id: AgentQueuedMessageID) async throws -> AgentMessageSendResult
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment]) async throws -> AgentMessageSendResult
    func implementAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, newThread: Bool, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?) async throws -> (runId: AgentRunID, implementationThreadId: AgentThreadID)
    func saveAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, relativePath: String?) throws -> (path: String, relativePath: String)
    func commandReceipt(method: String, clientRequestId: String) -> JSONValue?
    func recordCommandReceipt(method: String, clientRequestId: String, result: JSONValue)
    func respondAgentRequest(thread: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) throws
    func respondAgentUserInput(thread: AgentThreadID, requestId: String, text: String) throws
    func listAgentPendingCallbacks(thread: AgentThreadID) throws -> AssistantPendingCallbacksSnapshot
    func readAgentThreadEvents(thread: AgentThreadID) throws -> [AssistantEvent]
    func rollbackAgentThread(thread: AgentThreadID, toTurnId: String) throws
    func listAgentThreadCheckpoints(thread: AgentThreadID) throws -> [AgentTurnCheckpointSummary]
    func agentCheckpointDiff(thread: AgentThreadID, checkpointTurnCount: Int, path: String?) throws -> String
    func revertAgentThreadToCheckpoint(thread: AgentThreadID, checkpointTurnCount: Int) throws -> AgentTurnCheckpointSummary
    func stopAgentRun(thread: AgentThreadID) throws
    func deleteAgentThread(thread: AgentThreadID) throws
    func deleteAgentThreads(_ threads: [AgentThreadID]) throws
    func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread
    func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread
    func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread
    func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread]
    func markAgentThreadRead(thread: AgentThreadID) throws
    func listAgentModels(provider: AgentProvider) async -> [AgentModelDescriptor]
    func listAgentProviderSnapshots() async -> [AgentProviderSnapshot]
    func updateAgentProvider(provider: AgentProvider, providerInstanceId: String?) async throws -> JSONValue
    func agentPromptHistory(workspace: WorkspaceID?, limit: Int) throws -> [String]
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
    func gitDeliveryPlan(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryPlan
    func gitDeliver(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryResult
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
    func privatePushTokenUpdate(pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceID: String?) throws -> JSONValue
    // settings
    func settingsGet(keys: [String]) throws -> [String: String]
    func settingsSet(key: String, value: String) throws
    // workspace Files surface
    func filesStateGet(surface: SurfaceID) throws -> JSONValue
    func filesStateUpdate(surface: SurfaceID, patch: [String: JSONValue], baseRevision: Int?, deviceID: String?) throws -> JSONValue
    func fsWorkspaceList(workspace: WorkspaceID, path: String?) throws -> JSONValue
    func fsWorkspaceRead(workspace: WorkspaceID, path: String, maxBytes: Int?) throws -> JSONValue
    func fsWorkspacePreviewURL(workspace: WorkspaceID, path: String) throws -> JSONValue
    func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue
    func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue
    func fsWorkspaceDelete(workspace: WorkspaceID, paths: [String]) throws -> JSONValue
    func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue
    func filesEditApplyPatch(sessionID: String, baseDraftRevision: Int, rangeLocation: Int, rangeLength: Int, replacement: String, deviceID: String?) throws -> JSONValue
    func filesEditSave(sessionID: String) throws -> JSONValue
    func filesEditDiscard(sessionID: String) throws -> JSONValue
    func filesEditClose(sessionID: String) throws -> JSONValue
}

public extension CommandRouting {
    func closeWorkspace(_ id: WorkspaceID) throws {
        try closeWorkspace(id, publishEvent: true)
    }
}

@MainActor
public protocol TerminalCommandRouting: AnyObject {
    func sendTextResult(surface: SurfaceID, text: String) throws -> JSONValue
    func surfaceHealthDetails(surface: SurfaceID) -> JSONValue
    func readTextSnapshot(surface: SurfaceID) throws -> JSONValue
}

@MainActor
public protocol LayoutEventSuppressionRouting: AnyObject {
    func withSuppressedLayoutEvents<T>(_ body: () throws -> T) rethrows -> T
}

/// Bounded idempotency cache with insertion-order eviction (oldest-first) and TTL.
/// - `cap`: maximum number of entries before the oldest is dropped.
/// - `ttl`: seconds after insertion at or beyond which an entry is treated as
///   absent (the retried command is allowed to re-execute). A `ttl` of 0 means
///   entries are never considered fresh.
struct BoundedReceiptCache {
    struct Entry {
        let value: JSONValue
        let insertedAt: Date
    }
    private(set) var cap: Int
    private(set) var ttl: TimeInterval
    private var store: [String: Entry] = [:]
    /// Insertion-ordered keys (oldest first).
    private var order: [String] = []

    init(cap: Int = 256, ttl: TimeInterval = 300) {
        self.cap = cap
        self.ttl = ttl
    }

    /// Returns the value for `key` if present AND within TTL; otherwise nil.
    func value(for key: String) -> JSONValue? {
        guard let entry = store[key] else { return nil }
        guard Date().timeIntervalSince(entry.insertedAt) < ttl else { return nil }
        return entry.value
    }

    /// Inserts `value` for `key`. Evicts oldest entry when at cap.
    mutating func insert(key: String, value: JSONValue) {
        if store[key] == nil {
            // Evict oldest when at cap.
            while order.count >= cap, !order.isEmpty {
                let oldest = order.removeFirst()
                store.removeValue(forKey: oldest)
            }
            order.append(key)
        }
        store[key] = Entry(value: value, insertedAt: Date())
    }

    var count: Int { store.count }
}

/// Pure coalesce-decision helper for device-initiated pairing requests.
///
/// When a device repeatedly connects (e.g. re-pair-every-connect, IP drift,
/// Bonjour TXT race), it sends a fresh POST /v1/pair each time. Without
/// coalescing, each POST creates a new `pairing_requests` row and fires a new
/// Mac modal -- the user sees a flood of identical prompts.
///
/// `coalescePairingRequest` answers: "is there already an outstanding,
/// non-expired pending request for `deviceName` within the TTL window?" If yes,
/// return it so the caller can reuse it (no new row, no new modal). If no,
/// return `nil` so the caller creates a new one as normal.
///
/// Pure, deterministic, no I/O. The `now` parameter is injected for
/// deterministic unit tests. Call-site feeds the live `outstanding` slice from
/// the repository query.
///
/// - Parameters:
///   - deviceName: Name sent by the device in the pairing POST body.
///   - outstanding: All currently-pending (non-decided) `PairingRequest` rows.
///   - now: Current time (injected so tests need no sleep).
///   - ttl: Maximum age of an existing request for it to be reused (seconds).
/// - Returns: An existing `PairingRequest` to reuse, or `nil` if a new one
///   should be created.
public func coalescePairingRequest(
    deviceName: String,
    outstanding: [PairingRequest],
    now: Date,
    ttl: TimeInterval
) -> PairingRequest? {
    outstanding.first { req in
        req.deviceName == deviceName
            && req.status == "pending"
            && now.timeIntervalSince(req.createdAt) < ttl
    }
}

@MainActor
public final class JSONRPCDispatcher {
    let router: CommandRouting
    private var volatileCommandReceipts = BoundedReceiptCache()
    public init(router: CommandRouting) { self.router = router }

    private func commandReceipt(method: String, params: [String: JSONValue]) -> (String, JSONValue)? {
        guard let receiptKey = params["client_request_id"]?.stringValue else { return nil }
        if let durable = router.commandReceipt(method: method, clientRequestId: receiptKey) {
            return (receiptKey, durable)
        }
        if let cached = volatileCommandReceipts.value(for: "\(method):\(receiptKey)") {
            return (receiptKey, cached)
        }
        return nil
    }

    private func recordCommandReceipt(method: String, clientRequestId: String?, result: JSONValue) {
        guard let clientRequestId else { return }
        volatileCommandReceipts.insert(key: "\(method):\(clientRequestId)", value: result)
        router.recordCommandReceipt(method: method, clientRequestId: clientRequestId, result: result)
    }

    private func withSuppressedLayoutEvents<T>(_ body: () throws -> T) rethrows -> T {
        if let suppressingRouter = router as? LayoutEventSuppressionRouting {
            return try suppressingRouter.withSuppressedLayoutEvents(body)
        }
        return try body()
    }

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
                    "files": .object([
                        "methods": .array([
                            .string("fs.workspace.list"),
                            .string("fs.workspace.read"),
                            .string("fs.workspace.preview_url"),
                            .string("fs.workspace.create_file"),
                            .string("fs.workspace.rename"),
                            .string("fs.workspace.delete"),
                            .string("files.tab.open"),
                            .string("files.tab.split"),
                            .string("files.state.get"),
                            .string("files.state.update"),
                            .string("files.edit.open"),
                            .string("files.edit.apply_patch"),
                            .string("files.edit.save"),
                            .string("files.edit.discard"),
                            .string("files.edit.close")
                        ])
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
                let workspace = try workspaceID(from: params)
                return .init(id: id, result: encode(try router.sshHostList(workspace: workspace)))
            case "ssh.host.upsert":
                let workspace = try workspaceID(from: params)
                let profile = try sshProfile(from: params)
                let saved = try router.sshHostUpsert(profile, workspace: workspace)
                var payload = encode(saved).objectValue ?? [:]
                payload["workspace_id"] = .string(workspace.value.uuidString)
                EventBus.shared.publish(kind: "ssh.host.updated", payload: .object(payload))
                return .init(id: id, result: encode(saved))
            case "ssh.host.delete":
                let workspace = try workspaceID(from: params)
                guard let raw = params["id"]?.stringValue,
                      let uuid = UUID(uuidString: raw) else { throw JSONRPCError.invalidParams }
                try router.sshHostDelete(SSHHostID(uuid), workspace: workspace)
                EventBus.shared.publish(kind: "ssh.host.deleted", payload: .object([
                    "id": .string(raw),
                    "workspace_id": .string(workspace.value.uuidString)
                ]))
                return .init(id: id, result: .bool(true))
            case "ssh.connect":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                // UX-010: idempotent connect — a retried request must not
                // open a duplicate SSH surface.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let pid: PaneID? = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let profileID = params["profile_id"]?.stringValue.flatMap(UUID.init).map(SSHHostID.init)
                let profile = try optionalSSHProfile(from: params)
                let s = try withSuppressedLayoutEvents {
                    try router.sshConnect(workspace: wid, profileID: profileID, profile: profile, title: params["title"]?.stringValue, paneID: pid)
                }
                EventBus.shared.publish(kind: "surface.created", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(s)
                ]))
                EventBus.shared.publish(kind: "ssh.session.updated", payload: .object([
                    "surface_id": .string(s.id.value.uuidString),
                    "status": .string(s.metadata["ssh_status"] ?? "connected"),
                    "destination": .string(s.metadata["ssh_destination"] ?? "")
                ]))
                let result = encode(s)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
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
            case "fs.workspace.create_file":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                let result = try router.fsWorkspaceCreateFile(workspace: wid, path: path, content: params["content"]?.stringValue ?? "")
                EventBus.shared.publish(kind: "fs.workspace.changed", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "action": .string("create_file"),
                    "paths": .array([.string(result.objectValue?["relative_path"]?.stringValue ?? path)])
                ]))
                return .init(id: id, result: result)
            case "fs.workspace.rename":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue,
                      let newName = params["new_name"]?.stringValue else { throw JSONRPCError.invalidParams }
                let result = try router.fsWorkspaceRename(workspace: wid, path: path, newName: newName)
                EventBus.shared.publish(kind: "fs.workspace.changed", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "action": .string("rename"),
                    "paths": .array([.string(path), .string(result.objectValue?["relative_path"]?.stringValue ?? newName)])
                ]))
                return .init(id: id, result: result)
            case "fs.workspace.delete":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let paths = params["paths"]?.arrayValue?.compactMap { $0.stringValue }
                    ?? params["path"]?.stringValue.map { [$0] }
                    ?? []
                let result = try router.fsWorkspaceDelete(workspace: wid, paths: paths)
                EventBus.shared.publish(kind: "fs.workspace.changed", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "action": .string("delete"),
                    "paths": result.objectValue?["deleted"] ?? .array(paths.map { .string($0) })
                ]))
                return .init(id: id, result: result)
            case "files.tab.open":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                let sourceSurface = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init)
                let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let surface = try withSuppressedLayoutEvents {
                    try router.filesOpenTab(workspace: wid, sourceSurface: sourceSurface, paneID: pid, path: path)
                }
                EventBus.shared.publish(kind: "surface.created", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(surface)
                ]))
                return .init(id: id, result: encode(surface))
            case "files.tab.split":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let dirStr = params["direction"]?.stringValue,
                      let dir = SplitDirection(rawValue: dirStr),
                      let path = params["path"]?.stringValue else { throw JSONRPCError.invalidParams }
                let sourceSurface = params["surface_id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init)
                let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let surface = try withSuppressedLayoutEvents {
                    try router.filesSplitTab(workspace: wid, sourceSurface: sourceSurface, paneID: pid, direction: dir, path: path)
                }
                EventBus.shared.publish(kind: "pane.split", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(surface)
                ]))
                return .init(id: id, result: encode(surface))
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
                // UX-010: idempotent create — a retried request over a flaky
                // mobile link must not produce a duplicate workspace.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let name = params["name"]?.stringValue ?? "workspace"
                let cwd = params["cwd"]?.stringValue ?? FileManager.default.currentDirectoryPath
                let ws = try router.createWorkspace(name: name, cwd: cwd)
                EventBus.shared.publish(kind: "workspace.created", payload: encode(ws))
                let result = encode(ws)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "workspace.select":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try router.selectWorkspace(wid)
                EventBus.shared.publish(kind: "workspace.selected", payload: .object(["workspace_id": .string(wid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "workspace.close":
                guard let wid = params["id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                try router.closeWorkspace(wid, publishEvent: false)
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
                // UX-010: idempotent create — a retried request must not
                // produce a duplicate surface/pane.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let pid: PaneID? = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                let title = params["title"]?.stringValue
                let s = try withSuppressedLayoutEvents {
                    try router.createSurface(workspace: wid, type: type, paneID: pid, title: title)
                }
                EventBus.shared.publish(kind: "surface.created", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "surface": encode(s)
                ]))
                let result = encode(s)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "surface.split":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let pid = params["pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init),
                      let dirStr = params["direction"]?.stringValue,
                      let dir = SplitDirection(rawValue: dirStr) else { throw JSONRPCError.invalidParams }
                if let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) {
                    try withSuppressedLayoutEvents {
                        try router.splitSurface(workspace: wid, paneID: pid, surface: sid, direction: dir)
                    }
                    EventBus.shared.publish(kind: "surface.moved", payload: .object([
                        "workspace_id": .string(wid.value.uuidString),
                        "id": .string(sid.value.uuidString)
                    ]))
                    return .init(id: id, result: .bool(true))
                }
                guard let tStr = params["type"]?.stringValue,
                      let type = SurfaceType(rawValue: normalizeSurfaceTypeString(tStr)) else { throw JSONRPCError.invalidParams }
                let title = params["title"]?.stringValue
                let s = try withSuppressedLayoutEvents {
                    try router.splitPane(workspace: wid, paneID: pid, direction: dir, surfaceType: type, title: title)
                }
                EventBus.shared.publish(kind: "pane.split", payload: .object(["workspace_id": .string(wid.value.uuidString), "surface": encode(s)]))
                return .init(id: id, result: encode(s))
            case "surface.close":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.closeSurface(workspace: wid, surface: sid)
                }
                EventBus.shared.publish(kind: "surface.closed", payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.focus":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.focusSurface(workspace: wid, surface: sid)
                }
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
                if let terminalRouter = router as? TerminalCommandRouting {
                    return .init(id: id, result: try terminalRouter.sendTextResult(surface: sid, text: text))
                }
                try router.sendText(surface: sid, text: text)
                // UX-009: fold a liveness check into the response so a
                // non-terminal surface reports "delivered" only when the
                // target is alive; a dead surface reports "accepted" + a
                // warning instead of falsely reading as success.
                let alive = router.surfaceHealth(surface: sid)
                return .init(id: id, result: .object([
                    "status": .string(alive ? "delivered" : "accepted"),
                    "accepted": .bool(true),
                    "delivered": .bool(alive),
                    "surface_alive": .bool(alive)
                ]))
            case "surface.send_key":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let key = params["key"]?.stringValue else { throw JSONRPCError.invalidParams }
                let sequence = encodeKey(key)
                if let terminalRouter = router as? TerminalCommandRouting {
                    return .init(id: id, result: try terminalRouter.sendTextResult(surface: sid, text: sequence))
                }
                try router.sendText(surface: sid, text: sequence)
                // UX-009: same delivered/accepted liveness contract as
                // surface.send_text for non-terminal surfaces.
                let alive = router.surfaceHealth(surface: sid)
                return .init(id: id, result: .object([
                    "status": .string(alive ? "delivered" : "accepted"),
                    "accepted": .bool(true),
                    "delivered": .bool(alive),
                    "surface_alive": .bool(alive)
                ]))
            case "surface.health":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                if let terminalRouter = router as? TerminalCommandRouting {
                    return .init(id: id, result: terminalRouter.surfaceHealthDetails(surface: sid))
                }
                let alive = router.surfaceHealth(surface: sid)
                return .init(id: id, result: .object(["alive": .bool(alive)]))
            case "surface.clear_history":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                router.surfaceClearHistory(surface: sid)
                return .init(id: id, result: .bool(true))
            case "surface.read_text":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                if params["include_metadata"]?.boolValue == true,
                   let terminalRouter = router as? TerminalCommandRouting {
                    return .init(id: id, result: try terminalRouter.readTextSnapshot(surface: sid))
                }
                let text = try router.readText(surface: sid)
                return .init(id: id, result: .string(text))
            case "surface.read_history":
                guard let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init) else { throw JSONRPCError.invalidParams }
                let before = params["before_chunk_id"]?.intValue.map(Int64.init)
                let maxBytes = params["max_bytes"]?.intValue ?? (256 * 1024)
                let window = try router.readTerminalHistory(surface: sid, beforeChunkID: before, maxBytes: maxBytes)
                var result: [String: JSONValue] = [
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
                ]
                result["surface_seq"] = .number(Double(SurfaceOutputBus.shared.currentSequence(sid)))
                return .init(id: id, result: .object(result))
            case "agent.open":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let s = try router.openAgentApp(workspace: wid)
                return .init(id: id, result: encode(s))
            case "agent.thread.list":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let threads = try router.listAgentThreads(workspace: wid)
                // PERF-007: one batch query for all threads instead of N per-thread queries.
                let lockedThreads = (try? router.threadIdsWithMessages()) ?? []
                return .init(id: id, result: .array(threads.map { encodeThread($0, lockedThreads: lockedThreads) }))
            case "agent.thread.create":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let title = params["title"]?.stringValue ?? "New thread"
                let modelSelection = modelSelection(from: params["model_selection"])
                let provider = modelSelection?.provider ?? (AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue ?? "fake-model"
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init) ?? .supervised
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init) ?? .medium
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init) ?? .auto
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let t = try router.createAgentThread(workspace: wid, title: title, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
                EventBus.shared.publish(kind: "agent.thread.created", payload: threadPayload(t))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.configure":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let modelSelection = modelSelection(from: params["model_selection"])
                let provider = modelSelection?.provider ?? params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init)
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let t = try router.configureAgentThread(thread: tid, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
                var payload: [String: JSONValue] = [
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "provider": .string(t.provider.rawValue),
                    "model": .string(t.model)
                ]
                payload["provider_instance_id"] = t.providerInstanceId.map { .string($0) } ?? .null
                payload["providerInstanceId"] = t.providerInstanceId.map { .string($0) } ?? .null
                payload["permission_mode"] = .string(t.permissionMode.rawValue)
                payload["reasoning_effort"] = .string(t.reasoningEffort.rawValue)
                payload["service_tier"] = .string(t.serviceTier.rawValue)
                payload["model_selection"] = encode(t.modelSelection)
                payload["provider_locked"] = .bool(providerLocked(t))
                payload["providerLocked"] = .bool(providerLocked(t))
                EventBus.shared.publish(kind: "agent.thread.updated", payload: .object(payload))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.execution.configure":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let modeValue = params["execution_mode"]?.stringValue,
                      let mode = AgentExecutionMode(rawValue: modeValue) else { throw JSONRPCError.invalidParams }
                let t = try router.configureAgentThreadExecution(thread: tid, executionMode: mode, baseBranch: params["base_branch"]?.stringValue)
                EventBus.shared.publish(kind: "agent.thread.updated", payload: threadPayload(t))
                return .init(id: id, result: encodeThread(t))
            case "agent.thread.prepare_pr":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let url = params["url"]?.stringValue else { throw JSONRPCError.invalidParams }
                let modelSelection = modelSelection(from: params["model_selection"])
                let provider = modelSelection?.provider ?? (AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue ?? "fake-model"
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init) ?? .supervised
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init) ?? .medium
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init) ?? .auto
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let t = try router.prepareAgentThreadForPullRequest(workspace: wid, url: url, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
                EventBus.shared.publish(kind: "agent.thread.created", payload: threadPayload(t))
                return .init(id: id, result: encodeThread(t))
            case "agent.attachment.upload":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let filename = params["filename"]?.stringValue,
                      let dataBase64 = params["data_base64"]?.stringValue ?? params["dataBase64"]?.stringValue else { throw JSONRPCError.invalidParams }
                let uploaded = try router.uploadAgentAttachment(workspace: wid, filename: filename, mimeType: params["mime_type"]?.stringValue ?? params["mimeType"]?.stringValue, dataBase64: dataBase64)
                EventBus.shared.publish(kind: "agent.attachment.uploaded", payload: .object([
                    "workspace_id": .string(wid.value.uuidString),
                    "path": .string(uploaded.path),
                    "display_name": .string(uploaded.displayName),
                    "size_bytes": .number(Double(uploaded.sizeBytes))
                ]))
                return .init(id: id, result: encode(uploaded))
            case "agent.thread.select":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                try router.selectAgentThread(thread: tid)
                EventBus.shared.publish(kind: "agent.thread.selected", payload: .object(["thread_id": .string(tid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "agent.message.send":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let modelSelection = modelSelection(from: params["model_selection"])
                let provider = modelSelection?.provider ?? params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init)
                let interactionMode = params["interaction_mode"]?.stringValue.flatMap(AgentInteractionMode.init)
                let providerInstanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let attachments = agentAttachments(from: params["attachments"])
                let sendResult = try await router.sendAgentMessage(thread: tid, text: text, provider: provider, model: model, permissionMode: permission, reasoningEffort: reasoning, serviceTier: serviceTier, interactionMode: interactionMode, modelSelection: modelSelection, providerInstanceId: providerInstanceId, attachments: attachments)
                let result = messageSendResultPayload(sendResult)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.queue.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.listAgentQueuedMessages(thread: tid)))
            case "agent.message.queue.update":
                guard let qid = params["queued_message_id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init)
                        ?? params["id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init),
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let updated = try router.updateAgentQueuedMessage(id: qid, text: text, attachments: agentAttachments(from: params["attachments"]))
                let result = queuedMessagePayload(updated)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.queue.cancel":
                guard let qid = params["queued_message_id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init)
                        ?? params["id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let cancelled = try router.cancelAgentQueuedMessage(id: qid)
                let result = queuedMessagePayload(cancelled)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.queue.force_now":
                guard let qid = params["queued_message_id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init)
                        ?? params["id"]?.stringValue.flatMap(UUID.init).map(AgentQueuedMessageID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let forced = try await router.forceAgentQueuedMessageNow(id: qid)
                let result = messageSendResultPayload(forced)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.plan.implement":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let planId = params["plan_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let modelSelection = modelSelection(from: params["model_selection"])
                let provider = modelSelection?.provider ?? params["provider"]?.stringValue.flatMap(AgentProvider.init)
                let model = modelSelection?.effectiveModel ?? params["model"]?.stringValue
                let permission = params["permission_mode"]?.stringValue.flatMap(AgentPermissionMode.init)
                let reasoning = modelSelection?.reasoningEffort ?? params["reasoning_effort"]?.stringValue.flatMap(AgentReasoningEffort.init)
                let serviceTier = modelSelection?.serviceTier ?? params["service_tier"]?.stringValue.flatMap(AgentServiceTier.init)
                let implemented = try await router.implementAgentPlan(
                    thread: tid,
                    planId: planId,
                    planMarkdown: params["markdown"]?.stringValue,
                    newThread: params["new_thread"]?.boolValue ?? false,
                    provider: provider,
                    model: model,
                    permissionMode: permission,
                    reasoningEffort: reasoning,
                    serviceTier: serviceTier,
                    modelSelection: modelSelection
                )
                EventBus.shared.publish(kind: "agent.plan.implemented", payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "plan_id": .string(planId),
                    "implementation_thread_id": .string(implemented.implementationThreadId.value.uuidString),
                    "run_id": .string(implemented.runId.value.uuidString)
                ]))
                let result: JSONValue = .object([
                    "run_id": .string(implemented.runId.value.uuidString),
                    "implementation_thread_id": .string(implemented.implementationThreadId.value.uuidString)
                ])
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.plan.save":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let planId = params["plan_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let saved = try router.saveAgentPlan(
                    thread: tid,
                    planId: planId,
                    planMarkdown: params["markdown"]?.stringValue,
                    relativePath: params["relative_path"]?.stringValue
                )
                let result: JSONValue = .object([
                    "path": .string(saved.path),
                    "relative_path": .string(saved.relativePath)
                ])
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.message.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let limit = params["limit"]?.intValue ?? 200
                if params["pagination"]?.boolValue == true || params["page"]?.boolValue == true {
                    let page = try router.listAgentMessagesPage(
                        thread: tid,
                        limit: limit,
                        before: messageCursor(from: params["before"]),
                        after: messageCursor(from: params["after"])
                    )
                    return .init(id: id, result: messagePagePayload(page))
                }
                return .init(id: id, result: encode(try router.listAgentMessages(thread: tid, limit: limit)))
            case "agent.message.get":
                guard let mid = params["message_id"]?.stringValue.flatMap(UUID.init).map(AgentMessageID.init) else { throw JSONRPCError.invalidParams }
                guard let message = try router.getAgentMessage(id: mid) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(message))
            case "agent.run.stop":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.stopAgentRun(thread: tid)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.request.respond":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let requestId = params["request_id"]?.stringValue,
                      let decision = params["decision"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let response: AgentProviderRequestResponse
                switch decision {
                case "approve": response = .approve
                case "approve_for_session", "approveForSession": response = .approveForSession
                case "decline": response = .decline(params["message"]?.stringValue)
                case "cancel": response = .cancel
                default: throw JSONRPCError.invalidParams
                }
                try router.respondAgentRequest(thread: tid, requestId: requestId, response: response)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.user_input.respond":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let requestId = params["request_id"]?.stringValue,
                      let text = params["text"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.respondAgentUserInput(thread: tid, requestId: requestId, text: text)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.pending_callbacks.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.listAgentPendingCallbacks(thread: tid)))
            case "agent.thread.read":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.readAgentThreadEvents(thread: tid)))
            case "agent.thread.rollback":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let turnId = params["turn_id"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.rollbackAgentThread(thread: tid, toTurnId: turnId)
                let result: JSONValue = .bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.checkpoint.list":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.listAgentThreadCheckpoints(thread: tid)))
            case "agent.checkpoint.diff":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let turnCount = params["turn_count"]?.intValue else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: .string(try router.agentCheckpointDiff(thread: tid, checkpointTurnCount: turnCount, path: params["path"]?.stringValue)))
            case "agent.checkpoint.revert":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let turnCount = params["turn_count"]?.intValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let checkpoint = try router.revertAgentThreadToCheckpoint(thread: tid, checkpointTurnCount: turnCount)
                EventBus.shared.publish(kind: "agent.checkpoint.reverted", payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "turn_count": .number(Double(checkpoint.checkpointTurnCount)),
                    "turn_id": .string(checkpoint.turnId),
                    "checkpoint_ref": .string(checkpoint.checkpointRef)
                ]))
                let result = encode(checkpoint)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.delete":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.deleteAgentThread(thread: tid)
                EventBus.shared.publish(kind: "agent.thread.deleted", payload: .object(["thread_id": .string(tid.value.uuidString)]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.delete_many":
                guard case .array(let values) = params["thread_ids"] ?? .null else { throw JSONRPCError.invalidParams }
                let tids = values.compactMap { $0.stringValue.flatMap(UUID.init).map(AgentThreadID.init) }
                guard !tids.isEmpty else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.deleteAgentThreads(tids)
                EventBus.shared.publish(kind: "agent.thread.deleted_many", payload: .object([
                    "thread_ids": .array(tids.map { .string($0.value.uuidString) })
                ]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.rename":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let title = params["title"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let t = try router.renameAgentThread(thread: tid, title: title)
                EventBus.shared.publish(kind: "agent.thread.renamed", payload: threadPayload(t))
                let result = encodeThread(t)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.set_pinned":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let pinned = params["pinned"]?.boolValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
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
                let result = encodeThread(t)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.set_color":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init),
                      let color = params["color"]?.stringValue else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let t = try router.setAgentThreadColor(thread: tid, color: color)
                EventBus.shared.publish(kind: "agent.thread.updated", payload: .object([
                    "thread_id": .string(t.id.value.uuidString),
                    "workspace_id": t.workspaceId.map { .string($0.value.uuidString) } ?? .null,
                    "color": t.color.map { .string($0) } ?? .string(""),
                    "provider_locked": .bool(providerLocked(t)),
                    "providerLocked": .bool(providerLocked(t))
                ]))
                let result = encodeThread(t)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.reorder":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let list = try router.reorderAgentThread(thread: tid, position: pos)
                let wid = list.first(where: { $0.id == tid })?.workspaceId
                EventBus.shared.publish(kind: "agent.thread.reordered", payload: .object([
                    "thread_id": .string(tid.value.uuidString),
                    "workspace_id": wid.map { .string($0.value.uuidString) } ?? .null,
                    "position": .number(Double(pos)),
                    "order": .array(list.map { .string($0.id.value.uuidString) })
                ]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "agent.thread.mark_read":
                guard let tid = params["thread_id"]?.stringValue.flatMap(UUID.init).map(AgentThreadID.init) else { throw JSONRPCError.invalidParams }
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                try router.markAgentThreadRead(thread: tid)
                EventBus.shared.publish(kind: "agent.thread.read", payload: .object(["thread_id": .string(tid.value.uuidString)]))
                let result = JSONValue.bool(true)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
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
                // UX-010: idempotent commit — a retried request over a flaky
                // link must not double-commit.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let r = try router.gitCommit(workspace: wid, message: message)
                EventBus.shared.publish(kind: "git.commit", payload: .object(["workspace_id": .string(wid.value.uuidString), "ok": .bool(r.ok)]))
                let result = encode(r)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
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
                // UX-010: idempotent push — a retried request must not push
                // twice.
                let receiptKey = params["client_request_id"]?.stringValue
                if let (_, cached) = commandReceipt(method: req.method, params: params) {
                    return .init(id: id, result: cached)
                }
                let r = try router.gitPush(workspace: wid)
                EventBus.shared.publish(kind: "git.push", payload: .object(["workspace_id": .string(wid.value.uuidString), "ok": .bool(r.ok)]))
                let result = encode(r)
                recordCommandReceipt(method: req.method, clientRequestId: receiptKey, result: result)
                return .init(id: id, result: result)
            case "git.pull_request_url":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let url = try router.gitPullRequestURL(workspace: wid)
                return .init(id: id, result: .object(["url": url.map { .string($0) } ?? .null]))
            case "git.delivery_plan":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                return .init(id: id, result: encode(try router.gitDeliveryPlan(workspace: wid, copy: gitDeliveryCopy(from: params))))
            case "git.deliver":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let r = try router.gitDeliver(workspace: wid, copy: gitDeliveryCopy(from: params))
                EventBus.shared.publish(kind: "git.deliver", payload: .object(["workspace_id": .string(wid.value.uuidString), "ok": .bool(r.ok)]))
                return .init(id: id, result: encode(r))
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
            case "agent.providers.list":
                return .init(id: id, result: encode(await router.listAgentProviderSnapshots()))
            case "agent.provider.update":
                let provider = AgentProvider(rawValue: params["provider"]?.stringValue ?? "codex") ?? .codex
                let instanceId = params["provider_instance_id"]?.stringValue ?? params["providerInstanceId"]?.stringValue
                let result = try await router.updateAgentProvider(provider: provider, providerInstanceId: instanceId)
                EventBus.shared.publish(kind: "agent.provider.updated", payload: result)
                return .init(id: id, result: result)
            case "agent.state.current":
                let w = try router.currentWindow()
                return .init(id: id, result: .object([
                    "selected_workspace_id": w.selectedWorkspaceID.map { .string($0.value.uuidString) } ?? .null
                ]))
            case "agent.prompt_history":
                let wid: WorkspaceID? = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init)
                let limit = params["limit"]?.intValue ?? PromptHistoryStore.limit
                let prompts = try router.agentPromptHistory(workspace: wid, limit: limit)
                return .init(id: id, result: .object(["prompts": .array(prompts.map { .string($0) })]))
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
            case "private.push_token.update":
                guard let pushToken = params["push_token"]?.stringValue,
                      let pushTokenType = params["push_token_type"]?.stringValue,
                      pushTokenType == "apns" || pushTokenType == "fcm" else { throw JSONRPCError.invalidParams }
                let result = try router.privatePushTokenUpdate(
                    pushToken: pushToken,
                    pushTokenType: pushTokenType,
                    liveActivityToken: params["live_activity_token"]?.stringValue,
                    deviceID: params["device_id"]?.stringValue
                )
                return .init(id: id, result: result)
            case "pane.list":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let panes = try router.paneList(workspace: wid)
                return .init(id: id, result: .array(panes.map { .object($0) }))
            case "pane.surfaces":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let surfaces: [SurfaceDescriptor]
                if let pid = params["id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) {
                    surfaces = try router.paneSurfaces(pane: pid, workspace: wid)
                } else {
                    let paneIDs = try router.paneList(workspace: wid).compactMap { row in
                        row["kind"]?.stringValue == "pane"
                            ? row["id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                            : nil
                    }
                    surfaces = try paneIDs.flatMap { try router.paneSurfaces(pane: $0, workspace: wid) }
                }
                return .init(id: id, result: encode(surfaces))
            case "mirror.snapshot":
                // Collapses the iOS load() N per-pane pane.surfaces round-trips into ONE call.
                // "panes" is the verbatim pane.list encoding; each "surfaces" is the verbatim
                // pane.surfaces encoding so iOS reuses its existing decoders unchanged.
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init) else { throw JSONRPCError.invalidParams }
                let panes = try router.paneList(workspace: wid)
                let paneIDs = panes.compactMap { row in
                    row["kind"]?.stringValue == "pane"
                        ? row["id"]?.stringValue.flatMap(UUID.init).map(PaneID.init)
                        : nil
                }
                let perPane: [JSONValue] = try paneIDs.map { pid in
                    let surfaces = try router.paneSurfaces(pane: pid, workspace: wid)
                    return .object([
                        "pane_id": .string(pid.value.uuidString),
                        "surfaces": encode(surfaces)
                    ])
                }
                return .init(id: id, result: .object([
                    "panes": .array(panes.map { .object($0) }),
                    "pane_surfaces": .array(perPane)
                ]))
            case "pane.resize":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let split = params["split_id"]?.stringValue.flatMap(UUID.init) else { throw JSONRPCError.invalidParams }
                var ratios: [Double] = []
                if case .array(let arr) = params["ratios"] ?? .null {
                    for v in arr { if case .number(let n) = v { ratios.append(n) } }
                }
                try withSuppressedLayoutEvents {
                    try router.paneResize(workspace: wid, splitID: split, ratios: ratios)
                }
                EventBus.shared.publish(kind: "pane.resized", payload: .object(["workspace_id": .string(wid.value.uuidString), "split_id": .string(split.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.move":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let pid = params["target_pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                try withSuppressedLayoutEvents {
                    try router.surfaceMove(workspace: wid, surface: sid, targetPane: pid)
                }
                EventBus.shared.publish(kind: "surface.moved", payload: .object(["workspace_id": .string(wid.value.uuidString), "id": .string(sid.value.uuidString), "target_pane_id": .string(pid.value.uuidString)]))
                return .init(id: id, result: .bool(true))
            case "surface.reorder":
                guard let wid = params["workspace_id"]?.stringValue.flatMap(UUID.init).map(WorkspaceID.init),
                      let sid = params["id"]?.stringValue.flatMap(UUID.init).map(SurfaceID.init),
                      let pid = params["target_pane_id"]?.stringValue.flatMap(UUID.init).map(PaneID.init) else { throw JSONRPCError.invalidParams }
                let pos = params["position"]?.intValue ?? 0
                try withSuppressedLayoutEvents {
                    try router.surfaceReorder(workspace: wid, surface: sid, toPane: pid, position: pos)
                }
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
            // UX-005: map known domain errors to a stable code + concise,
            // user-presentable message + structured data so the client can
            // classify them and avoid surfacing raw Swift debug dumps. The
            // verbose form is logged separately; only truly unexpected
            // errors fall through to -32000/String(describing:).
            return .init(id: id, error: Self.mapDomainError(error, method: req.method))
        }
    }

    /// UX-005: translate known domain errors into stable JSON-RPC codes.
    /// `-32010` provider/agent, `-32011` persistence, `-32012` missing
    /// binary. Unknown errors return `-32000` + a generic user-safe message
    /// ("An unexpected error occurred on the host."); the verbose form is
    /// always logged host-side via NSLog so no internal detail leaks to iOS.
    static func mapDomainError(_ error: Error, method: String) -> JSONRPCError {
        let verbose = String(describing: error)
        switch error {
        case let e as AgentProviderAdapterError:
            switch e {
            case .sessionNotFound:
                NSLog("[RC2.Dispatch] %@ provider session not found: %@", method, verbose)
                return JSONRPCError(code: -32010, message: "Agent session not found.",
                                    data: .object(["domain": .string("agent"), "kind": .string("session_not_found")]))
            case .unsupported(let op):
                NSLog("[RC2.Dispatch] %@ provider unsupported: %@", method, verbose)
                return JSONRPCError(code: -32010, message: "Agent operation is not available right now.",
                                    data: .object(["domain": .string("agent"), "kind": .string("unsupported"), "detail": .string(op)]))
            }
        case let e as PersistenceDataError:
            NSLog("[RC2.Dispatch] %@ persistence error: %@", method, verbose)
            return JSONRPCError(code: -32011, message: "Stored data could not be read.",
                                data: .object(["domain": .string("persistence"), "detail": .string(e.description)]))
        case let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile:
            NSLog("[RC2.Dispatch] %@ file not found: %@", method, verbose)
            return JSONRPCError(code: -32012, message: "A required file was not found.",
                                data: .object(["domain": .string("filesystem"), "kind": .string("not_found")]))
        default:
            // Heuristic: provider binaries (codex/claude/git) report
            // "missing"/"not found" via untyped errors; classify those.
            let lowered = verbose.lowercased()
            if lowered.contains("missingbinary") || lowered.contains("binary not found") || lowered.contains("executable not found") {
                NSLog("[RC2.Dispatch] %@ missing binary: %@", method, verbose)
                return JSONRPCError(code: -32012, message: "A required command-line tool is not installed.",
                                    data: .object(["domain": .string("binary"), "detail": .string(verbose)]))
            }
            NSLog("[RC2.Dispatch] %@ unexpected error: %@", method, verbose)
            return JSONRPCError(code: -32000, message: "An unexpected error occurred on the host.")
        }
    }

    nonisolated public static func isReadOnlyBatchMethod(_ method: String) -> Bool {
        method.hasPrefix("system.")
            || method == "workspace.list"
            || method == "workspace.current"
            || method == "events.recent"
            || method == "settings.get"
            || method == "agent.prompt_history"
            || method.hasSuffix(".list")
            || method.hasSuffix(".read")
            || method.hasSuffix(".status")
            || method.hasSuffix(".get")
    }

    // MARK: - P2 per-route capability scopes

    /// RPC namespaces the dispatcher actually serves. A method whose namespace
    /// is not here is "unknown" and fails closed for any scoped device (only a
    /// "*" device may invoke it). Kept in sync with the dispatch `switch` by
    /// prefix, not an exact method list, so it tolerates the switch growing
    /// within an existing namespace.
    nonisolated private static let knownMethodNamespaces: Set<String> = [
        "system", "events", "settings", "rpc",
        "ssh", "fs", "files",
        "workspace", "window", "surface", "pane",
        "agent", "git", "project", "browser",
        "notification", "private"
    ]

    /// Required capability for a known method, or nil when the method is not
    /// recognized (unknown -> caller must hold "*").
    ///
    /// Buckets, matching the conventions already used elsewhere in this file:
    ///   - "file": filesystem + file-editor surface (`fs.*`, `files.*`).
    ///   - "read": read-only methods (`isReadOnlyBatchMethod`), e.g. *.list /
    ///     *.read / *.status / *.get, system.*, events.recent, settings.get.
    ///   - "write": every other known (mutating) method.
    nonisolated static func requiredCapability(for method: String) -> String? {
        guard let namespace = method.split(separator: ".").first.map(String.init),
              knownMethodNamespaces.contains(namespace) else {
            return nil
        }
        if namespace == "fs" || namespace == "files" {
            return "file"
        }
        if isReadOnlyBatchMethod(method) {
            return "read"
        }
        return "write"
    }

    /// Parse a stored `DeviceTrust.capabilities` string into a granted set.
    /// "*" (anywhere in the list) means "all capabilities". Tokens are
    /// separated by commas and/or whitespace; empty tokens are ignored.
    nonisolated static func parseCapabilities(_ raw: String) -> Set<String> {
        let tokens = raw
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\t" })
            .map { $0.lowercased() }
        return Set(tokens)
    }

    /// Authorization decision for one RPC `method` given a device's stored
    /// `grantedCapabilities` string. Pure: no actor state, no I/O.
    ///
    /// Contract:
    ///   - "*" grants everything (back-compat: every already-paired device).
    ///   - otherwise the method's required capability (`requiredCapability`)
    ///     must be in the granted set; an unknown method has no required
    ///     capability and is denied (fail closed).
    nonisolated static func isAuthorized(method: String, grantedCapabilities: String) -> Bool {
        let granted = parseCapabilities(grantedCapabilities)
        if granted.contains("*") { return true }
        guard let needed = requiredCapability(for: method) else { return false }
        return granted.contains(needed)
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
        let dirURL = URL(fileURLWithPath: path, isDirectory: true)
        let childURLs = try fm.contentsOfDirectory(at: dirURL,
                                                    includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [])
        let entries = childURLs.map { url -> (Bool, String, JSONValue) in
            let name = url.lastPathComponent
            // resourceValues(forKeys:) is a single prefetched-stat read; falls back to
            // false (not a directory) if the key is unavailable (e.g. broken symlinks).
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return (isDirectory, name, .object([
                "name": .string(name),
                "path": .string(url.path),
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

    private let _encoder = JSONEncoder()
    private let _decoder = JSONDecoder()

    private func encode<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? _encoder.encode(value),
              let result = try? _decoder.decode(JSONValue.self, from: data) else {
            return .null
        }
        return result
    }

    private func workspaceID(from params: [String: JSONValue]) throws -> WorkspaceID {
        guard let raw = params["workspace_id"]?.stringValue ?? params["workspaceId"]?.stringValue,
              let uuid = UUID(uuidString: raw) else {
            throw JSONRPCError.invalidParams
        }
        return WorkspaceID(uuid)
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
        object["model_selection"] = encode(thread.modelSelection)
        object["provider_instance_id"] = thread.providerInstanceId.map { .string($0) } ?? .null
        object["execution_mode"] = .string(thread.executionMode.rawValue)
        object["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        object["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        let locked = providerLocked(thread)
        object["providerLocked"] = .bool(locked)
        object["provider_locked"] = .bool(locked)
        return .object(object)
    }

    /// Batch overload used by agent.thread.list (PERF-007): caller pre-fetches
    /// the locked set once; no additional query is issued per thread.
    private func encodeThread(_ thread: AgentThread, lockedThreads: Set<AgentThreadID>) -> JSONValue {
        guard case .object(var object) = encode(thread) else { return .null }
        let display = AgentThreadTitle.display(thread.title)
        object["displayTitle"] = .string(display)
        object["display_title"] = .string(display)
        object["model_selection"] = encode(thread.modelSelection)
        object["provider_instance_id"] = thread.providerInstanceId.map { .string($0) } ?? .null
        object["execution_mode"] = .string(thread.executionMode.rawValue)
        object["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        object["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        let locked = lockedThreads.contains(thread.id)
        object["providerLocked"] = .bool(locked)
        object["provider_locked"] = .bool(locked)
        return .object(object)
    }

    private func messageSendResultPayload(_ result: AgentMessageSendResult) -> JSONValue {
        var payload: [String: JSONValue] = ["status": .string(result.status.rawValue)]
        if let runId = result.runId {
            payload["run_id"] = .string(runId.value.uuidString)
        }
        if let queued = result.queuedMessage {
            payload["queued_message_id"] = .string(queued.id.value.uuidString)
            payload["position"] = .number(Double(queued.position))
            payload["queued_message"] = queuedMessagePayload(queued)
        }
        return .object(payload)
    }

    private func queuedMessagePayload(_ message: AgentQueuedMessage) -> JSONValue {
        guard case .object(var object) = encode(message) else { return .null }
        object["id"] = .string(message.id.value.uuidString)
        object["thread_id"] = .string(message.threadId.value.uuidString)
        object["threadId"] = .string(message.threadId.value.uuidString)
        object["interaction_mode"] = .string(message.interactionMode.rawValue)
        object["interactionMode"] = .string(message.interactionMode.rawValue)
        object["attachments"] = encode(message.attachments)
        object["position"] = .number(Double(message.position))
        object["created_at"] = .string(iso8601(message.createdAt))
        object["updated_at"] = .string(iso8601(message.updatedAt))
        return .object(object)
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func messageCursor(from value: JSONValue?) -> AgentMessageCursor? {
        guard case .object(let object) = value,
              let id = object["id"]?.stringValue.flatMap(UUID.init).map(AgentMessageID.init) else {
            return nil
        }
        if let created = object["created_at"]?.stringValue ?? object["createdAt"]?.stringValue {
            return AgentMessageCursor(createdAt: parseISO8601(created), id: id)
        }
        return nil
    }

    private func parseISO8601(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? Date(timeIntervalSinceReferenceDate: 0)
    }

    private func messagePagePayload(_ page: AgentMessagePage) -> JSONValue {
        var object: [String: JSONValue] = [
            "messages": encode(page.messages),
            "has_more_older": .bool(page.hasMoreOlder),
            "hasMoreOlder": .bool(page.hasMoreOlder),
            "has_more_newer": .bool(page.hasMoreNewer),
            "hasMoreNewer": .bool(page.hasMoreNewer)
        ]
        if let cursor = page.nextBefore {
            let encoded: JSONValue = .object([
                "created_at": .string(iso8601(cursor.createdAt)),
                "createdAt": .string(iso8601(cursor.createdAt)),
                "id": .string(cursor.id.value.uuidString)
            ])
            object["next_before"] = encoded
            object["nextBefore"] = encoded
        } else {
            object["next_before"] = .null
            object["nextBefore"] = .null
        }
        if let cursor = page.nextAfter {
            let encoded: JSONValue = .object([
                "created_at": .string(iso8601(cursor.createdAt)),
                "createdAt": .string(iso8601(cursor.createdAt)),
                "id": .string(cursor.id.value.uuidString)
            ])
            object["next_after"] = encoded
            object["nextAfter"] = encoded
        } else {
            object["next_after"] = .null
            object["nextAfter"] = .null
        }
        return .object(object)
    }

    private func modelSelection(from value: JSONValue?) -> AgentModelSelection? {
        guard case .object(let object) = value else { return nil }
        guard let providerValue = object["provider"]?.stringValue,
              let provider = AgentProvider(rawValue: providerValue) else { return nil }
        let modelId = object["modelId"]?.stringValue ?? object["model_id"]?.stringValue ?? object["model"]?.stringValue ?? ""
        let customModelId = object["customModelId"]?.stringValue ?? object["custom_model_id"]?.stringValue
        let reasoning = (object["reasoningEffort"]?.stringValue ?? object["reasoning_effort"]?.stringValue)
            .flatMap(AgentReasoningEffort.init) ?? .medium
        let serviceTier = (object["serviceTier"]?.stringValue ?? object["service_tier"]?.stringValue)
            .flatMap(AgentServiceTier.init) ?? .auto
        return AgentModelSelection(
            provider: provider,
            modelId: modelId,
            customModelId: customModelId,
            reasoningEffort: reasoning,
            serviceTier: serviceTier
        )
    }

    private func agentAttachments(from value: JSONValue?) -> [AgentAttachment] {
        guard case .array(let values) = value else { return [] }
        return values.compactMap { value -> AgentAttachment? in
            guard case .object(let object) = value,
                  let path = object["path"]?.stringValue,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let kindRaw = object["kind"]?.stringValue ?? "file"
            let kind = AgentAttachmentKind(rawValue: kindRaw) ?? .file
            let displayName = object["displayName"]?.stringValue ?? object["display_name"]?.stringValue
            let mimeType = object["mimeType"]?.stringValue ?? object["mime_type"]?.stringValue
            return AgentAttachment(path: path, displayName: displayName, kind: kind, mimeType: mimeType)
        }
    }

    private func gitDeliveryCopy(from params: [String: JSONValue]) -> GitDeliveryCopy? {
        let object = params["copy"]?.objectValue ?? params["delivery_copy"]?.objectValue ?? params
        let copy = GitDeliveryCopy(
            branchName: object["branchName"]?.stringValue ?? object["branch_name"]?.stringValue,
            commitMessage: object["commitMessage"]?.stringValue ?? object["commit_message"]?.stringValue,
            pullRequestTitle: object["pullRequestTitle"]?.stringValue ?? object["pull_request_title"]?.stringValue,
            pullRequestBody: object["pullRequestBody"]?.stringValue ?? object["pull_request_body"]?.stringValue
        )
        return copy.branchName == nil &&
            copy.commitMessage == nil &&
            copy.pullRequestTitle == nil &&
            copy.pullRequestBody == nil ? nil : copy
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
            "provider_instance_id": thread.providerInstanceId.map { .string($0) } ?? .null,
            "providerInstanceId": thread.providerInstanceId.map { .string($0) } ?? .null,
            "model": .string(thread.model),
            "provider_locked": .bool(locked),
            "providerLocked": .bool(locked),
            "permission_mode": .string(thread.permissionMode.rawValue),
            "reasoning_effort": .string(thread.reasoningEffort.rawValue),
            "service_tier": .string(thread.serviceTier.rawValue),
            "model_selection": encode(thread.modelSelection),
            "execution_mode": .string(thread.executionMode.rawValue)
        ]
        payload["base_branch"] = thread.baseBranch.map { .string($0) } ?? .null
        payload["worktree_path"] = thread.worktreePath.map { .string($0) } ?? .null
        payload["color"] = thread.color.map { .string($0) } ?? .null
        payload["pinned"] = .bool(thread.pinned)
        payload["sort_order"] = .number(Double(thread.sortOrder))
        return .object(payload)
    }

    private func providerLocked(_ thread: AgentThread) -> Bool {
        !((try? router.listAgentMessages(thread: thread.id, limit: 1)) ?? []).isEmpty
    }
}
