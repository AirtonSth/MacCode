import Foundation
import XCTest
@testable import SocketServer
import CoreModel
import AgentRuntime
import Persistence

private final class Phase4MutationAuth: DirectAuthProvider {
    private let tokens: Set<String>

    init(tokens: Set<String>) {
        self.tokens = tokens
    }

    func verify(token: String) -> Bool { tokens.contains(token) }
    func createPairingCode() -> String? { nil }
    func redeemPairingCode(
        _ code: String,
        deviceName: String
    ) -> (deviceId: String, token: String)? { nil }
    func listDevices() -> [[String: Any]] { [] }
    func revokeDevice(_ id: String) {}
}

private actor Phase4FirstEffectGate {
    private var firstArrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdFirstEffect() async {
        guard !firstArrived else { return }
        firstArrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters.removeAll()
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForFirstEffect() async {
        guard !firstArrived else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    func releaseFirstEffect() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor Phase4LateEventGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private struct Phase4InjectedUnknownOutcome: Error {}
private struct Phase4InjectedReceiptUnavailable: Error {}

private final class Phase4ReceiptFakeRouter: FakeRouter, CommandReceiptStateRouting {
    private struct Receipt {
        let ownerFingerprint: String
        let paramsHash: String
        var state: String
        var result: JSONValue?
    }

    var receiptPersistenceUnavailable = false
    var finalizationPersistenceUnavailable = false
    var effectThenOutcomeUnknown = false
    var firstEffectGate: Phase4FirstEffectGate?
    var lateEventGate: Phase4LateEventGate?
    var lateEventKind = "agent.phase4.late"
    var eventClientRequestId = ""
    private(set) var receiptRecordCallCount = 0
    private(set) var createWorkspaceCallCount = 0
    private(set) var finalizationCallCount = 0
    private(set) var synchronousBatchEffectCallCount = 0
    private(set) var phase4ClaimCallCount = 0
    private(set) var finalizedEventKinds: [String: [String]] = [:]
    private var phase4Receipts: [String: Receipt] = [:]

    private func phase4ReceiptKey(method: String, clientRequestId: String) -> String {
        "\(method):\(clientRequestId)"
    }

    override func createWorkspace(name: String, cwd: String) throws -> Workspace {
        createWorkspaceCallCount += 1
        return try super.createWorkspace(name: name, cwd: cwd)
    }

    override func selectWorkspace(_ id: WorkspaceID) throws {
        synchronousBatchEffectCallCount += 1
        window.selectedWorkspaceID = id
    }

    override func closeWorkspace(_ id: WorkspaceID, publishEvent: Bool = true) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func renameWorkspace(_ id: WorkspaceID, _ newName: String) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func setWorkspaceDescription(_ id: WorkspaceID, _ text: String) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func setWorkspaceColor(_ id: WorkspaceID, _ color: String) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func setWorkspacePinned(_ id: WorkspaceID, _ pinned: Bool) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func reorderWorkspace(_ id: WorkspaceID, position: Int) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func moveWorkspaceToWindow(workspace: WorkspaceID, target: WindowID) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func createWindow(title: String?) throws -> AppWindow {
        synchronousBatchEffectCallCount += 1
        return try super.createWindow(title: title)
    }

    override func focusWindow(_ id: WindowID) throws {
        synchronousBatchEffectCallCount += 1
        try super.focusWindow(id)
    }

    override func closeWindow(_ id: WindowID) throws {
        synchronousBatchEffectCallCount += 1
        try super.closeWindow(id)
    }

    override func paneResize(workspace: WorkspaceID, splitID: UUID, ratios: [Double]) throws {
        synchronousBatchEffectCallCount += 1
        try super.paneResize(workspace: workspace, splitID: splitID, ratios: ratios)
    }

    override func paneSwap(workspace: WorkspaceID, a: PaneID, b: PaneID) throws {
        synchronousBatchEffectCallCount += 1
        try super.paneSwap(workspace: workspace, a: a, b: b)
    }

    override func createSurface(
        workspace: WorkspaceID,
        type: SurfaceType,
        paneID: PaneID?,
        title: String?
    ) throws -> SurfaceDescriptor {
        synchronousBatchEffectCallCount += 1
        return try super.createSurface(workspace: workspace, type: type, paneID: paneID, title: title)
    }

    override func closeSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        synchronousBatchEffectCallCount += 1
        try super.closeSurface(workspace: workspace, surface: surface)
    }

    override func focusSurface(workspace: WorkspaceID, surface: SurfaceID) throws {
        synchronousBatchEffectCallCount += 1
        try super.focusSurface(workspace: workspace, surface: surface)
    }

    override func renameSurface(_ wid: WorkspaceID, _ sid: SurfaceID, _ title: String) throws {
        synchronousBatchEffectCallCount += 1
        try super.renameSurface(wid, sid, title)
    }

    override func setSurfaceColor(_ wid: WorkspaceID, _ sid: SurfaceID, _ color: String) throws {
        synchronousBatchEffectCallCount += 1
        try super.setSurfaceColor(wid, sid, color)
    }

    override func splitPane(
        workspace: WorkspaceID,
        paneID: PaneID,
        direction: SplitDirection,
        surfaceType: SurfaceType,
        title: String?
    ) throws -> SurfaceDescriptor {
        synchronousBatchEffectCallCount += 1
        return try super.splitPane(
            workspace: workspace,
            paneID: paneID,
            direction: direction,
            surfaceType: surfaceType,
            title: title
        )
    }

    override func surfaceMove(workspace: WorkspaceID, surface: SurfaceID, targetPane: PaneID) throws {
        synchronousBatchEffectCallCount += 1
        try super.surfaceMove(workspace: workspace, surface: surface, targetPane: targetPane)
    }

    override func surfaceReorder(
        workspace: WorkspaceID,
        surface: SurfaceID,
        toPane: PaneID,
        position: Int
    ) throws {
        synchronousBatchEffectCallCount += 1
        try super.surfaceReorder(workspace: workspace, surface: surface, toPane: toPane, position: position)
    }

    override func surfaceClearHistory(surface: SurfaceID) {
        synchronousBatchEffectCallCount += 1
        super.surfaceClearHistory(surface: surface)
    }

    override func sendTextResult(surface: SurfaceID, text: String) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return try super.sendTextResult(surface: surface, text: text)
    }

    override func fsWorkspaceCreateFile(
        workspace: WorkspaceID,
        path: String,
        content: String
    ) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return .object(["relative_path": .string(path)])
    }

    override func fsWorkspaceRename(
        workspace: WorkspaceID,
        path: String,
        newName: String
    ) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return .object(["relative_path": .string(newName)])
    }

    override func fsWorkspaceDelete(workspace: WorkspaceID, paths: [String]) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return .object(["deleted": .array(paths.map(JSONValue.string))])
    }

    override func filesOpenTab(
        workspace: WorkspaceID,
        sourceSurface: SurfaceID?,
        paneID: PaneID?,
        path: String
    ) throws -> SurfaceDescriptor {
        synchronousBatchEffectCallCount += 1
        return SurfaceDescriptor(type: .files, title: path)
    }

    override func filesSplitTab(
        workspace: WorkspaceID,
        sourceSurface: SurfaceID?,
        paneID: PaneID?,
        direction: SplitDirection,
        path: String
    ) throws -> SurfaceDescriptor {
        synchronousBatchEffectCallCount += 1
        return SurfaceDescriptor(type: .files, title: path)
    }

    override func filesStateUpdate(
        surface: SurfaceID,
        patch: [String: JSONValue],
        baseRevision: Int?,
        deviceID: String?
    ) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        let result = try super.filesStateUpdate(
            surface: surface,
            patch: patch,
            baseRevision: baseRevision,
            deviceID: deviceID
        )
        EventBus.shared.publish(kind: "files.state.updated", payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "state": result
        ]))
        return result
    }

    override func filesEditOpen(surface: SurfaceID, path: String) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        let result: JSONValue = .object(["session_id": .string("phase4-session"), "path": .string(path)])
        publishPhase4FilesUpdate(surface: surface, result: result)
        return result
    }

    override func filesEditApplyPatch(
        sessionID: String,
        baseDraftRevision: Int,
        rangeLocation: Int,
        rangeLength: Int,
        replacement: String,
        deviceID: String?
    ) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        let result: JSONValue = .object(["session_id": .string(sessionID), "draft_revision": .number(2)])
        publishPhase4FilesUpdate(surface: SurfaceID(), result: result)
        return result
    }

    override func filesEditSave(sessionID: String) throws -> JSONValue {
        try phase4FileEditResult(sessionID: sessionID, action: "save")
    }

    override func filesEditDiscard(sessionID: String) throws -> JSONValue {
        try phase4FileEditResult(sessionID: sessionID, action: "discard")
    }

    override func filesEditClose(sessionID: String) throws -> JSONValue {
        try phase4FileEditResult(sessionID: sessionID, action: "close")
    }

    override func notificationCreate(
        workspaceId: WorkspaceID?,
        title: String,
        body: String?,
        category: String?
    ) throws -> String {
        synchronousBatchEffectCallCount += 1
        return "phase4-notification"
    }

    override func notificationMarkRead(id: String) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func notificationDismiss(id: String) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func settingsSet(key: String, value: String) throws {
        synchronousBatchEffectCallCount += 1
        try super.settingsSet(key: key, value: value)
    }

    override func projectOpenInEditor(workspace: WorkspaceID) throws -> String {
        synchronousBatchEffectCallCount += 1
        return try super.projectOpenInEditor(workspace: workspace)
    }

    override func privatePushTokenUpdate(
        pushToken: String,
        pushTokenType: String,
        liveActivityToken: String?,
        deviceID: String?,
        tokenPurpose: String?,
        environment: String?,
        serverID: String?,
        bootEpoch: Int?,
        activityGeneration: Int?,
        activityID: String?,
        activitySessionID: String?,
        registrationRevision: Int?,
        contractVersion: Int?,
        capabilities: [String]?
    ) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return .object(["ok": .bool(true)])
    }

    private func phase4FileEditResult(sessionID: String, action: String) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        let result: JSONValue = .object([
            "session_id": .string(sessionID),
            "action": .string(action)
        ])
        publishPhase4FilesUpdate(surface: SurfaceID(), result: result)
        return result
    }

    private func publishPhase4FilesUpdate(surface: SurfaceID, result: JSONValue) {
        EventBus.shared.publish(kind: "files.state.updated", payload: .object([
            "surface_id": .string(surface.value.uuidString),
            "state": result
        ]))
    }

    override func gitCheckout(workspace: WorkspaceID, branch: String) throws -> GitActionResult {
        synchronousBatchEffectCallCount += 1
        return GitActionResult(ok: true, message: branch)
    }

    override func gitCreateBranch(workspace: WorkspaceID, name: String) throws -> GitActionResult {
        synchronousBatchEffectCallCount += 1
        return GitActionResult(ok: true, message: name)
    }

    override func gitCommit(workspace: WorkspaceID, message: String) throws -> GitActionResult {
        synchronousBatchEffectCallCount += 1
        return GitActionResult(ok: true, message: message)
    }

    override func gitPush(workspace: WorkspaceID) throws -> GitActionResult {
        synchronousBatchEffectCallCount += 1
        return GitActionResult(ok: true, message: "pushed")
    }

    override func gitDeliver(workspace: WorkspaceID, copy: GitDeliveryCopy?) throws -> GitDeliveryResult {
        synchronousBatchEffectCallCount += 1
        let plan = GitDeliveryPlan(
            branchName: "phase4",
            commitMessage: "phase4",
            pullRequestTitle: "phase4",
            pullRequestBody: "phase4",
            pullRequestURL: nil,
            phases: []
        )
        return GitDeliveryResult(ok: true, plan: plan, phases: [], pullRequestURL: nil)
    }

    override func projectRunScript(workspace: WorkspaceID, name: String) throws -> SurfaceDescriptor {
        synchronousBatchEffectCallCount += 1
        let surface = SurfaceDescriptor(type: .terminal, title: "Run: \(name)")
        EventBus.shared.publish(kind: "surface.created", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface": .object(["id": .string(surface.id.value.uuidString)])
        ]))
        EventBus.shared.publish(kind: "project.script_started", payload: .object([
            "workspace_id": .string(workspace.value.uuidString),
            "surface_id": .string(surface.id.value.uuidString),
            "name": .string(name)
        ]))
        return surface
    }

    override func sshHostUpsert(
        _ profile: SSHHostProfile,
        workspace: WorkspaceID
    ) throws -> SSHHostProfile {
        synchronousBatchEffectCallCount += 1
        return profile
    }

    override func sshHostDelete(_ id: SSHHostID, workspace: WorkspaceID) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func sshConnect(
        workspace: WorkspaceID,
        profileID: SSHHostID?,
        profile: SSHHostProfile?,
        title: String?,
        paneID: PaneID?
    ) throws -> SurfaceDescriptor {
        synchronousBatchEffectCallCount += 1
        return SurfaceDescriptor(
            type: .ssh,
            title: title ?? "SSH",
            metadata: ["ssh_status": "connected", "ssh_destination": profile?.destination ?? "host"]
        )
    }

    override func sshDisconnect(surface: SurfaceID) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func sshTransferUpload(
        surface: SurfaceID,
        localPath: String,
        remotePath: String
    ) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return .object(["ok": .bool(true)])
    }

    override func sshTransferDownload(
        surface: SurfaceID,
        remotePath: String,
        localPath: String
    ) throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return .object(["ok": .bool(true)])
    }

    override func openAgentApp(workspace: WorkspaceID) throws -> SurfaceDescriptor {
        synchronousBatchEffectCallCount += 1
        return try super.openAgentApp(workspace: workspace)
    }

    override func createAgentThread(
        workspace: WorkspaceID?,
        title: String,
        provider: AgentProvider,
        model: String,
        permissionMode: AgentPermissionMode,
        reasoningEffort: AgentReasoningEffort,
        serviceTier: AgentServiceTier,
        modelSelection: AgentModelSelection?,
        providerInstanceId: String?,
        runAsUser: AgentRunAsUser?,
        surfaceID: SurfaceID?
    ) throws -> AgentThread {
        synchronousBatchEffectCallCount += 1
        return try super.createAgentThread(
            workspace: workspace,
            title: title,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            runAsUser: runAsUser,
            surfaceID: surfaceID
        )
    }

    override func prepareAgentThreadForPullRequest(
        workspace: WorkspaceID,
        url: String,
        provider: AgentProvider,
        model: String,
        permissionMode: AgentPermissionMode,
        reasoningEffort: AgentReasoningEffort,
        serviceTier: AgentServiceTier,
        modelSelection: AgentModelSelection?,
        providerInstanceId: String?
    ) throws -> AgentThread {
        synchronousBatchEffectCallCount += 1
        return try super.prepareAgentThreadForPullRequest(
            workspace: workspace,
            url: url,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId
        )
    }

    override func rollbackAgentThread(thread: AgentThreadID, toTurnId: String) async throws {
        synchronousBatchEffectCallCount += 1
        if let firstEffectGate {
            await firstEffectGate.holdFirstEffect()
        }
        try await super.rollbackAgentThread(thread: thread, toTurnId: toTurnId)
    }

    override func deleteAgentThread(thread: AgentThreadID) async throws {
        synchronousBatchEffectCallCount += 1
        try await super.deleteAgentThread(thread: thread)
    }

    override func deleteAgentThreads(_ threads: [AgentThreadID]) async throws {
        synchronousBatchEffectCallCount += 1
        try await super.deleteAgentThreads(threads)
    }

    override func renameAgentThread(thread: AgentThreadID, title: String) throws -> AgentThread {
        synchronousBatchEffectCallCount += 1
        return try super.renameAgentThread(thread: thread, title: title)
    }

    override func setAgentThreadPinned(thread: AgentThreadID, pinned: Bool) throws -> AgentThread {
        synchronousBatchEffectCallCount += 1
        return try super.setAgentThreadPinned(thread: thread, pinned: pinned)
    }

    override func setAgentThreadColor(thread: AgentThreadID, color: String) throws -> AgentThread {
        synchronousBatchEffectCallCount += 1
        return try super.setAgentThreadColor(thread: thread, color: color)
    }

    override func reorderAgentThread(thread: AgentThreadID, position: Int) throws -> [AgentThread] {
        synchronousBatchEffectCallCount += 1
        return try super.reorderAgentThread(thread: thread, position: position)
    }

    override func configureAgentThread(
        thread: AgentThreadID,
        provider: AgentProvider?,
        model: String?,
        permissionMode: AgentPermissionMode?,
        reasoningEffort: AgentReasoningEffort?,
        serviceTier: AgentServiceTier?,
        modelSelection: AgentModelSelection?,
        providerInstanceId: String?,
        runAsUser: AgentRunAsUser?
    ) throws -> AgentThread {
        synchronousBatchEffectCallCount += 1
        return try super.configureAgentThread(
            thread: thread,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            runAsUser: runAsUser
        )
    }

    override func configureAgentThreadExecution(
        thread: AgentThreadID,
        executionMode: AgentExecutionMode,
        baseBranch: String?
    ) throws -> AgentThread {
        synchronousBatchEffectCallCount += 1
        return try super.configureAgentThreadExecution(
            thread: thread,
            executionMode: executionMode,
            baseBranch: baseBranch
        )
    }

    override func markAgentThreadRead(thread: AgentThreadID) throws {
        synchronousBatchEffectCallCount += 1
        try super.markAgentThreadRead(thread: thread)
    }

    override func selectAgentThread(thread: AgentThreadID, surfaceID: SurfaceID?) throws {
        synchronousBatchEffectCallCount += 1
        try super.selectAgentThread(thread: thread, surfaceID: surfaceID)
    }

    override func browserNavigate(surface: SurfaceID, url: String) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func browserBack(surface: SurfaceID) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func browserForward(surface: SurfaceID) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func browserReload(surface: SurfaceID) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func browserMirrorURL(surface: SurfaceID) throws -> [String: JSONValue] {
        synchronousBatchEffectCallCount += 1
        return ["url": .string("file:///secret/path/index.html"), "is_file": .bool(true)]
    }

    override func browserEval(surface: SurfaceID, script: String) async throws -> String {
        synchronousBatchEffectCallCount += 1
        return "null"
    }

    override func browserScreenshot(surface: SurfaceID, savePath: String?) throws -> String {
        synchronousBatchEffectCallCount += 1
        return savePath ?? "/tmp/phase4.png"
    }

    override func browserAction(
        surface: SurfaceID,
        kind: String,
        ref: String,
        value: String?
    ) async throws -> String {
        synchronousBatchEffectCallCount += 1
        return "{\"ok\":true}"
    }

    func claimCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws -> CommandReceiptClaimResult {
        phase4ClaimCallCount += 1
        guard !receiptPersistenceUnavailable else {
            throw Phase4InjectedReceiptUnavailable()
        }
        let key = phase4ReceiptKey(method: method, clientRequestId: clientRequestId)
        if let receipt = phase4Receipts[key] {
            guard receipt.ownerFingerprint == ownerFingerprint else { return .ownerMismatch }
            guard receipt.paramsHash == paramsHash else { return .requestMismatch }
            switch receipt.state {
            case "claimed": return .inProgress
            case "committed":
                let data = try JSONEncoder().encode(receipt.result ?? .null)
                return .committed(resultJSON: String(decoding: data, as: UTF8.self))
            default: return .unknown
            }
        }
        if commandReceipts[key] != nil {
            return .legacyUnverifiable
        }
        phase4Receipts[key] = Receipt(
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            state: "claimed",
            result: nil
        )
        return .claimed
    }

    func commitCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue
    ) throws {
        let key = phase4ReceiptKey(method: method, clientRequestId: clientRequestId)
        guard var receipt = phase4Receipts[key],
              receipt.ownerFingerprint == ownerFingerprint,
              receipt.paramsHash == paramsHash,
              receipt.state == "claimed" else {
            throw Phase4InjectedReceiptUnavailable()
        }
        receipt.state = "committed"
        receipt.result = result
        phase4Receipts[key] = receipt
    }

    func finalizeCommandReceipt(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String,
        result: JSONValue,
        events: [EventBus.MutationEventIntent],
        minimumEventSequence: Int64
    ) throws -> [EventBus.Event] {
        guard !finalizationPersistenceUnavailable else {
            throw Phase4InjectedReceiptUnavailable()
        }
        finalizationCallCount += 1
        finalizedEventKinds[phase4ReceiptKey(method: method, clientRequestId: clientRequestId)] = events.map(\.kind)
        try commitCommandReceipt(
            method: method,
            clientRequestId: clientRequestId,
            ownerFingerprint: ownerFingerprint,
            paramsHash: paramsHash,
            result: result
        )
        return events.enumerated().map { ordinal, event in
            EventBus.Event(
                seq: minimumEventSequence + Int64(ordinal) + 1,
                kind: event.kind,
                payload: event.payload,
                ts: event.createdAt.timeIntervalSince1970
            )
        }
    }

    func markCommandReceiptUnknown(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String,
        paramsHash: String
    ) throws {
        let key = phase4ReceiptKey(method: method, clientRequestId: clientRequestId)
        guard var receipt = phase4Receipts[key],
              receipt.ownerFingerprint == ownerFingerprint,
              receipt.paramsHash == paramsHash else { return }
        receipt.state = "unknown"
        phase4Receipts[key] = receipt
    }

    func commandReceiptStatus(
        method: String,
        clientRequestId: String,
        ownerFingerprint: String
    ) throws -> CommandReceiptStatusResult {
        let key = phase4ReceiptKey(method: method, clientRequestId: clientRequestId)
        guard let receipt = phase4Receipts[key] else {
            return commandReceipts[key] == nil ? .absent : .legacyUnverifiable
        }
        guard receipt.ownerFingerprint == ownerFingerprint else { return .ownerMismatch }
        switch receipt.state {
        case "claimed": return .inProgress
        case "committed": return .committed
        default: return .unknown
        }
    }

    override func sendAgentMessage(
        thread: AgentThreadID,
        text: String,
        provider: AgentProvider?,
        model: String?,
        permissionMode: AgentPermissionMode?,
        reasoningEffort: AgentReasoningEffort?,
        serviceTier: AgentServiceTier?,
        interactionMode: AgentInteractionMode?,
        modelSelection: AgentModelSelection?,
        providerInstanceId: String?,
        attachments: [AgentAttachment]
    ) async throws -> AgentMessageSendResult {
        let result = try await super.sendAgentMessage(
            thread: thread,
            text: text,
            provider: provider,
            model: model,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            modelSelection: modelSelection,
            providerInstanceId: providerInstanceId,
            attachments: attachments
        )
        EventBus.shared.publish(kind: "agent.message.appended", payload: .object([
            "client_request_id": .string(eventClientRequestId),
            "thread_id": .string(thread.value.uuidString),
        ]))
        if let lateEventGate {
            let lateEventKind = self.lateEventKind
            Task {
                await lateEventGate.waitForRelease()
                EventBus.shared.publish(kind: lateEventKind, payload: .object([
                    "thread_id": .string(thread.value.uuidString),
                ]))
            }
        }
        if let firstEffectGate {
            await firstEffectGate.holdFirstEffect()
        }
        if effectThenOutcomeUnknown {
            throw Phase4InjectedUnknownOutcome()
        }
        return result
    }

    override func updateAgentQueuedMessage(
        id: AgentQueuedMessageID,
        text: String,
        attachments: [AgentAttachment]
    ) async throws -> AgentQueuedMessage {
        synchronousBatchEffectCallCount += 1
        return AgentQueuedMessage(id: id, threadId: AgentThreadID(), text: text, attachments: attachments)
    }

    override func cancelAgentQueuedMessage(id: AgentQueuedMessageID) throws -> AgentQueuedMessage {
        synchronousBatchEffectCallCount += 1
        return AgentQueuedMessage(id: id, threadId: AgentThreadID(), text: "cancelled")
    }

    override func forceAgentQueuedMessageNow(id: AgentQueuedMessageID) async throws -> AgentMessageSendResult {
        synchronousBatchEffectCallCount += 1
        return AgentMessageSendResult(status: .started, runId: AgentRunID())
    }

    override func reorderAgentQueuedMessage(
        thread: AgentThreadID,
        id: AgentQueuedMessageID,
        position: Int
    ) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func implementAgentPlan(
        thread: AgentThreadID,
        planId: String,
        planMarkdown: String?,
        newThread: Bool,
        provider: AgentProvider?,
        model: String?,
        permissionMode: AgentPermissionMode?,
        reasoningEffort: AgentReasoningEffort?,
        serviceTier: AgentServiceTier?,
        modelSelection: AgentModelSelection?
    ) async throws -> (runId: AgentRunID, implementationThreadId: AgentThreadID) {
        synchronousBatchEffectCallCount += 1
        return (AgentRunID(), newThread ? AgentThreadID() : thread)
    }

    override func saveAgentPlan(
        thread: AgentThreadID,
        planId: String,
        planMarkdown: String?,
        relativePath: String?
    ) throws -> (path: String, relativePath: String) {
        synchronousBatchEffectCallCount += 1
        let relative = relativePath ?? ".remotecode/plans/phase4.md"
        return ("/tmp/secret-phase4-plan/\(relative)", relative)
    }

    override func saveAgentPlanNotes(thread: AgentThreadID, notes: String) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func stopAgentRun(thread: AgentThreadID) throws {
        synchronousBatchEffectCallCount += 1
    }

    override func continueAgentRun(thread: AgentThreadID) async throws -> AgentRunID? {
        synchronousBatchEffectCallCount += 1
        return AgentRunID()
    }

    override func respondAgentRequest(
        thread: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {
        synchronousBatchEffectCallCount += 1
        EventBus.shared.publish(kind: "agent.thread.updated", payload: .object([
            "thread_id": .string(thread.value.uuidString),
        ]))
    }

    override func respondAgentUserInput(
        thread: AgentThreadID,
        requestId: String,
        text: String
    ) async throws {
        synchronousBatchEffectCallCount += 1
        EventBus.shared.publish(kind: "agent.user_input.resolved", payload: .object([
            "thread_id": .string(thread.value.uuidString),
            "request_id": .string(requestId),
            "answer": .string("secret-phase4-answer"),
        ]))
    }

    override func revertAgentThreadToCheckpoint(
        thread: AgentThreadID,
        checkpointTurnCount: Int
    ) async throws -> AgentTurnCheckpointSummary {
        synchronousBatchEffectCallCount += 1
        return AgentTurnCheckpointSummary(
            threadId: thread,
            runId: AgentRunID(),
            turnId: "turn-\(checkpointTurnCount)",
            checkpointTurnCount: checkpointTurnCount,
            checkpointRef: "phase4-checkpoint",
            status: .ready,
            files: []
        )
    }

    override func uploadAgentAttachment(
        workspace: WorkspaceID,
        filename: String,
        mimeType: String?,
        dataBase64: String
    ) throws -> AgentAttachmentUploadResult {
        synchronousBatchEffectCallCount += 1
        let id = String(repeating: "c", count: 64)
        return AgentAttachmentUploadResult(
            id: id,
            displayName: filename,
            kind: .file,
            mimeType: mimeType,
            sha256: id,
            sizeBytes: Data(base64Encoded: dataBase64)?.count ?? 0,
            composerInsertionText: "/tmp/remote-code-fake-attachments/\(id)/\(filename)"
        )
    }

    override func importAgentAttachment(
        workspace: WorkspaceID,
        relativePath: String
    ) throws -> AgentAttachmentUploadResult {
        synchronousBatchEffectCallCount += 1
        let id = String(repeating: "d", count: 64)
        return AgentAttachmentUploadResult(
            id: id,
            displayName: URL(fileURLWithPath: relativePath).lastPathComponent,
            kind: .file,
            mimeType: "text/plain",
            sha256: id,
            sizeBytes: 7,
            composerInsertionText: "/Users/dev/demo-api/\(relativePath)"
        )
    }

    override func updateAgentProvider(
        provider: AgentProvider,
        providerInstanceId: String?
    ) async throws -> JSONValue {
        synchronousBatchEffectCallCount += 1
        return .object([
            "provider": .string(provider.rawValue),
            "ok": .bool(true),
            "status": .number(0),
            "binary_path": .string("/tmp/secret-phase4-provider"),
            "stdout": .string("secret-phase4-provider-output"),
        ])
    }

    override func recordCommandReceipt(
        method: String,
        clientRequestId: String,
        result: JSONValue
    ) {
        receiptRecordCallCount += 1
        guard !receiptPersistenceUnavailable else { return }
        super.recordCommandReceipt(
            method: method,
            clientRequestId: clientRequestId,
            result: result
        )
    }
}

