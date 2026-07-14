import XCTest
@testable import SocketServer
import CoreModel
import Persistence
import AgentRuntime

@MainActor
class FakeRouter: CommandRouting, TerminalCommandRouting {
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
    func closeWorkspace(_ id: WorkspaceID, publishEvent: Bool = true) throws { workspaces.removeAll { $0.id == id } }
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
        SurfaceDescriptor(type: type, title: title ?? type.rawValue, metadata: type == .ssh ? ["ssh_status": "disconnected"] : [:])
    }
    func splitPane(workspace: WorkspaceID, paneID: PaneID, direction: SplitDirection, surfaceType: SurfaceType, title: String?) throws -> SurfaceDescriptor {
        SurfaceDescriptor(type: surfaceType, title: title ?? surfaceType.rawValue)
    }
    var filesOpenTabCalls: [(WorkspaceID, SurfaceID?, PaneID?, String)] = []
    func filesOpenTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, path: String) throws -> SurfaceDescriptor {
        filesOpenTabCalls.append((workspace, sourceSurface, paneID, path))
        return SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent, metadata: [
            "selected_path": path,
            "selected_relative_path": path
        ])
    }
    var filesSplitTabCalls: [(WorkspaceID, SurfaceID?, PaneID?, SplitDirection, String)] = []
    func filesSplitTab(workspace: WorkspaceID, sourceSurface: SurfaceID?, paneID: PaneID?, direction: SplitDirection, path: String) throws -> SurfaceDescriptor {
        filesSplitTabCalls.append((workspace, sourceSurface, paneID, direction, path))
        return SurfaceDescriptor(type: .files, title: (path as NSString).lastPathComponent, metadata: [
            "selected_path": path,
            "selected_relative_path": path
        ])
    }
    var splitSurfaceCalls: [(WorkspaceID, PaneID, SurfaceID, SplitDirection)] = []
    func splitSurface(workspace: WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection) throws {
        splitSurfaceCalls.append((workspace, paneID, surface, direction))
    }
    func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {}
    func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws {}
    func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws {}
    var sentSurfaceText: [(SurfaceID, String)] = []
    func sendText(surface: SurfaceID, text: String) throws { sentSurfaceText.append((surface, text)) }
    var terminalSendResult: JSONValue = .object(["status": .string("accepted"), "accepted": .bool(true)])
    func sendTextResult(surface: SurfaceID, text: String) throws -> JSONValue {
        sentSurfaceText.append((surface, text))
        return terminalSendResult
    }
    func readText(surface: SurfaceID) throws -> String { "" }
    var terminalSnapshot: JSONValue = .object([
        "text": .string(""),
        "complete": .bool(true),
        "partial": .bool(false),
        "source": .string("test")
    ])
    func readTextSnapshot(surface: SurfaceID) throws -> JSONValue { terminalSnapshot }
    var terminalHistory = TerminalOutputWindow(chunks: [], hasMoreOlder: false, nextBeforeChunkID: nil)
    var lastHistoryRequest: (SurfaceID, Int64?, Int)?
    func readTerminalHistory(surface: SurfaceID, beforeChunkID: Int64?, maxBytes: Int) throws -> TerminalOutputWindow {
        lastHistoryRequest = (surface, beforeChunkID, maxBytes)
        return terminalHistory
    }
    func surfaceHealth(surface: SurfaceID) -> Bool { true }
    var terminalHealth: JSONValue = .object(["alive": .bool(true), "process_alive": .bool(true), "input_accepting": .bool(true)])
    func surfaceHealthDetails(surface: SurfaceID) -> JSONValue { terminalHealth }
    func surfaceClearHistory(surface: SurfaceID) {}
    var sshHostsByWorkspace: [WorkspaceID: [SSHHostProfile]] = [:]
    func sshHostList(workspace: WorkspaceID) throws -> [SSHHostProfile] {
        sshHostsByWorkspace[workspace, default: []].map { host in
            var copy = host
            copy.hasSavedPassword = copy.hasSavedPassword || (copy.password?.isEmpty == false)
            copy.password = nil
            return copy
        }
    }
    func sshHostUpsert(_ profile: SSHHostProfile, workspace: WorkspaceID) throws -> SSHHostProfile {
        var hosts = sshHostsByWorkspace[workspace, default: []]
        var saved = profile
        if let idx = hosts.firstIndex(where: { $0.id == profile.id }) {
            if saved.password?.isEmpty == false {
                saved.hasSavedPassword = true
            } else {
                saved.password = hosts[idx].password
                saved.hasSavedPassword = hosts[idx].hasSavedPassword || (hosts[idx].password?.isEmpty == false)
            }
            hosts[idx] = saved
        } else {
            saved.hasSavedPassword = saved.hasSavedPassword || (saved.password?.isEmpty == false)
            hosts.append(saved)
        }
        sshHostsByWorkspace[workspace] = hosts
        return saved
    }
    func sshHostDelete(_ id: SSHHostID, workspace: WorkspaceID) throws { sshHostsByWorkspace[workspace, default: []].removeAll { $0.id == id } }
    func sshConnect(workspace: WorkspaceID, profileID: SSHHostID?, profile: SSHHostProfile?, title: String?, paneID: PaneID?) throws -> SurfaceDescriptor {
        let resolved = profile ?? profileID.flatMap { id in sshHostsByWorkspace[workspace, default: []].first { $0.id == id } } ?? SSHHostProfile(label: "SSH", destination: "example.test")
        return SurfaceDescriptor(type: .ssh, title: title ?? resolved.label, iconName: "network", metadata: [
            "ssh_profile_id": resolved.id.value.uuidString,
            "ssh_destination": resolved.destination,
            "ssh_status": "connecting"
        ])
    }
    func sshDisconnect(surface: SurfaceID) throws {}
    func sshTransferUpload(surface: SurfaceID, localPath: String, remotePath: String) throws -> JSONValue { .object(["ok": .bool(true)]) }
    func sshTransferDownload(surface: SurfaceID, remotePath: String, localPath: String) throws -> JSONValue { .object(["ok": .bool(true)]) }
    func sshFilesLocalList(path: String?) throws -> JSONValue { .object(["path": .string(path ?? "/tmp"), "entries": .array([])]) }
    func sshFilesRemoteList(surface: SurfaceID, path: String?) throws -> JSONValue { .object(["path": .string(path ?? "/"), "entries": .array([])]) }
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
    var lastCreateSurfaceID: SurfaceID?
    func createAgentThread(workspace: WorkspaceID?, title: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?, surfaceID: SurfaceID?) throws -> AgentThread {
        lastCreateSurfaceID = surfaceID
        let thread = AgentThread(workspaceId: workspace, title: title, provider: provider,
                                 providerInstanceId: providerInstanceId,
                                 model: model,
                                 permissionMode: permissionMode, reasoningEffort: reasoningEffort,
                                 serviceTier: serviceTier, modelSelection: modelSelection)
        threadStore.append(thread)
        return thread
    }
    var lastSendPermission: AgentPermissionMode?
    var lastSendReasoning: AgentReasoningEffort?
    var lastSendServiceTier: AgentServiceTier?
    var lastSendInteractionMode: AgentInteractionMode?
    var lastSendText: String?
    var lastSendAttachments: [AgentAttachment] = []
    var lastImplementedPlan: (AgentThreadID, String, AgentThreadID)?
    var lastSavedPlan: (AgentThreadID, String, String?, String?)?
    var sendAgentMessageCallCount = 0
    var commandReceipts: [String: JSONValue] = [:]
    var lastAgentRequestResponse: (AgentThreadID, String, AgentProviderRequestResponse)?
    var agentRequestResponses: [(AgentThreadID, String, AgentProviderRequestResponse)] = []
    var respondAgentRequestCallCount = 0
    var lastAgentUserInputResponse: (AgentThreadID, String, String)?
    var agentUserInputResponses: [(AgentThreadID, String, String)] = []
    var respondAgentUserInputCallCount = 0
    var readAgentEvents: [AssistantEvent] = []
    var pendingCallbackSnapshot = AssistantPendingCallbacksSnapshot()
    var lastRollback: (AgentThreadID, String)?
    var rollbackCallCount = 0
    var lastCheckpointRevert: (AgentThreadID, Int)?
    var checkpointRevertCallCount = 0
    var stopAgentRunCallCount = 0
    var stoppedAgentThreads: [AgentThreadID] = []
    var checkpointStore: [AgentTurnCheckpointSummary] = []
    var messageStore: [AgentMessage] = []
    var queuedMessageStore: [AgentQueuedMessage] = []
    func configureAgentThread(thread: AgentThreadID, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        if let provider, provider != threadStore[idx].provider {
            threadStore[idx].provider = provider
            threadStore[idx].providerInstanceId = provider.rawValue
            threadStore[idx].providerThreadId = nil
        }
        if let providerInstanceId { threadStore[idx].providerInstanceId = providerInstanceId }
        if let model, model != threadStore[idx].model {
            let canSwitchModelInSession = threadStore[idx].provider == .claude && threadStore[idx].providerThreadId?.isEmpty == false
            threadStore[idx].model = model
            if !canSwitchModelInSession {
                threadStore[idx].providerThreadId = nil
            }
        }
        if let permissionMode { threadStore[idx].permissionMode = permissionMode }
        if let reasoningEffort { threadStore[idx].reasoningEffort = reasoningEffort }
        if let serviceTier { threadStore[idx].serviceTier = serviceTier }
        if let modelSelection { threadStore[idx].modelSelection = modelSelection }
        return threadStore[idx]
    }
    func configureAgentThreadExecution(thread: AgentThreadID, executionMode: AgentExecutionMode, baseBranch: String?) throws -> AgentThread {
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].executionMode = executionMode
        threadStore[idx].baseBranch = baseBranch
        if executionMode == .local { threadStore[idx].worktreePath = nil }
        return threadStore[idx]
    }
    var lastPreparedPullRequest: (WorkspaceID, String)?
    func prepareAgentThreadForPullRequest(workspace: WorkspaceID, url: String, provider: AgentProvider, model: String, permissionMode: AgentPermissionMode, reasoningEffort: AgentReasoningEffort, serviceTier: AgentServiceTier, modelSelection: AgentModelSelection?, providerInstanceId: String?) throws -> AgentThread {
        lastPreparedPullRequest = (workspace, url)
        let thread = AgentThread(workspaceId: workspace, title: "PR #7: acme/widget", provider: provider,
                                 providerInstanceId: providerInstanceId,
                                 model: model,
                                 permissionMode: permissionMode,
                                 reasoningEffort: reasoningEffort,
                                 executionMode: .worktree,
                                 baseBranch: "rc-pr/github-com/acme-widget-7",
                                 worktreePath: "/tmp/rc-pr-7",
                                 serviceTier: serviceTier,
                                 modelSelection: modelSelection)
        threadStore.append(thread)
        return thread
    }
    func uploadAgentAttachment(workspace: WorkspaceID, filename: String, mimeType: String?, dataBase64: String) throws -> AgentAttachmentUploadResult {
        guard let data = Data(base64Encoded: dataBase64) else { throw JSONRPCError.invalidParams }
        let path = "/tmp/remotecode-attachments/\(filename)"
        return AgentAttachmentUploadResult(path: path, displayName: filename, kind: filename.hasSuffix(".png") ? .image : .file, mimeType: mimeType, sizeBytes: data.count)
    }
    var selectedThread: AgentThreadID?
    var lastSelectSurfaceID: SurfaceID?
    func selectAgentThread(thread: AgentThreadID, surfaceID: SurfaceID?) throws {
        guard threadStore.contains(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        selectedThread = thread
        lastSelectSurfaceID = surfaceID
    }
    func listAgentMessages(thread: AgentThreadID, limit: Int) throws -> [AgentMessage] {
        Array(messageStore.filter { $0.threadId == thread }.suffix(max(0, limit)))
    }
    func threadIdsWithMessages() throws -> Set<AgentThreadID> {
        Set(messageStore.map(\.threadId))
    }
    func listAgentMessagesPage(thread: AgentThreadID, limit requestedLimit: Int, before beforeCursor: AgentMessageCursor?, after afterCursor: AgentMessageCursor?) throws -> AgentMessagePage {
        let limit = max(0, min(requestedLimit, 500))
        let filtered = messageStore
            .filter { message in
                guard message.threadId == thread else { return false }
                if let cursor = afterCursor {
                    if message.createdAt != cursor.createdAt {
                        return message.createdAt > cursor.createdAt
                    }
                    return message.id.value.uuidString > cursor.id.value.uuidString
                }
                guard let cursor = beforeCursor else { return true }
                if message.createdAt != cursor.createdAt {
                    return message.createdAt < cursor.createdAt
                }
                return message.id.value.uuidString < cursor.id.value.uuidString
            }
            .sorted {
                if afterCursor != nil {
                    if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                    return $0.id.value.uuidString < $1.id.value.uuidString
                }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.value.uuidString > $1.id.value.uuidString
            }
        let pageRows = Array(filtered.prefix(limit))
        let display = afterCursor == nil ? Array(pageRows.reversed()) : pageRows
        let next = display.first.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        let after = display.last.map { AgentMessageCursor(createdAt: $0.createdAt, id: $0.id) }
        return AgentMessagePage(
            messages: display,
            hasMoreOlder: afterCursor != nil || filtered.count > limit,
            nextBefore: next,
            hasMoreNewer: beforeCursor != nil || (afterCursor != nil && filtered.count > limit),
            nextAfter: after
        )
    }
    func getAgentMessage(id: AgentMessageID) throws -> AgentMessage? {
        messageStore.first { $0.id == id }
    }
    func listAgentQueuedMessages(thread: AgentThreadID) throws -> [AgentQueuedMessage] {
        queuedMessageStore.filter { $0.threadId == thread }.sorted { $0.position < $1.position }
    }
    func updateAgentQueuedMessage(id: AgentQueuedMessageID, text: String, attachments: [AgentAttachment]) throws -> AgentQueuedMessage {
        guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        queuedMessageStore[idx].text = text
        queuedMessageStore[idx].attachments = attachments
        queuedMessageStore[idx].updatedAt = Date()
        return queuedMessageStore[idx]
    }
    func cancelAgentQueuedMessage(id: AgentQueuedMessageID) throws -> AgentQueuedMessage {
        guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        return queuedMessageStore.remove(at: idx)
    }
    func forceAgentQueuedMessageNow(id: AgentQueuedMessageID) async throws -> AgentMessageSendResult {
        guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        let queued = queuedMessageStore.remove(at: idx)
        if threadStore.first(where: { $0.id == queued.threadId })?.status == .running {
            queuedMessageStore.insert(queued, at: 0)
            normalizeQueuedPositions(thread: queued.threadId)
            guard let promoted = queuedMessageStore.first(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
            return AgentMessageSendResult(status: .queued, queuedMessage: promoted)
        }
        normalizeQueuedPositions(thread: queued.threadId)
        return try await sendAgentMessage(thread: queued.threadId,
                                          text: queued.text,
                                          provider: nil,
                                          model: nil,
                                          permissionMode: nil,
                                          reasoningEffort: nil,
                                          serviceTier: nil,
                                          interactionMode: queued.interactionMode,
                                          modelSelection: nil,
                                          providerInstanceId: nil,
                                          attachments: queued.attachments)
    }
    private func normalizeQueuedPositions(thread: AgentThreadID) {
        let sortedIds = queuedMessageStore
            .filter { $0.threadId == thread }
            .map(\.id)
        for (offset, id) in sortedIds.enumerated() {
            guard let idx = queuedMessageStore.firstIndex(where: { $0.id == id }) else { continue }
            queuedMessageStore[idx].position = offset + 1
        }
    }
    func sendAgentMessage(thread: AgentThreadID, text: String, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, interactionMode: AgentInteractionMode?, modelSelection: AgentModelSelection?, providerInstanceId: String?, attachments: [AgentAttachment]) async throws -> AgentMessageSendResult {
        sendAgentMessageCallCount += 1
        lastSendText = text
        lastSendInteractionMode = interactionMode
        lastSendAttachments = attachments
        _ = try configureAgentThread(thread: thread, provider: provider, model: model, permissionMode: permissionMode, reasoningEffort: reasoningEffort, serviceTier: serviceTier, modelSelection: modelSelection, providerInstanceId: providerInstanceId)
        lastSendPermission = threadStore.first(where: { $0.id == thread })?.permissionMode
        lastSendReasoning = threadStore.first(where: { $0.id == thread })?.reasoningEffort
        lastSendServiceTier = threadStore.first(where: { $0.id == thread })?.serviceTier
        if threadStore.first(where: { $0.id == thread })?.status == .running {
            let queued = AgentQueuedMessage(threadId: thread, text: text, attachments: attachments, interactionMode: interactionMode ?? .default, position: queuedMessageStore.count + 1)
            queuedMessageStore.append(queued)
            return AgentMessageSendResult(status: .queued, queuedMessage: queued)
        }
        return AgentMessageSendResult(status: .started, runId: AgentRunID())
    }
    func implementAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, newThread: Bool, provider: AgentProvider?, model: String?, permissionMode: AgentPermissionMode?, reasoningEffort: AgentReasoningEffort?, serviceTier: AgentServiceTier?, modelSelection: AgentModelSelection?) async throws -> (runId: AgentRunID, implementationThreadId: AgentThreadID) {
        let target: AgentThread
        if newThread {
            target = try createAgentThread(workspace: threadStore.first(where: { $0.id == thread })?.workspaceId,
                                           title: "Implement plan",
                                           provider: provider ?? .codex,
                                           model: model ?? "fake-model",
                                           permissionMode: permissionMode ?? .supervised,
                                           reasoningEffort: reasoningEffort ?? .medium,
                                           serviceTier: serviceTier ?? .auto,
                                           modelSelection: modelSelection,
                                           providerInstanceId: nil,
                                           surfaceID: nil)
        } else {
            guard let existing = threadStore.first(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
            target = existing
        }
        let sendResult = try await sendAgentMessage(thread: target.id,
                                                    text: AgentPlanImplementationPrompt.make(markdown: planMarkdown ?? ""),
                                                    provider: provider,
                                                    model: model,
                                                    permissionMode: permissionMode,
                                                    reasoningEffort: reasoningEffort,
                                                    serviceTier: serviceTier,
                                                    interactionMode: .default,
                                                    modelSelection: modelSelection,
                                                    providerInstanceId: nil,
                                                    attachments: [])
        let runId = try XCTUnwrap(sendResult.runId)
        lastImplementedPlan = (thread, planId, target.id)
        return (runId, target.id)
    }
    func saveAgentPlan(thread: AgentThreadID, planId: String, planMarkdown: String?, relativePath: String?) throws -> (path: String, relativePath: String) {
        lastSavedPlan = (thread, planId, planMarkdown, relativePath)
        return ("/tmp/\(relativePath ?? "plan.md")", relativePath ?? ".remotecode/plans/plan.md")
    }
    var planNotesByThread: [AgentThreadID: String] = [:]
    var planNotesSaveCallCount = 0
    var planNotesReadShouldFail = false
    var planNotesSaveShouldFail = false
    func agentPlanNotes(thread: AgentThreadID) throws -> String {
        if planNotesReadShouldFail {
            throw JSONRPCError(code: -32000, message: "Injected plan-notes read failure.")
        }
        return planNotesByThread[thread] ?? ""
    }
    func saveAgentPlanNotes(thread: AgentThreadID, notes: String) throws {
        planNotesSaveCallCount += 1
        if planNotesSaveShouldFail {
            throw JSONRPCError(code: -32000, message: "Injected plan-notes persistence failure.")
        }
        planNotesByThread[thread] = notes
    }
    var reorderAgentQueuedMessageCallCount = 0
    func reorderAgentQueuedMessage(thread: AgentThreadID, id: AgentQueuedMessageID, position: Int) throws {
        reorderAgentQueuedMessageCallCount += 1
        var queue = queuedMessageStore.filter { $0.threadId == thread }
        guard let fromIndex = queue.firstIndex(where: { $0.id == id }) else { throw JSONRPCError.invalidParams }
        let moved = queue.remove(at: fromIndex)
        queue.insert(moved, at: max(0, min(position, queue.count - 1)))
        queuedMessageStore.removeAll { $0.threadId == thread }
        for (index, var message) in queue.enumerated() {
            message.position = index + 1
            queuedMessageStore.append(message)
        }
    }
    func commandReceipt(method: String, clientRequestId: String) -> JSONValue? {
        commandReceipts["\(method):\(clientRequestId)"]
    }
    func recordCommandReceipt(method: String, clientRequestId: String, result: JSONValue) {
        commandReceipts["\(method):\(clientRequestId)"] = result
    }
    func respondAgentRequest(thread: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        respondAgentRequestCallCount += 1
        lastAgentRequestResponse = (thread, requestId, response)
        agentRequestResponses.append((thread, requestId, response))
    }
    func respondAgentUserInput(thread: AgentThreadID, requestId: String, text: String) async throws {
        respondAgentUserInputCallCount += 1
        lastAgentUserInputResponse = (thread, requestId, text)
        agentUserInputResponses.append((thread, requestId, text))
    }
    func listAgentPendingCallbacks(thread: AgentThreadID) throws -> AssistantPendingCallbacksSnapshot {
        pendingCallbackSnapshot
    }
    func readAgentThreadEvents(thread: AgentThreadID) async throws -> [AssistantEvent] {
        readAgentEvents
    }
    func readAgentThreadMirrorSnapshot(thread: AgentThreadID) async throws -> AgentThreadMirrorSnapshot {
        AgentThreadMirrorSnapshot(
            events: readAgentEvents,
            eventWatermark: EventBus.shared.currentSeq
        )
    }
    func rollbackAgentThread(thread: AgentThreadID, toTurnId: String) async throws {
        rollbackCallCount += 1
        lastRollback = (thread, toTurnId)
    }
    func listAgentThreadCheckpoints(thread: AgentThreadID) throws -> [AgentTurnCheckpointSummary] {
        checkpointStore.filter { $0.threadId == thread }
    }
    func agentCheckpointDiff(thread: AgentThreadID, checkpointTurnCount: Int, path: String?) throws -> String {
        guard let checkpoint = checkpointStore.first(where: { $0.threadId == thread && $0.checkpointTurnCount == checkpointTurnCount }) else {
            return ""
        }
        if let path { return checkpoint.fileDiffs.first(where: { $0.path == path })?.patch ?? "" }
        return checkpoint.diffPatch ?? checkpoint.fileDiffs.map(\.patch).joined(separator: "\n")
    }
    func revertAgentThreadToCheckpoint(thread: AgentThreadID, checkpointTurnCount: Int) async throws -> AgentTurnCheckpointSummary {
        checkpointRevertCallCount += 1
        lastCheckpointRevert = (thread, checkpointTurnCount)
        return AgentTurnCheckpointSummary(
            threadId: thread,
            runId: AgentRunID(),
            turnId: "turn-\(checkpointTurnCount)",
            checkpointTurnCount: checkpointTurnCount,
            checkpointRef: "local-diff:test:turn-\(checkpointTurnCount)",
            status: .ready,
            files: []
        )
    }
    func stopAgentRun(thread: AgentThreadID) throws {
        stopAgentRunCallCount += 1
        stoppedAgentThreads.append(thread)
    }
    var activeAgentRuns: [AgentThreadID: AgentActiveRunSnapshot] = [:]
    func activeAgentRun(thread: AgentThreadID) throws -> AgentActiveRunSnapshot? {
        activeAgentRuns[thread]
    }
    var continueAgentRunCallCount = 0
    var continuedAgentThreads: [AgentThreadID] = []
    func continueAgentRun(thread: AgentThreadID) async throws -> AgentRunID? {
        continueAgentRunCallCount += 1
        continuedAgentThreads.append(thread)
        return AgentRunID()
    }
    var threadStore: [AgentThread] = []
    var deleteAgentThreadCallCount = 0
    var deleteAgentThreadsCallCount = 0
    var setAgentThreadPinnedCallCount = 0
    var setAgentThreadColorCallCount = 0
    var reorderAgentThreadCallCount = 0
    var renameAgentThreadCallCount = 0
    var markAgentThreadReadCallCount = 0
    func deleteAgentThread(thread: AgentThreadID) throws {
        deleteAgentThreadCallCount += 1
        threadStore.removeAll { $0.id == thread }
    }
    func deleteAgentThreads(_ threads: [AgentThreadID]) throws {
        deleteAgentThreadsCallCount += 1
        threadStore.removeAll { threads.contains($0.id) }
    }
    func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread {
        setAgentThreadPinnedCallCount += 1
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].pinned = pinned
        try normalizeThreadOrder(workspaceId: threadStore[idx].workspaceId)
        return threadStore[idx]
    }
    func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread {
        setAgentThreadColorCallCount += 1
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].color = color.isEmpty ? nil : color
        return threadStore[idx]
    }
    func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread] {
        reorderAgentThreadCallCount += 1
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
        renameAgentThreadCallCount += 1
        guard let idx = threadStore.firstIndex(where: { $0.id == thread }) else { throw JSONRPCError.invalidParams }
        threadStore[idx].title = title
        return threadStore[idx]
    }
    func markAgentThreadRead(thread: AgentThreadID) throws {
        markAgentThreadReadCallCount += 1
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
    func listAgentProviderSnapshots() async -> [AgentProviderSnapshot] {
        [
            AgentProviderSnapshot(
                id: "codex-cli",
                provider: .codex,
                driverKind: .codexCLI,
                displayName: "Codex",
                accentColor: "#2F80ED",
                continuationGroup: "openai-codex",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "gpt-5.1-codex", label: "GPT-5.1 Codex", provider: .codex)],
                slashCommands: ["/status", "/goal"]
            ),
            AgentProviderSnapshot(
                id: "claude-cli",
                provider: .claude,
                driverKind: .claudeCLI,
                displayName: "Claude",
                accentColor: "#D97706",
                continuationGroup: "anthropic-claude",
                interactionModes: [.default, .plan],
                enabled: true,
                installed: true,
                status: .available,
                models: [AgentModelDescriptor(id: "sonnet", label: "Sonnet", provider: .claude)],
                slashCommands: ["/status"]
            )
        ]
    }
    var providerUpdateResult: JSONValue = .object(["ok": .bool(true)])
    var providerUpdateCall: (AgentProvider, String?)?
    func updateAgentProvider(provider: AgentProvider, providerInstanceId: String?) async throws -> JSONValue {
        providerUpdateCall = (provider, providerInstanceId)
        return providerUpdateResult
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
    func gitDeliveryPlan(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryPlan { GitDiff.deliveryPlan(in: gitCwd, copy: copy) }
    func gitDeliver(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryResult { GitDiff.deliver(in: gitCwd, copy: copy, environment: nil) }
    var projectCwd = "/tmp"
    func projectScripts(workspace: WorkspaceID) throws -> [ProjectScript] { ProjectScripts.discover(in: projectCwd) }
    func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor {
        guard ProjectScripts.discover(in: projectCwd).contains(where: { $0.name == name }) else { throw JSONRPCError(code: -32602, message: "no such script") }
        return SurfaceDescriptor(type: .terminal, title: "Run: \(name)")
    }
    var projectOpenInEditorError: Error?
    func projectOpenInEditor(workspace: WorkspaceID) throws -> String {
        if let projectOpenInEditorError { throw projectOpenInEditorError }
        return "Finder"
    }
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
    var lastPrivatePushTokenUpdate: (
        pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceID: String?,
        tokenPurpose: String?, environment: String?, serverID: String?, bootEpoch: Int?,
        activityGeneration: Int?, activityID: String?, activitySessionID: String?,
        registrationRevision: Int?, contractVersion: Int?, capabilities: [String]?
    )?
    func privatePushTokenUpdate(
        pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceID: String?,
        tokenPurpose: String?, environment: String?, serverID: String?, bootEpoch: Int?,
        activityGeneration: Int?, activityID: String?, activitySessionID: String?,
        registrationRevision: Int?, contractVersion: Int?, capabilities: [String]?
    ) throws -> JSONValue {
        lastPrivatePushTokenUpdate = (
            pushToken, pushTokenType, liveActivityToken, deviceID, tokenPurpose, environment,
            serverID, bootEpoch, activityGeneration, activityID, activitySessionID,
            registrationRevision, contractVersion, capabilities
        )
        return .object(["ok": .bool(true), "push_token_type": .string(pushTokenType)])
    }
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
    func fsWorkspaceCreateFile(workspace: WorkspaceID, path: String, content: String) throws -> JSONValue { try WorkspaceFileService().createFile(root: projectCwd, path: path, content: content) }
    func fsWorkspaceRename(workspace: WorkspaceID, path: String, newName: String) throws -> JSONValue { try WorkspaceFileService().rename(root: projectCwd, path: path, newName: newName) }
    func fsWorkspaceDelete(workspace: WorkspaceID, paths: [String]) throws -> JSONValue { try WorkspaceFileService().delete(root: projectCwd, paths: paths) }
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
    var promptHistoryByWorkspace: [WorkspaceID: [String]] = [:]
    func agentPromptHistory(workspace: WorkspaceID?, limit: Int) throws -> [String] {
        let wid = workspace ?? window.selectedWorkspaceID
        guard let wid else { return [] }
        let history = promptHistoryByWorkspace[wid, default: []]
        return Array(history.suffix(limit).reversed())
    }
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
    func test_agentProvidersListReturnsSnapshotsForProviderDrivenUI() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.providers.list", params: nil))

        guard case .array(let snapshots)? = resp.result,
              let codex = snapshots.compactMap(\.objectValue).first(where: { $0["provider"] == .string("codex") }) else {
            return XCTFail("agent.providers.list must expose provider snapshots so Agent App does not hardcode provider state")
        }
        XCTAssertEqual(codex["displayName"], .string("Codex"))
        XCTAssertEqual(codex["status"], .string("available"))
        XCTAssertEqual(codex["driverKind"], .string("codex_cli"))
        XCTAssertEqual(codex["slashCommands"]?.arrayValue?.contains(.string("/goal")), true)
        XCTAssertEqual(codex["models"]?.arrayValue?.isEmpty, false)
    }

    @MainActor
    func test_agentProviderUpdateRoutesThroughDispatcherWithInstanceId() async {
        let router = FakeRouter()
        router.providerUpdateResult = .object(["ok": .bool(true), "stdout": .string("updated\n")])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.provider.update",
            params: [
                "provider": .string("claude"),
                "provider_instance_id": .string("claude-work")
            ]
        ))

        XCTAssertEqual(router.providerUpdateCall?.0, .claude)
        XCTAssertEqual(router.providerUpdateCall?.1, "claude-work")
        XCTAssertEqual(resp.result, JSONValue.object(["ok": .bool(true), "stdout": .string("updated\n")]),
                       "provider update must be a host RPC action so macOS and iOS can invoke the same serialized provider-native update path")
    }

    @MainActor
    func test_capabilitiesAdvertiseSSHTabAndMethodsForMirrorParity() async {
        let d = JSONRPCDispatcher(router: FakeRouter())

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "system.capabilities", params: nil))

        guard case .object(let o)? = resp.result,
              case .array(let surfaceTypes)? = o["surface_types"],
              case .object(let ssh)? = o["ssh"],
              case .array(let methods)? = ssh["methods"] else {
            return XCTFail("capabilities must expose the SSH surface and SSH methods so iOS can mirror the macOS tab")
        }
        XCTAssertTrue(surfaceTypes.contains(.string("ssh")),
                      "SSH must be advertised by the host; otherwise iOS cannot discover or create the mirrored SSH tab")
        XCTAssertTrue(methods.contains(.string("ssh.host.list")),
                      "saved hosts must be reachable through the same host RPC contract on macOS and iOS")
        XCTAssertTrue(methods.contains(.string("ssh.transfer.upload")))
        XCTAssertTrue(methods.contains(.string("ssh.transfer.download")))
        XCTAssertTrue(methods.contains(.string("ssh.files.local.list")),
                      "the FileZilla-style local browser must be reachable from iOS through the host RPC contract")
        XCTAssertTrue(methods.contains(.string("ssh.files.remote.list")),
                      "the FileZilla-style remote browser must be reachable from iOS through the host RPC contract")
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
    func test_surfaceCreateAcceptsSSHType() async throws {
        let d = JSONRPCDispatcher(router: FakeRouter())
        let wid = JSONValue.string(UUID().uuidString)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.create", params: [
            "workspace_id": wid,
            "type": .string("ssh"),
            "title": .string("SSH")
        ]))

        XCTAssertNil(resp.error, "iOS must be able to create an SSH tab through the same surface.create RPC as macOS")
        guard case .object(let body)? = resp.result else { return XCTFail("surface.create must return the created SSH descriptor") }
        XCTAssertEqual(body["type"], .string("ssh"))
        guard case .object(let metadata)? = body["metadata"] else { return XCTFail("SSH descriptor must include metadata") }
        XCTAssertEqual(metadata["ssh_status"], .string("disconnected"),
                       "a bare SSH tab must be a real disconnected surface, not a dead descriptor")
    }

    @MainActor
    func test_sshHostSaveListConnectAndTransferRoundTrip() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID().uuidString

        let saved = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "ssh.host.upsert", params: [
            "workspace_id": .string(wid),
            "label": .string("Prod"),
            "destination": .string("root@example.test"),
            "port": .number(2222),
            "password": .string("saved-test-password")
        ]))
        guard case .object(let savedHost)? = saved.result,
              case .object(let savedID)? = savedHost["id"],
              let hostID = savedID["value"]?.stringValue else {
            return XCTFail("saved SSH host must echo an id so iOS can reconnect without retyping")
        }

        let list = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "ssh.host.list", params: [
            "workspace_id": .string(wid)
        ]))
        guard case .array(let hosts)? = list.result else { return XCTFail("ssh.host.list must return saved hosts") }
        XCTAssertEqual(hosts.count, 1, "saving a host must make it available for reconnect")
        guard case .object(let listedHost)? = hosts.first else { return XCTFail("ssh.host.list must return host objects") }
        XCTAssertNil(listedHost["password"],
                     "ssh.host.list must not expose saved passwords because opening the app should not trigger a Keychain prompt or leak a secret to clients")
        XCTAssertEqual(listedHost["hasSavedPassword"], .bool(true),
                       "the host list still needs metadata so the UI knows one-tap reconnect has a stored credential")

        let connected = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "ssh.connect", params: [
            "workspace_id": .string(wid),
            "profile_id": .string(hostID)
        ]))
        guard case .object(let surface)? = connected.result,
              case .object(let sidObject)? = surface["id"],
              let surfaceID = sidObject["value"]?.stringValue else {
            return XCTFail("ssh.connect must create a mirrored SSH surface")
        }
        XCTAssertEqual(surface["type"], .string("ssh"))
        guard case .object(let metadata)? = surface["metadata"] else { return XCTFail("SSH descriptor must include metadata") }
        XCTAssertEqual(metadata["ssh_destination"], .string("root@example.test"))

        let upload = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "ssh.transfer.upload", params: [
            "surface_id": .string(surfaceID),
            "local_path": .string("/tmp/local.txt"),
            "remote_path": .string("/tmp/remote.txt")
        ]))
        guard case .object(let uploadResult)? = upload.result else { return XCTFail("upload must return an object") }
        XCTAssertEqual(uploadResult["ok"], .bool(true), "upload must be exposed as a host-owned terminal/scp RPC")

        let download = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(5), method: "ssh.transfer.download", params: [
            "surface_id": .string(surfaceID),
            "remote_path": .string("/tmp/remote.txt"),
            "local_path": .string("/tmp/local.txt")
        ]))
        guard case .object(let downloadResult)? = download.result else { return XCTFail("download must return an object") }
        XCTAssertEqual(downloadResult["ok"], .bool(true), "download must be exposed as a host-owned terminal/scp RPC")
    }

    @MainActor
    func test_sshHostUpsertDoesNotEchoPassword() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID().uuidString
        let beforeSeq = EventBus.shared.currentSeq

        let saved = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "ssh.host.upsert", params: [
            "workspace_id": .string(wid),
            "label": .string("Prod"),
            "destination": .string("root@example.test"),
            "password": .string("saved-test-password")
        ]))

        guard case .object(let savedHost)? = saved.result else {
            return XCTFail("ssh.host.upsert must return the saved host metadata")
        }
        XCTAssertNil(savedHost["password"],
                     "ssh.host.upsert must accept a password for credential storage without echoing it to paired clients")
        XCTAssertEqual(savedHost["hasSavedPassword"], .bool(true),
                       "upsert still needs to confirm that a stored credential exists for one-tap reconnect")

        let updates = EventBus.shared.recentEvents(since: beforeSeq, maxBytes: nil).events.filter { $0.kind == "ssh.host.updated" }
        guard let update = updates.last?.payload.objectValue else {
            return XCTFail("saving an SSH host must publish an update event for mirrored clients")
        }
        XCTAssertNil(update["password"],
                     "ssh.host.updated must not retain or broadcast the saved password in the event backlog")
        XCTAssertEqual(update["hasSavedPassword"], .bool(true),
                       "mirrored clients still need credential metadata after event redaction")
    }

    @MainActor
    func test_sshHostRPCsScopeSavedHostsToWorkspace() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let firstWorkspace = UUID().uuidString
        let secondWorkspace = UUID().uuidString

        _ = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "ssh.host.upsert", params: [
            "workspace_id": .string(firstWorkspace),
            "label": .string("Workspace A"),
            "destination": .string("a.example.test")
        ]))

        let firstList = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "ssh.host.list", params: [
            "workspace_id": .string(firstWorkspace)
        ]))
        let secondList = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "ssh.host.list", params: [
            "workspace_id": .string(secondWorkspace)
        ]))

        XCTAssertEqual(firstList.result?.arrayValue?.count, 1,
                       "the workspace that saved an SSH host must keep it for one-tap reconnect")
        XCTAssertEqual(secondList.result?.arrayValue?.count, 0,
                       "a different workspace must not inherit globally persisted SSH hosts")
    }

    @MainActor
    func test_surfaceSendKeyCtrlCMapsToInterruptByte() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let sid = SurfaceID()

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.send_key", params: [
            "id": .string(sid.value.uuidString),
            "key": .string("ctrl-c")
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(router.sentSurfaceText.first?.1, "\u{03}",
                       "iOS Ctrl-C must reach the macOS PTY as ETX so Claude cancels instead of receiving printable CSI-u text")
    }

    @MainActor
    func test_surfaceReadHistoryReturnsBoundedDBWindowForInfiniteScroll() async throws {
        let router = FakeRouter()
        let sid = SurfaceID()
        router.terminalHistory = TerminalOutputWindow(chunks: [
            TerminalOutputChunk(id: 10, surfaceID: sid.value.uuidString, workspaceID: nil, chunkIndex: 3, data: Data("older".utf8), createdAt: Date())
        ], hasMoreOlder: true, nextBeforeChunkID: 10)
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.read_history", params: [
            "id": .string(sid.value.uuidString),
            "before_chunk_id": .number(11),
            "max_bytes": .number(1024)
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(router.lastHistoryRequest?.0, sid)
        XCTAssertEqual(router.lastHistoryRequest?.1, 11)
        XCTAssertEqual(router.lastHistoryRequest?.2, 1024)
        guard case .object(let result)? = resp.result else { return XCTFail("history must return a paged result object") }
        XCTAssertEqual(result["text"], .string("older"),
                       "terminal infinite scroll must fetch text from local DB history, not from the visible renderer")
        XCTAssertEqual(result["has_more_older"], .bool(true))
        XCTAssertEqual(result["next_before_chunk_id"], .number(10))
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
    func test_surfaceSplitWithExistingIdRoutesToSplitSurface() async {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = WorkspaceID()
        let pid = PaneID()
        let sid = SurfaceID()

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.split", params: [
            "workspace_id": .string(wid.value.uuidString),
            "pane_id": .string(pid.value.uuidString),
            "id": .string(sid.value.uuidString),
            "direction": .string("down"),
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(resp.result, .bool(true))
        XCTAssertEqual(router.splitSurfaceCalls.count, 1,
                       "iOS drag-down split sends an existing surface id, so the host must move that tab into the new vertical pane")
        XCTAssertEqual(router.splitSurfaceCalls.first?.0, wid)
        XCTAssertEqual(router.splitSurfaceCalls.first?.1, pid)
        XCTAssertEqual(router.splitSurfaceCalls.first?.2, sid)
        XCTAssertEqual(router.splitSurfaceCalls.first?.3, .down)
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
        let remote = NSTemporaryDirectory() + "rc2-disp-git-remote-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: remote) }
        sh(["git", "init", "-q", "--bare", remote])
        try "hi\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        sh(["git", "-C", dir, "add", "a.txt"])
        sh(["git", "-C", dir, "commit", "-q", "-m", "init"])
        sh(["git", "-C", dir, "remote", "add", "origin", remote])
        sh(["git", "-C", dir, "push", "-q", "origin", "main"])
        let router = FakeRouter(); router.gitCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let workspaceUUID = UUID()
        let workspaceID = WorkspaceID(workspaceUUID)
        let terminal = SurfaceDescriptor(type: .terminal, title: "terminal")
        let gitSurface = SurfaceDescriptor(
            type: .rightSidebarTool,
            title: "Git",
            metadata: ["tool": "diff"]
        )
        let pane = PaneNode(surfaces: [terminal, gitSurface], selectedSurfaceID: terminal.id)
        router.workspaces = [Workspace(
            id: workspaceID,
            name: "git-route",
            cwd: dir,
            layout: .pane(pane),
            focusedPaneID: pane.id
        )]
        let wid = JSONValue.string(workspaceUUID.uuidString)

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

        var pushEvents: [EventBus.Event] = []
        let pushToken = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "git.push" { pushEvents.append(event) }
        }
        defer { EventBus.shared.unsubscribe(pushToken) }
        let pushed = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(4),
            method: "git.push",
            params: ["workspace_id": wid]
        ))
        XCTAssertNil(pushed.error)
        XCTAssertEqual(pushEvents.count, 1)
        XCTAssertEqual(pushEvents.first?.payload.objectValue, [
            "workspace_id": .string(workspaceUUID.uuidString),
            "surface_id": .string(gitSurface.id.value.uuidString),
            "ok": .bool(true)
        ], "Socket Git outcomes must carry the exact canonical Git surface in the same workspace.")

        try "changed\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let delivery = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(5), method: "git.delivery_plan", params: [
            "workspace_id": wid,
            "copy": .object([
                "branchName": .string("agent/provider-copy"),
                "commitMessage": .string("Use provider generated commit copy"),
                "pullRequestTitle": .string("Provider generated PR title"),
                "pullRequestBody": .string("Provider generated PR body")
            ])
        ]))
        guard case .object(let plan)? = delivery.result else { return XCTFail("git.delivery_plan must return structured delivery text and phases") }
        XCTAssertEqual(plan["commitMessage"], .string("Use provider generated commit copy"))
        XCTAssertEqual(plan["branchName"], .string("agent/provider-copy"))
        XCTAssertEqual(plan["pullRequestTitle"], .string("Provider generated PR title"))
        guard case .array(let phases)? = plan["phases"], phases.count == 4 else {
            return XCTFail("git.delivery_plan must expose branch/commit/push/pull_request phase status for safe agent delivery")
        }

        var deliveryEvents: [EventBus.Event] = []
        let deliveryToken = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "git.deliver" { deliveryEvents.append(event) }
        }
        defer { EventBus.shared.unsubscribe(deliveryToken) }
        let delivered = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(6), method: "git.deliver", params: ["workspace_id": wid]))
        guard case .object(let result)? = delivered.result else { return XCTFail("git.deliver must return one-shot delivery phase status") }
        XCTAssertEqual(result["ok"], .bool(true), "git.deliver must execute branch, commit, and push through the socket")
        guard case .array(let deliveredPhases)? = result["phases"], deliveredPhases.count == 4 else {
            return XCTFail("git.deliver must return each stacked phase")
        }
        XCTAssertEqual(GitDiff.branches(in: dir).current, "agent/a-txt")
        XCTAssertEqual(deliveryEvents.count, 1,
            "One RPC delivery must publish one canonical Pet/mirror outcome.")
        XCTAssertEqual(deliveryEvents.first?.payload.objectValue, [
            "workspace_id": .string(workspaceUUID.uuidString),
            "surface_id": .string(gitSurface.id.value.uuidString),
            "ok": .bool(true)
        ])
    }

    @MainActor
    func test_agentAttachmentUploadRoutesImportedMobileFileToHostPath() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)

        let uploaded = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.attachment.upload", params: [
            "workspace_id": wid,
            "filename": .string("screen.png"),
            "mime_type": .string("image/png"),
            "data_base64": .string(Data("image-bytes".utf8).base64EncodedString())
        ]))

        guard case .object(let obj)? = uploaded.result else { return XCTFail("agent.attachment.upload must return a host attachment path") }
        XCTAssertEqual(obj["path"], .string("/tmp/remotecode-attachments/screen.png"))
        XCTAssertEqual(obj["displayName"], .string("screen.png"))
        XCTAssertEqual(obj["kind"], .string("image"),
                       "iOS local imports must become host-readable structured attachments before agent.message.send")
        XCTAssertEqual(obj["sizeBytes"], .number(11))
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
    func test_filesWorkspaceMutations_overSocket() async throws {
        let dir = NSTemporaryDirectory() + "rc2-disp-files-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: dir + "/Sources", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let router = FakeRouter(); router.projectCwd = dir
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)

        let created = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "fs.workspace.create_file", params: [
            "workspace_id": wid,
            "path": .string("Sources/NewFile.swift"),
        ]))
        XCTAssertEqual(created.result?.objectValue?["relative_path"], .string("Sources/NewFile.swift"),
                       "add-file must be available over RPC so macOS and iOS use the same host mutation")

        let renamed = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "fs.workspace.rename", params: [
            "workspace_id": wid,
            "path": .string("Sources/NewFile.swift"),
            "new_name": .string("Renamed.swift"),
        ]))
        XCTAssertEqual(renamed.result?.objectValue?["relative_path"], .string("Sources/Renamed.swift"),
                       "context-menu rename must return the new workspace-relative path over the socket")

        let deleted = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "fs.workspace.delete", params: [
            "workspace_id": wid,
            "paths": .array([.string("Sources/Renamed.swift")]),
        ]))
        XCTAssertEqual(deleted.result?.objectValue?["deleted"]?.arrayValue?.compactMap { $0.stringValue }, ["Sources/Renamed.swift"],
                       "bulk delete must delete every selected file through one RPC mutation")
    }

    @MainActor
    func test_filesOpenNewTabAndSplit_overSocket() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)
        let wid = UUID()
        let sourceSurface = UUID()
        let paneID = UUID()

        let opened = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "files.tab.open", params: [
            "workspace_id": .string(wid.uuidString),
            "surface_id": .string(sourceSurface.uuidString),
            "path": .string("Sources/App.swift"),
        ]))
        XCTAssertNil(opened.error, "Open in New Tab must be a Files RPC so macOS and iOS create the same source-reader tab")
        XCTAssertEqual(opened.result?.objectValue?["type"], .string("files"))
        XCTAssertEqual(opened.result?.objectValue?["metadata"]?.objectValue?["selected_path"], .string("Sources/App.swift"))
        XCTAssertEqual(router.filesOpenTabCalls.first?.0, WorkspaceID(wid))
        XCTAssertEqual(router.filesOpenTabCalls.first?.1, SurfaceID(sourceSurface))
        XCTAssertNil(router.filesOpenTabCalls.first?.2)
        XCTAssertEqual(router.filesOpenTabCalls.first?.3, "Sources/App.swift")

        let split = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "files.tab.split", params: [
            "workspace_id": .string(wid.uuidString),
            "surface_id": .string(sourceSurface.uuidString),
            "pane_id": .string(paneID.uuidString),
            "direction": .string("right"),
            "path": .string("Sources/App.swift"),
        ]))
        XCTAssertNil(split.error, "Dragging a file onto side/bottom split targets must create a Files tab in the split pane")
        XCTAssertEqual(split.result?.objectValue?["type"], .string("files"))
        XCTAssertEqual(split.result?.objectValue?["metadata"]?.objectValue?["selected_relative_path"], .string("Sources/App.swift"))
        XCTAssertEqual(router.filesSplitTabCalls.first?.0, WorkspaceID(wid))
        XCTAssertEqual(router.filesSplitTabCalls.first?.1, SurfaceID(sourceSurface))
        XCTAssertEqual(router.filesSplitTabCalls.first?.2, PaneID(paneID))
        XCTAssertEqual(router.filesSplitTabCalls.first?.3, .right)
        XCTAssertEqual(router.filesSplitTabCalls.first?.4, "Sources/App.swift")
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
        let editor = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "project.open_in_editor", params: ["workspace_id": wid]))
        XCTAssertEqual(editor.result?.objectValue?["app"], .string("Finder"),
                       "opening a workspace in an editor must return the app that handled the request")
    }

    @MainActor
    func test_projectOpenInEditor_propagatesOpenFailureOverSocket() async throws {
        let router = FakeRouter()
        router.projectOpenInEditorError = ProjectScripts.OpenError.failed(cwd: "/tmp/missing-workspace")
        let d = JSONRPCDispatcher(router: router)
        let wid = JSONValue.string(UUID().uuidString)
        let response = await d.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "project.open_in_editor",
            params: ["workspace_id": wid]
        ))
        XCTAssertNotNil(response.error, "editor launch failure must be visible to JSON-RPC callers")
        XCTAssertEqual(response.error?.message, "Workspace could not be opened in an editor or Finder.")
        XCTAssertEqual(response.error?.data?.objectValue?["domain"], .string("project_scripts"))
        XCTAssertEqual(response.error?.data?.objectValue?["kind"], .string("open_failed"))
    }

    @MainActor
    func test_privatePushTokenUpdateRoutesValidatedTokenOverSocket() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "private.push_token.update", params: [
            "push_token": .string("fcm-token"),
            "push_token_type": .string("fcm"),
            "device_id": .string("device-1"),
        ]))

        XCTAssertNil(resp.error, "paired clients must be able to register an FCM target for backend push delivery")
        XCTAssertEqual(resp.result?.objectValue?["ok"], .bool(true))
        XCTAssertEqual(resp.result?.objectValue?["push_token_type"], .string("fcm"))
        XCTAssertNil(resp.result?.objectValue?["push_token"],
                     "the JSON-RPC response must not echo sensitive push-token material back to the caller")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.pushToken, "fcm-token")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.pushTokenType, "fcm")
        XCTAssertNil(router.lastPrivatePushTokenUpdate?.liveActivityToken,
                     "live activity tokens are optional because plain alert delivery still needs a stored push target")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.deviceID, "device-1")
    }

    @MainActor
    func test_privatePushTokenUpdateRejectsUnsupportedTokenTypeBeforeRouting() async throws {
        let router = FakeRouter()
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "private.push_token.update", params: [
            "push_token": .string("webpush-token"),
            "push_token_type": .string("webpush"),
        ]))

        XCTAssertEqual(resp.error?.code, -32602,
                       "unsupported token types must fail validation before the host stores an unusable notification target")
        XCTAssertNil(router.lastPrivatePushTokenUpdate)
    }

    @MainActor
    func test_privatePushTokenUpdateRoutesTypedLiveActivityV2Capability() async throws {
        let router = FakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "private.push_token.update",
            params: [
                "push_token": .string("apns-token"),
                "push_token_type": .string("apns"),
                "live_activity_token": .string("start-token"),
                "device_id": .string("device-1"),
                "token_purpose": .string("activity_update"),
                "environment": .string("sandbox"),
                "server_id": .string("server-1"),
                "boot_epoch": .number(8),
                "activity_generation": .number(4),
                "activity_id": .string("activity-1"),
                "activity_session_id": .string("server-1:8:4"),
                "registration_revision": .number(12),
                "contract_version": .number(2),
                "capabilities": .array([.string("live_activity_v2")])
            ]
        ))

        XCTAssertNil(response.error)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.tokenPurpose, "activity_update")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.environment, "sandbox")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.serverID, "server-1")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.bootEpoch, 8)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.activityGeneration, 4)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.activityID, "activity-1")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.activitySessionID, "server-1:8:4")
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.registrationRevision, 12)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.contractVersion, 2)
        XCTAssertEqual(router.lastPrivatePushTokenUpdate?.capabilities, ["live_activity_v2"])
    }

    @MainActor
    func test_privatePushTokenUpdateRejectsMalformedTypedActivityRegistration() async throws {
        let missingTokenRouter = FakeRouter()
        let missingTokenResponse = await JSONRPCDispatcher(router: missingTokenRouter).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "private.push_token.update",
            params: [
                "push_token": .string("apns-token"),
                "push_token_type": .string("apns"),
                "device_id": .string("device-1"),
                "token_purpose": .string("push_to_start"),
                "environment": .string("sandbox"),
                "server_id": .string("server-1"),
                "contract_version": .number(2),
                "capabilities": .array([.string("live_activity_v2")])
            ]
        ))
        XCTAssertEqual(missingTokenResponse.error?.code, -32602)
        XCTAssertNil(missingTokenRouter.lastPrivatePushTokenUpdate,
                     "an APNs alert token must never be substituted for a missing ActivityKit token")

        let malformedCapabilityRouter = FakeRouter()
        let malformedCapabilityResponse = await JSONRPCDispatcher(router: malformedCapabilityRouter).dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "private.push_token.update",
            params: [
                "push_token": .string("apns-token"),
                "push_token_type": .string("apns"),
                "live_activity_token": .string("start-token"),
                "device_id": .string("device-1"),
                "token_purpose": .string("push_to_start"),
                "environment": .string("sandbox"),
                "server_id": .string("server-1"),
                "contract_version": .number(2),
                "capabilities": .array([.number(2)])
            ]
        ))
        XCTAssertEqual(malformedCapabilityResponse.error?.code, -32602)
        XCTAssertNil(malformedCapabilityRouter.lastPrivatePushTokenUpdate,
                     "malformed capability metadata must fail loudly instead of silently disabling v2")
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
            "reasoning_effort": .string("high"),
            "service_tier": .string("fast"),
            "model_selection": .object([
                "provider": .string("claude"),
                "model_id": .string("claude-sonnet-4-6"),
                "reasoning_effort": .string("high"),
                "service_tier": .string("fast")
            ])
        ]))
        guard case .object(let cfgObj)? = cfg.result else { return XCTFail("configure must echo the updated host thread") }
        XCTAssertEqual(cfgObj["provider"], .string("claude"))
        XCTAssertEqual(cfgObj["providerInstanceId"], .string("claude"),
                       "provider instance identity must round-trip with thread metadata so clients can keep personal/work sessions separate")
        XCTAssertEqual(cfgObj["model"], .string("claude-sonnet-4-6"))
        XCTAssertEqual(cfgObj["permissionMode"], .string("full_access"))
        XCTAssertEqual(cfgObj["reasoningEffort"], .string("high"))
        XCTAssertEqual(cfgObj["serviceTier"], .string("fast"))
        guard case .object(let cfgSelection)? = cfgObj["model_selection"] else { return XCTFail("configure must echo structured model selection") }
        XCTAssertEqual(cfgSelection["modelId"], .string("claude-sonnet-4-6"))
        XCTAssertEqual(cfgSelection["reasoningEffort"], .string("high"),
                       "iOS must be able to round-trip model options as one structured selection, not loose fields that can drift")

        let send = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: [
            "thread_id": tid,
            "text": .string("run on host"),
            "model_selection": .object([
                "provider": .string("codex"),
                "model_id": .string(""),
                "custom_model_id": .string("gpt-5.5-experimental"),
                "reasoning_effort": .string("xhigh"),
                "service_tier": .string("fast")
            ]),
            "interaction_mode": .string("plan"),
            "attachments": .array([
                .object([
                    "path": .string("/tmp/screen.png"),
                    "display_name": .string("screen.png"),
                    "kind": .string("image"),
                    "mime_type": .string("image/png")
                ]),
                .object([
                    "path": .string("/tmp/notes.txt"),
                    "displayName": .string("notes.txt"),
                    "kind": .string("file")
                ])
            ])
        ]))
        guard case .object(let sendObj)? = send.result else { return XCTFail("send must return host run object") }
        XCTAssertNotNil(sendObj["run_id"]?.stringValue, "send must return host run id")
        XCTAssertEqual(router.threadStore.first?.provider, .codex)
        XCTAssertEqual(router.threadStore.first?.model, "gpt-5.5-experimental")
        XCTAssertEqual(router.threadStore.first?.modelSelection.customModelId, "gpt-5.5-experimental")
        XCTAssertEqual(router.lastSendPermission, .fullAccess,
                       "send must use the thread's persisted permission mode when no override is sent")
        XCTAssertEqual(router.lastSendReasoning, .xhigh,
                       "send must use structured model-selection reasoning when iOS sends a custom model")
        XCTAssertEqual(router.lastSendServiceTier, .fast,
                       "send must use the thread's persisted service tier when no override is sent")
        XCTAssertEqual(router.lastSendInteractionMode, .plan,
                       "mobile /plan must reach the provider runtime as interaction_mode, not only local UI text")
        XCTAssertEqual(router.lastSendAttachments.map(\.path), ["/tmp/screen.png", "/tmp/notes.txt"],
                       "mobile attachments must reach the host as structured metadata instead of being folded into prompt text")
        XCTAssertEqual(router.lastSendAttachments.first?.kind, .image)
        XCTAssertEqual(router.lastSendAttachments.first?.mimeType, "image/png")
    }

    @MainActor
    func test_agentThreadExecutionConfigureRoutesWorktreeMode() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "exec", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.execution.configure", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "execution_mode": .string("worktree"),
            "base_branch": .string("main")
        ]))

        XCTAssertNotNil(response.result)
        XCTAssertEqual(router.threadStore[0].executionMode, .worktree)
        XCTAssertEqual(router.threadStore[0].baseBranch, "main",
                       "worktree execution must require and persist a base branch before the first provider turn")
    }

    @MainActor
    func test_agentThreadPreparePRCreatesWorktreeThread() async throws {
        let router = FakeRouter()
        let workspace = WorkspaceID()
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.prepare_pr", params: [
            "workspace_id": .string(workspace.value.uuidString),
            "url": .string("https://github.com/acme/widget/pull/7"),
            "provider": .string("codex"),
            "provider_instance_id": .string("codex-work"),
            "model": .string("gpt-5.5")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("prepare_pr must return the created agent thread") }
        XCTAssertEqual(router.lastPreparedPullRequest?.0, workspace)
        XCTAssertEqual(router.lastPreparedPullRequest?.1, "https://github.com/acme/widget/pull/7")
        XCTAssertEqual(obj["execution_mode"], .string("worktree"))
        XCTAssertEqual(obj["worktree_path"], .string("/tmp/rc-pr-7"),
                       "PR preparation must expose the isolated checkout path so mobile can show where the Agent thread will run")
        XCTAssertEqual(obj["provider_instance_id"], .string("codex-work"))
    }

    @MainActor
    func test_agentPlanImplementBuildsPromptAndReturnsTraceability() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "plan", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.plan.implement", params: [
            "thread_id": .string(t.id.value.uuidString),
            "plan_id": .string("plan-1"),
            "markdown": .string("1. Inspect\n2. Patch")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("implement plan must return run and implementation thread ids") }
        XCTAssertNotNil(obj["run_id"]?.stringValue)
        XCTAssertEqual(obj["implementation_thread_id"]?.stringValue, t.id.value.uuidString)
        XCTAssertEqual(router.lastImplementedPlan?.1, "plan-1")
        XCTAssertTrue(router.lastSendText?.contains("Implement this proposed plan now") == true)
        XCTAssertTrue(router.lastSendText?.contains("1. Inspect") == true,
                      "implement plan must send the selected plan content to the provider")
    }

    @MainActor
    func test_agentPlanSaveReturnsWorkspacePathForMobileClients() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "plan", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.plan.save", params: [
            "thread_id": .string(t.id.value.uuidString),
            "plan_id": .string("plan-1"),
            "markdown": .string("1. Inspect\n2. Patch"),
            "relative_path": .string(".remotecode/plans/fix.md")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("save plan must return host path metadata") }
        XCTAssertEqual(obj["relative_path"]?.stringValue, ".remotecode/plans/fix.md")
        XCTAssertEqual(router.lastSavedPlan?.1, "plan-1")
        XCTAssertEqual(router.lastSavedPlan?.2, "1. Inspect\n2. Patch",
                       "mobile plan save must persist exact proposed-plan markdown through the host")
    }

    @MainActor
    func test_agentMessageSendClientRequestIdIsIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "idempotent", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)
        let params: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "text": .string("run once"),
            "client_request_id": .string("send-1")
        ]

        let first = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.send", params: params))
        let second = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: params))

        XCTAssertEqual(first.result, second.result,
                       "a retried agent send with the same client_request_id must return the original run id")
        XCTAssertEqual(router.sendAgentMessageCallCount, 1,
                       "retrying the same send command must not duplicate user messages or provider turns")
    }

    @MainActor
    func test_agentMessageSendClientRequestIdSurvivesDispatcherRecreation() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "idempotent", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let params: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "text": .string("run once"),
            "client_request_id": .string("send-restart-1")
        ]

        let first = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.send", params: params))
        let second = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.send", params: params))

        XCTAssertEqual(first.result, second.result,
                       "durable command receipts must let a recreated dispatcher return the original run id")
        XCTAssertEqual(router.sendAgentMessageCallCount, 1,
                       "a client retry after socket/dispatcher recreation must not duplicate provider turns")
    }

    @MainActor
    func test_agentMessageSendQueuesWhenThreadIsRunning() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "running", provider: .codex, model: "gpt-5.5")
        t.status = .running
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.send", params: [
            "thread_id": .string(t.id.value.uuidString),
            "text": .string("run after current turn")
        ]))

        guard case .object(let obj)? = response.result else { return XCTFail("running sends must return a queued result") }
        XCTAssertEqual(obj["status"], .string("queued"))
        XCTAssertNotNil(obj["queued_message_id"]?.stringValue)
        XCTAssertEqual(obj["position"], .number(1))
        XCTAssertNil(obj["run_id"],
                     "queued sends must not expose a run id before they actually start")
        XCTAssertEqual(router.queuedMessageStore.first?.text, "run after current turn",
                       "a send during an active run must persist as an editable queued message instead of being dropped")
    }

    @MainActor
    func test_agentMessageQueueUpdateAndCancelAreIdempotentWithClientRequestId() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "queue", provider: .codex, model: "gpt-5.5")
        let q = AgentQueuedMessage(threadId: t.id, text: "draft", attachments: [], interactionMode: .default, position: 1)
        router.threadStore = [t]
        router.queuedMessageStore = [q]

        let updateParams: [String: JSONValue] = [
            "queued_message_id": .string(q.id.value.uuidString),
            "text": .string("edited draft"),
            "client_request_id": .string("queue-update-1")
        ]
        let firstUpdate = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.queue.update", params: updateParams))
        let secondUpdate = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.queue.update", params: updateParams))

        XCTAssertEqual(firstUpdate.result, secondUpdate.result,
                       "retries for queued-message edits must return the same host result and not mutate twice")
        XCTAssertEqual(router.queuedMessageStore.first?.text, "edited draft")

        let cancelParams: [String: JSONValue] = [
            "queued_message_id": .string(q.id.value.uuidString),
            "client_request_id": .string("queue-cancel-1")
        ]
        let firstCancel = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.message.queue.cancel", params: cancelParams))
        let secondCancel = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.message.queue.cancel", params: cancelParams))

        XCTAssertEqual(firstCancel.result, secondCancel.result,
                       "retries for queued-message cancellation must not fail after the first removal")
        XCTAssertTrue(router.queuedMessageStore.isEmpty,
                      "cancelling a queued item must remove only that queued item")
    }

    @MainActor
    func test_agentMessageQueueForceNowPromotesRunningThreadAndStartsIdleThread() async throws {
        let router = FakeRouter()
        var running = AgentThread(workspaceId: nil, title: "queue", provider: .codex, model: "gpt-5.5")
        running.status = .running
        let first = AgentQueuedMessage(threadId: running.id, text: "first", attachments: [], interactionMode: .default, position: 1)
        let second = AgentQueuedMessage(threadId: running.id, text: "force me", attachments: [], interactionMode: .plan, position: 2)
        router.threadStore = [running]
        router.queuedMessageStore = [first, second]

        let forceParams: [String: JSONValue] = [
            "queued_message_id": .string(second.id.value.uuidString),
            "client_request_id": .string("queue-force-1")
        ]
        let firstForce = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.queue.force_now", params: forceParams))
        let secondForce = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.queue.force_now", params: forceParams))

        XCTAssertEqual(firstForce.result, secondForce.result,
                       "retries for Force Now must return the same host result and not start or promote twice")
        XCTAssertEqual(router.queuedMessageStore.map(\.text), ["force me", "first"],
                       "Force Now on a running thread must promote the selected queued message to the next slot")
        guard case .object(let queuedResult)? = firstForce.result else { return XCTFail("Force Now must return queue status while the active run is still running") }
        XCTAssertEqual(queuedResult["status"], .string("queued"))
        XCTAssertEqual(queuedResult["position"], .number(1))

        var idle = AgentThread(workspaceId: nil, title: "idle queue", provider: .codex, model: "gpt-5.5")
        idle.status = .completed
        let idleQueued = AgentQueuedMessage(threadId: idle.id, text: "start now", attachments: [], interactionMode: .default, position: 1)
        router.threadStore = [idle]
        router.queuedMessageStore = [idleQueued]
        router.sendAgentMessageCallCount = 0

        let started = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.message.queue.force_now", params: [
            "queued_message_id": .string(idleQueued.id.value.uuidString)
        ]))

        guard case .object(let startedResult)? = started.result else { return XCTFail("Force Now must return run status once it can start immediately") }
        XCTAssertEqual(startedResult["status"], .string("started"))
        XCTAssertNotNil(startedResult["run_id"]?.stringValue)
        XCTAssertEqual(router.lastSendText, "start now",
                       "Force Now on an idle thread must drain and start the selected queued message immediately")
        XCTAssertTrue(router.queuedMessageStore.isEmpty)
    }

    @MainActor
    func test_agentPlanImplementClientRequestIdIsIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "plan", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let params: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "plan_id": .string("plan-1"),
            "markdown": .string("1. Inspect"),
            "client_request_id": .string("implement-1")
        ]

        let first = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.plan.implement", params: params))
        let second = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.plan.implement", params: params))

        XCTAssertEqual(first.result, second.result,
                       "retrying plan implementation must return the original run and implementation thread ids")
        XCTAssertEqual(router.sendAgentMessageCallCount, 1,
                       "a retried implement-plan command must not send the implementation prompt twice")
    }

    @MainActor
    func test_agentCallbackAndRollbackClientRequestIdsAreIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "callbacks", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let threadId = JSONValue.string(t.id.value.uuidString)
        let approvalParams: [String: JSONValue] = [
            "thread_id": threadId,
            "request_id": .string("approval-1"),
            "decision": .string("approve"),
            "client_request_id": .string("approval-retry-1")
        ]
        let inputParams: [String: JSONValue] = [
            "thread_id": threadId,
            "request_id": .string("question-1"),
            "text": .string("Run"),
            "client_request_id": .string("input-retry-1")
        ]
        let rollbackParams: [String: JSONValue] = [
            "thread_id": threadId,
            "turn_id": .string("turn-1"),
            "client_request_id": .string("rollback-retry-1")
        ]

        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.request.respond", params: approvalParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.request.respond", params: approvalParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.user_input.respond", params: inputParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.user_input.respond", params: inputParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(5), method: "agent.thread.rollback", params: rollbackParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(6), method: "agent.thread.rollback", params: rollbackParams))

        XCTAssertEqual(router.respondAgentRequestCallCount, 1,
                       "approval retries must not submit duplicate provider approvals")
        XCTAssertEqual(router.respondAgentUserInputCallCount, 1,
                       "question retries must not submit duplicate provider input")
        XCTAssertEqual(router.rollbackCallCount, 1,
                       "rollback retries must not rollback the provider session twice")
    }

    @MainActor
    func test_agentCallbackResponsesRouteByThreadForEveryProviderAndStartSurface() async throws {
        let router = FakeRouter()
        let cases: [(title: String, provider: AgentProvider)] = [
            ("codex macOS-started", .codex),
            ("codex iOS-started", .codex),
            ("claude macOS-started", .claude),
            ("claude iOS-started", .claude)
        ]
        router.threadStore = cases.map {
            var thread = AgentThread(title: $0.title, provider: $0.provider, model: "test-model")
            thread.status = .running
            return thread
        }

        for thread in router.threadStore {
            let threadId = JSONValue.string(thread.id.value.uuidString)
            let approve = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.request.respond",
                params: [
                    "thread_id": threadId,
                    "request_id": .string("approval-\(thread.id.value.uuidString)"),
                    "decision": .string("approve")
                ]
            ))
            let decline = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(2),
                method: "agent.request.respond",
                params: [
                    "thread_id": threadId,
                    "request_id": .string("decline-\(thread.id.value.uuidString)"),
                    "decision": .string("decline"),
                    "message": .string("No")
                ]
            ))
            let input = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(3),
                method: "agent.user_input.respond",
                params: [
                    "thread_id": threadId,
                    "request_id": .string("input-\(thread.id.value.uuidString)"),
                    "text": .string("Run")
                ]
            ))

            XCTAssertEqual(approve.result, .bool(true), "approval response must route for \(thread.title)")
            XCTAssertEqual(decline.result, .bool(true), "decline response must route for \(thread.title)")
            XCTAssertEqual(input.result, .bool(true), "user-input response must route for \(thread.title)")
        }

        XCTAssertEqual(router.agentRequestResponses.map(\.0), router.threadStore.flatMap { [$0.id, $0.id] },
                       "approval and decline responses must stay thread-scoped for Codex/Claude and either start surface")
        XCTAssertEqual(router.agentUserInputResponses.map(\.0), router.threadStore.map(\.id),
                       "user-input answers must stay thread-scoped for Codex/Claude and either start surface")
        XCTAssertEqual(router.agentRequestResponses.compactMap { record -> String? in
            if case .decline(let message) = record.2 { return message }
            return nil
        }, Array(repeating: "No", count: cases.count),
                       "decline approvals from macOS or iOS must reach the provider as explicit declines, not as silent cancellations")
    }

    @MainActor
    func test_agentStopAndCheckpointRevertClientRequestIdsAreIdempotent() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "revert", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let stopParams: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "client_request_id": .string("stop-retry-1")
        ]
        let revertParams: [String: JSONValue] = [
            "thread_id": .string(t.id.value.uuidString),
            "turn_count": .number(1),
            "client_request_id": .string("checkpoint-retry-1")
        ]

        let firstRevert = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.revert", params: revertParams))
        let secondRevert = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.revert", params: revertParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.run.stop", params: stopParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.run.stop", params: stopParams))

        XCTAssertEqual(firstRevert.result, secondRevert.result,
                       "checkpoint revert retries must return the first checkpoint result")
        XCTAssertEqual(router.checkpointRevertCallCount, 1,
                       "checkpoint revert retries must not apply the rollback twice")
        XCTAssertEqual(router.stopAgentRunCallCount, 1,
                       "stop retries must not repeat the stop side effect")
    }

    @MainActor
    func test_agentRunStopRoutesByThreadForEveryProviderAndStartSurface() async throws {
        let router = FakeRouter()
        let cases: [(title: String, provider: AgentProvider)] = [
            ("codex macOS-started", .codex),
            ("codex iOS-started", .codex),
            ("claude macOS-started", .claude),
            ("claude iOS-started", .claude)
        ]
        router.threadStore = cases.map {
            var thread = AgentThread(title: $0.title, provider: $0.provider, model: "test-model")
            thread.status = .running
            return thread
        }

        for thread in router.threadStore {
            let response = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .number(1),
                method: "agent.run.stop",
                params: [
                    "thread_id": .string(thread.id.value.uuidString),
                    "client_request_id": .string("stop-\(thread.id.value.uuidString)")
                ]
            ))
            XCTAssertEqual(response.result, .bool(true),
                           "Stop Chat must return success for \(thread.title) instead of depending on provider or origin surface")
        }

        XCTAssertEqual(router.stoppedAgentThreads, router.threadStore.map(\.id),
                       "agent.run.stop must be thread-scoped so macOS and iOS Stop Chat can stop Codex or Claude runs regardless of where the run started")
    }

    @MainActor
    func test_agentThreadMetadataClientRequestIdsAreIdempotent() async throws {
        let router = FakeRouter()
        let workspace = WorkspaceID()
        let first = AgentThread(workspaceId: workspace, title: "first", provider: .codex, model: "gpt-5.5", sortOrder: 0)
        let second = AgentThread(workspaceId: workspace, title: "second", provider: .codex, model: "gpt-5.5", hasUnread: true, sortOrder: 1)
        let third = AgentThread(workspaceId: workspace, title: "third", provider: .codex, model: "gpt-5.5", sortOrder: 2)
        router.threadStore = [first, second, third]
        let threadId = JSONValue.string(second.id.value.uuidString)
        let thirdId = JSONValue.string(third.id.value.uuidString)
        let calls: [(method: String, params: [String: JSONValue])] = [
            ("agent.thread.rename", ["thread_id": threadId, "title": .string("renamed"), "client_request_id": .string("rename-1")]),
            ("agent.thread.set_pinned", ["thread_id": threadId, "pinned": .bool(true), "client_request_id": .string("pin-1")]),
            ("agent.thread.set_color", ["thread_id": threadId, "color": .string("#ff0000"), "client_request_id": .string("color-1")]),
            ("agent.thread.reorder", ["thread_id": threadId, "position": .number(0), "client_request_id": .string("reorder-1")]),
            ("agent.thread.mark_read", ["thread_id": threadId, "client_request_id": .string("read-1")]),
            ("agent.thread.delete", ["thread_id": thirdId, "client_request_id": .string("delete-1")])
        ]

        for call in calls {
            let firstResponse = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: call.method, params: call.params))
            let secondResponse = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: call.method, params: call.params))
            XCTAssertEqual(firstResponse.result, secondResponse.result,
                           "\(call.method) retries must return the original result")
        }

        let deleteManyParams: [String: JSONValue] = [
            "thread_ids": .array([.string(first.id.value.uuidString)]),
            "client_request_id": .string("delete-many-1")
        ]
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.thread.delete_many", params: deleteManyParams))
        _ = await JSONRPCDispatcher(router: router).dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(4), method: "agent.thread.delete_many", params: deleteManyParams))

        XCTAssertEqual(router.renameAgentThreadCallCount, 1, "rename retry must not rename twice")
        XCTAssertEqual(router.setAgentThreadPinnedCallCount, 1, "pin retry must not reorder twice")
        XCTAssertEqual(router.setAgentThreadColorCallCount, 1, "color retry must not update twice")
        XCTAssertEqual(router.reorderAgentThreadCallCount, 1, "reorder retry must not reorder twice")
        XCTAssertEqual(router.markAgentThreadReadCallCount, 1, "mark-read retry must not emit duplicate read side effects")
        XCTAssertEqual(router.deleteAgentThreadCallCount, 1, "delete retry must not delete twice")
        XCTAssertEqual(router.deleteAgentThreadsCallCount, 1, "bulk delete retry must not delete twice")
    }

    @MainActor
    func test_agentApprovalAndUserInputResponsesRouteThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "callbacks", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let d = JSONRPCDispatcher(router: router)
        let threadId = JSONValue.string(thread.id.value.uuidString)

        let approval = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.request.respond", params: [
            "thread_id": threadId,
            "request_id": .string("approval-1"),
            "decision": .string("approve_for_session")
        ]))
        let input = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.user_input.respond", params: [
            "thread_id": threadId,
            "request_id": .string("question-1"),
            "text": .string("Run")
        ]))

        XCTAssertEqual(approval.result, .bool(true))
        XCTAssertEqual(input.result, .bool(true))
        XCTAssertEqual(router.lastAgentRequestResponse?.0, thread.id)
        XCTAssertEqual(router.lastAgentRequestResponse?.1, "approval-1")
        XCTAssertEqual(router.lastAgentRequestResponse?.2, .approveForSession)
        XCTAssertEqual(router.lastAgentUserInputResponse?.0, thread.id)
        XCTAssertEqual(router.lastAgentUserInputResponse?.1, "question-1")
        XCTAssertEqual(router.lastAgentUserInputResponse?.2, "Run")
    }

    @MainActor
    func test_agentPendingCallbacksListRoutesThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "callbacks", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.pendingCallbackSnapshot = AssistantPendingCallbacksSnapshot(
            requests: [AssistantPendingRequest(id: "approval-1", turnId: "turn-1", kind: .commandExecution, title: "Run tests", detail: "swift test", state: .stale, createdAtMs: 1, resolvedAtMs: 2)],
            userInputs: [AssistantUserInputRequest(id: "question-1", turnId: "turn-1", prompt: "Pick mode", options: ["Plan", "Run"], state: .pending, createdAtMs: 3)]
        )
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.pending_callbacks.list", params: [
            "thread_id": .string(thread.id.value.uuidString)
        ]))

        let data = try JSONEncoder().encode(try XCTUnwrap(response.result))
        let snapshot = try JSONDecoder().decode(AssistantPendingCallbacksSnapshot.self, from: data)
        XCTAssertEqual(snapshot.requests.first?.state, .stale,
                       "iOS reconnects must be able to reload stale provider approvals from the host instead of waiting for live events")
        XCTAssertEqual(snapshot.userInputs.first?.options, ["Plan", "Run"],
                       "iOS reconnects must reload pending provider questions with answer options intact")
    }

    @MainActor
    func test_agentThreadReadAndRollbackRouteThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "read", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.readAgentEvents = [.turnStarted(turnId: "turn-1")]
        let d = JSONRPCDispatcher(router: router)
        let threadId = JSONValue.string(thread.id.value.uuidString)

        let read = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.read", params: [
            "thread_id": threadId
        ]))
        let rollback = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.thread.rollback", params: [
            "thread_id": threadId,
            "turn_id": .string("turn-1")
        ]))

        XCTAssertNotNil(read.result,
                        "readThread must be exposed over RPC so mobile/macOS can recover provider state")
        XCTAssertEqual(rollback.result, .bool(true))
        XCTAssertEqual(router.lastRollback?.0, thread.id)
        XCTAssertEqual(router.lastRollback?.1, "turn-1")
    }

    @MainActor
    func test_agentCheckpointRevertRoutesThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "revert", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let d = JSONRPCDispatcher(router: router)

        let response = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.revert", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "turn_count": .number(1)
        ]))

        XCTAssertNotNil(response.result)
        XCTAssertEqual(router.lastCheckpointRevert?.0, thread.id)
        XCTAssertEqual(router.lastCheckpointRevert?.1, 1,
                       "checkpoint revert must route as a combined workspace/provider rollback command, not only provider readThread rollback")
    }

    @MainActor
    func test_agentCheckpointListAndDiffRoutesThroughDispatcher() async throws {
        let router = FakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "diff", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.checkpointStore = [AgentTurnCheckpointSummary(
            threadId: thread.id,
            runId: AgentRunID(),
            turnId: "turn-1",
            checkpointTurnCount: 1,
            checkpointRef: "local-diff:test:turn-1",
            status: .ready,
            files: [AgentTurnCheckpointFile(path: "README.md", kind: "modified", additions: 1, deletions: 0)],
            diffPatch: "diff --git a/README.md b/README.md\n",
            fileDiffs: [AgentTurnCheckpointFileDiff(path: "README.md", patch: "@@ README\n+changed\n")]
        )]
        let d = JSONRPCDispatcher(router: router)

        let list = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.checkpoint.list", params: [
            "thread_id": .string(thread.id.value.uuidString)
        ]))
        let diff = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.checkpoint.diff", params: [
            "thread_id": .string(thread.id.value.uuidString),
            "turn_count": .number(1),
            "path": .string("README.md")
        ]))

        XCTAssertNotNil(list.result)
        XCTAssertEqual(diff.result, .string("@@ README\n+changed\n"),
                       "per-turn file diffs must be reachable over RPC so clients can inspect a specific agent turn without relying on current git state")
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
    func test_agentMessageListPaginationReturnsEnvelopeAndOlderCursor() async throws {
        let router = FakeRouter()
        let t = AgentThread(workspaceId: nil, title: "history", provider: .codex, model: "gpt-5.5")
        router.threadStore = [t]
        let base = Date(timeIntervalSinceReferenceDate: 1_000)
        router.messageStore = (0..<35).map { index in
            AgentMessage(
                id: AgentMessageID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!),
                threadId: t.id,
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message-\(index)",
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        let d = JSONRPCDispatcher(router: router)

        let first = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(10),
            "pagination": .bool(true)
        ]))

        guard case .object(let page)? = first.result,
              case .array(let firstMessages)? = page["messages"],
              case .object(let firstMessage)? = firstMessages.first,
              case .object(let lastMessage)? = firstMessages.last,
              case .object(let firstCursor)? = page["next_before"] else {
            return XCTFail("paginated message list must return envelope with cursor")
        }
        XCTAssertEqual(firstMessages.count, 10)
        XCTAssertEqual(firstMessage["content"], .string("message-25"))
        XCTAssertEqual(lastMessage["content"], .string("message-34"))
        XCTAssertEqual(page["has_more_older"], .bool(true))

        let second = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(2), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(30),
            "pagination": .bool(true),
            "before": .object(firstCursor)
        ]))

        guard case .object(let olderPage)? = second.result,
              case .array(let olderMessages)? = olderPage["messages"],
              case .object(let firstOlderMessage)? = olderMessages.first,
              case .object(let lastOlderMessage)? = olderMessages.last else {
            return XCTFail("older paginated message list must return envelope")
        }
        XCTAssertEqual(olderMessages.count, 25)
        XCTAssertEqual(firstOlderMessage["content"], .string("message-0"))
        XCTAssertEqual(lastOlderMessage["content"], .string("message-24"))
        XCTAssertEqual(olderPage["has_more_older"], .bool(false))
        XCTAssertEqual(olderPage["has_more_newer"], .bool(true))

        guard case .object(let newerCursor)? = olderPage["next_after"] else {
            return XCTFail("older page must expose newer cursor for viewport-only down-scroll hydration")
        }
        let third = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(3), method: "agent.message.list", params: [
            "thread_id": .string(t.id.value.uuidString),
            "limit": .number(10),
            "pagination": .bool(true),
            "after": .object(newerCursor)
        ]))
        guard case .object(let newerPage)? = third.result,
              case .array(let newerMessages)? = newerPage["messages"],
              case .object(let firstNewerMessage)? = newerMessages.first,
              case .object(let lastNewerMessage)? = newerMessages.last else {
            return XCTFail("newer paginated message list must return envelope")
        }
        XCTAssertEqual(newerMessages.count, 10)
        XCTAssertEqual(firstNewerMessage["content"], .string("message-25"))
        XCTAssertEqual(lastNewerMessage["content"], .string("message-34"))
        XCTAssertEqual(newerPage["has_more_newer"], .bool(false))
    }

    @MainActor
    func test_agentThreadListKeepsFullTitleAndAddsDisplayTitleForMirrors() async throws {
        let router = FakeRouter()
        let fullTitle = "git add commit and push all repos here with this long exact wording"
        let thread = AgentThread(workspaceId: nil, title: fullTitle, provider: .claude, model: "fake-model")
        router.threadStore = [thread]
        router.messageStore = [AgentMessage(threadId: thread.id, role: .user, content: "start")]
        let runId = AgentRunID(UUID(uuidString: "00000000-0000-0000-0000-000000000123")!)
        router.activeAgentRuns[thread.id] = AgentActiveRunSnapshot(
            runId: runId,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.125)
        )
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
        XCTAssertEqual(first["active_run_id"], .string(runId.value.uuidString))
        XCTAssertEqual(first["active_run_started_at_ms"], .number(1_700_000_000_125),
                       "iOS rebaseline must retain the Mac-owned elapsed-run clock")
    }

    @MainActor
    func testAgentThreadReadCanReturnTypedMirrorSnapshotWithEventWatermark() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = [.turnStarted(turnId: "turn-mirror")]
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true)
            ]
        ))

        let result = try XCTUnwrap(response.result?.objectValue)
        XCTAssertEqual(result["event_watermark"], .number(Double(EventBus.shared.currentSeq)))
        XCTAssertEqual(result["events"]?.arrayValue?.count, 1)
        XCTAssertNotNil(result["events"]?.arrayValue?.first?.objectValue?["turnStarted"],
                        "the mirror snapshot must preserve the typed AssistantEvent wire shape")
        XCTAssertEqual(result["events_truncated"], .bool(false))
    }

    @MainActor
    func testAgentThreadReadCanBoundLargeMobileRecoverySnapshots() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.readAgentEvents = [
            .turnStarted(turnId: "turn-1"),
            .turnStarted(turnId: "turn-2"),
            .turnStarted(turnId: "turn-3")
        ]
        let dispatcher = JSONRPCDispatcher(router: router)

        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.thread.read",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "include_event_watermark": .bool(true),
                "event_limit": .number(2)
            ]
        ))

        let result = try XCTUnwrap(response.result?.objectValue)
        let events = try XCTUnwrap(result["events"]?.arrayValue)
        XCTAssertEqual(events.count, 2)
        XCTAssertNotNil(events.first?.objectValue?["turnStarted"]?.objectValue)
        XCTAssertEqual(events.first?.objectValue?["turnStarted"]?.objectValue?["turnId"], .string("turn-2"),
                       "bounded recovery must keep the newest contiguous event suffix")
        XCTAssertEqual(result["event_watermark"], .number(Double(EventBus.shared.currentSeq)),
                       "truncating old payload must not move the authoritative event cursor")
        XCTAssertEqual(result["events_truncated"], .bool(true))
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
    func test_agentThreadConfigureClearsProviderSessionWhenProviderChanges() async throws {
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
        XCTAssertNil(router.threadStore.first?.providerThreadId, "changing provider must not resume an incompatible provider session")
    }

    @MainActor
    func test_agentThreadConfigurePreservesClaudeProviderSessionWhenOnlyModelChanges() async throws {
        let router = FakeRouter()
        var t = AgentThread(workspaceId: nil, title: "switch model", provider: .claude, model: "claude-sonnet-4-6")
        t.providerThreadId = "claude-session"
        router.threadStore = [t]
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "agent.thread.configure", params: [
            "thread_id": .string(t.id.value.uuidString),
            "provider": .string("claude"),
            "model": .string("claude-opus-4-7")
        ]))

        XCTAssertNil(resp.error)
        XCTAssertEqual(router.threadStore.first?.model, "claude-opus-4-7")
        XCTAssertEqual(router.threadStore.first?.providerThreadId, "claude-session",
                       "Claude model switching must keep the provider session cursor so the next turn can resume the same conversation")
    }

    @MainActor
    func test_surfaceSendTextReturnsExplicitTerminalFailureStatus() async throws {
        let router = FakeRouter()
        let surface = SurfaceID()
        router.terminalSendResult = .object(["status": .string("process_exited"), "accepted": .bool(false)])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.send_text", params: [
            "id": .string(surface.value.uuidString),
            "text": .string("pwd")
        ]))

        let result = try XCTUnwrap(resp.result?.objectValue)
        XCTAssertEqual(result["status"], .string("process_exited"),
                       "remote terminal input must fail loudly after child exit instead of returning opaque success")
        XCTAssertEqual(result["accepted"], .bool(false))
    }

    @MainActor
    func test_surfaceHealthIncludesTerminalProcessState() async throws {
        let router = FakeRouter()
        let surface = SurfaceID()
        router.terminalHealth = .object([
            "alive": .bool(false),
            "process_alive": .bool(false),
            "pty_open": .bool(false),
            "input_accepting": .bool(false),
            "terminal_dead_reason": .string("process_exited")
        ])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.health", params: [
            "id": .string(surface.value.uuidString)
        ]))

        let result = try XCTUnwrap(resp.result?.objectValue)
        XCTAssertEqual(result["alive"], .bool(false))
        XCTAssertEqual(result["terminal_dead_reason"], .string("process_exited"),
                       "iOS ALIVE/DEAD must reflect terminal process state, not just surface object existence")
    }

    @MainActor
    func test_surfaceReadTextCanReturnSnapshotReliabilityMetadata() async throws {
        let router = FakeRouter()
        let surface = SurfaceID()
        router.terminalSnapshot = .object([
            "text": .string("partial"),
            "complete": .bool(false),
            "partial": .bool(true),
            "source": .string("ansi_fallback"),
            "partial_reason": .string("ghostty_unavailable")
        ])
        let d = JSONRPCDispatcher(router: router)

        let resp = await d.dispatch(JSONRPCRequest(jsonrpc: "2.0", id: .number(1), method: "surface.read_text", params: [
            "id": .string(surface.value.uuidString),
            "include_metadata": .bool(true)
        ]))

        let result = try XCTUnwrap(resp.result?.objectValue)
        XCTAssertEqual(result["complete"], .bool(false))
        XCTAssertEqual(result["partial_reason"], .string("ghostty_unavailable"),
                       "snapshot reads must say when terminal text is degraded so iOS does not show fake complete output")
    }

    @MainActor
    func testAgentPlanNotesSaveRejectsStaleExpectedValue() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.planNotesByThread[thread] = "newer Mac notes"
        let dispatcher = JSONRPCDispatcher(router: router)

        let rejected = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("stale iOS overwrite"),
                "expected_notes": .string("older notes"),
                "client_request_id": .string(UUID().uuidString)
            ]
        ))

        XCTAssertEqual(rejected.error?.code, -32009)
        XCTAssertEqual(rejected.error?.message, "Plan notes changed on another device.")
        XCTAssertEqual(router.planNotesByThread[thread], "newer Mac notes",
                       "a stale mobile save must not overwrite the authoritative Mac value")

        let accepted = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(2),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("merged iOS notes"),
                "expected_notes": .string("newer Mac notes"),
                "client_request_id": .string(UUID().uuidString)
            ]
        ))

        XCTAssertNil(accepted.error)
        XCTAssertEqual(accepted.result, .bool(true))
        XCTAssertEqual(router.planNotesByThread[thread], "merged iOS notes")
    }

    @MainActor
    func testAgentPlanNotesPersistenceFailureIsNotReturnedOrCachedAsSuccess() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        let requestID = UUID().uuidString
        let dispatcher = JSONRPCDispatcher(router: router)
        let request = JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("durable notes"),
                "expected_notes": .string(""),
                "client_request_id": .string(requestID)
            ]
        )

        router.planNotesSaveShouldFail = true
        let failed = await dispatcher.dispatch(request)

        XCTAssertNil(failed.result, "a failed durable write must never return RPC success")
        XCTAssertNotNil(failed.error)
        XCTAssertNil(router.commandReceipt(method: request.method, clientRequestId: requestID),
                     "a failed durable write must not poison retries with a cached success receipt")

        router.planNotesSaveShouldFail = false
        let retried = await dispatcher.dispatch(request)

        XCTAssertEqual(retried.result, .bool(true))
        XCTAssertEqual(router.planNotesSaveCallCount, 2,
                       "the same request ID must reach persistence again after the first write failed")
        XCTAssertEqual(router.planNotesByThread[thread], "durable notes")
    }

    @MainActor
    func testAgentPlanNotesCASReadFailureDoesNotAssumeEmptyValueOrWrite() async throws {
        let router = FakeRouter()
        let thread = AgentThreadID()
        router.planNotesReadShouldFail = true
        let dispatcher = JSONRPCDispatcher(router: router)

        let failed = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "agent.plan.notes.save",
            params: [
                "thread_id": .string(thread.value.uuidString),
                "notes": .string("must not write"),
                "expected_notes": .string("")
            ]
        ))

        XCTAssertNil(failed.result,
                     "a failed authoritative read must never be treated as an empty CAS value")
        XCTAssertNotNil(failed.error)
        XCTAssertEqual(router.planNotesSaveCallCount, 0,
                       "CAS must stop before persistence when the authoritative read failed")
    }

    // Verifies that the encode<T> helper's new path (JSONDecoder -> JSONValue) produces the
    // same structure as the old path (JSONSerialization + JSONValue.from) for a representative
    // Codable. This guards against any behavioral divergence introduced by the optimization.
    func test_encodeHelper_newPathMatchesOldPath() throws {
        struct Sample: Codable {
            let name: String
            let count: Int
            let ratio: Double
            let flag: Bool
            let tags: [String]
            let nested: Nested
            struct Nested: Codable {
                let value: String
            }
        }
        let sample = Sample(
            name: "hello",
            count: 42,
            ratio: 1.5,
            flag: true,
            tags: ["a", "b"],
            nested: .init(value: "world")
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(sample)

        // Old path: JSONSerialization -> JSONValue.from
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let oldResult = JSONValue.from(any)

        // New path: JSONDecoder -> JSONValue directly
        let newResult = try JSONDecoder().decode(JSONValue.self, from: data)

        XCTAssertEqual(oldResult, newResult,
                       "encode<T> optimization must produce structurally identical JSONValue output as the original double-round-trip path")
    }
}
