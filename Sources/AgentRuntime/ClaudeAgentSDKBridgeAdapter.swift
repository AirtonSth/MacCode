import Foundation
import CoreModel

struct ClaudeSDKSessionRecord: Sendable, Equatable {
    let sessionId: String
    let customTitle: String?
}

protocol ClaudeSDKSessionMutating: Sendable {
    func listSessions() async throws -> [ClaudeSDKSessionRecord]
    func forkSession(sourceSessionId: String, title: String) async throws -> String
    func deleteSession(sessionId: String) async throws
}

enum ClaudeForkReconciliationError: Error, Equatable, CustomStringConvertible {
    case markerConflictCleaned(marker: String, childIds: [String])
    case invalidForkResult(childId: String)
    case cleanupFailed(marker: String, details: String)

    var description: String {
        switch self {
        case .markerConflictCleaned(let marker, let childIds):
            return "Claude fork marker conflict was cleaned for \(marker): \(childIds.joined(separator: ", "))"
        case .invalidForkResult(let childId):
            return "Claude native fork returned an invalid child session: \(childId)"
        case .cleanupFailed(let marker, let details):
            return "Claude fork cleanup failed for \(marker): \(details)"
        }
    }
}

public final class ClaudeAgentSDKBridgeAdapter: AgentProviderAdapter, @unchecked Sendable {
    static let defaultSDKPackageSpec = "@anthropic-ai/claude-agent-sdk@0.3.157"
    static let bridgeProtocolVersion = 3

    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        let parser = ClaudeParser()
        let lineBuffer = LineBuffer()
        // Serializes the stdout readabilityHandler against finishTerminated's
        // EOF drain: nil-ing a readabilityHandler does not wait for a callback
        // already running, and LineBuffer is not thread-safe. Taken BEFORE the
        // fd read so byte order is preserved across the two readers.
        let stdoutReadLock = NSLock()
        let writeQueue = DispatchQueue(label: "remotecode.claude-sdk.write")
        var events: [AssistantEvent] = []
        var status: AgentRunStatus = .running
        var providerThreadId: String?
        var model: String
        var permissionMode: AgentPermissionMode
        var interactionMode: AgentInteractionMode
        let reasoningEffort: AgentReasoningEffort?
        var activeTurnId: String?
        var completedTurnIds: [String] = []
        var inFlightRunId: AgentRunID?
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var sawError = false
        var pendingRequestIds = Set<String>()
        var pendingUserInputIds = Set<String>()
        var bridgeUserInputIds = Set<String>()
        var bridgeUserInputSchemas: [String: [String: Any]] = [:]
        var cancellationRequested = false
        let claudeExecutablePath: String?

