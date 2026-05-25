import Foundation
import CoreModel

public final class ClaudeStreamingCLIAdapter: AgentProviderAdapter, @unchecked Sendable {
    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        var model: String
        let parser = ClaudeParser()
        let lineBuffer = LineBuffer()
        let writeQueue = DispatchQueue(label: "remotecode.claude-stream.write")
        var events: [AssistantEvent] = []
        var status: AgentRunStatus = .running
        var providerThreadId: String?
        var permissionMode: AgentPermissionMode
        var reasoningEffort: AgentReasoningEffort?
        var interactionMode: AgentInteractionMode
        var activeTurnId: String?
        var completedTurnIds: [String] = []
        var inFlightToolIds = Set<String>()
        var lastAssistantUuid: String?
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var inFlightRunId: AgentRunID?
        var sawError = false
        var pendingRequestIds = Set<String>()
        var pendingUserInputIds = Set<String>()
        var environment: [String: String] = [:]

        init(threadId: AgentThreadID,
             process: Process,
             stdinPipe: Pipe,
             stdoutPipe: Pipe,
             stderrPipe: Pipe,
             model: String,
             permissionMode: AgentPermissionMode,
             reasoningEffort: AgentReasoningEffort?,
             interactionMode: AgentInteractionMode) {
            self.threadId = threadId
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.model = model
            self.permissionMode = permissionMode
            self.reasoningEffort = reasoningEffort
            self.interactionMode = interactionMode
        }
    }

    public let provider: AgentProvider = .claude
    private let binaryNameOverride: String?
    private let maxReadableEvents: Int
    private let transcriptStore: ClaudeTranscriptStore
    private let lock = NSLock()
    private var sessions: [AgentThreadID: Session] = [:]

    public init(binaryNameOverride: String? = nil, maxReadableEvents: Int = 5_000, transcriptStore: ClaudeTranscriptStore = ClaudeTranscriptStore()) {
        self.binaryNameOverride = binaryNameOverride
        self.maxReadableEvents = max(1, maxReadableEvents)
        self.transcriptStore = transcriptStore
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await ClaudeRunner(binaryNameOverride: binaryNameOverride).listModels()
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let session = try sessionFor(request: request)
        lock.lock()
        if session.inFlightRunId != nil {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude streaming session already has an in-flight turn")
        }
        session.onEvent = onEvent
        session.inFlightRunId = request.runId
        session.sawError = false
        session.status = .running
        lock.unlock()

        onEvent(.status(.running))
        try sendPrompt(request.providerPrompt, to: session)
        return AgentRunHandle(runId: request.runId, process: session.process) { [weak self] in
            try? self?.stopSession(threadId: request.threadId)
        }
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        try stopSession(threadId: threadId)
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingRequestIds.remove(requestId) != nil else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude streaming request not found: \(requestId)")
        }
        lock.unlock()

        try sendPermissionResponse(requestId: requestId, response: response, to: session)
        let resolved = AssistantEvent.requestResolved(requestId: requestId, state: Self.requestState(for: response))
        record(resolved, session: session)
        emit(.event(resolved), session: session)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingUserInputIds.remove(requestId) != nil else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude streaming user input request not found: \(requestId)")
        }
        lock.unlock()

        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: text)
        record(resolved, session: session)
        try sendPrompt(text, to: session)
        emit(.event(resolved), session: session)
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions.removeValue(forKey: threadId)
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        terminate(session: session, status: .cancelled)
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Claude streaming recovery requires providerThreadId")
        }
        lock.lock()
        if let existing = sessions[request.threadId] {
            existing.providerThreadId = request.providerThreadId
            existing.onEvent = onEvent
            existing.environment = request.environment
            seedTranscriptIfNeeded(session: existing)
            lock.unlock()
            return
        }
        lock.unlock()

        let session = try sessionFor(request: request)
        lock.lock()
        session.providerThreadId = request.providerThreadId
        session.status = .completed
        session.onEvent = onEvent
        session.environment = request.environment
        seedTranscriptIfNeeded(session: session)
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

    public func readThread(threadId: AgentThreadID) throws -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[threadId] else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        seedTranscriptIfNeeded(session: session)
        return session.events
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let index = session.events.lastIndex(where: { Self.completedTurnId($0) == toTurnId || Self.startedTurnId($0) == toTurnId }) else {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("rollbackThread target not found")
        }
        session.events = Array(session.events.prefix(through: index))
        session.completedTurnIds = session.events.compactMap(Self.completedTurnId)
        session.activeTurnId = nil
        session.inFlightToolIds.removeAll()
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "thread_rolled_back")
    }

    public func stopAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        active.forEach { terminate(session: $0, status: .cancelled) }
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

    private func sessionFor(request: AgentRunRequest) throws -> Session {
        lock.lock()
        if let existing = sessions[request.threadId] {
            if Self.canReuse(existing, for: request) {
                lock.unlock()
                return existing
            }
            if existing.inFlightRunId != nil {
                lock.unlock()
                throw AgentProviderAdapterError.unsupported("Claude streaming runtime switch while a turn is in-flight")
            }
            let providerThreadId = request.providerThreadId ?? existing.providerThreadId
            guard let providerThreadId, !providerThreadId.isEmpty else {
                lock.unlock()
                throw AgentProviderAdapterError.unsupported("Claude streaming runtime switch requires providerThreadId")
            }
            sessions.removeValue(forKey: request.threadId)
            lock.unlock()
            terminate(session: existing, status: .cancelled)
            return try startNewSession(request: request.withProviderThreadId(providerThreadId))
        }
        lock.unlock()
        return try startNewSession(request: request)
    }

    private func startNewSession(request: AgentRunRequest) throws -> Session {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? request.providerBinary! : (binaryNameOverride ?? "claude")
        guard let path = ProcessLocator.resolve(binary) else {
            throw AgentRunError.missingBinary(binary)
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ClaudeRunner.buildStreamingArgs(request)
        process.currentDirectoryURL = URL(fileURLWithPath: request.cwd)
        process.environment = CodexRunner.processEnvironment(overrides: request.environment)
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let session = Session(threadId: request.threadId,
                              process: process,
                              stdinPipe: stdinPipe,
                              stdoutPipe: stdoutPipe,
                              stderrPipe: stderrPipe,
                              model: request.model,
                              permissionMode: request.permissionMode,
                              reasoningEffort: request.reasoningEffort,
                              interactionMode: request.interactionMode)
        session.environment = request.environment
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self, weak session] handle in
            guard let self, let session else { return }
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
        } catch {
            throw AgentRunError.spawnFailed(error.localizedDescription)
        }

        lock.lock()
        sessions[request.threadId] = session
        lock.unlock()
        return session
    }

    private static func canReuse(_ session: Session, for request: AgentRunRequest) -> Bool {
        session.model == request.model
            && session.permissionMode == request.permissionMode
            && session.reasoningEffort == request.reasoningEffort
            && session.interactionMode == request.interactionMode
    }

    private func sendPrompt(_ text: String, to session: Session) throws {
        let payload: [String: Any] = [
            "type": "user",
            "message": [
                "role": "user",
                "content": [["type": "text", "text": text]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        session.writeQueue.sync {
            session.stdinPipe.fileHandleForWriting.write(line)
        }
    }

    private func handleLine(_ line: String, session: Session) {
        let rawObject = Self.jsonObject(from: line)
        if let assistantUuid = Self.assistantUuid(from: rawObject) {
            lock.lock()
            session.lastAssistantUuid = assistantUuid
            lock.unlock()
        }
        if let runtimeEvent = ProviderRuntimeEvent.fromJSONLine(line, provider: .claude, source: "claude.stream-json") {
            emit(.event(.providerRuntime(runtimeEvent)), session: session)
        }
        let parsed = session.parser.parseLine(line)
        for event in parsed {
            record(event, session: session)
            emit(.event(event), session: session)
            if case .error(_, let recoverable) = event, !recoverable {
                session.sawError = true
            }
            if case .threadStarted(_, let providerThreadId) = event {
                session.providerThreadId = providerThreadId
                emitSessionSnapshot(session: session, reason: "thread_started")
            }
            if case .turnStarted(let turnId) = event {
                lock.lock()
                session.activeTurnId = turnId
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "turn_started")
            }
            if case .itemStarted(let item) = event, item.type == .tool {
                lock.lock()
                session.inFlightToolIds.insert(item.id)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "tool_started")
            }
            if case .itemCompleted(let itemId, _) = event {
                lock.lock()
                session.inFlightToolIds.remove(itemId)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "tool_completed")
            }
            if case .userInputRequested(let request) = event {
                lock.lock()
                session.pendingUserInputIds.insert(request.id)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "user_input_requested")
            }
            if case .requestOpened(let request) = event {
                lock.lock()
                session.pendingRequestIds.insert(request.id)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_opened")
            }
            if case .requestResolved(let requestId, _) = event {
                lock.lock()
                session.pendingRequestIds.remove(requestId)
                lock.unlock()
                emitSessionSnapshot(session: session, reason: "request_resolved")
            }
            if case .turnCompleted(_, let finalMessage) = event {
                if case .turnCompleted(let turnId, _) = event {
                    lock.lock()
                    if !session.completedTurnIds.contains(turnId) {
                        session.completedTurnIds.append(turnId)
                    }
                    session.activeTurnId = nil
                    session.inFlightToolIds.removeAll()
                    lock.unlock()
                    emitSessionSnapshot(session: session, reason: "turn_completed")
                }
                let status: AgentRunStatus = session.sawError ? .failed : .completed
                session.status = status
                let providerThreadId = session.providerThreadId
                emit(.status(status), session: session)
                emit(.finished(status, finalMessage: finalMessage, providerThreadId: providerThreadId), session: session)
                lock.lock()
                session.inFlightRunId = nil
                session.onEvent = nil
                session.sawError = false
                session.pendingRequestIds.removeAll()
                session.pendingUserInputIds.removeAll()
                lock.unlock()
            }
        }
    }

    private func handleStderr(_ data: Data, session: Session) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let visible = ClaudeRunner.displayableStderr(raw) else { return }
        let event = AssistantEvent.providerRuntime(ProviderStderrClassifier.runtimeEvent(
            message: visible,
            provider: .claude,
            source: "claude.stream-json.stderr"
        ))
        record(event, session: session)
        emit(.event(event), session: session)
        emit(.error("[claude stderr] " + visible), session: session)
    }

    private func finishTerminated(_ session: Session) {
        lock.lock()
        if sessions[session.threadId] === session {
            sessions.removeValue(forKey: session.threadId)
        }
        let shouldFinish = session.inFlightRunId != nil
        session.inFlightRunId = nil
        session.status = .cancelled
        let onEvent = session.onEvent
        session.onEvent = nil
        lock.unlock()
        if shouldFinish {
            onEvent?(.status(.cancelled))
            onEvent?(.finished(.cancelled, finalMessage: nil, providerThreadId: session.providerThreadId))
        }
    }

    private func terminate(session: Session, status: AgentRunStatus) {
        session.status = status
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            ProcessTerminator.terminateTree(session.process)
        }
    }

    private func sendPermissionResponse(requestId: String, response: AgentProviderRequestResponse, to session: Session) throws {
        var payload: [String: Any] = [
            "type": "permission_response",
            "request_id": requestId,
            "decision": Self.permissionDecision(for: response)
        ]
        if case .decline(let reason) = response, let reason, !reason.isEmpty {
            payload["message"] = reason
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        var line = data
        line.append(0x0A)
        session.writeQueue.sync {
            session.stdinPipe.fileHandleForWriting.write(line)
        }
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
        emitSessionSnapshot(session: session, reason: "requests_settled")
    }

    private func settlePendingUserInputs(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingUserInputIds)
        session.pendingUserInputIds.removeAll()
        lock.unlock()
        for requestId in requestIds {
            let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: nil)
            record(resolved, session: session)
            emit(.event(resolved), session: session)
        }
        emitSessionSnapshot(session: session, reason: "user_inputs_settled")
    }

    private func emit(_ event: AgentRunEvent, session: Session) {
        lock.lock()
        let callback = session.onEvent
        lock.unlock()
        callback?(event)
    }

    private func record(_ event: AssistantEvent, session: Session) {
        lock.lock()
        if shouldAppend(event, session: session) {
            session.events.append(event)
            pruneReadableEvents(session)
        }
        lock.unlock()
    }

    private func seedTranscriptIfNeeded(session: Session) {
        guard !Self.hasReadableTurn(session.events),
              let providerThreadId = session.providerThreadId,
              !providerThreadId.isEmpty else {
            return
        }
        let transcriptEvents = transcriptStore.readSession(providerThreadId: providerThreadId, environment: session.environment)
        guard !transcriptEvents.isEmpty else { return }
        session.events = Array(transcriptEvents.suffix(maxReadableEvents))
    }

    private static func hasReadableTurn(_ events: [AssistantEvent]) -> Bool {
        events.contains { event in
            switch event {
            case .turnCompleted:
                return true
            case .itemDelta(_, let bodyAppend, let outputAppend, _):
                return bodyAppend?.isEmpty == false || outputAppend?.isEmpty == false
            default:
                return false
            }
        }
    }

    private func shouldAppend(_ event: AssistantEvent, session: Session) -> Bool {
        guard case .turnStarted(let turnId) = event else { return true }
        return Self.startedTurnId(session.events.last) != turnId
    }

    private static func startedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnStarted(let turnId) = event else { return nil }
        return turnId
    }

    private static func completedTurnId(_ event: AssistantEvent?) -> String? {
        guard let event, case .turnCompleted(let turnId, _) = event else { return nil }
        return turnId
    }

    private func pruneReadableEvents(_ session: Session) {
        guard session.events.count > maxReadableEvents else { return }
        session.events = Array(session.events.suffix(maxReadableEvents))
    }

    private func emitSessionSnapshot(session: Session, reason: String) {
        lock.lock()
        let payload = Self.sessionSnapshotPayload(session: session, reason: reason)
        let providerTurnId = session.activeTurnId ?? session.completedTurnIds.last
        lock.unlock()
        guard let payloadJSON = Self.jsonString(payload) else { return }
        let event = AssistantEvent.providerRuntime(ProviderRuntimeEvent(
            provider: .claude,
            source: "claude.stream-json.session",
            method: "claude.session.snapshot",
            providerTurnId: providerTurnId,
            payloadJSON: payloadJSON,
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
        emit(.event(event), session: session)
    }

    private static func sessionSnapshotPayload(session: Session, reason: String) -> [String: Any] {
        var payload: [String: Any] = [
            "reason": reason,
            "provider": "claude",
            "model": session.model,
            "turnCount": session.completedTurnIds.count,
            "pendingApprovalRequestIds": Array(session.pendingRequestIds).sorted(),
            "pendingUserInputRequestIds": Array(session.pendingUserInputIds).sorted(),
            "inFlightToolIds": Array(session.inFlightToolIds).sorted()
        ]
        if let providerThreadId = session.providerThreadId {
            payload["providerThreadId"] = providerThreadId
            payload["resume"] = providerThreadId
        }
        if let activeTurnId = session.activeTurnId {
            payload["activeTurnId"] = activeTurnId
        }
        if let lastCompletedTurnId = session.completedTurnIds.last {
            payload["lastCompletedTurnId"] = lastCompletedTurnId
        }
        if let lastAssistantUuid = session.lastAssistantUuid {
            payload["resumeSessionAt"] = lastAssistantUuid
            payload["lastAssistantUuid"] = lastAssistantUuid
        }
        return payload
    }

    private static func jsonObject(from line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func assistantUuid(from object: [String: Any]?) -> String? {
        guard let object else { return nil }
        if let uuid = object["uuid"] as? String, !uuid.isEmpty { return uuid }
        if let message = object["message"] as? [String: Any] {
            if let uuid = message["uuid"] as? String, !uuid.isEmpty { return uuid }
            if let uuid = message["id"] as? String, !uuid.isEmpty { return uuid }
        }
        return nil
    }

    private static func jsonString(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func requestState(for response: AgentProviderRequestResponse) -> AssistantRequestState {
        switch response {
        case .approve, .approveForSession:
            return .approved
        case .decline:
            return .declined
        case .cancel:
            return .cancelled
        }
    }

    private static func permissionDecision(for response: AgentProviderRequestResponse) -> String {
        switch response {
        case .approve:
            return "approve"
        case .approveForSession:
            return "approveForSession"
        case .decline:
            return "decline"
        case .cancel:
            return "cancel"
        }
    }
}

private extension AgentRunRequest {
    func withProviderThreadId(_ providerThreadId: String) -> AgentRunRequest {
        AgentRunRequest(
            runId: runId,
            threadId: threadId,
            provider: provider,
            providerInstanceId: providerInstanceId,
            model: model,
            cwd: cwd,
            prompt: prompt,
            userMessageContent: userMessageContent,
            attachments: attachments,
            providerThreadId: providerThreadId,
            permissionMode: permissionMode,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            interactionMode: interactionMode,
            providerBinary: providerBinary,
            environment: environment,
            extraArgs: extraArgs
        )
    }
}
