import Foundation
import CoreModel

public final class ClaudeAgentSDKBridgeAdapter: AgentProviderAdapter, @unchecked Sendable {
    static let defaultSDKPackageSpec = "@anthropic-ai/claude-agent-sdk@0.3.157"

    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
        let parser = ClaudeParser()
        let lineBuffer = LineBuffer()
        let writeQueue = DispatchQueue(label: "remotecode.claude-sdk.write")
        var events: [AssistantEvent] = []
        var status: AgentRunStatus = .running
        var providerThreadId: String?
        var model: String
        var permissionMode: AgentPermissionMode
        var interactionMode: AgentInteractionMode
        var activeTurnId: String?
        var completedTurnIds: [String] = []
        var inFlightRunId: AgentRunID?
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var sawError = false
        var pendingRequestIds = Set<String>()
        var pendingUserInputIds = Set<String>()
        var bridgeUserInputIds = Set<String>()

        init(threadId: AgentThreadID,
             process: Process,
             stdinPipe: Pipe,
             stdoutPipe: Pipe,
             stderrPipe: Pipe,
             model: String,
             permissionMode: AgentPermissionMode,
             interactionMode: AgentInteractionMode,
             providerThreadId: String?) {
            self.threadId = threadId
            self.process = process
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.model = model
            self.permissionMode = permissionMode
            self.interactionMode = interactionMode
            self.providerThreadId = providerThreadId
        }
    }

    public let provider: AgentProvider = .claude
    private let nodeBinary: String
    private let bridgeScriptPath: String
    private let maxReadableEvents: Int
    private let lock = NSLock()
    private var sessions: [AgentThreadID: Session] = [:]
    private var recoveredEvents: [AgentThreadID: [AssistantEvent]] = [:]
    private var rollbackResumeSessionAt: [AgentThreadID: String] = [:]
    private var rollbackProviderThreadIds: [AgentThreadID: String] = [:]

    public init(nodeBinary: String = "node", bridgeScriptPath: String? = nil, maxReadableEvents: Int = 5_000) {
        self.nodeBinary = nodeBinary
        self.bridgeScriptPath = bridgeScriptPath
            ?? ProcessInfo.processInfo.environment["RC_CLAUDE_AGENT_SDK_BRIDGE"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("ClaudeAgentSDKBridge.mjs").path
        self.maxReadableEvents = max(1, maxReadableEvents)
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await ClaudeRunner().listModels()
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        let session = try sessionFor(request, provisioningCallback: onEvent)
        lock.lock()
        if session.inFlightRunId != nil {
            lock.unlock()
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK bridge already has an in-flight turn")
        }
        session.onEvent = onEvent
        session.inFlightRunId = request.runId
        session.sawError = false
        session.status = .running
        lock.unlock()

        onEvent(.status(.running))
        try write([
            "type": "rc_turn",
            "prompt": request.providerPrompt,
            "attachments": Self.attachmentPayload(request.attachments),
            "session_id": session.providerThreadId ?? request.threadId.value.uuidString
        ], to: session)
        return AgentRunHandle(runId: request.runId, process: session.process) { [weak self] in
            try? self?.stopSession(threadId: request.threadId)
        }
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions[threadId]
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        try write(["type": "rc_interrupt"], to: session)
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard session.pendingRequestIds.remove(requestId) != nil else {
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
        try write(payload, to: session)
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
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK user input request not found: \(requestId)")
        }
        let usesBridgeCallback = session.bridgeUserInputIds.remove(requestId) != nil
        lock.unlock()
        let resolved = AssistantEvent.userInputResolved(requestId: requestId, answer: text)
        record(resolved, session: session)
        if usesBridgeCallback {
            try write(["type": "user_input_response", "request_id": requestId, "text": text], to: session)
        } else {
            try write(["type": "rc_turn", "prompt": text], to: session)
        }
        emit(.event(resolved), session: session)
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        let session = sessions.removeValue(forKey: threadId)
        lock.unlock()
        guard let session else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        terminate(session)
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK recovery requires providerThreadId")
        }
        let session = try sessionFor(request)
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

    public func readThread(threadId: AgentThreadID) throws -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        if let session = sessions[threadId] {
            return session.events
        }
        if let events = recoveredEvents[threadId] {
            return events
        }
        throw AgentProviderAdapterError.sessionNotFound(threadId)
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
        lock.unlock()
        emitSessionSnapshot(session: session, reason: "thread_rolled_back")
        terminate(session)
    }

    public func stopAll() {
        lock.lock()
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        active.forEach(terminate)
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

    private func sessionFor(_ request: AgentRunRequest) throws -> Session {
        try sessionFor(request, provisioningCallback: nil)
    }

    private func sessionFor(_ request: AgentRunRequest,
                            provisioningCallback: (@Sendable (AgentRunEvent) -> Void)?) throws -> Session {
        lock.lock()
        if let existing = sessions[request.threadId] {
            lock.unlock()
            try applyRuntimeSwitchIfNeeded(existing, request: request)
            return existing
        }
        lock.unlock()
        return try startNewSession(request, provisioningCallback: provisioningCallback)
    }

    private func startNewSession(_ request: AgentRunRequest,
                                 provisioningCallback: (@Sendable (AgentRunEvent) -> Void)? = nil) throws -> Session {
        let bridgeScriptPath = try resolvedBridgeScriptPath(onProgress: provisioningCallback)
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
        let session = Session(threadId: request.threadId,
                              process: process,
                              stdinPipe: stdinPipe,
                              stdoutPipe: stdoutPipe,
                              stderrPipe: stderrPipe,
                              model: request.model,
                              permissionMode: request.permissionMode,
                              interactionMode: request.interactionMode,
                              providerThreadId: effectiveProviderThreadId)
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
        try write(configurePayload(for: request), to: session)
        return session
    }

    private func resolvedBridgeScriptPath(onProgress: (@Sendable (AgentRunEvent) -> Void)? = nil) throws -> String {
        let url = URL(fileURLWithPath: bridgeScriptPath)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return bridgeScriptPath
        }
        let source = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard source.contains("@anthropic-ai/claude-agent-sdk") else {
            return bridgeScriptPath
        }
        let localPackage = url.deletingLastPathComponent()
            .appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
        if FileManager.default.isReadableFile(atPath: localPackage.path) {
            return bridgeScriptPath
        }
        let cache = try sdkRuntimeCacheDirectory()
        let cachedBridge = cache.appendingPathComponent("ClaudeAgentSDKBridge.mjs")
        let cachedPackage = cache.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
        if !FileManager.default.isReadableFile(atPath: cachedBridge.path)
            || ((try? String(contentsOf: cachedBridge, encoding: .utf8)) != source) {
            try source.write(to: cachedBridge, atomically: true, encoding: .utf8)
        }
        let packageSpec = Self.sdkPackageSpec()
        if !Self.installedSDKPackage(at: cachedPackage, matches: packageSpec) {
            try installSDKPackage(in: cache, packageSpec: packageSpec, onProgress: onProgress)
        }
        return cachedBridge.path
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

    private func installSDKPackage(in directory: URL,
                                   packageSpec: String,
                                   onProgress: (@Sendable (AgentRunEvent) -> Void)? = nil) throws {
        guard let npm = ProcessLocator.resolve("npm") else {
            throw AgentRunError.missingBinary("npm")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: npm)
        process.arguments = ["install", "--no-fund", "--no-audit", packageSpec]
        process.currentDirectoryURL = directory
        process.environment = CodexRunner.processEnvironment(overrides: [:])
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        if let onProgress {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
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
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            ProcessTerminator.terminateTree(process)
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK package install timed out")
        }
        if process.terminationStatus != 0 {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            throw AgentProviderAdapterError.unsupported("Claude Agent SDK package install failed: \(text)")
        }
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

    private func configurePayload(for request: AgentRunRequest) -> [String: Any] {
        let resumeSessionAt: String?
        let providerThreadId: String?
        lock.lock()
        resumeSessionAt = rollbackResumeSessionAt.removeValue(forKey: request.threadId)
        providerThreadId = request.providerThreadId ?? rollbackProviderThreadIds.removeValue(forKey: request.threadId)
        lock.unlock()
        var payload: [String: Any] = [
            "type": "rc_configure",
            "cwd": request.cwd,
            "model": request.model,
            "permission_mode": request.permissionMode.rawValue,
            "interaction_mode": request.interactionMode.rawValue,
            "provider_thread_id": providerThreadId ?? "",
            "session_id": request.threadId.value.uuidString,
            "environment": request.environment
        ]
        if let resumeSessionAt, !resumeSessionAt.isEmpty {
            payload["resume_session_at"] = resumeSessionAt
        }
        return payload
    }

    private func effectiveProviderThreadId(for request: AgentRunRequest) -> String? {
        lock.lock(); defer { lock.unlock() }
        return request.providerThreadId ?? rollbackProviderThreadIds[request.threadId]
    }

    private func handleLine(_ line: String, session: Session) {
        let bridgeUserInputRequestId = Self.bridgeUserInputRequestId(in: line)
        if let runtimeEvent = ProviderRuntimeEvent.fromJSONLine(line, provider: .claude, source: "claude.agent-sdk") {
            let event = AssistantEvent.providerRuntime(runtimeEvent)
            record(event, session: session)
            emit(.event(event), session: session)
        }
        let parsed = session.parser.parseLine(line)
        for event in parsed {
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
            if case .userInputRequested(let request) = event {
                lock.lock()
                session.pendingUserInputIds.insert(request.id)
                if bridgeUserInputRequestId == request.id {
                    session.bridgeUserInputIds.insert(request.id)
                }
                lock.unlock()
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
                let status: AgentRunStatus = session.sawError ? .failed : .completed
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
                lock.unlock()
            }
        }
    }

    private func handleStderr(_ data: Data, session: Session) {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let event = AssistantEvent.providerRuntime(ProviderStderrClassifier.runtimeEvent(
            message: raw,
            provider: .claude,
            source: "claude.agent-sdk.stderr"
        ))
        record(event, session: session)
        emit(.event(event), session: session)
        emit(.error("[claude sdk stderr] " + raw), session: session)
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
        if sessions[session.threadId] === session { sessions.removeValue(forKey: session.threadId) }
        let shouldFinish = session.inFlightRunId != nil
        let callback = session.onEvent
        session.inFlightRunId = nil
        session.status = .cancelled
        session.onEvent = nil
        lock.unlock()
        if shouldFinish {
            callback?(.status(.cancelled))
            callback?(.finished(.cancelled, finalMessage: nil, providerThreadId: session.providerThreadId))
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

        let status: AgentRunStatus = session.sawError ? .failed : .completed
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
        lock.unlock()
    }

    private func terminate(_ session: Session) {
        try? write(["type": "rc_close"], to: session)
        settlePendingRequests(session)
        settlePendingUserInputs(session)
        session.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        session.stderrPipe.fileHandleForReading.readabilityHandler = nil
        if session.process.isRunning {
            ProcessTerminator.terminateTree(session.process)
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
        if !requestIds.isEmpty {
            emitSessionSnapshot(session: session, reason: "requests_settled")
        }
    }

    private func settlePendingUserInputs(_ session: Session) {
        lock.lock()
        let requestIds = Array(session.pendingUserInputIds)
        session.pendingUserInputIds.removeAll()
        session.bridgeUserInputIds.removeAll()
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

    private static func bridgeUserInputRequestId(in line: String) -> String? {
        guard let data = line.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "user_input_request" else {
            return nil
        }
        return obj["request_id"] as? String ?? obj["id"] as? String ?? obj["elicitation_id"] as? String
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
}
