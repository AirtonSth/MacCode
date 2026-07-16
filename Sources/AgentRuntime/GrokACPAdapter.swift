import Foundation
import CoreModel

public struct GrokACPDiscoveryResult: Sendable, Equatable {
    public let models: [AgentModelDescriptor]
    public let isFallback: Bool
    public let interactionModes: [AgentInteractionMode]
    public let permissionModes: [AgentPermissionMode]
    public let capabilities: AgentProviderCapabilities
    public let discoveryCacheKey: String

    public init(
        models: [AgentModelDescriptor],
        isFallback: Bool,
        interactionModes: [AgentInteractionMode],
        permissionModes: [AgentPermissionMode],
        capabilities: AgentProviderCapabilities,
        discoveryCacheKey: String
    ) {
        self.models = models
        self.isFallback = isFallback
        self.interactionModes = interactionModes
        self.permissionModes = permissionModes
        self.capabilities = capabilities
        self.discoveryCacheKey = discoveryCacheKey
    }
}

public final class GrokACPAdapter: AgentProviderAdapter, @unchecked Sendable {
    /// Discovery is still a provider runtime. It must enter the same durable
    /// ownership ledger as interactive Grok sessions so a host crash cannot
    /// leave it untracked.
    static let discoveryProcessOwnershipTaggingEnabled = true
    private final class NotificationBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Any?)] = []
        func append(method: String, params: Any?) { lock.lock(); items.append((method, params)); lock.unlock() }
        func drain() -> [(String, Any?)] { lock.lock(); defer { lock.unlock() }; let value = items; items.removeAll(); return value }
    }

    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let providerThreadId: String
        let client: GrokACPClient
        let capabilities: GrokACPInitializeResult
        let mapper: GrokACPEventMapper
        var model: String
        let availableModeIDs: Set<String>
        let planModeID: String?
        var mode: String?
        var status: AgentRunStatus = .completed
        var inFlight = false
        var cancelRequested = false
        var forcedKillByUs = false
        var turnTerminalEmitted = false
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var history: [AssistantEvent] = []
        var pendingPermissions: [String: PendingPermission] = [:]

        init(
            threadId: AgentThreadID,
            providerThreadId: String,
            client: GrokACPClient,
            capabilities: GrokACPInitializeResult,
            mapper: GrokACPEventMapper,
            model: String,
            availableModeIDs: Set<String>,
            planModeID: String?,
            mode: String?,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) {
            self.threadId = threadId
            self.providerThreadId = providerThreadId
            self.client = client
            self.capabilities = capabilities
            self.mapper = mapper
            self.model = model
            self.availableModeIDs = availableModeIDs
            self.planModeID = planModeID
            self.mode = mode
            self.onEvent = onEvent
        }
    }

    private struct PendingPermission {
        let request: GrokACPPermissionRequest
        let continuation: CheckedContinuation<Any?, Error>
    }

    public let provider: AgentProvider = .grok
    private let binaryNameOverride: String?
    private let cancellationGracePeriod: TimeInterval
    private let discoveryCwd: String
    private let discoveryEnvironment: [String: String]
    private let modelCacheTTL: TimeInterval
    private let lock = NSLock()
    private static let discoveryCacheLock = NSLock()
    private static var sharedDiscoveryCache: [String: (result: GrokACPDiscoveryResult, fetchedAt: Date)] = [:]
    private var sessions: [AgentThreadID: Session] = [:]

    public init(
        binaryNameOverride: String? = nil,
        cancellationGracePeriod: TimeInterval = 2,
        discoveryCwd: String = FileManager.default.temporaryDirectory.path,
        discoveryEnvironment: [String: String] = [:],
        modelCacheTTL: TimeInterval = 300
    ) {
        self.binaryNameOverride = binaryNameOverride
        self.cancellationGracePeriod = max(0.01, cancellationGracePeriod)
        self.discoveryCwd = discoveryCwd
        self.discoveryEnvironment = discoveryEnvironment
        self.modelCacheTTL = max(0, modelCacheTTL)
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await listModelsResult().models
    }

    public func listModelsResult() async -> ModelListResult {
        let discovery = await discoveryResult()
        return ModelListResult(models: discovery.models, isFallback: discovery.isFallback)
    }

    public func discoveryResult() async -> GrokACPDiscoveryResult {
        let now = Date()
        let cacheKey = Self.discoveryCacheKey(
            binary: binaryNameOverride ?? "grok",
            cwd: discoveryCwd,
            environment: discoveryEnvironment
        )
        if let cached = Self.cachedDiscovery(for: cacheKey),
           now.timeIntervalSince(cached.fetchedAt) < modelCacheTTL {
            return cached.result
        }
        let result: GrokACPDiscoveryResult
        do {
            let client = try GrokACPClient(
                binary: binaryNameOverride ?? "grok",
                cwd: discoveryCwd,
                environment: discoveryEnvironment,
                tagProcess: Self.discoveryProcessOwnershipTaggingEnabled
            )
            defer { client.stop() }
            let initialized = try await client.initialize()
            let opened = try await client.newSession(cwd: discoveryCwd)
            let discovered = initialized.models.isEmpty ? opened.models : initialized.models
            let modeIDs = Set(opened.availableModes.map(\.id))
            // Live Grok 0.2.x often omits `modes.availableModes` from session/new
            // while still accepting session/set_mode for the CLI wire IDs
            // (default / acceptEdits / bypassPermissions / plan). When modes are
            // advertised, only expose the negotiated subset.
            let interactionModes: [AgentInteractionMode]
            if modeIDs.isEmpty {
                interactionModes = [.default]
            } else {
                interactionModes = opened.planModeId != nil ? [.default, .plan] : [.default]
            }
            let permissionModes = Self.permissionModes(from: modeIDs)
            var attachmentKinds: [AgentAttachmentKind] = []
            if initialized.embeddedContext { attachmentKinds.append(.file) }
            if initialized.image { attachmentKinds.append(.image) }
            var mediaTypes = initialized.embeddedContext
                ? ["text/plain", "text/markdown", "application/json"]
                : []
            if initialized.image {
                mediaTypes.append(contentsOf: ["image/jpeg", "image/png", "image/gif", "image/webp"])
            }
            let capabilities = AgentProviderCapabilities(
                supportsAttachments: !attachmentKinds.isEmpty,
                supportedAttachmentKinds: attachmentKinds,
                supportedAttachmentMediaTypes: mediaTypes,
                supportsApprovals: true,
                supportsUserInput: false,
                supportsStreaming: true,
                supportsFork: false,
                supportsRollback: false,
                supportsPlanReview: interactionModes.contains(.plan)
            )
            result = discovered.isEmpty
                ? GrokACPDiscoveryResult(
                    models: GrokRunner.listModels(installedVersion: nil),
                    isFallback: true,
                    interactionModes: [.default],
                    permissionModes: Self.defaultPermissionModes,
                    capabilities: .conservative,
                    discoveryCacheKey: cacheKey
                )
                : GrokACPDiscoveryResult(
                    models: discovered,
                    isFallback: false,
                    interactionModes: interactionModes,
                    permissionModes: permissionModes,
                    capabilities: capabilities,
                    discoveryCacheKey: cacheKey
                )
        } catch {
            result = GrokACPDiscoveryResult(
                models: GrokRunner.listModels(installedVersion: nil),
                isFallback: true,
                interactionModes: [.default],
                permissionModes: Self.defaultPermissionModes,
                capabilities: .conservative,
                discoveryCacheKey: cacheKey
            )
        }
        Self.storeDiscovery(result, for: cacheKey, fetchedAt: now, ttl: modelCacheTTL)
        return result
    }

    /// Opaque identity for one binary/account configuration. File metadata makes
    /// an in-place CLI update invalidate a still-live adapter's discovery cache;
    /// hashing prevents HOME or account-scoped environment values from leaking.
    nonisolated static func discoveryCacheKey(
        binary: String,
        cwd: String,
        environment: [String: String]
    ) -> String {
        let resolvedBinary = ProcessLocator.resolve(binary) ?? binary
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedBinary)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let environmentKeys = environment.keys.sorted().joined(separator: "\u{1f}")
        let accountSelectors = ["HOME", "GROK_HOME", "REMOTE_CODE_INSTANCE"]
            .map { "\($0)=\(environment[$0] ?? "")" }
            .joined(separator: "\u{1f}")
        let input = "grok-acp-v1\u{1e}\(resolvedBinary)\u{1e}\(size)\u{1e}\(modified)\u{1e}\(cwd)\u{1e}\(environmentKeys)\u{1e}\(accountSelectors)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "grok-acp-v1-%016llx", hash)
    }

    private static func cachedDiscovery(for key: String) -> (result: GrokACPDiscoveryResult, fetchedAt: Date)? {
        discoveryCacheLock.lock()
        defer { discoveryCacheLock.unlock() }
        return sharedDiscoveryCache[key]
    }

    private static func storeDiscovery(
        _ result: GrokACPDiscoveryResult,
        for key: String,
        fetchedAt: Date,
        ttl: TimeInterval
    ) {
        discoveryCacheLock.lock()
        defer { discoveryCacheLock.unlock() }
        sharedDiscoveryCache = sharedDiscoveryCache.filter {
            fetchedAt.timeIntervalSince($0.value.fetchedAt) < max(ttl, 1)
        }
        sharedDiscoveryCache[key] = (result, fetchedAt)
    }

    public func startSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        try await openSession(request, loadExisting: false, onEvent: onEvent, startPrompt: true)
    }

    public func sendTurn(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws -> AgentRunHandle {
        let existing = synchronized { sessions[request.threadId] }
        guard let existing else {
            return try await openSession(
                request,
                loadExisting: request.providerThreadId?.isEmpty == false,
                onEvent: onEvent,
                startPrompt: true
            )
        }
        try await startPrompt(request, session: existing, onEvent: onEvent)
        return handle(for: request.runId, session: existing)
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock()
        guard let session = sessions[threadId] else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let shouldCancel = session.inFlight && !session.cancelRequested
        if shouldCancel { session.cancelRequested = true }
        lock.unlock()
        guard shouldCancel else { return }
        do { try session.client.cancel(sessionId: session.providerThreadId) }
        catch {
            let failure = GrokACPFailureTaxonomy.normalize(error, context: .turn)
            finishTransportFailure(session: session, error: failure, forced: false)
            throw failure
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + cancellationGracePeriod) { [weak self, weak session] in
            guard let self, let session else { return }
            self.lock.lock()
            let force = session.inFlight && !session.turnTerminalEmitted
            if force { session.forcedKillByUs = true }
            self.lock.unlock()
            if force { session.client.stop() }
        }
    }

    public func respondToRequest(
        threadId: AgentThreadID,
        requestId: String,
        response: AgentProviderRequestResponse
    ) async throws {
        let (session, pending): (Session, PendingPermission) = try synchronized {
            guard let session = sessions[threadId] else {
                throw AgentProviderAdapterError.sessionNotFound(threadId)
            }
            guard let pending = session.pendingPermissions.removeValue(forKey: requestId) else {
                throw AgentProviderAdapterError.unsupported("Grok ACP permission request not found: \(requestId)")
            }
            return (session, pending)
        }

        let result: [String: Any]
        let state: AssistantRequestState
        if case .cancel = response {
            result = ["outcome": ["outcome": "cancelled"]]
            state = .cancelled
        } else if let optionId = pending.request.optionId(for: response) {
            result = ["outcome": ["outcome": "selected", "optionId": optionId]]
            switch response {
            case .approve, .approveForSession: state = .approved
            case .decline: state = .declined
            case .cancel: state = .cancelled
            }
        } else {
            pending.continuation.resume(throwing: AgentProviderAdapterError.unsupported("Grok ACP permission option unavailable for response"))
            throw AgentProviderAdapterError.unsupported("Grok ACP permission option unavailable for response")
        }
        emit(.requestResolved(requestId: requestId, state: state), session: session)
        pending.continuation.resume(returning: result)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("Grok ACP 0.2.101 does not negotiate user-input elicitation")
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        guard let session = sessions.removeValue(forKey: threadId) else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        let pending = Array(session.pendingPermissions.values)
        session.pendingPermissions.removeAll()
        lock.unlock()
        for request in pending {
            request.continuation.resume(throwing: AgentProviderAdapterError.sessionNotFound(threadId))
        }
        if session.inFlight { try? session.client.cancel(sessionId: session.providerThreadId) }
        session.client.stop()
    }

    public func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Grok ACP recovery requires providerThreadId")
        }
        _ = try await openSession(request, loadExisting: true, onEvent: onEvent, startPrompt: false)
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map {
            AgentProviderSessionSummary(
                threadId: $0.threadId,
                provider: .grok,
                status: $0.status,
                providerThreadId: $0.providerThreadId
            )
        }
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        try synchronized {
            guard let session = sessions[threadId] else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
            return session.history
        }
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        throw AgentProviderAdapterError.unsupported("Grok ACP 0.2.101 does not negotiate rollback")
    }

    public func stopAll() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.client.stop() }
    }

    public func stopAllForAppTermination() {
        lock.lock()
        let all = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.client.stopImmediatelyForAppTermination() }
    }

    public func streamEvents(
        threadId: AgentThreadID,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard let session = sessions[threadId] else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        session.onEvent = onEvent
    }

    private func openSession(
        _ request: AgentRunRequest,
        loadExisting: Bool,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void,
        startPrompt shouldStartPrompt: Bool
    ) async throws -> AgentRunHandle {
        let binary = request.providerBinary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? request.providerBinary!
            : (binaryNameOverride ?? "grok")
        let bufferedNotifications = NotificationBuffer()
        let client: GrokACPClient
        do {
            client = try GrokACPClient(
                binary: binary,
                cwd: request.cwd,
                environment: request.environment,
                notificationHandler: { method, params in
                    bufferedNotifications.append(method: method, params: params)
                }
            )
        } catch {
            throw GrokACPFailureTaxonomy.normalize(
                error,
                context: loadExisting ? .resume : .start
            )
        }
        do {
            let capabilities = try await client.initialize()
            let opened: GrokACPSessionOpenResult
            if loadExisting {
                guard capabilities.loadSession, let providerThreadId = request.providerThreadId, !providerThreadId.isEmpty else {
                    throw AgentProviderAdapterError.unsupported("Grok ACP session/load is not negotiated")
                }
                opened = try await client.loadSession(sessionId: providerThreadId, cwd: request.cwd)
            } else {
                opened = try await client.newSession(cwd: request.cwd)
            }
            let mapper = GrokACPEventMapper(sessionId: opened.sessionId)
            let session = Session(
                threadId: request.threadId,
                providerThreadId: opened.sessionId,
                client: client,
                capabilities: capabilities,
                mapper: mapper,
                model: opened.currentModelId ?? request.model,
                availableModeIDs: Set(opened.availableModes.map(\.id)),
                planModeID: opened.planModeId,
                mode: opened.currentModeId,
                onEvent: onEvent
            )
            client.notificationHandler = { [weak self, weak session] method, params in
                guard let self, let session else { return }
                self.handleNotification(method: method, params: params, session: session)
            }
            client.serverRequestHandler = { [weak self, weak session] id, method, params in
                guard let self, let session else { throw AgentProviderAdapterError.unsupported("Grok ACP adapter released") }
                return try await self.handleServerRequest(id: id, method: method, params: params, session: session)
            }
            client.terminationHandler = { [weak self, weak session] reason, status, error in
                guard let self, let session else { return }
                self.handleTermination(session: session, reason: reason, status: status, error: error)
            }
            let replaced = synchronized { sessions.updateValue(session, forKey: request.threadId) }
            replaced?.client.stop()
            for (method, params) in bufferedNotifications.drain() {
                handleNotification(method: method, params: params, session: session)
            }
            if shouldStartPrompt {
                try await startPrompt(request, session: session, onEvent: onEvent)
            } else {
                session.status = .completed
            }
            return handle(for: request.runId, session: session)
        } catch {
            synchronized {
                if sessions[request.threadId]?.client === client {
                    sessions.removeValue(forKey: request.threadId)
                }
            }
            client.stop()
            if error is AgentProviderAdapterError { throw error }
            throw GrokACPFailureTaxonomy.normalize(
                error,
                context: loadExisting ? .resume : .start
            )
        }
    }

    private func startPrompt(
        _ request: AgentRunRequest,
        session: Session,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {
        try synchronized {
            guard !session.inFlight else {
                throw AgentProviderAdapterError.unsupported("Grok ACP session already has an in-flight prompt")
            }
            session.inFlight = true
            session.cancelRequested = false
            session.forcedKillByUs = false
            session.turnTerminalEmitted = false
            session.status = .running
            session.onEvent = onEvent
        }

        do {
            let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if !model.isEmpty, model != session.model {
                try await session.client.setModel(sessionId: session.providerThreadId, modelId: model)
                synchronized { session.model = model }
            }
            let requestedMode: String?
            if request.interactionMode == .plan {
                guard let planModeID = session.planModeID else {
                    throw AgentProviderAdapterError.unsupported("Grok ACP did not advertise Plan mode for this session")
                }
                requestedMode = planModeID
            } else {
                requestedMode = try Self.resolvedPermissionModeID(
                    for: request.permissionMode,
                    availableModeIDs: session.availableModeIDs
                )
            }
            if let requestedMode, requestedMode != session.mode {
                try await session.client.setMode(sessionId: session.providerThreadId, modeId: requestedMode)
                synchronized { session.mode = requestedMode }
            }
            for event in session.mapper.beginTurn() { emit(event, session: session) }
            onEvent(.status(.running))
            Task { [weak self, weak session] in
                guard let self, let session else { return }
                do {
                    let response = try await session.client.prompt(
                        sessionId: session.providerThreadId,
                        request: request,
                        capabilities: session.capabilities
                    )
                    self.handlePromptResponse(response, session: session)
                } catch {
                    self.finishTransportFailure(session: session, error: error, forced: false)
                }
            }
        } catch {
            synchronized { session.inFlight = false }
            if error is AgentProviderAdapterError { throw error }
            throw GrokACPFailureTaxonomy.normalize(error, context: .turn)
        }
    }

    private func handleNotification(method: String, params: Any?, session: Session) {
        guard method == "session/update",
              let params = params as? [String: Any],
              params["sessionId"] as? String == session.providerThreadId,
              let update = params["update"] as? [String: Any] else {
            if method.hasPrefix("_x.ai/") { emit(Self.runtimeEvent(method: method, payload: params), session: session) }
            return
        }
        for event in session.mapper.consumeSessionUpdate(update) { emit(event, session: session) }
    }

    private func handleServerRequest(
        id: GrokACPRequestID,
        method: String,
        params: Any?,
        session: Session
    ) async throws -> Any? {
        guard method == "session/request_permission" else {
            throw AgentProviderAdapterError.unsupported("Unhandled Grok ACP request: \(method)")
        }
        let request = try GrokACPPermissionRequest.parse(id: id, params: params)
        guard request.sessionId == session.providerThreadId else {
            throw AgentProviderAdapterError.unsupported("Grok ACP permission session mismatch")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let key = id.stringValue
            let turnId = synchronized { () -> String? in
                session.pendingPermissions[key] = PendingPermission(request: request, continuation: continuation)
                return session.history.compactMap { if case .turnStarted(let id) = $0 { return id }; return nil }.last
            }
            emit(.requestOpened(AssistantPendingRequest(
                id: key,
                turnId: turnId,
                kind: .dynamic,
                title: request.title,
                detail: request.detail,
                createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                supportsSessionApproval: request.options.contains { $0.kind == "allow_always" }
            )), session: session)
        }
    }

    private func handlePromptResponse(_ response: [String: Any], session: Session) {
        let stopReason = response["stopReason"] as? String ?? "failed"
        let metadata = response["_meta"] as? [String: Any]
        let usage = metadata?["usage"] as? [String: Any]
        for event in session.mapper.finishTurn(stopReason: stopReason, usage: usage) { emit(event, session: session) }
        let status: AgentRunStatus
        switch stopReason {
        case "end_turn": status = .completed
        case "cancelled": status = .cancelled
        default: status = .failed
        }
        if status == .failed {
            session.onEvent?(.error(GrokACPFailureTaxonomy.normalize(
                diagnostic: "Grok ACP stopped: \(stopReason)",
                context: .turn
            ).message))
        }
        finishTurn(session: session, status: status)
    }

    private func handleTermination(
        session: Session,
        reason: Process.TerminationReason,
        status: Int32,
        error: Error
    ) {
        lock.lock()
        let active = session.inFlight && !session.turnTerminalEmitted
        let forced = session.forcedKillByUs
        let cancelled = session.cancelRequested
        lock.unlock()
        guard active else { return }
        let terminal = GrokACPTerminalClassifier.status(
            promptResolved: false,
            cancelRequested: cancelled,
            forcedKillByUs: forced,
            terminationReason: reason,
            exitStatus: status
        )
        if terminal == .failed {
            session.onEvent?(.error(GrokACPFailureTaxonomy.normalize(error, context: .turn).message))
        }
        for event in session.mapper.finishTurn(stopReason: terminal == .cancelled ? "cancelled" : "failed", usage: nil) {
            emit(event, session: session)
        }
        finishTurn(session: session, status: terminal)
    }

    private func finishTransportFailure(session: Session, error: Error, forced: Bool) {
        if forced { lock.lock(); session.forcedKillByUs = true; lock.unlock() }
        lock.lock()
        let terminal = session.cancelRequested && session.forcedKillByUs ? AgentRunStatus.cancelled : .failed
        let active = session.inFlight && !session.turnTerminalEmitted
        lock.unlock()
        guard active else { return }
        if terminal == .failed {
            session.onEvent?(.error(GrokACPFailureTaxonomy.normalize(error, context: .turn).message))
        }
        for event in session.mapper.finishTurn(stopReason: terminal == .cancelled ? "cancelled" : "failed", usage: nil) {
            emit(event, session: session)
        }
        finishTurn(session: session, status: terminal)
    }

    private func finishTurn(session: Session, status: AgentRunStatus) {
        lock.lock()
        guard !session.turnTerminalEmitted else { lock.unlock(); return }
        session.turnTerminalEmitted = true
        session.inFlight = false
        session.status = status
        let callback = session.onEvent
        let final = session.mapper.finalAssistantMessage
        let providerThreadId = session.providerThreadId
        let pending = Array(session.pendingPermissions.values)
        session.pendingPermissions.removeAll()
        lock.unlock()
        for request in pending {
            request.continuation.resume(throwing: AgentProviderAdapterError.unsupported("Grok ACP turn ended before permission response"))
        }
        callback?(.status(status))
        callback?(.finished(status, finalMessage: final, providerThreadId: providerThreadId))
    }

    private func emit(_ event: AssistantEvent, session: Session) {
        lock.lock()
        session.history.append(event)
        let callback = session.onEvent
        lock.unlock()
        callback?(.event(event))
    }

    private func handle(for runId: AgentRunID, session: Session) -> AgentRunHandle {
        AgentRunHandle(runId: runId, process: session.client.runningProcess) { [weak self, weak session] in
            guard let self, let session else { return }
            try? self.interruptTurn(threadId: session.threadId)
        }
    }

    /// CLI/ACP wire values accepted by Grok Build (`--permission-mode` / session/set_mode).
    static let defaultPermissionModes: [AgentPermissionMode] = AgentPermissionMode.allCases

    private static func mode(for permission: AgentPermissionMode) -> String {
        switch permission {
        case .supervised: return "default"
        case .autoAcceptEdits: return "acceptEdits"
        case .fullAccess: return "bypassPermissions"
        }
    }

    /// Map advertised ACP mode IDs to RemoteCode permission modes.
    /// Empty advertisement (live Grok 0.2.x) means the known CLI set is usable.
    static func permissionModes(from availableModeIDs: Set<String>) -> [AgentPermissionMode] {
        if availableModeIDs.isEmpty {
            return defaultPermissionModes
        }
        var modes: [AgentPermissionMode] = [.supervised]
        if availableModeIDs.contains(mode(for: .autoAcceptEdits)) {
            modes.append(.autoAcceptEdits)
        }
        if availableModeIDs.contains(mode(for: .fullAccess)) {
            modes.append(.fullAccess)
        }
        return modes
    }

    /// Resolve a permission mode to an ACP mode ID for session/set_mode.
    /// When the session omits availableModes, still apply the known wire ID —
    /// live Grok accepts set_mode without advertising the catalog.
    static func resolvedPermissionModeID(
        for permission: AgentPermissionMode,
        availableModeIDs: Set<String>
    ) throws -> String? {
        let wireID = mode(for: permission)
        if availableModeIDs.isEmpty {
            return wireID
        }
        if availableModeIDs.contains(wireID) {
            return wireID
        }
        if permission == .supervised {
            return nil
        }
        throw AgentProviderAdapterError.unsupported(
            "Grok ACP did not advertise the \(permission.rawValue) permission mode for this session"
        )
    }

    private static func runtimeEvent(method: String, payload: Any?) -> AssistantEvent {
        let object = payload as? [String: Any] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .grok,
            source: "grok.acp",
            method: method,
            payloadJSON: String(data: data, encoding: .utf8) ?? "{}",
            receivedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
