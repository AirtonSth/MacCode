import Foundation

public enum RemoteCodeEventKind: String, Codable, CaseIterable, Sendable {
    case agentAccountUsage = "agent.account.usage"
    case agentAccountUsageRefresh = "agent.account.usage.refresh"
    case agentAttachmentUploaded = "agent.attachment.uploaded"
    case agentCheckpointReverted = "agent.checkpoint.reverted"
    case agentContextCompaction = "agent.context.compaction"
    case agentItemCompleted = "agent.item.completed"
    case agentItemDelta = "agent.item.delta"
    case agentItemProgress = "agent.item.progress"
    case agentItemStarted = "agent.item.started"
    case agentMessageQueueFailed = "agent.message.queue.failed"
    case agentPlanActiveUpdated = "agent.plan.active_updated"
    case agentPlanImplemented = "agent.plan.implemented"
    case agentPlanProposed = "agent.plan.proposed"
    case agentProviderUpdated = "agent.provider.updated"
    case agentProviderRuntimeEvent = "agent.provider_runtime.event"
    case agentRequestOpened = "agent.request.opened"
    case agentRequestResolved = "agent.request.resolved"
    case agentRunError = "agent.run.error"
    case agentRunFinished = "agent.run.finished"
    case agentRunStarted = "agent.run.started"
    case agentSR1Translation = "agent.sr1.translation"
    case agentThreadCreated = "agent.thread.created"
    case agentThreadDeleted = "agent.thread.deleted"
    case agentThreadDeletedMany = "agent.thread.deleted_many"
    case agentThreadRead = "agent.thread.read"
    case agentThreadRenamed = "agent.thread.renamed"
    case agentThreadReordered = "agent.thread.reordered"
    case agentThreadRolledBack = "agent.thread.rolled_back"
    case agentThreadSelected = "agent.thread.selected"
    case agentThreadTokenUsage = "agent.thread.token_usage"
    case agentThreadUpdated = "agent.thread.updated"
    case agentTurnCompleted = "agent.turn.completed"
    case agentTurnStarted = "agent.turn.started"
    case agentUserInputRequested = "agent.user_input.requested"
    case agentUserInputResolved = "agent.user_input.resolved"
    case agentWireTranslation = "agent.wire.translation"
    case botCreated = "bot.created"
    case botGuestUpdated = "bot.guest.updated"
    case botsAttentionChanged = "bots.attention.changed"
    case browserMirrorURLRegistered = "browser.mirror_url.registered"
    case browserScreenshotCreated = "browser.screenshot.created"
    case diagnosticHTTPClOExecFailed = "diagnostic.http_cloexec_failed"
    case diagnosticHTTPConnectionLimit = "diagnostic.http_connection_limit"
    case diagnosticUnixClientLimit = "diagnostic.unix_client_limit"
    case diagnosticUnixRequestLimit = "diagnostic.unix_request_limit"
    case diagnosticUnixRequestTimeout = "diagnostic.unix_request_timeout"
    case diagnosticUnixSlowClient = "diagnostic.unix_slow_client"
    case diagnosticWSOutboundPressure = "diagnostic.ws_outbound_pressure"
    case diagnosticWSSlowClient = "diagnostic.ws_slow_client"
    case filesEditClosed = "files.edit.closed"
    case filesEditConflict = "files.edit.conflict"
    case filesEditDiscarded = "files.edit.discarded"
    case filesEditOpened = "files.edit.opened"
    case filesEditPatchApplied = "files.edit.patch_applied"
    case filesEditSaved = "files.edit.saved"
    case filesStateUpdated = "files.state.updated"
    case fsWorkspaceChanged = "fs.workspace.changed"
    case gitBranchCreated = "git.branch_created"
    case gitCheckout = "git.checkout"
    case gitCommit = "git.commit"
    case gitDeliver = "git.deliver"
    case gitPush = "git.push"
    case graphifyThreadRoots = "graphify.thread.roots"
    case notificationCreated = "notification.created"
    case notificationDismissed = "notification.dismissed"
    case notificationRead = "notification.read"
    case paneResized = "pane.resized"
    case paneSplit = "pane.split"
    case paneSwapped = "pane.swapped"
    case privatePushTokenUpdated = "private.push_token.updated"
    case projectOpenedInEditor = "project.opened_in_editor"
    case projectScriptFinished = "project.script.finished"
    case projectScriptStarted = "project.script_started"
    case serverListener = "server.listener"
    case serverListenerPublication = "server.listener.publication"
    case settingsUpdated = "settings.updated"
    case sshHostDeleted = "ssh.host.deleted"
    case sshHostUpdated = "ssh.host.updated"
    case sshSessionUpdated = "ssh.session.updated"
    case sshTransferFinished = "ssh.transfer.finished"
    case sshTransferStarted = "ssh.transfer.started"
    case surfaceBrowser = "surface.browser"
    case surfaceClosed = "surface.closed"
    case surfaceCreated = "surface.created"
    case surfaceFocused = "surface.focused"
    case surfaceHealth = "surface.health"
    case surfaceMoved = "surface.moved"
    case surfaceOutput = "surface.output"
    case surfaceOutputSummary = "surface.output.summary"
    case surfaceRenamed = "surface.renamed"
    case surfaceReordered = "surface.reordered"
    case surfaceUpdated = "surface.updated"
    case windowClosed = "window.closed"
    case windowCreated = "window.created"
    case windowFocused = "window.focused"
    case workspaceClosed = "workspace.closed"
    case workspaceCreated = "workspace.created"
    case workspaceRenamed = "workspace.renamed"
    case workspaceReordered = "workspace.reordered"
    case workspaceSelected = "workspace.selected"
    case workspaceUpdated = "workspace.updated"
}

public enum RemoteCodeEvent: Equatable, Sendable {
    case known(kind: RemoteCodeEventKind, payload: RemoteCodeJSONValue)
    case unknown(kind: String, payload: RemoteCodeJSONValue)
}

public struct RemoteCodeEventEnvelope: Codable, Equatable, Sendable {
    public let seq: Int
    public let rawKind: String
    public let payload: RemoteCodeJSONValue
    public let ts: Double

    public var kind: RemoteCodeEventKind? { RemoteCodeEventKind(rawValue: rawKind) }
    public var isUnknown: Bool { kind == nil }
    public var event: RemoteCodeEvent {
        if let kind { return .known(kind: kind, payload: payload) }
        return .unknown(kind: rawKind, payload: payload)
    }

    public init(seq: Int, kind: RemoteCodeEventKind, payload: RemoteCodeJSONValue, ts: Double) {
        self.seq = seq
        self.rawKind = kind.rawValue
        self.payload = payload
        self.ts = ts
    }

    private enum CodingKeys: String, CodingKey { case seq, kind, payload, ts }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        rawKind = try container.decode(String.self, forKey: .kind)
        payload = try container.decode(RemoteCodeJSONValue.self, forKey: .payload)
        ts = try container.decode(Double.self, forKey: .ts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(rawKind, forKey: .kind)
        try container.encode(payload, forKey: .payload)
        try container.encode(ts, forKey: .ts)
    }
}