private final class Phase4EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [EventBus.Event] = []

    func append(_ event: EventBus.Event) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [EventBus.Event] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class Phase4LiveServer {
    static let hostId = "phase4-host"
    static let ownerToken = "phase4-owner-token-a"
    static let otherOwnerToken = "phase4-owner-token-b"

    let server: DirectHTTPServer
    let socket: URLSessionWebSocketTask
    let port: UInt16
    let connectionId: String
    let bootEpoch: UInt64

    private init(
        server: DirectHTTPServer,
        socket: URLSessionWebSocketTask,
        port: UInt16,
        connectionId: String,
        bootEpoch: UInt64
    ) {
        self.server = server
        self.socket = socket
        self.port = port
        self.connectionId = connectionId
        self.bootEpoch = bootEpoch
    }

    @MainActor
    static func start(
        router: CommandRouting,
        bootEpoch: UInt64,
        commandReceiptMetrics: CommandReceiptMetrics = CommandReceiptMetrics()
    ) async throws -> Phase4LiveServer {
        let port = UInt16.random(in: 33_000...44_000)
        let auth = Phase4MutationAuth(tokens: [ownerToken, otherOwnerToken])
        let server = DirectHTTPServer(
            port: port,
            loopbackOnly: false,
            dispatcher: JSONRPCDispatcher(
                router: router,
                commandReceiptMetrics: commandReceiptMetrics
            ),
            auth: auth,
            serverId: hostId,
            bootEpoch: bootEpoch
        )
        try server.start()
        try await Task.sleep(nanoseconds: 80_000_000)

        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("Bearer \(ownerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        let welcome = try await receiveObject(socket)
        let connectionId = try XCTUnwrap(welcome["connectionId"] as? String)
        return Phase4LiveServer(
            server: server,
            socket: socket,
            port: port,
            connectionId: connectionId,
            bootEpoch: bootEpoch
        )
    }

    func stop() {
        socket.cancel(with: .normalClosure, reason: nil)
        server.stop()
    }

    func mutationParams(
        requestId: String,
        threadId: AgentThreadID,
        text: String
    ) -> [String: Any] {
        [
            "client_request_id": requestId,
            "connection_id": connectionId,
            "expected_host_id": Self.hostId,
            "expected_boot_epoch": bootEpoch,
            "thread_id": threadId.value.uuidString,
            "text": text,
        ]
    }

    func openConnection(token: String) async throws -> (URLSessionWebSocketTask, String) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/v1/ws")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("\(EventBus.shared.currentSeq)", forHTTPHeaderField: "x-rc2-since-seq")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        let welcome = try await Self.receiveObject(socket)
        return (socket, try XCTUnwrap(welcome["connectionId"] as? String))
    }

    func rpc(
        method: String,
        params: [String: Any],
        token: String = ownerToken
    ) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/rpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params,
        ])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func receiveObject(
        _ socket: URLSessionWebSocketTask
    ) async throws -> [String: Any] {
        let message = try await socket.receive()
        let data: Data
        switch message {
        case .data(let value): data = value
        case .string(let value): data = Data(value.utf8)
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
final class Phase4MutationReceiptContractTests: XCTestCase {
    private let commandInProgress = -32096
    private let commandOutcomeUnknown = -32095
    private let idempotencyOwnerMismatch = -32094
    private let idempotencyRequestMismatch = -32093
    private let legacyReceiptUnverifiable = -32092
    private let commandReceiptUnavailable = -32091

    func test_canonicalManifestExactlyMatchesDispatcherMutationCatalog() throws {
        let canonical = try canonicalMutationMethods()

        XCTAssertEqual(canonical.count, 99)
        XCTAssertEqual(JSONRPCDispatcher.hostMutationMethods, canonical,
                       "every and only canonical host mutators must enter the Phase 4 gate")
    }

    func test_readOnlyBatchCatalogIsExplicitAndDisjointFromAllCanonicalMutations() throws {
        let canonical = try canonicalMutationMethods()

        XCTAssertTrue(JSONRPCDispatcher.readOnlyBatchMethods.contains("rpc.batch"),
                      "nested read-only batches remain supported")
        XCTAssertTrue(JSONRPCDispatcher.readOnlyBatchMethods.isDisjoint(with: canonical),
                      "no canonical mutation may enter context-free batch dispatch")
        XCTAssertFalse(JSONRPCDispatcher.isReadOnlyBatchMethod("browser.mirror_url.get"))
    }

    func test_authenticatedHTTPBatchRejectsMirrorRegistrationWithZeroEffectReceiptAndEvent() async throws {
        let router = Phase4ReceiptFakeRouter()
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 405)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "browser.mirror_url.registered" { recorder.append(event) }
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let rejected = try await live.rpc(method: "rpc.batch", params: [
            "calls": [[
                "method": "browser.mirror_url.get",
                "params": ["id": UUID().uuidString],
            ]],
        ])
        XCTAssertEqual(errorCode(rejected), -32602)
        XCTAssertEqual(router.synchronousBatchEffectCallCount, 0)
        XCTAssertEqual(router.phase4ClaimCallCount, 0)
        XCTAssertTrue(recorder.events.isEmpty)

        let nestedRead = try await live.rpc(method: "rpc.batch", params: [
            "calls": [[
                "method": "rpc.batch",
                "params": ["calls": [["method": "workspace.list", "params": [:]]]],
            ]],
        ])
        XCTAssertNil(nestedRead["error"])
        XCTAssertEqual(router.synchronousBatchEffectCallCount, 0)
        XCTAssertEqual(router.phase4ClaimCallCount, 0)
    }

    func test_unknownMutatorFailsClosedWithoutCallingRouter() async {
        let router = Phase4ReceiptFakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let response = await dispatcher.dispatch(JSONRPCRequest(
            jsonrpc: "2.0",
            id: .number(1),
            method: "workspace.phase4_unknown_mutator",
            params: phase4WireParams(requestId: "unknown-mutator")
        ))

        XCTAssertEqual(response.error?.code, -32601)
        XCTAssertNil(response.result)
        XCTAssertEqual(router.sendAgentMessageCallCount, 0)
        XCTAssertEqual(router.receiptRecordCallCount, 0)
    }

    func test_everyCanonicalMutationRejectsBeforeBusinessParsingWithoutClientRequestId() async throws {
        // WHY: empty params lack client_request_id; business preflight must not run.
        let router = Phase4ReceiptFakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let mutationContext = MutationRequestContext(
            ownerFingerprint: "phase4-owner",
            hostId: "phase4-host",
            bootEpoch: 1
        )

        for method in try canonicalMutationMethods().sorted() {
            let response = await dispatcher.dispatch(JSONRPCRequest(
                jsonrpc: "2.0",
                id: .string(method),
                method: method,
                params: [:]
            ), mutationContext: mutationContext)
            XCTAssertEqual(response.error?.code, -32097,
                           "\(method) must be rejected without client_request_id before business params")
            XCTAssertNil(response.result, "\(method) must not mutate without client_request_id")
        }
    }

    func test_everyCanonicalMutationRunsPureSyntacticPreflightBeforeReceiptClaim() async throws {
        let router = Phase4ReceiptFakeRouter()
        let dispatcher = JSONRPCDispatcher(router: router)
        let context = MutationRequestContext(
            ownerFingerprint: "phase4-owner",
            hostId: "phase4-host",
            bootEpoch: 1,
            activeConnection: { connectionID, owner in
                connectionID == "phase4-connection" && owner == "phase4-owner"
            }
        )
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) {
            recorder.append($0)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let canonical = try canonicalMutationMethods()
        let parameterless: Set<String> = [
            "workspace.create", "window.create", "agent.thread.create",
            "agent.provider.update", "notification.create",
        ]
        var covered: Set<String> = []
        var probeCount = 0

        for method in canonical.sorted() {
            XCTAssertNoThrow(try HostMutationContract.preflight(
                method: method,
                params: HostMutationContract.validPreflightProbe(method: method)
            ), method)
            let probes = HostMutationContract.invalidPreflightProbes(method: method)
            XCTAssertEqual(probes.isEmpty, parameterless.contains(method), method)
            covered.insert(method)
            for (index, probe) in probes.enumerated() {
                probeCount += 1
                var params = probe.params
                params["client_request_id"] = .string("preflight-\(method)-\(index)")
                params["connection_id"] = .string("phase4-connection")
                params["expected_host_id"] = .string("phase4-host")
                params["expected_boot_epoch"] = .number(1)
                let response = await dispatcher.dispatch(JSONRPCRequest(
                    jsonrpc: "2.0",
                    id: .string("\(method):\(probe.label)"),
                    method: method,
                    params: params
                ), mutationContext: context)

                XCTAssertEqual(response.error?.code, -32602, "\(method):\(probe.label)")
                XCTAssertNil(response.result, "\(method):\(probe.label)")
            }
        }

        XCTAssertEqual(covered, canonical)
        XCTAssertGreaterThan(probeCount, canonical.count)
        XCTAssertEqual(router.phase4ClaimCallCount, 0)
        XCTAssertEqual(router.synchronousBatchEffectCallCount, 0)
        XCTAssertEqual(router.sendAgentMessageCallCount, 0)
        XCTAssertEqual(router.createWorkspaceCallCount, 0)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func test_preflightAcceptsCanonicalAliasesBranchesAndTypedPushMetadata() throws {
        let uuid = UUID().uuidString
        let cases: [(String, [String: JSONValue])] = [
            ("workspace.set_description", ["id": .string(uuid), "text": .string("")]),
            ("surface.create", ["workspace_id": .string(uuid), "type": .string("TERMINAL")]),
            ("surface.split", ["workspace_id": .string(uuid), "pane_id": .string(uuid), "direction": .string("right"), "id": .string(uuid)]),
            ("agent.message.queue.cancel", ["id": .string(uuid)]),
            ("agent.checkpoint.revert", ["thread_id": .string(uuid), "checkpoint_turn_count": .number(1)]),
            ("agent.attachment.upload", ["workspace_id": .string(uuid), "filename": .string(""), "dataBase64": .string("")]),
            ("ssh.host.upsert", ["workspaceId": .string(uuid), "profile": .object(["host": .string("")])]),
            ("private.push_token.update", [
                "push_token": .string("token"),
                "push_token_type": .string("apns"),
                "token_purpose": .string("activity_update"),
                "environment": .string("sandbox"),
                "device_id": .string("device"),
                "server_id": .string("server"),
                "live_activity_token": .string("activity"),
                "contract_version": .number(2),
                "capabilities": .array([.string("live_activity_v2")]),
            ]),
        ]
        for (method, params) in cases {
            XCTAssertNoThrow(try HostMutationContract.preflight(method: method, params: params), method)
        }
    }

    func test_liveMutationRequiresClientRequestIdAndBearerOwnerOnly() async throws {
        // WHY: HTTP mutations admit with bearer owner + client_request_id + valid
        // method/params. connection_id / expected_host_id / expected_boot_epoch
        // are optional ignored legacy fields — never -32097 blockers.
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "phase4-gate", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 410)
        defer { live.stop() }

        let valid = live.mutationParams(requestId: "gate-valid", threadId: thread.id, text: "valid")
        let validResponse = try await live.rpc(method: "agent.message.send", params: valid)
        XCTAssertNil(validResponse["error"])

        let blocked: [(String, [String: Any], String)] = [
            ("missing request id", removing("client_request_id", from: valid), Phase4LiveServer.ownerToken),
            ("empty request id", replacing("client_request_id", with: "", in: valid), Phase4LiveServer.ownerToken),
        ]
        for (name, params, token) in blocked {
            let response = try await live.rpc(
                method: "agent.message.send",
                params: params,
                token: token
            )
            XCTAssertEqual(errorCode(response), -32097, name)
        }

        let admitted: [(String, [String: Any])] = [
            ("missing connection", removing("connection_id", from: valid)),
            ("wrong connection", replacing("connection_id", with: "other-connection", in: valid)),
            ("missing host", removing("expected_host_id", from: valid)),
            ("wrong host", replacing("expected_host_id", with: "other-host", in: valid)),
            ("missing epoch", removing("expected_boot_epoch", from: valid)),
            ("wrong epoch", replacing("expected_boot_epoch", with: 411, in: valid)),
            ("minimal transport", [
                "client_request_id": "gate-minimal-transport",
                "thread_id": thread.id.value.uuidString,
                "text": "minimal",
            ]),
        ]
        var effectCount = 1
        for (name, params) in admitted {
            var uniqueParams = params
            if uniqueParams["client_request_id"] as? String == "gate-valid" {
                uniqueParams["client_request_id"] = "gate-\(name)"
            }
            let response = try await live.rpc(
                method: "agent.message.send",
                params: uniqueParams
            )
            XCTAssertNil(response["error"], "\(name): \(response)")
            effectCount += 1
            XCTAssertEqual(router.sendAgentMessageCallCount, effectCount, name)
        }
        XCTAssertEqual(router.sendAgentMessageCallCount, 1 + admitted.count)
    }

    func test_sameRequestConcurrentSequentialAndRestartHasOneEffectOneEventAndStableResult() async throws {
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "phase4-dedupe", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let gate = Phase4FirstEffectGate()
        router.firstEffectGate = gate
        router.eventClientRequestId = "same-request"
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.message.accepted",
                  event.payload.objectValue?["thread_id"]?.stringValue == thread.id.value.uuidString else { return }
            recorder.append(event)
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let firstServer = try await Phase4LiveServer.start(router: router, bootEpoch: 420)
        let params = firstServer.mutationParams(
            requestId: "same-request",
            threadId: thread.id,
            text: "same payload"
        )
        let firstTask = Task { try await firstServer.rpc(method: "agent.message.send", params: params) }
        await gate.waitForFirstEffect()
        let concurrent = try await firstServer.rpc(method: "agent.message.send", params: params)
        XCTAssertEqual(errorCode(concurrent), commandInProgress)
        await gate.releaseFirstEffect()
        let first = try await firstTask.value
        router.firstEffectGate = nil
        let sequential = try await firstServer.rpc(method: "agent.message.send", params: params)
        firstServer.stop()

        let restarted = try await Phase4LiveServer.start(router: router, bootEpoch: 421)
        defer { restarted.stop() }
        let restartedParams = restarted.mutationParams(
            requestId: "same-request",
            threadId: thread.id,
            text: "same payload"
        )
        let afterRestart = try await restarted.rpc(method: "agent.message.send", params: restartedParams)

        XCTAssertNil(first["error"])
        XCTAssertEqual(canonicalResult(first), canonicalResult(sequential))
        XCTAssertEqual(canonicalResult(first), canonicalResult(afterRestart),
                       "transport fields must be excluded from the immutable business-payload hash")
        XCTAssertEqual(router.sendAgentMessageCallCount, 1)
        XCTAssertEqual(recorder.events.count, 1)
    }

    func test_sameRequestIdWithDifferentBusinessPayloadIsRejected() async throws {
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "phase4-payload", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.eventClientRequestId = "payload-mismatch"
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 430)
        defer { live.stop() }

        let first = try await live.rpc(method: "agent.message.send", params: live.mutationParams(
            requestId: "payload-mismatch",
            threadId: thread.id,
            text: "payload A"
        ))
        let second = try await live.rpc(method: "agent.message.send", params: live.mutationParams(
            requestId: "payload-mismatch",
            threadId: thread.id,
            text: "payload B"
        ))

        XCTAssertNil(first["error"])
        XCTAssertEqual(errorCode(second), idempotencyRequestMismatch)
        XCTAssertEqual(router.sendAgentMessageCallCount, 1)
    }

    func test_sameRequestIdFromDifferentAuthenticatedOwnerIsRejected() async throws {
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "phase4-owner", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.eventClientRequestId = "owner-mismatch"
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 440)
        defer { live.stop() }
        let params = live.mutationParams(
            requestId: "owner-mismatch",
            threadId: thread.id,
            text: "same payload"
        )

        let first = try await live.rpc(method: "agent.message.send", params: params)
        XCTAssertNil(first["error"])
        let (otherOwnerSocket, otherOwnerConnectionId) = try await live.openConnection(
            token: Phase4LiveServer.otherOwnerToken
        )
        defer { otherOwnerSocket.cancel(with: .normalClosure, reason: nil) }
        var otherOwnerParams = params
        otherOwnerParams["connection_id"] = otherOwnerConnectionId
        let rejected = try await live.rpc(
            method: "agent.message.send",
            params: otherOwnerParams,
            token: Phase4LiveServer.otherOwnerToken
        )

        XCTAssertEqual(errorCode(rejected), idempotencyOwnerMismatch)
        XCTAssertEqual(router.sendAgentMessageCallCount, 1)
    }

    func test_claimPersistenceFailurePreventsEffectAndEvent() async throws {
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "phase4-claim", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.receiptPersistenceUnavailable = true
        router.eventClientRequestId = "claim-failure"
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.message.appended",
                  event.payload.objectValue?["client_request_id"]?.stringValue == "claim-failure" else { return }
            recorder.append(event)
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 450)
        defer { live.stop() }

        let response = try await live.rpc(method: "agent.message.send", params: live.mutationParams(
            requestId: "claim-failure",
            threadId: thread.id,
            text: "must not execute"
        ))

        XCTAssertEqual(errorCode(response), commandReceiptUnavailable)
        XCTAssertEqual(router.sendAgentMessageCallCount, 0)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func test_workspaceFinalizationFailureNeverFansOutBufferedEventOrReplaysEffect() async throws {
        let router = Phase4ReceiptFakeRouter()
        router.finalizationPersistenceUnavailable = true
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 451)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "workspace.created" {
                recorder.append(event)
            }
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        var params = live.mutationParams(
            requestId: "workspace-finalize-fault",
            threadId: AgentThreadID(),
            text: "unused"
        )
        params.removeValue(forKey: "thread_id")
        params.removeValue(forKey: "text")
        params["name"] = "atomic workspace"
        params["cwd"] = FileManager.default.currentDirectoryPath

        let first = try await live.rpc(method: "workspace.create", params: params)
        XCTAssertEqual(errorCode(first), commandOutcomeUnknown)
        XCTAssertEqual(router.createWorkspaceCallCount, 1)
        XCTAssertTrue(recorder.events.isEmpty)

        let retry = try await live.rpc(method: "workspace.create", params: params)
        XCTAssertEqual(errorCode(retry), commandOutcomeUnknown)
        XCTAssertEqual(router.createWorkspaceCallCount, 1)
        XCTAssertTrue(recorder.events.isEmpty)
    }

    func test_workspaceSuccessFinalizesBeforeSingleFanoutAndRetryDoesNotReplay() async throws {
        let router = Phase4ReceiptFakeRouter()
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 452)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "workspace.created" {
                recorder.append(event)
            }
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        var params = live.mutationParams(
            requestId: "workspace-finalize-success",
            threadId: AgentThreadID(),
            text: "unused"
        )
        params.removeValue(forKey: "thread_id")
        params.removeValue(forKey: "text")
        params["name"] = "durable workspace"
        params["cwd"] = FileManager.default.currentDirectoryPath

        let first = try await live.rpc(method: "workspace.create", params: params)
        let retry = try await live.rpc(method: "workspace.create", params: params)

        XCTAssertNil(first["error"])
        XCTAssertNil(retry["error"])
        XCTAssertEqual(first["result"] as? NSDictionary, retry["result"] as? NSDictionary)
        XCTAssertEqual(router.createWorkspaceCallCount, 1)
        XCTAssertEqual(router.finalizationCallCount, 1)
        XCTAssertEqual(recorder.events.count, 1)
    }

    func test_remainingWorkspaceMethodsHavePerMethodSuccessAndFaultProof() async throws {
        let workspaceID = UUID().uuidString
        let windowID = UUID().uuidString
        let cases: [(method: String, params: [String: Any], eventKinds: [String])] = [
            ("workspace.rename", ["id": workspaceID, "name": "renamed"], ["workspace.renamed"]),
            ("workspace.close", ["id": workspaceID], ["workspace.closed"]),
            ("workspace.select", ["id": workspaceID], ["workspace.selected"]),
            ("workspace.reorder", ["id": workspaceID, "position": 1], ["workspace.reordered"]),
            ("workspace.set_color", ["id": workspaceID, "color": "blue"], ["workspace.updated"]),
            ("workspace.set_description", ["id": workspaceID, "description": "description"], ["workspace.updated"]),
            ("workspace.set_pinned", ["id": workspaceID, "pinned": true], ["workspace.updated", "workspace.reordered"]),
            ("workspace.move_to_window", ["workspace_id": workspaceID, "window_id": windowID], ["workspace.updated"]),
        ]

        for (index, testCase) in cases.enumerated() {
            let expectedKinds = Set(testCase.eventKinds)
            let router = Phase4ReceiptFakeRouter()
            if testCase.method == "workspace.select",
               let uuid = UUID(uuidString: workspaceID) {
                seedPhase4Workspace(router: router, id: WorkspaceID(uuid))
            }
            let live = try await Phase4LiveServer.start(router: router, bootEpoch: UInt64(900 + index))
            let recorder = Phase4EventRecorder()
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { recorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(subscription)
                    live.stop()
                }
                var params = live.mutationParams(
                    requestId: "workspace-table-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await live.rpc(method: testCase.method, params: params)
                let retry = try await live.rpc(method: testCase.method, params: params)

                XCTAssertNil(first["error"], testCase.method)
                XCTAssertNil(retry["error"], testCase.method)
                XCTAssertEqual(router.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(router.finalizationCallCount, 1, testCase.method)
                XCTAssertEqual(recorder.events.map(\.kind), testCase.eventKinds, testCase.method)
            }

            let faultRouter = Phase4ReceiptFakeRouter()
            if testCase.method == "workspace.select",
               let uuid = UUID(uuidString: workspaceID) {
                seedPhase4Workspace(router: faultRouter, id: WorkspaceID(uuid))
            }
            faultRouter.finalizationPersistenceUnavailable = true
            let faultLive = try await Phase4LiveServer.start(
                router: faultRouter,
                bootEpoch: UInt64(950 + index)
            )
            let faultRecorder = Phase4EventRecorder()
            let faultSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { faultRecorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(faultSubscription)
                    faultLive.stop()
                }
                var params = faultLive.mutationParams(
                    requestId: "workspace-table-fault-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await faultLive.rpc(method: testCase.method, params: params)
                let retry = try await faultLive.rpc(method: testCase.method, params: params)

                XCTAssertEqual(errorCode(first), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(errorCode(retry), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(faultRouter.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(faultRouter.finalizationCallCount, 0, testCase.method)
                XCTAssertTrue(faultRecorder.events.isEmpty, testCase.method)
            }
        }
    }

    /// WHY: a syntactically valid UUID that is absent on the host used to claim
    /// a durable receipt, fail before mutation, then permanent -32095. Preflight
    /// must reject with a domain error and leave receipt status absent.
    func test_workspaceSelectAbsentIdIsDomainRejectionWithoutUnknownReceipt() async throws {
        let router = Phase4ReceiptFakeRouter()
        let existing = WorkspaceID()
        seedPhase4Workspace(router: router, id: existing)
        router.window.selectedWorkspaceID = existing
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 2_010)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "workspace.selected" { recorder.append(event) }
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        let absentID = UUID().uuidString
        var params = live.mutationParams(
            requestId: "select-absent",
            threadId: AgentThreadID(),
            text: "unused"
        )
        params.removeValue(forKey: "thread_id")
        params.removeValue(forKey: "text")
        params["id"] = absentID

        let first = try await live.rpc(method: "workspace.select", params: params)
        let retry = try await live.rpc(method: "workspace.select", params: params)
        let status = try await live.rpc(method: "command.receipt.status", params: statusParams(
            live: live,
            method: "workspace.select",
            requestId: "select-absent"
        ))

        XCTAssertNotEqual(errorCode(first), commandOutcomeUnknown)
        XCTAssertNotEqual(errorCode(retry), commandOutcomeUnknown)
        XCTAssertNotNil(first["error"])
        XCTAssertNotNil(retry["error"])
        XCTAssertEqual(errorCode(first), errorCode(retry))
        XCTAssertEqual(router.phase4ClaimCallCount, 0)
        XCTAssertEqual(router.synchronousBatchEffectCallCount, 0)
        XCTAssertEqual(router.finalizationCallCount, 0)
        XCTAssertEqual(router.window.selectedWorkspaceID, existing)
        XCTAssertTrue(recorder.events.isEmpty)
        try assertStatusResult(
            status,
            status: "absent",
            method: "workspace.select",
            requestId: "select-absent"
        )
        XCTAssertNotEqual(statusResultStatus(status), "unknown")
    }

    /// WHY: successful select must claim once, finalize once, publish exactly one
    /// event, and replay without a second effect when the response is lost.
    func test_workspaceSelectExistingIdSucceedsExactlyOnceWithReplaySafety() async throws {
        let router = Phase4ReceiptFakeRouter()
        let target = WorkspaceID()
        let other = WorkspaceID()
        seedPhase4Workspace(router: router, id: other)
        seedPhase4Workspace(router: router, id: target)
        router.window.selectedWorkspaceID = other
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 2_011)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "workspace.selected" { recorder.append(event) }
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        var params = live.mutationParams(
            requestId: "select-success",
            threadId: AgentThreadID(),
            text: "unused"
        )
        params.removeValue(forKey: "thread_id")
        params.removeValue(forKey: "text")
        params["id"] = target.value.uuidString

        let first = try await live.rpc(method: "workspace.select", params: params)
        let retry = try await live.rpc(method: "workspace.select", params: params)
        let status = try await live.rpc(method: "command.receipt.status", params: statusParams(
            live: live,
            method: "workspace.select",
            requestId: "select-success"
        ))

        XCTAssertNil(first["error"])
        XCTAssertNil(retry["error"])
        XCTAssertEqual(first["result"] as? Bool, true)
        XCTAssertEqual(retry["result"] as? Bool, true)
        XCTAssertEqual(router.phase4ClaimCallCount, 2)
        XCTAssertEqual(router.synchronousBatchEffectCallCount, 1)
        XCTAssertEqual(router.finalizationCallCount, 1)
        XCTAssertEqual(router.window.selectedWorkspaceID, target)
        XCTAssertEqual(recorder.events.map(\.kind), ["workspace.selected"])
        try assertStatusResult(
            status,
            status: "committed",
            method: "workspace.select",
            requestId: "select-success"
        )
    }

    /// WHY: true post-effect finalization uncertainty must stay commandOutcomeUnknown
    /// with no mutation replay on retry.
    func test_workspaceSelectFinalizationFailureRemainsUnknownWithoutReplay() async throws {
        let router = Phase4ReceiptFakeRouter()
        let target = WorkspaceID()
        seedPhase4Workspace(router: router, id: target)
        router.finalizationPersistenceUnavailable = true
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 2_012)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "workspace.selected" { recorder.append(event) }
        }
        defer { EventBus.shared.unsubscribe(subscription) }

        var params = live.mutationParams(
            requestId: "select-finalize-fault",
            threadId: AgentThreadID(),
            text: "unused"
        )
        params.removeValue(forKey: "thread_id")
        params.removeValue(forKey: "text")
        params["id"] = target.value.uuidString

        let first = try await live.rpc(method: "workspace.select", params: params)
        let retry = try await live.rpc(method: "workspace.select", params: params)
        let status = try await live.rpc(method: "command.receipt.status", params: statusParams(
            live: live,
            method: "workspace.select",
            requestId: "select-finalize-fault"
        ))

        XCTAssertEqual(errorCode(first), commandOutcomeUnknown)
        XCTAssertEqual(errorCode(retry), commandOutcomeUnknown)
        XCTAssertEqual(router.synchronousBatchEffectCallCount, 1)
        XCTAssertEqual(router.finalizationCallCount, 0)
        XCTAssertTrue(recorder.events.isEmpty)
        try assertStatusResult(
            status,
            status: "unknown",
            method: "workspace.select",
            requestId: "select-finalize-fault"
        )
    }

    func test_windowPaneSurfaceBatchHasOneEffectFinalizeExactEventsAndNoRetryReplay() async throws {
        let workspaceID = UUID().uuidString
        let windowID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let paneID = UUID().uuidString
        let otherPaneID = UUID().uuidString
        let splitID = UUID().uuidString
        let cases: [(method: String, params: [String: Any], eventKinds: [String])] = [
            ("window.create", ["title": "window"], ["window.created"]),
            ("window.close", ["id": windowID], ["window.closed"]),
            ("window.focus", ["id": windowID], ["window.focused"]),
            ("pane.resize", ["workspace_id": workspaceID, "split_id": splitID, "ratios": [0.4, 0.6]], ["pane.resized"]),
            ("pane.swap", ["workspace_id": workspaceID, "a": paneID, "b": otherPaneID], ["pane.swapped"]),
            ("surface.create", ["workspace_id": workspaceID, "type": "terminal"], ["surface.created"]),
            ("surface.close", ["workspace_id": workspaceID, "id": surfaceID], ["surface.closed"]),
            ("surface.focus", ["workspace_id": workspaceID, "id": surfaceID], ["surface.focused"]),
            ("surface.move", ["workspace_id": workspaceID, "id": surfaceID, "target_pane_id": paneID], ["surface.moved"]),
            ("surface.rename", ["workspace_id": workspaceID, "id": surfaceID, "title": "renamed"], ["surface.renamed"]),
            ("surface.reorder", ["workspace_id": workspaceID, "id": surfaceID, "target_pane_id": paneID, "position": 1], ["surface.reordered"]),
            ("surface.set_color", ["workspace_id": workspaceID, "id": surfaceID, "color": "blue"], ["surface.updated"]),
            ("surface.split", ["workspace_id": workspaceID, "pane_id": paneID, "direction": "right", "type": "terminal"], ["pane.split"]),
            ("surface.clear_history", ["id": surfaceID], ["surface.updated"]),
            ("surface.send_key", ["id": surfaceID, "key": "enter"], ["surface.updated"]),
            ("surface.send_text", ["id": surfaceID, "text": "hello"], ["surface.updated"]),
        ]

        for (index, testCase) in cases.enumerated() {
            let router = Phase4ReceiptFakeRouter()
            let live = try await Phase4LiveServer.start(router: router, bootEpoch: UInt64(500 + index))
            let recorder = Phase4EventRecorder()
            let expectedKinds = Set(testCase.eventKinds)
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) {
                    recorder.append(event)
                }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(subscription)
                    live.stop()
                }
                var params = live.mutationParams(
                    requestId: "sync-batch-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await live.rpc(method: testCase.method, params: params)
                let retry = try await live.rpc(method: testCase.method, params: params)

                XCTAssertNil(first["error"], testCase.method)
                XCTAssertNil(retry["error"], testCase.method)
                XCTAssertEqual(router.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(router.finalizationCallCount, 1, testCase.method)
                XCTAssertEqual(recorder.events.map(\.kind), testCase.eventKinds, testCase.method)
            }

            let faultRouter = Phase4ReceiptFakeRouter()
            faultRouter.finalizationPersistenceUnavailable = true
            let faultLive = try await Phase4LiveServer.start(
                router: faultRouter,
                bootEpoch: UInt64(600 + index)
            )
            let faultRecorder = Phase4EventRecorder()
            let faultSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) {
                    faultRecorder.append(event)
                }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(faultSubscription)
                    faultLive.stop()
                }
                var params = faultLive.mutationParams(
                    requestId: "sync-batch-fault-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await faultLive.rpc(method: testCase.method, params: params)
                let retry = try await faultLive.rpc(method: testCase.method, params: params)

                XCTAssertEqual(errorCode(first), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(errorCode(retry), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(faultRouter.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(faultRouter.finalizationCallCount, 0, testCase.method)
                XCTAssertTrue(faultRecorder.events.isEmpty, testCase.method)
            }
        }
    }

    func test_filesNotificationSettingsProjectPrivateBatchIsDurableAndNoReplay() async throws {
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let cases: [(method: String, params: [String: Any], eventKinds: [String])] = [
            ("fs.workspace.create_file", ["workspace_id": workspaceID, "path": "new.txt", "content": "x"], ["fs.workspace.changed"]),
            ("fs.workspace.delete", ["workspace_id": workspaceID, "paths": ["old.txt"]], ["fs.workspace.changed"]),
            ("fs.workspace.rename", ["workspace_id": workspaceID, "path": "old.txt", "new_name": "new.txt"], ["fs.workspace.changed"]),
            ("files.edit.open", ["surface_id": surfaceID, "path": "file.txt"], ["files.state.updated"]),
            ("files.edit.apply_patch", ["session_id": "session", "base_draft_revision": 1, "range_utf16": ["location": 0, "length": 0], "replacement": "x"], ["files.state.updated"]),
            ("files.edit.save", ["session_id": "session"], ["files.state.updated"]),
            ("files.edit.discard", ["session_id": "session"], ["files.state.updated"]),
            ("files.edit.close", ["session_id": "session"], ["files.state.updated"]),
            ("files.state.update", ["surface_id": surfaceID, "patch": ["selected_path": "file.txt"]], ["files.state.updated"]),
            ("files.tab.open", ["workspace_id": workspaceID, "path": "file.txt"], ["surface.created"]),
            ("files.tab.split", ["workspace_id": workspaceID, "direction": "right", "path": "file.txt"], ["pane.split"]),
            ("notification.create", ["title": "notice"], ["notification.created"]),
            ("notification.dismiss", ["id": "notification"], ["notification.dismissed"]),
            ("notification.mark_read", ["id": "notification"], ["notification.read"]),
            ("settings.set", ["key": "theme", "value": "dark"], ["settings.updated"]),
            ("project.open_in_editor", ["workspace_id": workspaceID], ["project.opened_in_editor"]),
            ("private.push_token.update", ["push_token": "secret-phase4-token", "push_token_type": "apns"], ["private.push_token.updated"]),
        ]

        for (index, testCase) in cases.enumerated() {
            let expectedKinds = Set(testCase.eventKinds)
            let router = Phase4ReceiptFakeRouter()
            let live = try await Phase4LiveServer.start(router: router, bootEpoch: UInt64(700 + index))
            let recorder = Phase4EventRecorder()
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { recorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(subscription)
                    live.stop()
                }
                var params = live.mutationParams(
                    requestId: "sync-batch-b-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await live.rpc(method: testCase.method, params: params)
                let retry = try await live.rpc(method: testCase.method, params: params)

                XCTAssertNil(first["error"], testCase.method)
                XCTAssertNil(retry["error"], testCase.method)
                XCTAssertEqual(router.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(router.finalizationCallCount, 1, testCase.method)
                XCTAssertEqual(recorder.events.map(\.kind), testCase.eventKinds, testCase.method)
                if testCase.method == "private.push_token.update" {
                    let payload = try JSONEncoder().encode(try XCTUnwrap(recorder.events.first).payload)
                    XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("secret-phase4-token"))
                }
            }

            let faultRouter = Phase4ReceiptFakeRouter()
            faultRouter.finalizationPersistenceUnavailable = true
            let faultLive = try await Phase4LiveServer.start(
                router: faultRouter,
                bootEpoch: UInt64(800 + index)
            )
            let faultRecorder = Phase4EventRecorder()
            let faultSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { faultRecorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(faultSubscription)
                    faultLive.stop()
                }
                var params = faultLive.mutationParams(
                    requestId: "sync-batch-b-fault-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await faultLive.rpc(method: testCase.method, params: params)
                let retry = try await faultLive.rpc(method: testCase.method, params: params)

                XCTAssertEqual(errorCode(first), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(errorCode(retry), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(faultRouter.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(faultRouter.finalizationCallCount, 0, testCase.method)
                XCTAssertTrue(faultRecorder.events.isEmpty, testCase.method)
            }
        }
    }

    func test_gitSSHAndProjectLaunchBatchIsDurableAndNoReplay() async throws {
        let workspaceUUID = UUID()
        let workspaceID = workspaceUUID.uuidString
        let surfaceID = UUID().uuidString
        let hostID = UUID().uuidString
        let cases: [(method: String, params: [String: Any], eventKinds: [String])] = [
            ("git.checkout", ["workspace_id": workspaceID, "branch": "main"], ["git.checkout"]),
            ("git.commit", ["workspace_id": workspaceID, "message": "phase4"], ["git.commit"]),
            ("git.create_branch", ["workspace_id": workspaceID, "name": "phase4"], ["git.branch_created"]),
            ("git.deliver", ["workspace_id": workspaceID], ["git.deliver"]),
            ("git.push", ["workspace_id": workspaceID], ["git.push"]),
            ("ssh.connect", ["workspace_id": workspaceID, "destination": "host.example"], ["surface.created", "ssh.session.updated"]),
            ("ssh.disconnect", ["surface_id": surfaceID], ["ssh.session.updated"]),
            ("ssh.host.upsert", ["workspace_id": workspaceID, "id": hostID, "destination": "host.example", "password": "secret-ssh-password"], ["ssh.host.updated"]),
            ("ssh.host.delete", ["workspace_id": workspaceID, "id": hostID], ["ssh.host.deleted"]),
            ("ssh.transfer.upload", ["surface_id": surfaceID, "local_path": "/tmp/local", "remote_path": "/remote"], ["ssh.transfer.started", "ssh.transfer.finished"]),
            ("ssh.transfer.download", ["surface_id": surfaceID, "remote_path": "/remote", "local_path": "/tmp/local"], ["ssh.transfer.started", "ssh.transfer.finished"]),
            ("project.run_script", ["workspace_id": workspaceID, "name": "test"], ["surface.created", "project.script_started"]),
        ]

        for (index, testCase) in cases.enumerated() {
            let expectedKinds = Set(testCase.eventKinds)
            let router = Phase4ReceiptFakeRouter()
            seedPhase4GitSurface(router: router, workspaceID: WorkspaceID(workspaceUUID))
            let live = try await Phase4LiveServer.start(router: router, bootEpoch: UInt64(1_000 + index))
            let recorder = Phase4EventRecorder()
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { recorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(subscription)
                    live.stop()
                }
                var params = live.mutationParams(
                    requestId: "sync-batch-c-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await live.rpc(method: testCase.method, params: params)
                let retry = try await live.rpc(method: testCase.method, params: params)

                XCTAssertNil(first["error"], testCase.method)
                XCTAssertNil(retry["error"], testCase.method)
                XCTAssertEqual(router.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(router.finalizationCallCount, 1, testCase.method)
                XCTAssertEqual(recorder.events.map(\.kind), testCase.eventKinds, testCase.method)
                if testCase.method == "ssh.host.upsert" {
                    let payload = try JSONEncoder().encode(try XCTUnwrap(recorder.events.first).payload)
                    XCTAssertFalse(String(decoding: payload, as: UTF8.self).contains("secret-ssh-password"))
                }
            }

            let faultRouter = Phase4ReceiptFakeRouter()
            faultRouter.finalizationPersistenceUnavailable = true
            seedPhase4GitSurface(router: faultRouter, workspaceID: WorkspaceID(workspaceUUID))
            let faultLive = try await Phase4LiveServer.start(
                router: faultRouter,
                bootEpoch: UInt64(1_100 + index)
            )
            let faultRecorder = Phase4EventRecorder()
            let faultSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { faultRecorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(faultSubscription)
                    faultLive.stop()
                }
                var params = faultLive.mutationParams(
                    requestId: "sync-batch-c-fault-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await faultLive.rpc(method: testCase.method, params: params)
                let retry = try await faultLive.rpc(method: testCase.method, params: params)

                XCTAssertEqual(errorCode(first), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(errorCode(retry), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(faultRouter.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(faultRouter.finalizationCallCount, 0, testCase.method)
                XCTAssertTrue(faultRecorder.events.isEmpty, testCase.method)
            }
        }
    }

    func test_agentThreadAndBrowserBatchIsDurableAndNoReplay() async throws {
        let workspaceUUID = UUID()
        let workspaceID = workspaceUUID.uuidString
        let threadUUID = UUID()
        let threadID = threadUUID.uuidString
        let otherThreadID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let cases: [(method: String, params: [String: Any], eventKinds: [String])] = [
            ("agent.open", ["workspace_id": workspaceID], ["surface.created"]),
            ("agent.thread.create", ["workspace_id": workspaceID, "title": "thread"], ["agent.thread.created"]),
            ("agent.thread.prepare_pr", ["workspace_id": workspaceID, "url": "https://example.test/pull/1"], ["agent.thread.created", "agent.thread.selected"]),
            ("agent.thread.rollback", ["thread_id": threadID, "turn_id": "turn-1"], ["agent.thread.rolled_back"]),
            ("agent.thread.delete", ["thread_id": threadID], ["agent.thread.deleted"]),
            ("agent.thread.delete_many", ["thread_ids": [threadID, otherThreadID]], ["agent.thread.deleted_many"]),
            ("agent.thread.rename", ["thread_id": threadID, "title": "renamed"], ["agent.thread.renamed"]),
            ("agent.thread.set_pinned", ["thread_id": threadID, "pinned": true], ["agent.thread.updated", "agent.thread.reordered"]),
            ("agent.thread.set_color", ["thread_id": threadID, "color": "blue"], ["agent.thread.updated"]),
            ("agent.thread.reorder", ["thread_id": threadID, "position": 1], ["agent.thread.reordered"]),
            ("agent.thread.configure", ["thread_id": threadID, "model": "gpt-5.5"], ["agent.thread.updated"]),
            ("agent.thread.execution.configure", ["thread_id": threadID, "execution_mode": "local"], ["agent.thread.updated"]),
            ("agent.thread.mark_read", ["thread_id": threadID], ["agent.thread.updated"]),
            ("agent.thread.select", ["thread_id": threadID], ["agent.thread.selected"]),
            ("browser.navigate", ["id": surfaceID, "url": "https://example.test"], ["surface.browser"]),
            ("browser.back", ["id": surfaceID], ["surface.browser"]),
            ("browser.forward", ["id": surfaceID], ["surface.browser"]),
            ("browser.reload", ["id": surfaceID], ["surface.browser"]),
            ("browser.click", ["id": surfaceID, "ref": "button"], ["surface.browser"]),
            ("browser.fill", ["id": surfaceID, "ref": "input", "value": "secret-browser-value"], ["surface.browser"]),
            ("browser.type", ["id": surfaceID, "ref": "input", "value": "secret-browser-value"], ["surface.browser"]),
            ("browser.focus", ["id": surfaceID, "ref": "input"], ["surface.browser"]),
            ("browser.hover", ["id": surfaceID, "ref": "button"], ["surface.browser"]),
            ("browser.check", ["id": surfaceID, "ref": "check"], ["surface.browser"]),
            ("browser.uncheck", ["id": surfaceID, "ref": "check"], ["surface.browser"]),
            ("browser.select", ["id": surfaceID, "ref": "select", "value": "secret-browser-value"], ["surface.browser"]),
            ("browser.eval", ["id": surfaceID, "script": "secret-browser-value"], ["surface.browser"]),
            ("browser.screenshot", ["id": surfaceID, "path": "/tmp/secret-phase4-path.png"], ["browser.screenshot.created"]),
            ("browser.mirror_url.get", ["id": surfaceID], ["browser.mirror_url.registered"]),
        ]

        for (index, testCase) in cases.enumerated() {
            let expectedKinds = Set(testCase.eventKinds)
            let router = Phase4ReceiptFakeRouter()
            seedPhase4AgentThreads(
                router: router,
                workspaceID: WorkspaceID(workspaceUUID),
                threadID: AgentThreadID(threadUUID),
                otherThreadID: AgentThreadID(UUID(uuidString: otherThreadID)!)
            )
            let live = try await Phase4LiveServer.start(router: router, bootEpoch: UInt64(1_200 + index))
            let recorder = Phase4EventRecorder()
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { recorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(subscription)
                    live.stop()
                }
                var params = live.mutationParams(
                    requestId: "sync-batch-d-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await live.rpc(method: testCase.method, params: params)
                let retry = try await live.rpc(method: testCase.method, params: params)

                XCTAssertNil(first["error"], testCase.method)
                XCTAssertNil(retry["error"], testCase.method)
                XCTAssertEqual(router.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(router.finalizationCallCount, 1, testCase.method)
                XCTAssertEqual(recorder.events.map(\.kind), testCase.eventKinds, testCase.method)
                if testCase.method.hasPrefix("browser.") {
                    let payloads = try recorder.events.map { try JSONEncoder().encode($0.payload) }
                    let rendered = payloads.map { String(decoding: $0, as: UTF8.self) }.joined()
                    XCTAssertFalse(rendered.contains("secret-browser-value"), testCase.method)
                    XCTAssertFalse(rendered.contains("/secret/path"), testCase.method)
                    XCTAssertFalse(rendered.contains("/tmp/secret-phase4-path.png"), testCase.method)
                }
            }

            let faultRouter = Phase4ReceiptFakeRouter()
            faultRouter.finalizationPersistenceUnavailable = true
            seedPhase4AgentThreads(
                router: faultRouter,
                workspaceID: WorkspaceID(workspaceUUID),
                threadID: AgentThreadID(threadUUID),
                otherThreadID: AgentThreadID(UUID(uuidString: otherThreadID)!)
            )
            let faultLive = try await Phase4LiveServer.start(
                router: faultRouter,
                bootEpoch: UInt64(1_300 + index)
            )
            let faultRecorder = Phase4EventRecorder()
            let faultSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if expectedKinds.contains(event.kind) { faultRecorder.append(event) }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(faultSubscription)
                    faultLive.stop()
                }
                var params = faultLive.mutationParams(
                    requestId: "sync-batch-d-fault-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await faultLive.rpc(method: testCase.method, params: params)
                let retry = try await faultLive.rpc(method: testCase.method, params: params)

                XCTAssertEqual(errorCode(first), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(errorCode(retry), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(faultRouter.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(faultRouter.finalizationCallCount, 0, testCase.method)
                XCTAssertTrue(faultRecorder.events.isEmpty, testCase.method)
            }
        }
    }

    func test_agentExecutionBatchHasCanonicalEventDurabilityAndNoReplay() async throws {
        let workspaceUUID = UUID()
        let workspaceID = workspaceUUID.uuidString
        let threadUUID = UUID()
        let threadID = threadUUID.uuidString
        let queuedMessageID = UUID().uuidString
        let attachmentData = Data("phase4".utf8).base64EncodedString()
        let cases: [(method: String, params: [String: Any], eventKind: String)] = [
            ("agent.message.send", ["thread_id": threadID, "text": "secret-phase4-message"], "agent.message.accepted"),
            ("agent.message.queue.cancel", ["queued_message_id": queuedMessageID], "agent.message.queue.cancelled"),
            ("agent.message.queue.force_now", ["queued_message_id": queuedMessageID], "agent.message.queue.force_requested"),
            ("agent.message.queue.reorder", ["thread_id": threadID, "queued_message_id": queuedMessageID, "position": 0], "agent.message.queue.updated"),
            ("agent.message.queue.update", ["queued_message_id": queuedMessageID, "text": "secret-phase4-queued"], "agent.message.queue.updated"),
            ("agent.run.continue", ["thread_id": threadID], "agent.run.continue_requested"),
            ("agent.run.stop", ["thread_id": threadID], "agent.run.stop_requested"),
            ("agent.request.respond", ["thread_id": threadID, "request_id": "request-1", "decision": "approve_for_session"], "agent.request.resolved"),
            ("agent.user_input.respond", ["thread_id": threadID, "request_id": "input-1", "text": "secret-phase4-answer"], "agent.user_input.resolved"),
            ("agent.plan.implement", ["thread_id": threadID, "plan_id": "plan-1", "markdown": "secret-phase4-plan"], "agent.plan.implemented"),
            ("agent.plan.save", ["thread_id": threadID, "plan_id": "plan-1", "markdown": "secret-phase4-plan"], "agent.plan.saved"),
            ("agent.plan.notes.save", ["thread_id": threadID, "notes": "secret-phase4-notes"], "agent.plan.notes.updated"),
            ("agent.checkpoint.revert", ["thread_id": threadID, "turn_count": 1], "agent.checkpoint.reverted"),
            ("agent.attachment.upload", ["workspace_id": workspaceID, "filename": "phase4.txt", "data_base64": attachmentData], "agent.attachment.uploaded"),
            ("agent.attachment.import", ["workspace_id": workspaceID, "relative_path": "docs/phase4.txt"], "agent.attachment.uploaded"),
            ("agent.provider.update", ["provider": "codex"], "agent.provider.updated"),
        ]

        for (index, testCase) in cases.enumerated() {
            let router = Phase4ReceiptFakeRouter()
            seedPhase4AgentThreads(
                router: router,
                workspaceID: WorkspaceID(workspaceUUID),
                threadID: AgentThreadID(threadUUID),
                otherThreadID: AgentThreadID()
            )
            let live = try await Phase4LiveServer.start(router: router, bootEpoch: UInt64(1_500 + index))
            let recorder = Phase4EventRecorder()
            let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if event.kind == testCase.eventKind || event.kind == "agent.thread.updated" || event.kind == "agent.message.appended" {
                    recorder.append(event)
                }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(subscription)
                    live.stop()
                }
                var params = live.mutationParams(
                    requestId: "sync-batch-e-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await live.rpc(method: testCase.method, params: params)
                let retry = try await live.rpc(method: testCase.method, params: params)

                XCTAssertNil(first["error"], testCase.method)
                XCTAssertNil(retry["error"], testCase.method)
                XCTAssertEqual(router.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(router.finalizationCallCount, 1, testCase.method)
                XCTAssertEqual(recorder.events.map(\.kind), [testCase.eventKind], testCase.method)
                let rendered = try recorder.events
                    .map { try JSONEncoder().encode($0.payload) }
                    .map { String(decoding: $0, as: UTF8.self) }
                    .joined()
                XCTAssertFalse(rendered.contains("secret-phase4"), testCase.method)
            }

            let faultRouter = Phase4ReceiptFakeRouter()
            faultRouter.finalizationPersistenceUnavailable = true
            seedPhase4AgentThreads(
                router: faultRouter,
                workspaceID: WorkspaceID(workspaceUUID),
                threadID: AgentThreadID(threadUUID),
                otherThreadID: AgentThreadID()
            )
            let faultLive = try await Phase4LiveServer.start(
                router: faultRouter,
                bootEpoch: UInt64(1_600 + index)
            )
            let faultRecorder = Phase4EventRecorder()
            let faultSubscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
                if event.kind == testCase.eventKind || event.kind == "agent.thread.updated" || event.kind == "agent.message.appended" {
                    faultRecorder.append(event)
                }
            }
            do {
                defer {
                    EventBus.shared.unsubscribe(faultSubscription)
                    faultLive.stop()
                }
                var params = faultLive.mutationParams(
                    requestId: "sync-batch-e-fault-\(index)",
                    threadId: AgentThreadID(),
                    text: "unused"
                )
                params.removeValue(forKey: "thread_id")
                params.removeValue(forKey: "text")
                for (key, value) in testCase.params { params[key] = value }

                let first = try await faultLive.rpc(method: testCase.method, params: params)
                let retry = try await faultLive.rpc(method: testCase.method, params: params)

                XCTAssertEqual(errorCode(first), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(errorCode(retry), commandOutcomeUnknown, testCase.method)
                XCTAssertEqual(faultRouter.synchronousBatchEffectCallCount, 1, testCase.method)
                XCTAssertEqual(faultRouter.finalizationCallCount, 0, testCase.method)
                XCTAssertTrue(faultRecorder.events.isEmpty, testCase.method)
            }
        }
    }

    func test_childTaskPublishingAfterSealUsesLegacyLaneWithoutChangingReceiptEvents() async throws {
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "late capture", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        let gate = Phase4LateEventGate()
        router.lateEventGate = gate
        router.lateEventKind = "agent.phase4.late.\(UUID().uuidString)"
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 1_700)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let lateDelivered = expectation(description: "late event delivered through legacy lane")
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            guard event.kind == "agent.message.accepted" || event.kind == router.lateEventKind else { return }
            recorder.append(event)
            if event.kind == router.lateEventKind { lateDelivered.fulfill() }
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        let params = live.mutationParams(requestId: "late-capture", threadId: thread.id, text: "start")

        let first = try await live.rpc(method: "agent.message.send", params: params)
        XCTAssertNil(first["error"])
        XCTAssertEqual(
            router.finalizedEventKinds["agent.message.send:late-capture"],
            ["agent.message.accepted"],
            "only the explicit immediate canonical event belongs to the receipt T2"
        )

        await gate.release()
        await fulfillment(of: [lateDelivered], timeout: 1)
        let (retrySocket, retryConnectionID) = try await live.openConnection(token: Phase4LiveServer.ownerToken)
        defer { retrySocket.cancel(with: .normalClosure, reason: nil) }
        var retryParams = params
        retryParams["connection_id"] = retryConnectionID
        let retry = try await live.rpc(method: "agent.message.send", params: retryParams)

        XCTAssertNil(retry["error"])
        XCTAssertEqual(router.sendAgentMessageCallCount, 1)
        XCTAssertEqual(router.finalizationCallCount, 1)
        XCTAssertEqual(recorder.events.map(\.kind), ["agent.message.accepted", router.lateEventKind])
        XCTAssertEqual(router.finalizedEventKinds["agent.message.send:late-capture"], ["agent.message.accepted"])
    }

    func test_concurrentDifferentRequestsKeepReceiptSuppressionAndEventSinksInvocationLocal() async throws {
        let router = Phase4ReceiptFakeRouter()
        let gate = Phase4FirstEffectGate()
        router.firstEffectGate = gate
        let thread = AgentThread(
            workspaceId: nil,
            title: "concurrent rollback",
            provider: .codex,
            model: "gpt-5.5"
        )
        router.threadStore = [thread]
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 1_400)
        defer { live.stop() }
        let recorder = Phase4EventRecorder()
        let subscription = EventBus.shared.subscribe(since: EventBus.shared.currentSeq) { event in
            if event.kind == "agent.thread.rolled_back" { recorder.append(event) }
        }
        defer { EventBus.shared.unsubscribe(subscription) }
        var firstParams = live.mutationParams(
            requestId: "concurrent-a",
            threadId: thread.id,
            text: "unused"
        )
        firstParams.removeValue(forKey: "text")
        firstParams["turn_id"] = "turn-a"
        var secondParams = firstParams
        secondParams["client_request_id"] = "concurrent-b"
        secondParams["turn_id"] = "turn-b"

        let firstTask = Task {
            try await live.rpc(method: "agent.thread.rollback", params: firstParams)
        }
        await gate.waitForFirstEffect()
        let second = try await live.rpc(method: "agent.thread.rollback", params: secondParams)
        await gate.releaseFirstEffect()
        let first = try await firstTask.value

        XCTAssertNil(first["error"])
        XCTAssertNil(second["error"])
        XCTAssertEqual(router.synchronousBatchEffectCallCount, 2)
        XCTAssertEqual(router.finalizationCallCount, 2)
        XCTAssertEqual(router.receiptRecordCallCount, 0)
        XCTAssertEqual(recorder.events.count, 2)
        let turnIDs = Set(recorder.events.compactMap { event in
            event.payload.objectValue?["turn_id"]?.stringValue
        })
        XCTAssertEqual(turnIDs, ["turn-a", "turn-b"])
    }

    private func seedPhase4Workspace(router: Phase4ReceiptFakeRouter, id: WorkspaceID) {
        let pane = PaneNode(surfaces: [])
        let workspace = Workspace(
            id: id,
            name: "phase4-workspace",
            cwd: FileManager.default.currentDirectoryPath,
            layout: .pane(pane),
            focusedPaneID: pane.id
        )
        if !router.workspaces.contains(where: { $0.id == id }) {
            router.workspaces.append(workspace)
        }
        if !router.window.workspaces.contains(id) {
            router.window.workspaces.append(id)
        }
    }

    private func seedPhase4GitSurface(
        router: Phase4ReceiptFakeRouter,
        workspaceID: WorkspaceID
    ) {
        let gitSurface = SurfaceDescriptor(
            type: .rightSidebarTool,
            title: "Git",
            metadata: ["tool": "diff"]
        )
        router.workspaces = [Workspace(
            id: workspaceID,
            name: "phase4",
            cwd: FileManager.default.currentDirectoryPath,
            layout: .pane(PaneNode(surfaces: [gitSurface]))
        )]
    }

    private func seedPhase4AgentThreads(
        router: Phase4ReceiptFakeRouter,
        workspaceID: WorkspaceID,
        threadID: AgentThreadID,
        otherThreadID: AgentThreadID
    ) {
        router.threadStore = [
            AgentThread(
                id: threadID,
                workspaceId: workspaceID,
                title: "phase4",
                provider: .codex,
                model: "gpt-5.5"
            ),
            AgentThread(
                id: otherThreadID,
                workspaceId: workspaceID,
                title: "phase4 other",
                provider: .codex,
                model: "gpt-5.5"
            ),
        ]
    }

    func test_unknownOutcomeIsPermanentAcrossSequentialAndRestartRetries() async throws {
        let router = Phase4ReceiptFakeRouter()
        let metrics = CommandReceiptMetrics()
        let thread = AgentThread(workspaceId: nil, title: "phase4-unknown", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.effectThenOutcomeUnknown = true
        router.eventClientRequestId = "unknown-outcome"

        let firstServer = try await Phase4LiveServer.start(
            router: router,
            bootEpoch: 460,
            commandReceiptMetrics: metrics
        )
        let firstParams = firstServer.mutationParams(
            requestId: "unknown-outcome",
            threadId: thread.id,
            text: "effect before lost result"
        )
        let first = try await firstServer.rpc(method: "agent.message.send", params: firstParams)
        let sequential = try await firstServer.rpc(method: "agent.message.send", params: firstParams)
        let requestMismatch = try await firstServer.rpc(
            method: "agent.message.send",
            params: firstServer.mutationParams(
                requestId: "unknown-outcome",
                threadId: thread.id,
                text: "different payload"
            )
        )
        let (otherSocket, otherConnectionId) = try await firstServer.openConnection(
            token: Phase4LiveServer.otherOwnerToken
        )
        defer { otherSocket.cancel(with: .normalClosure, reason: nil) }
        var otherOwnerParams = firstParams
        otherOwnerParams["connection_id"] = otherConnectionId
        let ownerMismatch = try await firstServer.rpc(
            method: "agent.message.send",
            params: otherOwnerParams,
            token: Phase4LiveServer.otherOwnerToken
        )
        let metricSnapshot = metrics.snapshot()
        firstServer.stop()

        let restarted = try await Phase4LiveServer.start(router: router, bootEpoch: 461)
        defer { restarted.stop() }
        let afterRestart = try await restarted.rpc(
            method: "agent.message.send",
            params: restarted.mutationParams(
                requestId: "unknown-outcome",
                threadId: thread.id,
                text: "effect before lost result"
            )
        )

        XCTAssertEqual(errorCode(first), commandOutcomeUnknown)
        XCTAssertEqual(errorCode(sequential), commandOutcomeUnknown)
        XCTAssertEqual(errorCode(requestMismatch), idempotencyRequestMismatch)
        XCTAssertEqual(errorCode(ownerMismatch), idempotencyOwnerMismatch)
        XCTAssertEqual(errorCode(afterRestart), commandOutcomeUnknown)
        XCTAssertEqual(metricSnapshot.claimsTotal, 4)
        XCTAssertEqual(metricSnapshot.duplicatesUnknownTotal, 1)
        XCTAssertEqual(metricSnapshot.rejectedClaimsTotal, 2)
        XCTAssertEqual(router.sendAgentMessageCallCount, 1,
                       "unknown tombstones must never permit lease takeover or re-execution")
    }

    func test_legacyReceiptCannotBeReplayedWithoutOwnerAndPayloadProof() async throws {
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "phase4-legacy", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.commandReceipts["agent.message.send:legacy-receipt"] = .object([
            "run_id": .string(UUID().uuidString),
            "status": .string("started"),
        ])
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 470)
        defer { live.stop() }

        let response = try await live.rpc(method: "agent.message.send", params: live.mutationParams(
            requestId: "legacy-receipt",
            threadId: thread.id,
            text: "cannot verify legacy owner or hash"
        ))

        XCTAssertEqual(errorCode(response), legacyReceiptUnverifiable)
        XCTAssertEqual(router.sendAgentMessageCallCount, 0)
    }

    func test_commandReceiptStatusReturnsOnlySafeCanonicalFields() async throws {
        let router = Phase4ReceiptFakeRouter()
        let thread = AgentThread(workspaceId: nil, title: "phase4-status", provider: .codex, model: "gpt-5.5")
        router.threadStore = [thread]
        router.eventClientRequestId = "status-committed"
        let live = try await Phase4LiveServer.start(router: router, bootEpoch: 480)
        defer { live.stop() }

        _ = try await live.rpc(method: "agent.message.send", params: live.mutationParams(
            requestId: "status-committed",
            threadId: thread.id,
            text: "status"
        ))
        let committed = try await live.rpc(method: "command.receipt.status", params: statusParams(
            live: live,
            method: "agent.message.send",
            requestId: "status-committed"
        ))
        let absent = try await live.rpc(method: "command.receipt.status", params: statusParams(
            live: live,
            method: "agent.message.send",
            requestId: "status-absent"
        ))

        try assertStatusResult(committed, status: "committed", requestId: "status-committed")
        try assertStatusResult(absent, status: "absent", requestId: "status-absent")
    }

    private func canonicalMutationMethods() throws -> Set<String> {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "host-mutation-event-manifest",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        if let mutations = object["mutations"] as? [[String: Any]] {
            return Set(mutations.compactMap { $0["method"] as? String })
        }
        let families = try XCTUnwrap(object["families"] as? [[String: Any]])
        return Set(families.flatMap { $0["methods"] as? [String] ?? [] })
    }

    private func dispatcherTopLevelMethods() throws -> Set<String> {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repositoryRoot
            .appendingPathComponent("Sources/SocketServer/Dispatcher.swift"))
        let prefix = "            case "
        return Set(source.split(separator: "\n").flatMap { rawLine -> [String] in
            let line = String(rawLine)
            guard line.hasPrefix(prefix), line.hasSuffix(":") else { return [] }
            return line.dropFirst(prefix.count).dropLast().split(separator: ",").compactMap { rawCase in
                let value = rawCase.trimmingCharacters(in: .whitespaces)
                guard value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
                return String(value.dropFirst().dropLast())
            }
        })
    }

    private func phase4WireParams(requestId: String) -> [String: JSONValue] {
        [
            "client_request_id": .string(requestId),
            "connection_id": .string("phase4-connection"),
            "expected_host_id": .string(Phase4LiveServer.hostId),
            "expected_boot_epoch": .number(1),
        ]
    }

    private func statusParams(
        live: Phase4LiveServer,
        method: String,
        requestId: String
    ) -> [String: Any] {
        [
            "method": method,
            "client_request_id": requestId,
            "connection_id": live.connectionId,
            "expected_host_id": Phase4LiveServer.hostId,
            "expected_boot_epoch": live.bootEpoch,
        ]
    }

    private func removing(_ key: String, from object: [String: Any]) -> [String: Any] {
        var copy = object
        copy.removeValue(forKey: key)
        return copy
    }

    private func replacing(_ key: String, with value: Any, in object: [String: Any]) -> [String: Any] {
        var copy = object
        copy[key] = value
        return copy
    }

    private func errorCode(_ object: [String: Any]) -> Int? {
        (object["error"] as? [String: Any])?["code"] as? Int
    }

    private func canonicalResult(_ object: [String: Any]) -> Data? {
        guard let result = object["result"] else { return nil }
        return try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private func assertStatusResult(
        _ response: [String: Any],
        status: String,
        requestId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try assertStatusResult(
            response,
            status: status,
            method: "agent.message.send",
            requestId: requestId,
            file: file,
            line: line
        )
    }

    private func assertStatusResult(
        _ response: [String: Any],
        status: String,
        method: String,
        requestId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try XCTUnwrap(response["result"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(Set(result.keys), [
            "status", "method", "clientRequestId", "retryable", "requiresSnapshot",
        ], file: file, line: line)
        XCTAssertEqual(result["status"] as? String, status, file: file, line: line)
        XCTAssertEqual(result["method"] as? String, method, file: file, line: line)
        XCTAssertEqual(result["clientRequestId"] as? String, requestId, file: file, line: line)
        XCTAssertNotNil(result["retryable"] as? Bool, file: file, line: line)
        XCTAssertNotNil(result["requiresSnapshot"] as? Bool, file: file, line: line)
    }

    private func statusResultStatus(_ response: [String: Any]) -> String? {
        (response["result"] as? [String: Any])?["status"] as? String
    }
}
