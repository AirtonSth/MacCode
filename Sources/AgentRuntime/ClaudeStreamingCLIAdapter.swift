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
        // PERF-008: last emitted snapshot JSON (state fields only, reason
        // excluded) so identical snapshots fired by high-frequency tool
        // deltas are not re-encoded and re-broadcast.
        var lastSnapshotStateJSON: String?

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
        lock.lock()
        let session = sessions[threadId]
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        // Attempt graceful interrupt via stream-json control message first.
        // This lets the Claude CLI finish writing and close cleanly, preserving
        // the warm session for potential resumption. Fall back to process kill
        // only if the stdin write fails (pipe closed, process already dead, etc.).
        let line = Self.controlInterruptLine()
        let didSend = session.writeQueue.sync {
            (try? GuardedStdinWrite.write(line,
                                          to: session.stdinPipe.fileHandleForWriting,
                                          process: session.process,
                                          notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })) != nil
        }
        if !didSend {
            try stopSession(threadId: threadId)
        }
    }

    /// Builds the newline-terminated stream-json control interrupt payload.
    /// Pure builder — no I/O, no actor isolation. Extracted for unit testing.
    nonisolated static func controlInterruptLine() -> Data {
        // Claude CLI stream-json protocol: sending {"type":"control","action":"interrupt"}
        // over stdin requests a clean turn abort without killing the process.
        let payload: [String: Any] = ["type": "control", "action": "interrupt"]
        var data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        data.append(0x0A) // newline delimiter
        return data
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
            lock.unlock()
            seedTranscriptOutsideLock(session: existing)
            return
        }
        lock.unlock()

        let session = try sessionFor(request: request)
        lock.lock()
        session.providerThreadId = request.providerThreadId
        session.status = .completed
        session.onEvent = onEvent
        session.environment = request.environment
        lock.unlock()
        seedTranscriptOutsideLock(session: session)
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
        lock.lock()
        let session = sessions[threadId]
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        seedTranscriptOutsideLock(session: session)
        lock.lock(); defer { lock.unlock() }
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
        process.environment = CodexRunner.processEnvironment(overrides: request.environment, provider: .claude)
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
        try session.writeQueue.sync {
            try GuardedStdinWrite.write(line,
                                        to: session.stdinPipe.fileHandleForWriting,
                                        process: session.process,
                                        notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })
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
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        let tail = session.stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        for line in session.lineBuffer.take(tail) + session.lineBuffer.flush() {
            handleLine(line, session: session)
        }
        for event in session.parser.finalize() {
            handleFinalizedEvent(event, session: session)
        }

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

    private func handleFinalizedEvent(_ event: AssistantEvent, session: Session) {
        record(event, session: session)
        emit(.event(event), session: session)
        guard case .turnCompleted(let turnId, let finalMessage) = event else { return }

        lock.lock()
        if !session.completedTurnIds.contains(turnId) {
            session.completedTurnIds.append(turnId)
        }
        session.activeTurnId = nil
        session.inFlightToolIds.removeAll()
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "turn_completed")

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
        try session.writeQueue.sync {
            try GuardedStdinWrite.write(line,
                                        to: session.stdinPipe.fileHandleForWriting,
                                        process: session.process,
                                        notFound: { AgentProviderAdapterError.sessionNotFound(session.threadId) })
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

    /// Seeds in-memory transcript without holding `lock` across the recursive
    /// disk enumeration in `ClaudeTranscriptStore.readSession`. The disk read is
    /// the slow part (filesystem walk of ~/.claude/projects + file reads); doing
    /// it under the adapter lock stalled every pipe-readability callback and any
    /// other adapter API. Sequence:
    ///   1. snapshot the seed inputs under the lock, then release it,
    ///   2. perform the disk read with NO lock held,
    ///   3. re-take the lock only to merge the result, re-checking the guard so a
    ///      concurrent live turn that produced a readable turn meanwhile wins
    ///      (no double-seed / no clobbering live events).
    /// Callers MUST invoke this WITHOUT holding `lock`.
    private func seedTranscriptOutsideLock(session: Session) {
        lock.lock()
        let currentEvents = session.events
        let providerThreadId = session.providerThreadId
        let environment = session.environment
        lock.unlock()

        guard Self.shouldReadTranscript(currentEvents: currentEvents, providerThreadId: providerThreadId),
              let providerThreadId else {
            return
        }
        // Disk I/O performed with the lock released.
        let transcriptEvents = transcriptStore.readSession(providerThreadId: providerThreadId, environment: environment)

        lock.lock()
        // Re-check against the latest events under the lock so a concurrent
        // live turn cannot be clobbered by a stale transcript snapshot.
        if let merged = Self.transcriptSeedMerge(currentEvents: session.events,
                                                 transcriptEvents: transcriptEvents,
                                                 maxReadableEvents: maxReadableEvents) {
            session.events = merged
        }
        lock.unlock()
    }

    /// Pure pre-read guard: should we even hit disk for this session? Disk read
    /// is wasted when the session already has a readable turn or has no provider
    /// thread to read from. No I/O, no isolation. Extracted for unit testing.
    nonisolated static func shouldReadTranscript(currentEvents: [AssistantEvent], providerThreadId: String?) -> Bool {
        guard let providerThreadId, !providerThreadId.isEmpty else { return false }
        return !hasReadableTurn(currentEvents)
    }

    /// Pure merge step: given the latest in-memory events and the events read
    /// from the transcript, return the events to assign, or nil to skip. Skips
    /// when the session already has a readable turn (a live turn won the race)
    /// or the transcript is empty. No I/O, no isolation. Extracted for unit
    /// testing the concurrent-safe merge.
    nonisolated static func transcriptSeedMerge(currentEvents: [AssistantEvent],
                                                transcriptEvents: [AssistantEvent],
                                                maxReadableEvents: Int) -> [AssistantEvent]? {
        guard !hasReadableTurn(currentEvents), !transcriptEvents.isEmpty else { return nil }
        return Array(transcriptEvents.suffix(maxReadableEvents))
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
        // PERF-008: coalesce identical snapshots. Compute a signature over
        // the state fields (the payload minus the per-call `reason`); if it
        // matches the last emitted snapshot, skip the encode + broadcast.
        // This drops the dozens-of-encodes/sec a tool-heavy turn would
        // otherwise produce on the stdout-readability thread.
        var stateForSignature = payload
        stateForSignature.removeValue(forKey: "reason")
        let signature = Self.jsonString(stateForSignature)
        if let signature, signature == session.lastSnapshotStateJSON {
            lock.unlock()
            return
        }
        session.lastSnapshotStateJSON = signature
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

    /// Pure helper: merges (original SR1 text, rewritten translation) into a
    /// payload dict suitable for embedding in a persisted stream event so a
    /// "view original" affordance is possible downstream.
    ///
    /// Contract:
    ///   - When original != rewritten: dict contains "originalText" (original),
    ///     "rewrittenText" (rewritten), "sr1Translated" = true.
    ///   - When original == rewritten (no rewrite): dict contains "rewrittenText"
    ///     only, "sr1Translated" = false. "originalText" is omitted (redundant).
    nonisolated static func sr1TranslationPayload(original: String, rewritten: String) -> [String: Any] {
        if original == rewritten {
            return ["rewrittenText": rewritten, "sr1Translated": false]
        }
        return ["originalText": original, "rewrittenText": rewritten, "sr1Translated": true]
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