        init(threadId: AgentThreadID,
             process: Process,
             stdinPipe: Pipe,
             stdoutPipe: Pipe,
             stderrPipe: Pipe,
             model: String,
             permissionMode: AgentPermissionMode,
             interactionMode: AgentInteractionMode,
             reasoningEffort: AgentReasoningEffort?,
             providerThreadId: String?,
             claudeExecutablePath: String?) {
            self.threadId = threadId
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.model = model
            self.permissionMode = permissionMode
            self.interactionMode = interactionMode
            self.reasoningEffort = reasoningEffort
            self.providerThreadId = providerThreadId
            self.claudeExecutablePath = claudeExecutablePath
        }
    }

    public let provider: AgentProvider = .claude
    private let nodeBinary: String
    private let bridgeScriptPath: String
    private let binaryNameOverride: String?
    private let maxReadableEvents: Int
    private let interruptGracePeriod: TimeInterval
    private let sessionMutator: ClaudeSDKSessionMutating?
    private let lock = NSLock()
    private let cancellationQueue = DispatchQueue(
        label: "io.remotecode.agent.claude-sdk-cancellation",
        qos: .userInitiated
    )
    private let bridgeCloseGracePeriod: TimeInterval = 0.25
    private var sessions: [AgentThreadID: Session] = [:]
    private var recoveredEvents: [AgentThreadID: [AssistantEvent]] = [:]
    private var rollbackResumeSessionAt: [AgentThreadID: String] = [:]
    private var rollbackProviderThreadIds: [AgentThreadID: String] = [:]

    public convenience init(
        nodeBinary: String = "node",
        bridgeScriptPath: String? = nil,
        binaryNameOverride: String? = nil,
        maxReadableEvents: Int = 5_000,
        interruptGracePeriod: TimeInterval = 2
    ) {
        self.init(
            nodeBinary: nodeBinary,
            bridgeScriptPath: bridgeScriptPath,
            binaryNameOverride: binaryNameOverride,
            maxReadableEvents: maxReadableEvents,
            interruptGracePeriod: interruptGracePeriod,
            sessionMutator: nil
        )
    }

    init(
        nodeBinary: String = "node",
        bridgeScriptPath: String? = nil,
        binaryNameOverride: String? = nil,
        maxReadableEvents: Int = 5_000,
        interruptGracePeriod: TimeInterval = 2,
        sessionMutator: ClaudeSDKSessionMutating?
    ) {
        self.nodeBinary = nodeBinary
        self.bridgeScriptPath = bridgeScriptPath
            ?? ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_BRIDGE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ClaudeAgentSDKBridge.mjs").path
        self.binaryNameOverride = binaryNameOverride
        self.maxReadableEvents = max(1, maxReadableEvents)
        self.interruptGracePeriod = max(0, interruptGracePeriod)
        self.sessionMutator = sessionMutator
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await ClaudeRunner().listModels()
    }

    public var forkSafety: AgentProviderForkSafety {
        guard sessionMutator != nil || Self.installedForkProtocolSupported(bridgeScriptPath: bridgeScriptPath) else {
            return .unsupported
        }
        return .keyedIdempotent(compensationSupported: true)
    }

    public func forkSafety(threadId: AgentThreadID) -> AgentProviderForkSafety {
        forkSafety
    }

    public func forkThread(threadId: AgentThreadID) async throws -> String {
        throw AgentProviderAdapterError.unsupported(
            "unkeyed Claude fork is unsafe; use the durable AgentProviderForkRequest path"
        )
    }

    public func forkThread(_ request: AgentProviderForkRequest) async throws -> String {
        guard forkSafety(threadId: request.sourceThreadId).supportsDurableFork else {
            throw AgentProviderAdapterError.unsupported("Claude SDK fork reconciliation contract is unavailable")
        }
        let (sourceSessionId, hasActiveTurn) = forkSourceSnapshot(threadId: request.sourceThreadId)
        guard let sourceSessionId, !sourceSessionId.isEmpty else {
            throw AgentProviderAdapterError.sessionNotFound(request.sourceThreadId)
        }
        if let expectedSourceId = request.sourceProviderThreadId,
           !expectedSourceId.isEmpty,
           expectedSourceId != sourceSessionId {
            throw AgentProviderAdapterError.unsupported("Claude SDK recovered the wrong parent session for fork")
        }
        guard !hasActiveTurn else {
            throw AgentProviderAdapterError.unsupported("Claude SDK cannot fork while the parent turn is active")
        }

        let marker = Self.forkMarker(for: request)
        let existing = try await forkMarkerMatches(marker)
        if !existing.isEmpty {
            if existing.count == 1, let child = existing.first, child.sessionId != sourceSessionId {
                return child.sessionId
            }
            try await cleanForkMarkerConflict(existing, marker: marker, protectedSessionId: sourceSessionId)
            throw ClaudeForkReconciliationError.markerConflictCleaned(
                marker: marker,
                childIds: existing.map(\.sessionId).sorted()
            )
        }

        let childId = try await nativeForkSession(sourceSessionId: sourceSessionId, title: marker)
        guard !childId.isEmpty, childId != sourceSessionId else {
            throw ClaudeForkReconciliationError.invalidForkResult(childId: childId)
        }
        let reconciled = try await forkMarkerMatches(marker)
        guard reconciled.count == 1, reconciled.first?.sessionId == childId else {
            var cleanupTargets = reconciled
            if !cleanupTargets.contains(where: { $0.sessionId == childId }) {
                cleanupTargets.append(ClaudeSDKSessionRecord(sessionId: childId, customTitle: marker))
            }
            try await cleanForkMarkerConflict(cleanupTargets, marker: marker, protectedSessionId: sourceSessionId)
            throw ClaudeForkReconciliationError.invalidForkResult(childId: childId)
        }
        return childId
    }

    public func compensateFork(
        _ request: AgentProviderForkRequest,
        providerChildThreadId: String
    ) async throws {
        guard forkSafety(threadId: request.sourceThreadId).supportsCompensation else {
            throw AgentProviderAdapterError.unsupported("Claude SDK fork compensation contract is unavailable")
        }
        let sessions = try await nativeListSessions()
        let marker = Self.forkMarker(for: request)
        var targets = sessions.filter {
            $0.customTitle == marker && $0.sessionId != request.sourceProviderThreadId
        }
        if targets.isEmpty,
           let recorded = sessions.first(where: { $0.sessionId == providerChildThreadId }) {
            targets = [recorded]
        }
        for target in targets {
            do {
                try await nativeDeleteSession(sessionId: target.sessionId)
            } catch {
                throw ClaudeForkReconciliationError.cleanupFailed(
                    marker: marker,
                    details: "session \(target.sessionId) could not be deleted: \(error)"
                )
            }
        }
    }

    private static func forkMarker(for request: AgentProviderForkRequest) -> String {
        "RemoteCode fork \(request.idempotencyKey)"
    }

    private func forkSourceSnapshot(threadId: AgentThreadID) -> (sessionId: String?, hasActiveTurn: Bool) {
        lock.lock(); defer { lock.unlock() }
        let session = sessions[threadId]
        return (session?.providerThreadId, session?.inFlightRunId != nil)
    }

    public static func installedForkProtocolSupported(bridgeScriptPath: String? = nil) -> Bool {
        let configuredBridge = bridgeScriptPath
            ?? ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_BRIDGE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ClaudeAgentSDKBridge.mjs").path
        guard bridgeSupportsNativeSessionMutation(at: configuredBridge) else { return false }
        let bridgeURL = URL(fileURLWithPath: configuredBridge)
        let localSDK = bridgeURL.deletingLastPathComponent()
            .appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        if FileManager.default.fileExists(atPath: localSDK.appendingPathComponent("package.json").path) {
            return installedSDKForkContract(at: localSDK)
        }

        let cacheRoot: URL
        if let override = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_CACHE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            cacheRoot = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            cacheRoot = root
                .appendingPathComponent("RemoteCode", isDirectory: true)
                .appendingPathComponent("AgentRuntime", isDirectory: true)
                .appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true)
        }
        return installedSDKForkContract(
            at: cacheRoot.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk", isDirectory: true)
        )
    }

    private static func bridgeSupportsNativeSessionMutation(at path: String) -> Bool {
        guard pinnedNPMVersion(in: sdkPackageSpec()) == "0.3.157",
              let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return source.contains("const BRIDGE_PROTOCOL_VERSION = 3")
            && source.contains("claudeSDK.forkSession")
            && source.contains("claudeSDK.listSessions")
            && source.contains("claudeSDK.deleteSession")
    }

    private static func installedSDKForkContract(at sdkDirectory: URL) -> Bool {
        guard installedSDKPackage(
            at: sdkDirectory.appendingPathComponent("package.json"),
            matches: sdkPackageSpec()
        ), let declarations = try? String(
            contentsOf: sdkDirectory.appendingPathComponent("sdk.d.ts"),
            encoding: .utf8
        ) else {
            return false
        }
        return declarations.contains("function forkSession")
            && declarations.contains("function listSessions")
            && declarations.contains("function deleteSession")
    }

    private func forkMarkerMatches(_ marker: String) async throws -> [ClaudeSDKSessionRecord] {
        try await nativeListSessions().filter { $0.customTitle == marker }
    }

    private func cleanForkMarkerConflict(
        _ sessions: [ClaudeSDKSessionRecord],
        marker: String,
        protectedSessionId: String
    ) async throws {
        for session in sessions where session.sessionId != protectedSessionId {
            do {
                try await nativeDeleteSession(sessionId: session.sessionId)
            } catch {
                throw ClaudeForkReconciliationError.cleanupFailed(
                    marker: marker,
                    details: "session \(session.sessionId) could not be deleted: \(error)"
                )
            }
        }
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try Self.validateAttachments(request.attachments)
        let session = try await sessionForAsync(request, provisioningCallback: onEvent)
        lock.lock()
        if session.inFlightRunId != nil {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK bridge already has an in-flight turn")
        }
        session.onEvent = onEvent
        session.inFlightRunId = request.runId
        session.sawError = false
        session.status = .running
        session.cancellationRequested = false
        lock.unlock()

        onEvent(.status(.running))
        do {
            try write([
                "type": "rc_turn",
                "prompt": request.providerPrompt,
                "attachments": Self.attachmentPayload(request.attachments),
                "session_id": session.providerThreadId ?? request.threadId.value.uuidString
            ], to: session)
        } catch {
            lock.lock()
            if session.inFlightRunId == request.runId {
                session.inFlightRunId = nil
                session.onEvent = nil
                session.status = .failed
            }
            lock.unlock()
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        return AgentRunHandle(runId: request.runId, process: session.process) { [weak self] in
            try? self?.requestCancellation(threadId: request.threadId)
        }
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        try requestCancellation(threadId: threadId)
    }

    private func requestCancellation(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions[threadId]
        session?.cancellationRequested = true
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        do {
            try write(["type": "rc_interrupt"], to: session)
        } catch {
            try? stopSession(threadId: threadId)
            throw error
        }
        cancellationQueue.asyncAfter(deadline: .now() + interruptGracePeriod) { [weak self, weak session] in
            guard let self, let session else { return }
            self.lock.lock()
            let stillRunning = self.sessions[threadId] === session && session.inFlightRunId != nil
            self.lock.unlock()
            if stillRunning { try? self.stopSession(threadId: threadId) }
        }
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingRequestIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK request not found: \(requestId)")
        }
        lock.unlock()
        var payload: [String: Any] = [
            "type": "permission_response",
            "request_id": requestId,
            "decision": Self.permissionDecision(for: response)
        ]
        if case .decline(let reason) = response, let reason, !reason.isEmpty {
            payload["message"] = reason
        }
        do {
            try write(payload, to: session)
        } catch {
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        lock.lock(); session.pendingRequestIds.remove(requestId); lock.unlock()
        let resolved = AssistantEvent.requestResolved(requestId: requestId, state: Self.requestState(for: response))
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        try respondToUserInput(threadId: threadId, requestId: requestId, verbatimText: text, outboundText: text)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, verbatimText: String, outboundText: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingUserInputIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK user input request not found: \(requestId)")
        }
        let usesBridgeCallback = session.bridgeUserInputIds.contains(requestId)
        let requestedSchema = session.bridgeUserInputSchemas[requestId]
        lock.unlock()
        let bridgeContent = usesBridgeCallback
            ? try Self.elicitationContent(text: verbatimText, requestedSchema: requestedSchema)
            : nil
        do {
            if let bridgeContent {
                try write([
                    "type": "user_input_response",
                    "request_id": requestId,
                    "text": verbatimText,
                    "content": bridgeContent
                ], to: session)
            } else {
                try write(["type": "rc_turn", "prompt": outboundText], to: session)
            }
        } catch {
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        lock.lock()
        session.pendingUserInputIds.remove(requestId)
        session.bridgeUserInputIds.remove(requestId)
        session.bridgeUserInputSchemas.removeValue(forKey: requestId)
        lock.unlock()
        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: verbatimText)
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingUserInputIds.contains(requestId) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK user input request not found: \(requestId)")
        }
        lock.unlock()

        // Question cancellation is request-scoped. rc_interrupt is reserved for
        // cancelling the whole active turn and draining every pending callback.
        do {
            try write(["type": "user_input_cancel", "request_id": requestId], to: session)
        } catch {
            invalidateSessionAfterControlWriteFailure(session)
            throw error
        }
        lock.lock()
        session.pendingUserInputIds.remove(requestId)
        session.bridgeUserInputIds.remove(requestId)
        session.bridgeUserInputSchemas.removeValue(forKey: requestId)
        lock.unlock()
        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: nil)
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions.removeValue(forKey: threadId)
        session?.cancellationRequested = true
        recoveredEvents.removeValue(forKey: threadId)
        rollbackResumeSessionAt.removeValue(forKey: threadId)
        rollbackProviderThreadIds.removeValue(forKey: threadId)
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        terminate(session)
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK recovery requires providerThreadId")
        }
        let session = try await sessionForAsync(request, provisioningCallback: nil)
        lock.lock()
        session.onEvent = onEvent
        session.status = .completed
        lock.unlock()
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map {
            AgentProviderSessionSummary(threadId: $0.threadId, provider: .claude, status: $0.status, providerThreadId: $0.providerThreadId)
        }
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        if let session = sessions[threadId] {
            return session.events
        }
        if let events = recoveredEvents[threadId] {
            return events
        }
        throw AgentProviderAdapterError.sessionNotFound(threadId)
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let index = session.events.lastIndex(where: { Self.completedTurnId($0) == toTurnId || Self.startedTurnId($0) == toTurnId }) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("rollbackThread target not found")
        }
        let prunedEvents = Array(session.events.prefix(through: index))
        let resumeSessionAt = Self.resumeSessionAt(in: prunedEvents)
        let providerThreadId = session.providerThreadId
        session.events = prunedEvents
        session.completedTurnIds = prunedEvents.compactMap(Self.completedTurnId)
        session.activeTurnId = nil
        recoveredEvents[threadId] = prunedEvents
        if let resumeSessionAt { rollbackResumeSessionAt[threadId] = resumeSessionAt }
        if let providerThreadId { rollbackProviderThreadIds[threadId] = providerThreadId }
        sessions.removeValue(forKey: threadId)
        // Prune stale recoveredEvents: entries that have no active session and no pending
        // rollback re-use cursor are abandoned — remove them to bound memory.
        let openIds = Set(sessions.keys)
        let pendingIds = Set(rollbackProviderThreadIds.keys).union(rollbackResumeSessionAt.keys)
        let staleKeys = Self.recoveredEventsPruneKeys(
            recoveredKeys: Set(recoveredEvents.keys),
            openIds: openIds,
            pendingIds: pendingIds
        )
        for key in staleKeys { recoveredEvents.removeValue(forKey: key) }
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "thread_rolled_back")
        terminate(session)
    }

    public func stopAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        recoveredEvents.removeAll()
        rollbackResumeSessionAt.removeAll()
        rollbackProviderThreadIds.removeAll()
        lock.unlock()
        active.forEach(terminate)
    }

    public func stopAllForAppTermination() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        recoveredEvents.removeAll()
        rollbackResumeSessionAt.removeAll()
        rollbackProviderThreadIds.removeAll()
        lock.unlock()
        active.forEach(terminateImmediatelyForAppTermination)
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        session.onEvent = onEvent
        lock.unlock()
    }

    // Async path used by sendTurn and recoverSession (via Task+semaphore) — no Thread.sleep, no cooperative-pool pinning.
    private func sessionForAsync(_ request: AgentRunRequest,
                                 provisioningCallback: (@Sendable (AgentRunEvent) -> Void)?) async throws -> Session {
        let claudeExecutablePath = try resolveClaudeExecutable(request.providerBinary)
        lock.lock()
        if let existing = sessions[request.threadId] {
            // Model/permission changes switch live over the bridge (rc_set_model /
            // rc_set_permission), but effort is fixed for the life of the SDK query —
            // there is no live effort control — so an effort change is a runtime
            // switch: respawn with resume, mirroring ClaudeStreamingCLIAdapter.canReuse.
            // An in-flight turn keeps the session (sendTurn rejects it right after,
            // exactly as before; recoverSession just re-attaches).
            if (existing.reasoningEffort == request.reasoningEffort && existing.claudeExecutablePath == claudeExecutablePath) || existing.inFlightRunId != nil {
                lock.unlock()
                do {
                    try applyRuntimeSwitchIfNeeded(existing, request: request)
                    return existing
                } catch {
                    invalidateSessionAfterControlWriteFailure(existing)
                    throw error
                }
            }
            // Stash the live session id as the resume cursor for the respawn:
            // configurePayload/effectiveProviderThreadId consult this map whenever
            // the request itself carries no providerThreadId.
            if request.providerThreadId?.isEmpty != false,
               let resumeId = existing.providerThreadId, !resumeId.isEmpty {
                rollbackProviderThreadIds[request.threadId] = resumeId
            }
            sessions.removeValue(forKey: request.threadId)
            lock.unlock()
            terminate(existing)
            return try await startNewSession(request, provisioningCallback: provisioningCallback)
        }
        lock.unlock()
        return try await startNewSession(request, provisioningCallback: provisioningCallback)
    }

    private func startNewSession(_ request: AgentRunRequest,
                                 provisioningCallback: (@Sendable (AgentRunEvent) -> Void)? = nil) async throws -> Session {
        let bridgeScriptPath = try await resolvedBridgeScriptPath(onProgress: provisioningCallback)
        return try spawnSession(request, bridgeScriptPath: bridgeScriptPath)
    }

    private func nativeListSessions() async throws -> [ClaudeSDKSessionRecord] {
        if let sessionMutator {
            return try await sessionMutator.listSessions()
        }
        let response = try await executeSessionMutation([
            "type": "rc_list_sessions"
        ], expectedSubtype: "rc_list_sessions_result")
        let sessions = response["sessions"] as? [[String: Any]] ?? []
        return sessions.compactMap { session in
            guard let sessionId = session["session_id"] as? String, !sessionId.isEmpty else { return nil }
            let title = (session["custom_title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return ClaudeSDKSessionRecord(sessionId: sessionId, customTitle: title)
        }
    }

    private func nativeForkSession(sourceSessionId: String, title: String) async throws -> String {
        if let sessionMutator {
            return try await sessionMutator.forkSession(sourceSessionId: sourceSessionId, title: title)
        }
        let response = try await executeSessionMutation([
            "type": "rc_fork_session",
            "source_session_id": sourceSessionId,
            "title": title
        ], expectedSubtype: "rc_fork_session_result")
        guard let sessionId = response["session_id"] as? String, !sessionId.isEmpty else {
            throw AgentProviderAdapterError.unsupported("Claude SDK fork response omitted session_id")
        }
        return sessionId
    }

    private func nativeDeleteSession(sessionId: String) async throws {
        if let sessionMutator {
            try await sessionMutator.deleteSession(sessionId: sessionId)
            return
        }
        _ = try await executeSessionMutation([
            "type": "rc_delete_session",
            "session_id": sessionId
        ], expectedSubtype: "rc_delete_session_result")
    }

    private func executeSessionMutation(
        _ operation: [String: Any],
        expectedSubtype: String
    ) async throws -> [String: Any] {
        let script = try await resolvedBridgeScriptPath()
        guard Self.bridgeSupportsNativeSessionMutation(at: script) else {
            throw AgentProviderAdapterError.unsupported("Claude SDK bridge session mutation schema is unavailable")
        }
        guard let node = ProcessLocator.resolve(nodeBinary) else {
            throw AgentRunError.missingBinary(nodeBinary)
        }
        let requestId = UUID().uuidString
        var operation = operation
        operation["request_id"] = requestId
        var configure: [String: Any] = [
            "type": "rc_configure",
            "bridge_protocol_version": Self.bridgeProtocolVersion,
            "session_id": UUID().uuidString
        ]
        if let expectedSDKVersion = Self.pinnedNPMVersion(in: Self.sdkPackageSpec()) {
            configure["expected_sdk_version"] = expectedSDKVersion
        }
        let input = try [configure, operation].map { object -> Data in
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(0x0A)
            return data
        }.reduce(into: Data()) { $0.append($1) }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [script]
        process.environment = CodexRunner.processEnvironment(overrides: [:], provider: .claude)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
            try stdinPipe.fileHandleForWriting.write(contentsOf: input)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }
        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let lines = String(decoding: stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if object["request_id"] as? String == requestId,
               object["type"] as? String == "sdk_error" {
                throw AgentProviderAdapterError.unsupported(
                    "Claude SDK session mutation failed: \(object["message"] as? String ?? "unknown error")"
                )
            }
            if object["request_id"] as? String == requestId,
               object["subtype"] as? String == expectedSubtype {
                return object
            }
        }
        let stderrText = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw AgentProviderAdapterError.unsupported(
            "Claude SDK bridge did not return \(expectedSubtype) (exit \(process.terminationStatus))\(stderrText.isEmpty ? "" : ": \(stderrText)")"
        )
    }

    // Shared session spawn logic — validates binary, wires pipes, starts process, registers session.
    private func spawnSession(_ request: AgentRunRequest, bridgeScriptPath: String) throws -> Session {
        guard FileManager.default.isReadableFile(atPath: bridgeScriptPath) else {
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK bridge script not found: \(bridgeScriptPath)")
        }
        guard let node = ProcessLocator.resolve(nodeBinary) else {
            throw AgentRunError.missingBinary(nodeBinary)
        }
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [bridgeScriptPath] + request.extraArgs
        process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        process.environment = CodexRunner.processEnvironment(overrides: request.environment, provider: .claude)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let effectiveProviderThreadId = effectiveProviderThreadId(for: request)
        let claudeExecutablePath = try resolveClaudeExecutable(request.providerBinary)
        let session = Session(threadId: request.threadId,
                              process: process,
                              stdinPipe: stdinPipe,
                              stdoutPipe: stdoutPipe,
                              stderrPipe: stderrPipe,
                              model: request.model,
                              permissionMode: request.permissionMode,
                              interactionMode: request.interactionMode,
                              reasoningEffort: request.reasoningEffort,
                              providerThreadId: effectiveProviderThreadId,
                              claudeExecutablePath: claudeExecutablePath)
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            session.stdoutReadLock.lock()
            defer { session.stdoutReadLock.unlock() }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in session.lineBuffer.take(data) {
                self.handleLine(line, session: session)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.handleStderr(data, session: session)
        }
        process.terminationHandler = { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.finishTerminated(session)
        }
        do {
            try process.run()
            try ProcessSpawnTagger.tagProcess(process, provider: .claude)
        } catch {
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }
        lock.lock()
        sessions[request.threadId] = session
        lock.unlock()
        do {
            try write(configurePayload(for: request, claudeExecutablePath: claudeExecutablePath), to: session)
        } catch {
            lock.lock()
            if sessions[request.threadId] === session { sessions.removeValue(forKey: request.threadId) }
            lock.unlock()
            terminate(session)
            throw error
        }
        return session
    }

    private func resolvedBridgeScriptPath(onProgress: (@Sendable (AgentRunEvent) -> Void)? = nil) async throws -> String {
        guard let components = try resolvedBridgeScriptComponents() else { return bridgeScriptPath }
        if !Self.installedSDKPackage(at: components.cacheDir.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json"), matches: components.packageSpec) {
            try await installSDKPackage(in: components.cacheDir, packageSpec: components.packageSpec, onProgress: onProgress)
        }
        return components.cachedBridgePath
    }

    // Returns (cacheDir, cachedBridgePath, packageSpec) when install may be needed,
    // or nil when the local/existing bridge script is already usable.
    private func resolvedBridgeScriptComponents() throws -> (cacheDir: URL, cachedBridgePath: String, packageSpec: String)? {
        let url = URL(fileURLWithPath: bridgeScriptPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return nil
        }
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard source.contains("@anthropic-ai/claude-agent-sdk") else {
            return nil
        }
        let localPackage = url.deletingLastPathComponent()
            .appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
        if FileManager.default.isReadableFile(atPath: localPackage.path) {
            return nil
        }
        let cache = try sdkRuntimeCacheDirectory()
        let cachedBridge = cache.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        if !FileManager.default.isReadableFile(atPath: cachedBridge.path)
            || ((try? String(contentsOf: cachedBridge, encoding: .utf8)) != source) {
            try source.write(to: cachedBridge, atomically: true, encoding: .utf8)
        }
        let packageSpec = Self.sdkPackageSpec()
        return (cache, cachedBridge.path, packageSpec)
    }

    static func sdkPackageSpec() -> String {
        let package = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_PACKAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return package?.isEmpty == false ? package! : defaultSDKPackageSpec
    }

    static func installedSDKPackage(at packageJSON: URL, matches packageSpec: String) -> Bool {
        guard FileManager.default.isReadableFile(atPath: packageJSON.path) else { return false }
        guard let data = try? Data(contentsOf: packageJSON),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard let expectedVersion = pinnedNPMVersion(in: packageSpec) else {
            return true
        }
        return object["version"] as? String == expectedVersion
    }

    private static func pinnedNPMVersion(in packageSpec: String) -> String? {
        let prefix = "@anthropic-ai/claude-agent-sdk@"
        guard packageSpec.hasPrefix(prefix) else { return nil }
        let version = String(packageSpec.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.first?.isNumber == true else { return nil }
        return version
    }

    private func sdkRuntimeCacheDirectory() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_CACHE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            let cache = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let package = cache.appendingPathComponent("package.json")
            if !FileManager.default.fileExists(atPath: package.path) {
                try (#"{"type":"module","private":true}"# + "\n").write(to: package, atomically: true, encoding: .utf8)
            }
            return cache
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let cache = root
            .appendingPathComponent("RemoteCode", isDirectory: true)
            .appendingPathComponent("AgentRuntime", isDirectory: true)
            .appendingPathComponent("ClaudeAgentSDKBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let package = cache.appendingPathComponent("package.json")
        if !FileManager.default.fileExists(atPath: package.path) {
            try (#"{"type":"module","private":true}"# + "\n").write(to: package, atomically: true, encoding: .utf8)
        }
        return cache
    }

    // Async install — suspends the Swift task instead of pinning a cooperative-pool thread.
    private func installSDKPackage(in directory: URL,
                                   packageSpec: String,
                                   onProgress: (@Sendable (AgentRunEvent) -> Void)? = nil) async throws {
        let (process, outputPipe, outputBuffer) = try Self.makeNpmInstallProcess(in: directory, packageSpec: packageSpec, onProgress: onProgress)
        // Wait for termination via a continuation; the cooperative-pool thread is NOT blocked.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                outputPipe.fileHandleForReading.readabilityHandler = nil
                if proc.isRunning {
                    // Should not happen since handler fires after exit, but guard defensively.
                    ProcessTerminator.terminateTree(proc)
                    continuation.resume(throwing: AgentProviderAdapterError.unsupported("Claude Agent SDK package install timed out"))
                    return
                }
                if proc.terminationStatus != 0 {
                    let text = Self.npmInstallFailureText(buffered: outputBuffer, outputPipe: outputPipe)
                    continuation.resume(throwing: AgentProviderAdapterError.unsupported("Claude Agent SDK package install failed: \(text)"))
                } else {
                    continuation.resume()
                }
            }
            // 120 s hard timeout via a background task so install can't run indefinitely.
            let proc = process
            Task.detached {
                try? await Task.sleep(nanoseconds: Self.sdkInstallTimeoutNanoseconds())
                if proc.isRunning {
                    ProcessTerminator.terminateTree(proc)
                }
            }
        }
    }

    // Pure helper — returns the install timeout; extracted for testability.
    nonisolated static func sdkInstallTimeoutSeconds() -> Double { 120 }

    // Pure helper — returns the install timeout in nanoseconds for Task.sleep.
    nonisolated static func sdkInstallTimeoutNanoseconds() -> UInt64 {
        UInt64(sdkInstallTimeoutSeconds() * 1_000_000_000)
    }

    // Minimal locked byte accumulator for the npm install output.
    // Internal (not private) so the failure-text regression test can drive
    // makeNpmInstallProcess/npmInstallFailureText directly.
    final class LockedDataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    // Assembles the diagnostic text for a failed npm install: everything the
    // progress readabilityHandler already consumed (`buffered`) plus the
    // undelivered tail still in the pipe. Tail-only (the pre-fix behaviour)
    // was usually EMPTY because the progress handler had drained the pipe,
    // yielding "install failed: " with no explanation.
    static func npmInstallFailureText(buffered: LockedDataBuffer, outputPipe: Pipe) -> String {
        var data = buffered.value
        data.append(BoundedPipeDrain.readRemaining(from: outputPipe.fileHandleForReading))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Shared npm install process setup (spawn only — caller awaits termination).
    // Internal + npmBinary injection so tests can exercise the streamed-output
    // buffering against a deterministic fake npm.
    static func makeNpmInstallProcess(in directory: URL,
                                      packageSpec: String,
                                      onProgress: (@Sendable (AgentRunEvent) -> Void)?,
                                      npmBinary: String = "npm") throws -> (Process, Pipe, LockedDataBuffer) {
        guard let npm = ProcessLocator.resolve(npmBinary) else {
            throw AgentRunError.missingBinary(npmBinary)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["install", "--no-fund", "--no-audit", packageSpec]
        process.currentDirectoryURL = directory
        process.environment = CodexRunner.processEnvironment(overrides: [:])
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        let outputBuffer = LockedDataBuffer()
        if let onProgress {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                // Keep every consumed chunk: on failure this buffer (plus the
                // pipe tail) is the only source of npm's real error text.
                outputBuffer.append(data)
                guard let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: "\n") {
                    guard let parsed = NpmInstallProgressParser.parse(line: line) else { continue }
                    let payload = Self.provisioningPayload(stage: parsed.stage, progress: parsed.progress, packageSpec: packageSpec)
                    onProgress(Self.provisioningEvent(payload: payload))
                }
            }
            onProgress(Self.provisioningEvent(payload: Self.provisioningPayload(stage: "starting", progress: 0.0, packageSpec: packageSpec)))
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }
        return (process, outputPipe, outputBuffer)
    }

    private static func provisioningPayload(stage: String, progress: Double, packageSpec: String) -> [String: Any] {
        [
            "stage": stage,
            "progress": progress,
            "package": packageSpec
        ]
    }

    private static func provisioningEvent(payload: [String: Any]) -> AgentRunEvent {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: data, encoding: .utf8) else {
            return .event(.providerRuntime(ProviderRuntimeEvent(
                provider: .claude,
                source: "claude.agent-sdk.provisioning",
                method: "rc_provisioning",
                payloadJSON: "{}",
                receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )))
        }
        return .event(.providerRuntime(ProviderRuntimeEvent(
            provider: .claude,
            source: "claude.agent-sdk.provisioning",
            method: "rc_provisioning",
            payloadJSON: payloadJSON,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )))
    }

    private func applyRuntimeSwitchIfNeeded(_ session: Session, request: AgentRunRequest) throws {
        if session.model != request.model {
            try write(["type": "rc_set_model", "model": request.model, "session_id": session.providerThreadId ?? request.threadId.value.uuidString], to: session)
            lock.lock(); session.model = request.model; lock.unlock()
        }
        if session.permissionMode != request.permissionMode || session.interactionMode != request.interactionMode {
            try write([
                "type": "rc_set_permission",
                "permission_mode": request.permissionMode.rawValue,
                "interaction_mode": request.interactionMode.rawValue,
                "session_id": session.providerThreadId ?? request.threadId.value.uuidString
            ], to: session)
            lock.lock()
            session.permissionMode = request.permissionMode
            session.interactionMode = request.interactionMode
            lock.unlock()
        }
    }

    private static func attachmentPayload(_ attachments: [AgentAttachment]) -> [[String: Any]] {
        attachments.map {
            [
                "path": $0.path,
                "display_name": $0.displayName,
                "kind": $0.kind.rawValue,
                "mime_type": $0.mimeType ?? ""
            ]
        }
    }

    private static let supportedImageMIMETypes: Set<String> = ["image/jpeg", "image/png", "image/gif", "image/webp"]

    static func validateAttachments(_ attachments: [AgentAttachment]) throws {
        for attachment in attachments where attachment.kind == .image {
            let mime = attachment.mimeType ?? ""
            guard supportedImageMIMETypes.contains(mime) else {
                throw AgentProviderAdapterError.unsupported("Unsupported Claude image attachment type: \(mime.isEmpty ? "unknown" : mime)")
            }
        }
    }

    private func resolveClaudeExecutable(_ requested: String?) throws -> String? {
        let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = binaryNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let configured = requested?.isEmpty == false ? requested : fallback,
              !configured.isEmpty else { return nil }
        guard let resolved = ProcessLocator.resolve(configured) else { throw AgentRunError.missingBinary(configured) }
        return resolved
    }

    private func configurePayload(for request: AgentRunRequest, claudeExecutablePath: String?) -> [String: Any] {
        let resumeSessionAt: String?
        let providerThreadId: String?
        lock.lock()
        resumeSessionAt = rollbackResumeSessionAt.removeValue(forKey: request.threadId)
        providerThreadId = request.providerThreadId ?? rollbackProviderThreadIds.removeValue(forKey: request.threadId)
        lock.unlock()
        var payload: [String: Any] = [
            "type": "rc_configure",
            "bridge_protocol_version": Self.bridgeProtocolVersion,
            "cwd": request.cwd,
            "model": request.model,
            "permission_mode": request.permissionMode.rawValue,
            "interaction_mode": request.interactionMode.rawValue,
            "provider_thread_id": providerThreadId ?? "",
            "session_id": request.threadId.value.uuidString,
            "environment": request.environment
        ]
        if let expectedSDKVersion = Self.pinnedNPMVersion(in: Self.sdkPackageSpec()) {
            payload["expected_sdk_version"] = expectedSDKVersion
        }
        if let resumeSessionAt, !resumeSessionAt.isEmpty {
            payload["resume_session_at"] = resumeSessionAt
        }
        if let claudeExecutablePath {
            payload["claude_executable_path"] = claudeExecutablePath
        }
        // Effort + ultracode settings reuse ClaudeRunner's canonical CLI mapping
        // (ultracode → xhigh effort + {"ultracode":true,"enableWorkflows":true},
        // effort always sent) so the SDK bridge and the streaming CLI never drift.
        if let effort = ClaudeRunner.effortArgs(request.reasoningEffort).last {
            payload["effort"] = effort
        }
        if let settings = ClaudeRunner.ultracodeSettingsArgs(request.reasoningEffort).last {
            payload["settings"] = settings
        }
        payload["system_prompt"] = Self.claudeSystemPrompt(environment: request.environment)
        return payload
    }

    /// System prompt for the SDK session, set on every run (additive — the SDK's
    /// `systemPrompt` string does not introduce the `claude_code` preset; the agent
    /// behaviour rides on the separate `tools` preset, so this never strips it).
    ///
    /// Always carries the background-await self-declaration rule
    /// (`BackgroundAwaitContinuation.systemPromptDirective`) so the agent marks any
    /// unavoidable wait with the recovery marker independent of Token Saver. When
    /// Token Saver is on (`RC_TOKEN_SAVER_DISTILL_HINT`, set by providerEnvironment
    /// iff the managed `distill` CLI exists) it also carries the canonical distill
    /// rules — the same visible behavior Codex gets via per-turn developer_instructions
    /// and `~/.codex/AGENTS.md`. Fixed for the session's life (the SDK query is
    /// long-lived); a mid-session Token Saver toggle takes effect on the next session.
    static func claudeSystemPrompt(environment: [String: String]) -> String {
        var prompt = BackgroundAwaitContinuation.systemPromptDirective
        if environment["RC_TOKEN_SAVER_DISTILL_HINT"] == "1" {
            prompt += "\n\n" + AgentSkillInstaller.distillAgentInstructionsBody
        }
        return prompt
    }

    private func effectiveProviderThreadId(for request: AgentRunRequest) -> String? {
        lock.lock(); defer { lock.unlock() }
        return request.providerThreadId ?? rollbackProviderThreadIds[request.threadId]
    }

    private func handleLine(_ line: String, session: Session) {
        let bridgeUserInputRequest = Self.bridgeUserInputRequest(in: line)
        let isSDKError = line.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["type"] as? String == "sdk_error"
        if isSDKError { session.sawError = true }
        if let runtimeEvent = ProviderRuntimeEvent.fromJSONLine(line, provider: .claude, source: "claude.agent-sdk") {
            let event = AssistantEvent.providerRuntime(runtimeEvent)
            record(event, session: session)
            emit(.event(event), session: session)
        }
        let parsed = session.parser.parseLine(line)
        for event in parsed {
            // The SDK emits AskUserQuestion as an assistant tool block before
            // canUseTool has registered its callback. The bridge then emits the
            // authoritative user_input_request after registration. Publishing the
            // earlier parser event creates duplicate cards and lets an immediate
            // response race ahead of the callback map.
            if case .userInputRequested = event, bridgeUserInputRequest == nil {
                continue
            }
            if case .userInputRequested(let request) = event {
                lock.lock()
                session.pendingUserInputIds.insert(request.id)
                session.bridgeUserInputIds.insert(request.id)
                if let schema = bridgeUserInputRequest?.requestedSchema {
                    session.bridgeUserInputSchemas[request.id] = schema
                }
                lock.unlock()
            }
            record(event, session: session)
            emit(.event(event), session: session)
            if case .error(_, let recoverable) = event, !recoverable { session.sawError = true }
            if case .threadStarted(_, let providerThreadId) = event {
                lock.lock(); session.providerThreadId = providerThreadId; lock.unlock()
                emitSessionSnapshot(session: session, reason: "thread_started")
            }
            if case .turnStarted(let turnId) = event {
                lock.lock(); session.activeTurnId = turnId; lock.unlock()
                emitSessionSnapshot(session: session, reason: "turn_started")
            }
            if case .userInputRequested = event {
                emitSessionSnapshot(session: session, reason: "user_input_requested")
            }
            if case .requestOpened(let request) = event {
                lock.lock(); session.pendingRequestIds.insert(request.id); lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_opened")
            }
            if case .requestResolved(let requestId, _) = event {
                lock.lock(); session.pendingRequestIds.remove(requestId); lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_resolved")
            }
            if case .turnCompleted(let turnId, let finalMessage) = event {
                lock.lock()
                if !session.completedTurnIds.contains(turnId) { session.completedTurnIds.append(turnId) }
                session.activeTurnId = nil
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "turn_completed")
                let status: AgentRunStatus = session.cancellationRequested ? .cancelled : (session.sawError ? .failed : .completed)
                emit(.status(status), session: session)
                emit(.finished(status, finalMessage: finalMessage, providerThreadId: session.providerThreadId), session: session)
                lock.lock()
                session.status = status
                session.inFlightRunId = nil
                session.onEvent = nil
                session.sawError = false
                session.pendingRequestIds.removeAll()
                session.pendingUserInputIds.removeAll()
                session.bridgeUserInputIds.removeAll()
                session.bridgeUserInputSchemas.removeAll()
                lock.unlock()
            }
        }
    }

    private func handleStderr(_ data: Data, session: Session) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        // The bridge is a Node process: it prints Deprecation/Experimental
        // warnings to stderr during normal successful runs. Only lines the
        // classifier keeps may surface as a fatal error — the same gate as
        // ClaudeStreamingCLIAdapter.handleStderr / ClaudeRunner.
        guard let visible = ClaudeRunner.displayableStderr(raw) else { return }
        let event = AssistantEvent.providerRuntime(ProviderStderrClassifier.runtimeEvent(
            message: visible,
            provider: .claude,
            source: "claude.agent-sdk.stderr"
        ))
        record(event, session: session)
        emit(.event(event), session: session)
        emit(.error("[claude sdk stderr] " + visible), session: session)
    }

    private func finishTerminated(_ session: Session) {
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        // Drain under the lock: an in-flight readabilityHandler callback may
        // still be reading/parsing — the lock keeps LineBuffer access and fd
        // read order serialized so no final line is split or reordered.
        session.stdoutReadLock.lock()
        let tail = BoundedPipeDrain.readRemaining(from: session.stdoutPipe.fileHandleForReading)
        for line in session.lineBuffer.take(tail) + session.lineBuffer.flush() {
            handleLine(line, session: session)
        }
        session.stdoutReadLock.unlock()
        // Mirror the stdout drain for stderr: a bridge that dies instantly
        // (missing module, ESM syntax error, auth failure) writes the only
        // explanation to stderr, and the async handler can lose the race with
        // the teardown above, leaving the bytes undelivered in the pipe.
        let stderrTail = BoundedPipeDrain.readRemaining(from: session.stderrPipe.fileHandleForReading)
        if !stderrTail.isEmpty {
            handleStderr(stderrTail, session: session)
        }
        for event in session.parser.finalize() {
            handleFinalizedEvent(event, session: session)
        }

        lock.lock()
        if sessions[session.threadId] === session { sessions.removeValue(forKey: session.threadId) }
        let shouldFinish = session.inFlightRunId != nil
        let callback = session.onEvent
        session.inFlightRunId = nil
        let status: AgentRunStatus = session.cancellationRequested ? .cancelled : .failed
        session.status = status
        session.onEvent = nil
        lock.unlock()
        if shouldFinish {
            if !session.cancellationRequested {
                let diagnostic: String
                if session.process.terminationReason == .uncaughtSignal {
                    diagnostic = "Claude Agent SDK bridge crashed with signal \(session.process.terminationStatus)."
                } else {
                    diagnostic = "Claude Agent SDK bridge exited with status \(session.process.terminationStatus)."
                }
                callback?(.error(diagnostic))
            }
            callback?(.status(status))
            callback?(.finished(status, finalMessage: nil, providerThreadId: session.providerThreadId))
        }
    }

    private func handleFinalizedEvent(_ event: AssistantEvent, session: Session) {
        record(event, session: session)
        emit(.event(event), session: session)
        guard case .turnCompleted(let turnId, let finalMessage) = event else { return }

        lock.lock()
        if !session.completedTurnIds.contains(turnId) { session.completedTurnIds.append(turnId) }
        session.activeTurnId = nil
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "turn_completed")

        let status: AgentRunStatus = session.cancellationRequested ? .cancelled : (session.sawError ? .failed : .completed)
        emit(.status(status), session: session)
        emit(.finished(status, finalMessage: finalMessage, providerThreadId: session.providerThreadId), session: session)

        lock.lock()
        session.status = status
        session.inFlightRunId = nil
        session.onEvent = nil
        session.sawError = false
        session.pendingRequestIds.removeAll()
        session.pendingUserInputIds.removeAll()
        session.bridgeUserInputIds.removeAll()
        session.bridgeUserInputSchemas.removeAll()
        lock.unlock()
    }

    private func terminate(_ session: Session) {
        try? write(["type": "rc_close"], to: session)
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            let deadline = Date().addingTimeInterval(bridgeCloseGracePeriod)
            while session.process.isRunning, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if session.process.isRunning {
                ProcessTerminator.terminateTree(session.process)
            }
        }
    }

    private func terminateImmediatelyForAppTermination(_ session: Session) {
        try? write(["type": "rc_close"], to: session)
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            ProcessTerminator.terminateTreeImmediately(session.process)
        }
    }

    private func invalidateSessionAfterControlWriteFailure(_ session: Session) {
        lock.lock()
        let ownsSession = sessions[session.threadId] === session
        if ownsSession { sessions.removeValue(forKey: session.threadId) }
        lock.unlock()
        guard ownsSession else { return }
        terminate(session)
    }

    private func settlePendingRequests(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingRequestIds)
        session.pendingRequestIds.removeAll()
        lock.unlock()
        for requestId in requestIds {
            let resolved = AssistantEvent.requestResolved(requestId: requestId, state: .cancelled)
            record(resolved, session: session)
            emit(.event(resolved), session: session)
        }
        if !requestIds.isEmpty {
            emitSessionSnapshot(session: session, reason: "requests_settled")
        }
    }

    private func settlePendingUserInputs(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingUserInputIds)
        session.pendingUserInputIds.removeAll()
        session.bridgeUserInputIds.removeAll()
        session.bridgeUserInputSchemas.removeAll()
        lock.unlock()
        for requestId in requestIds {
            let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: nil)
            record(resolved, session: session)
            emit(.event(resolved), session: session)
        }
        if !requestIds.isEmpty {
            emitSessionSnapshot(session: session, reason: "user_inputs_settled")
        }
    }

    private func write(_ payload: [String: Any], to session: Session) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        try session.writeQueue.sync {
            try GuardedStdinWrite.write(line,
                                        to: session.stdinPipe.fileHandleForWriting,
                                        process: session.process,
                                        notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })
        }
    }

    private func emit(_ event: AgentRunEvent, session: Session) {
        lock.lock(); let callback = session.onEvent; lock.unlock()
        callback?(event)
    }

    private func record(_ event: AssistantEvent, session: Session) {
        lock.lock()
        session.events.append(event)
        if session.events.count > maxReadableEvents {
            session.events = Array(session.events.suffix(maxReadableEvents))
        }
        lock.unlock()
    }

    private func emitSessionSnapshot(session: Session, reason: String) {
        lock.lock()
        var payload: [String: Any] = [
            "reason": reason,
            "provider": "claude",
            "sdk": "agent-sdk",
            "model": session.model,
            "turnCount": session.completedTurnIds.count,
            "pendingApprovalRequestIds": Array(session.pendingRequestIds).sorted(),
            "pendingUserInputRequestIds": Array(session.pendingUserInputIds).sorted()
        ]
        if let providerThreadId = session.providerThreadId {
            payload["providerThreadId"] = providerThreadId
            payload["resume"] = providerThreadId
        }
        if let activeTurnId = session.activeTurnId { payload["activeTurnId"] = activeTurnId }
        if let lastCompletedTurnId = session.completedTurnIds.last { payload["lastCompletedTurnId"] = lastCompletedTurnId }
        let providerTurnId = session.activeTurnId ?? session.completedTurnIds.last
        lock.unlock()
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let payloadJSON = String(data: data, encoding: .utf8) else { return }
        emit(.event(.providerRuntime(ProviderRuntimeEvent(
            provider: .claude,
            source: "claude.agent-sdk.session",
            method: "claude.session.snapshot",
            providerTurnId: providerTurnId,
            payloadJSON: payloadJSON,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))), session: session)
    }

    private static func bridgeUserInputRequest(
        in line: String
    ) -> (id: String, requestedSchema: [String: Any]?)? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "user_input_request" else {
            return nil
        }
        guard let id = obj["request_id"] as? String
            ?? obj["id"] as? String
            ?? obj["elicitation_id"] as? String else { return nil }
        return (id, obj["requested_schema"] as? [String: Any])
    }

    private static func elicitationContent(
        text: String,
        requestedSchema: [String: Any]?
    ) throws -> [String: Any] {
        let structured: [String: Any] = {
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return [:]
            }
            return object
        }()
        guard let properties = requestedSchema?["properties"] as? [String: Any],
              !properties.isEmpty else {
            return structured.isEmpty ? ["answer": text] : structured
        }

        var content: [String: Any] = [:]
        let names = properties.keys.sorted()
        for name in names {
            guard let property = properties[name] as? [String: Any] else { continue }
            let raw: Any?
            if let structuredValue = structured[name] {
                raw = structuredValue
            } else if names.count == 1 {
                raw = text
            } else {
                raw = nil
            }
            guard let raw,
                  let value = elicitationValue(raw, type: property["type"] as? String) else { continue }
            if let allowed = property["enum"] as? [Any],
               !allowed.contains(where: { String(describing: $0) == String(describing: value) }) {
                continue
            }
            content[name] = value
        }
        let required = requestedSchema?["required"] as? [String] ?? []
        if let missing = required.first(where: { content[$0] == nil }) {
            throw AgentProviderAdapterError.unsupported(
                "Claude elicitation requires a valid value for \(missing)"
            )
        }
        return content
    }

    private static func elicitationValue(_ raw: Any, type: String?) -> Any? {
        switch type {
        case "boolean":
            if let value = raw as? Bool { return value }
            switch String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        case "integer":
            if let value = raw as? Int { return value }
            if let value = raw as? NSNumber { return value.intValue }
            return Int(String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines))
        case "number":
            if let value = raw as? NSNumber { return value.doubleValue }
            return Double(String(describing: raw).trimmingCharacters(in: .whitespacesAndNewlines))
        case "array":
            if let value = raw as? [Any] { return value }
            return String(describing: raw).split(separator: ",").map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        default:
            return raw is String ? raw : String(describing: raw)
        }
    }

    private static func permissionDecision(for response: AgentProviderRequestResponse) -> String {
        switch response {
        case .approve: return "approve"
        case .approveForSession: return "approve_for_session"
        case .decline: return "decline"
        case .cancel: return "cancel"
        }
    }

    private static func requestState(for response: AgentProviderRequestResponse) -> AssistantRequestState {
        switch response {
        case .approve, .approveForSession: return .approved
        case .decline: return .declined
        case .cancel: return .cancelled
        }
    }

    private static func startedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnStarted(let turnId) = event else { return nil }
        return turnId
    }

    private static func completedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnCompleted(let turnId, _) = event else { return nil }
        return turnId
    }

    private static func resumeSessionAt(in events: [AssistantEvent]) -> String? {
        for event in events.reversed() {
            guard case .providerRuntime(let runtime) = event,
                  runtime.method == "claude.session.snapshot",
                  let data = runtime.payloadJSON.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let value = payload["resumeSessionAt"] as? String, !value.isEmpty {
                return value
            }
            if let value = payload["lastAssistantUuid"] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    // Pure helper — returns recoveredEvents keys eligible for pruning.
    // A key is eligible when it has no open session and no pending rollback re-use cursor,
    // meaning the thread was rolled back but never resumed. Safe to call under lock.
    // Extracted as nonisolated static for direct unit-testability without instantiating the adapter.
    nonisolated static func recoveredEventsPruneKeys(
        recoveredKeys: Set<AgentThreadID>,
        openIds: Set<AgentThreadID>,
        pendingIds: Set<AgentThreadID>
    ) -> Set<AgentThreadID> {
        recoveredKeys.subtracting(openIds).subtracting(pendingIds)
    }
}
