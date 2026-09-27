import Foundation
import CoreModel
import os

private let distillAcpLog = Logger(subsystem: "io.remotecode.agent", category: "distill.acp")

public struct DistillACPDiscoveryResult: Sendable, Equatable {
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

/// Bounded pull-history for Distill ACP sessions. The public read window matches
/// AgentRunCoordinator while a small high-water slack amortizes storage compaction.
struct DistillACPHistoryRetention: Sendable {
    static let eventPruneSlack = 1_024
    static let bytePruneSlack: Int64 = 1_024 * 1_024

    private var storage: [AssistantEvent] = []
    private var storageBytes: [Int64] = []
    private var startIndex = 0
    private var discardedBytes: Int64 = 0
    private var estimatedBytes: Int64 = 0
    private let eventLimit: Int
    private let byteLimit: Int64
    private let eventSlack: Int
    private let byteSlack: Int64

    init(
        eventLimit: Int = AgentRunCoordinator.hotReplayEventCount,
        byteLimit: Int64 = AgentRunCoordinator.hotReplayEventBytes,
        eventSlack: Int = eventPruneSlack,
        byteSlack: Int64 = bytePruneSlack
    ) {
        self.eventLimit = max(1, eventLimit)
        self.byteLimit = max(1, byteLimit)
        self.eventSlack = max(0, eventSlack)
        self.byteSlack = max(0, byteSlack)
        storage.reserveCapacity(self.eventLimit + self.eventSlack + 1)
        storageBytes.reserveCapacity(self.eventLimit + self.eventSlack + 1)
    }

    var readableEvents: [AssistantEvent] {
        Array(storage[startIndex...])
    }

    var retainedEventCount: Int { storage.count - startIndex }
    var bufferedEventCount: Int { storage.count }
    var bufferedEstimatedBytes: Int64 { estimatedBytes + discardedBytes }

    mutating func append(_ event: AssistantEvent) {
        let eventBytes = Int64(max(1, event.estimatedHotQueueBytes))
        // Match boundedHotReplay: a frame larger than the whole window cannot
        // fit alone and must not evict a valid recent tail.
        guard eventBytes <= byteLimit else { return }
        storage.append(event)
        storageBytes.append(eventBytes)
        estimatedBytes += eventBytes
        evictIfNeeded()
    }

    mutating func append(contentsOf newEvents: [AssistantEvent]) {
        for event in newEvents { append(event) }
    }

    private mutating func evictIfNeeded() {
        while retainedEventCount > eventLimit || estimatedBytes > byteLimit {
            let evictedBytes = storageBytes[startIndex]
            estimatedBytes -= evictedBytes
            discardedBytes += evictedBytes
            startIndex += 1
        }
        let crossedEventSlack = eventSlack == 0 ? startIndex > 0 : startIndex > eventSlack
        let crossedByteSlack = byteSlack == 0 ? discardedBytes > 0 : discardedBytes > byteSlack
        guard crossedEventSlack || crossedByteSlack else { return }
        storage.removeFirst(startIndex)
        storageBytes.removeFirst(startIndex)
        startIndex = 0
        discardedBytes = 0
    }
}

public final class DistillACPAdapter: AgentProviderAdapter, @unchecked Sendable {
    /// Discovery is still a provider runtime. It must enter the same durable
    /// ownership ledger as interactive distill sessions so a host crash cannot
    /// leave it untracked.
    static let discoveryProcessOwnershipTaggingEnabled = true
    private final class NotificationBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, Any?)] = []
        func append(method: String, params: Any?) { lock.lock(); items.append((method, params)); lock.unlock() }
        func drain() -> [(String, Any?)] { lock.lock(); defer { lock.unlock() }; let value = items; items.removeAll(); return value }
    }

    private final class PromptAcceptanceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var settled = false

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.withLock { self.continuation = continuation }
        }

        func settle(_ result: Result<Void, Error>) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard !settled else { return nil }
                settled = true
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }
    }

    private final class Session: @unchecked Sendable {
        let threadId: AgentThreadID
        let providerThreadId: String
        let client: DistillACPClient
        let capabilities: DistillACPInitializeResult
        let mapper: DistillACPEventMapper
        var model: String
        /// Last effort bound via set_config_option or set_model `_meta.reasoningEffort`.
        var reasoningEffort: AgentReasoningEffort?
        var reasoningModel: String?
        /// True when open advertised a selectable `reasoning_effort` config option.
        let advertisesReasoningEffortConfig: Bool
        /// Thought-level ids from the open-result config option (and live model catalog).
        let advertisedEfforts: [AgentReasoningEffort]
        let availableModeIDs: Set<String>
        let planModeID: String?
        var mode: String?
        var status: AgentRunStatus = .completed
        var isLive = true
        var inFlight = false
        var promptAccepted = false
        var cancelRequested = false
        var forcedKillByUs = false
        var turnTerminalEmitted = false
        /// Bumped on every `session/prompt` start so a late RPC result cannot
        /// finish a newer turn after the inactivity watchdog already closed the
        /// previous one (or the user started a follow-up).
        var promptGeneration: UInt64 = 0
        var turnWatchdog: DispatchWorkItem?
        /// Force-kill armed for a specific `promptGeneration`. Cancelled when a
        /// newer generation starts so N's timer cannot kill N+1.
        var forceKillWorkItem: DispatchWorkItem?
        /// True while `fireTurnInactivityWatchdog` is synthesizing a terminal.
        /// Blocks emit→refresh→fire re-entry: finishTurn/emit used to re-arm the
        /// inactivity timer mid-synthesis and recurse until SIGBUS (stack guard).
        var turnWatchdogSynthesisInProgress = false
        var promptWritePermit = AgentRunAcceptancePermit()
        var onEvent: (@Sendable (AgentRunEvent) -> Void)?
        var history: DistillACPHistoryRetention
        var pendingPermissions: [String: PendingPermission] = [:]

        init(
            threadId: AgentThreadID,
            providerThreadId: String,
            client: DistillACPClient,
            capabilities: DistillACPInitializeResult,
            mapper: DistillACPEventMapper,
            model: String,
            reasoningEffort: AgentReasoningEffort? = nil,
            reasoningModel: String? = nil,
            advertisesReasoningEffortConfig: Bool = false,
            advertisedEfforts: [AgentReasoningEffort] = [],
            availableModeIDs: Set<String>,
            planModeID: String?,
            mode: String?,
            maxReadableEvents: Int,
            maxReadableBytes: Int64,
            onEvent: @escaping @Sendable (AgentRunEvent) -> Void
        ) {
            self.threadId = threadId
            self.providerThreadId = providerThreadId
            self.client = client
            self.capabilities = capabilities
            self.mapper = mapper
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.reasoningModel = reasoningModel
            self.advertisesReasoningEffortConfig = advertisesReasoningEffortConfig
            self.advertisedEfforts = advertisedEfforts
            self.availableModeIDs = availableModeIDs
            self.planModeID = planModeID
            self.mode = mode
            self.history = DistillACPHistoryRetention(
                eventLimit: maxReadableEvents,
                byteLimit: maxReadableBytes
            )
            self.onEvent = onEvent
        }
    }

    private struct PendingPermission {
        let request: DistillACPPermissionRequest
        let continuation: CheckedContinuation<Any?, Error>
    }

    public let provider: AgentProvider = .distill
    private let binaryNameOverride: String?
    private let discoveryRunAsUser: AgentRunAsUser?
    private let cancellationGracePeriod: TimeInterval
    /// Inactivity bound while a prompt is in flight. Re-armed on every emitted
    /// turn event (tools, stream deltas). When `session/prompt` never returns
    /// after the model has finished streaming *and* events stop, this
    /// synthesizes the terminal so Working cannot stick forever (field: 70m
    /// distill zombie with full **COMPLETE** final). There is intentionally **no**
    /// absolute wall-clock max: long goals with continuous tool progress must
    /// not be cut mid-work (field: 15m false `completed` on starsac CI goal).
    private let turnInactivityTimeout: TimeInterval
    private let discoveryCwd: String
    private let discoveryEnvironment: [String: String]
    private let modelCacheTTL: TimeInterval
    private let maxReadableEvents: Int
    private let maxReadableBytes: Int64
    private let lock = NSLock()
    private static let discoveryCacheLock = NSLock()
    private static var sharedDiscoveryCache: [String: (result: DistillACPDiscoveryResult, fetchedAt: Date)] = [:]
    private var sessions: [AgentThreadID: Session] = [:]
    private var promptWriteAcceptanceCountForTestingStorage = 0
    var beforePromptWriteForTesting: (() -> Void)?
    var beforePhysicalPromptWriteForTesting: (() -> Void)?
    var afterPromptWriteForTesting: (() -> Void)?
    /// Runs on the cancel-write queue before `session/cancel`. Tests block here
    /// without stalling `interruptTurn`.
    var beforeCancelWriteForTesting: (() -> Void)?
    /// When set, the ACP cancel write is skipped and treated as a diagnostic
    /// failure. Teardown stays armed and the terminal stays cancelled.
    var cancelWriteErrorForTesting: Error?
    private var cancelWriteAttemptCountForTestingStorage = 0
    var cancelWriteAttemptCountForTesting: Int {
        synchronized { cancelWriteAttemptCountForTestingStorage }
    }
    var promptWriteAcceptanceCountForTesting: Int {
        synchronized { promptWriteAcceptanceCountForTestingStorage }
    }

    public init(
        binaryNameOverride: String? = nil,
        cancellationGracePeriod: TimeInterval = 2,
        turnInactivityTimeout: TimeInterval = 900,
        discoveryCwd: String = FileManager.default.temporaryDirectory.path,
        discoveryEnvironment: [String: String] = [:],
        discoveryRunAsUser: AgentRunAsUser? = nil,
        modelCacheTTL: TimeInterval = 300,
        maxReadableEvents: Int = AgentRunCoordinator.hotReplayEventCount,
        maxReadableBytes: Int64 = AgentRunCoordinator.hotReplayEventBytes
    ) {
        self.binaryNameOverride = binaryNameOverride
        self.cancellationGracePeriod = max(0.01, cancellationGracePeriod)
        self.turnInactivityTimeout = max(0.01, turnInactivityTimeout)
        self.discoveryCwd = discoveryCwd
        self.discoveryEnvironment = discoveryEnvironment
        self.discoveryRunAsUser = discoveryRunAsUser
        self.modelCacheTTL = max(0, modelCacheTTL)
        self.maxReadableEvents = max(1, maxReadableEvents)
        self.maxReadableBytes = max(1, maxReadableBytes)
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await listModelsResult().models
    }

    public func listModelsResult() async -> ModelListResult {
        let discovery = await discoveryResult()
        return ModelListResult(models: discovery.models, isFallback: discovery.isFallback)
    }

    public func discoveryResult() async -> DistillACPDiscoveryResult {
        let now = Date()
        let cacheKey = Self.discoveryCacheKey(
            binary: binaryNameOverride ?? DistillProvisioner.binaryName,
            cwd: discoveryCwd,
            environment: discoveryEnvironment
        )
        if let cached = Self.cachedDiscovery(for: cacheKey),
           now.timeIntervalSince(cached.fetchedAt) < modelCacheTTL {
            return cached.result
        }
        let result: DistillACPDiscoveryResult
        do {
            let client = try DistillACPClient(
                binary: binaryNameOverride ?? DistillProvisioner.binaryName,
                cwd: discoveryCwd,
                environment: discoveryEnvironment,
                runAsUser: discoveryRunAsUser,
                tagProcess: Self.discoveryProcessOwnershipTaggingEnabled
            )
            defer { client.stop() }
            let initialized = try await client.initialize()
            let opened = try await client.newSession(cwd: discoveryCwd)
            let discovered = Self.mergeModelCatalogs(initialized.models, opened.models)
            let modeIDs = Set(opened.availableModes.map(\.id))
            // Live distill builds often omit `modes.availableModes` from session/new
            // while still accepting session/set_mode for the CLI wire IDs
            // (default / acceptEdits / bypassPermissions / plan). Live canary
            // confirms set_mode plan succeeds when the catalog is omitted.
            // Empty catalog → open Plan (same pattern as permission modes).
            // When modes ARE advertised, only expose the negotiated subset
            // (fail-closed for Plan if plan is absent from the catalog).
            let interactionModes = Self.interactionModes(
                availableModeIDs: modeIDs,
                advertisedPlanModeID: opened.planModeId
            )
            let permissionModes = Self.permissionModes(from: modeIDs)
            // Attachment kinds for iOS/macOS pickers.
            // distill reports promptCapabilities.image=false while still accepting
            // type=image blocks (live semantic canary). Advertise the effective
            // capability so Camera/Photos are not marked Unavailable on the mirror.
            var attachmentKinds: [AgentAttachmentKind] = []
            if initialized.embeddedContext { attachmentKinds.append(.file) }
            let imageEnabled = DistillACPImageCompatibility.effectiveImageEnabled(
                advertised: initialized.image,
                agentVersion: initialized.agentVersion
            )
            if imageEnabled { attachmentKinds.append(.image) }
            var mediaTypes = initialized.embeddedContext
                ? ["text/plain", "text/markdown", "application/json"]
                : []
            if imageEnabled {
                mediaTypes.append(contentsOf: DistillACPImageCompatibility.supportedImageMediaTypes)
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
                ? DistillACPDiscoveryResult(
                    models: DistillRunner.listModels(installedVersion: nil),
                    isFallback: true,
                    interactionModes: [.default],
                    permissionModes: Self.defaultPermissionModes,
                    capabilities: .conservative,
                    discoveryCacheKey: cacheKey
                )
                : DistillACPDiscoveryResult(
                    models: discovered,
                    isFallback: false,
                    interactionModes: interactionModes,
                    permissionModes: permissionModes,
                    capabilities: capabilities,
                    discoveryCacheKey: cacheKey
                )
        } catch {
            result = DistillACPDiscoveryResult(
                models: DistillRunner.listModels(installedVersion: nil),
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

    /// Initialization and session/new can advertise different portions of the
    /// current account catalog. Keep the union and let the later session/new
    /// response own duplicate IDs because it is the current negotiated session
    /// metadata; do not infer authority from a metadata score.
    nonisolated static func mergeModelCatalogs(_ catalogs: [AgentModelDescriptor]...) -> [AgentModelDescriptor] {
        var merged: [AgentModelDescriptor] = []
        var indexes: [String: Int] = [:]
        for catalog in catalogs {
            for model in catalog {
                guard !model.id.isEmpty else { continue }
                if let index = indexes[model.id] {
                    merged[index] = model
                } else {
                    indexes[model.id] = merged.count
                    merged.append(model)
                }
            }
        }
        return merged
    }

    /// Opaque identity for one binary/account configuration. File metadata makes
    /// an in-place CLI update invalidate a still-live adapter's discovery cache;
    /// hashing prevents HOME or account-scoped environment values from leaking.
    nonisolated static func discoveryCacheKey(
        binary: String,
        cwd: String,
        environment: [String: String]
    ) -> String {
        let resolvedBinary = ProcessLocator.resolveDistillAgent(binary) ?? binary
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedBinary)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let environmentKeys = environment.keys.sorted().joined(separator: "\u{1f}")
        let accountSelectors = ["HOME", "GROK_HOME", "REMOTE_CODE_INSTANCE"]
            .map { "\($0)=\(environment[$0] ?? "")" }
            .joined(separator: "\u{1f}")
        let input = "distill-acp-v1\u{1e}\(resolvedBinary)\u{1e}\(size)\u{1e}\(modified)\u{1e}\(cwd)\u{1e}\(environmentKeys)\u{1e}\(accountSelectors)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        // PERF: nibble table avoids String(format:) per discovery; same lowercase 16-hex.
        let hex = DistillACPAdapter.hex16(hash)
        return "distill-acp-v1-\(hex)"
    }

    private static let hexAlphabet: [UInt8] = Array("0123456789abcdef".utf8)
    private static func hex16(_ value: UInt64) -> String {
        var out: [UInt8] = Array(repeating: 0, count: 16)
        var v = value
        for i in (0..<16).reversed() {
            out[i] = hexAlphabet[Int(v & 0xf)]
            v >>= 4
        }
        return String(bytes: out, encoding: .utf8) ?? String(format: "%016llx", value)
    }

    private static func cachedDiscovery(for key: String) -> (result: DistillACPDiscoveryResult, fetchedAt: Date)? {
        discoveryCacheLock.lock()
        defer { discoveryCacheLock.unlock() }
        return sharedDiscoveryCache[key]
    }

    private static func storeDiscovery(
        _ result: DistillACPDiscoveryResult,
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
        let captured: (session: Session, generation: UInt64)? = synchronized {
            guard let session = sessions[threadId] else { return nil }
            let shouldCancel = session.inFlight && !session.cancelRequested
            guard shouldCancel else { return nil }
            session.cancelRequested = true
            let generation = session.promptGeneration
            armForceKillLocked(session: session, generation: generation)
            return (session, generation)
        }
        guard let captured else {
            if synchronized({ sessions[threadId] == nil }) {
                throw AgentProviderAdapterError.sessionNotFound(threadId)
            }
            return
        }
        enqueueCancelWrite(session: captured.session, generation: captured.generation)
    }

    private func armForceKillLocked(session: Session, generation: UInt64) {
        session.forceKillWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.forceKillIfCurrent(session: session, generation: generation)
        }
        session.forceKillWorkItem = item
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + cancellationGracePeriod,
            execute: item
        )
        distillAcpLog.info(
            "distill.cancel.force.armed thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
        )
    }

    private func enqueueCancelWrite(session: Session, generation: UInt64) {
        distillAcpLog.info(
            "distill.cancel.enqueue thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
        )
        DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
            guard let self, let session else { return }
            self.beforeCancelWriteForTesting?()
            if let injected = self.cancelWriteErrorForTesting {
                distillAcpLog.info(
                    "distill.cancel.write.failed thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public) injected=1"
                )
                _ = injected
                return
            }
            do {
                let wrote = try session.client.cancel(
                    sessionId: session.providerThreadId,
                    admittedBy: { [weak self, weak session] in
                        guard let self, let session else { return false }
                        return self.synchronized {
                            let current = self.sessions[session.threadId] === session
                                && session.promptGeneration == generation
                                && session.inFlight
                                && !session.turnTerminalEmitted
                                && session.cancelRequested
                            if current {
                                self.cancelWriteAttemptCountForTestingStorage += 1
                            }
                            return current
                        }
                    }
                )
                if !wrote {
                    distillAcpLog.info(
                        "distill.cancel.write.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
                    )
                }
            } catch {
                distillAcpLog.info(
                    "distill.cancel.write.failed thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
                )
            }
        }
    }

    private func forceKillIfCurrent(session: Session, generation: UInt64) {
        lock.lock()
        let current = sessions[session.threadId] === session
            && session.promptGeneration == generation
            && session.inFlight
            && !session.turnTerminalEmitted
            && session.cancelRequested
        if current {
            session.forcedKillByUs = true
            // Retain map identity for handleTermination's one terminal, but
            // close reuse before dropping the lock. A natural N completion in
            // the tiny interval before client.stop cannot admit N+1.
            session.isLive = false
            session.promptWritePermit.invalidate()
        }
        lock.unlock()
        guard current else {
            distillAcpLog.info(
                "distill.cancel.force.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
            return
        }
        distillAcpLog.info(
            "distill.cancel.force.kill thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
        )
        session.client.stop()
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
                throw AgentProviderAdapterError.unsupported("Distill ACP permission request not found: \(requestId)")
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
            pending.continuation.resume(throwing: AgentProviderAdapterError.unsupported("Distill ACP permission option unavailable for response"))
            throw AgentProviderAdapterError.unsupported("Distill ACP permission option unavailable for response")
        }
        emit(.requestResolved(requestId: requestId, state: state), session: session)
        pending.continuation.resume(returning: result)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("Distill ACP 0.2.101 does not negotiate user-input elicitation")
    }

    public func stopSession(threadId: AgentThreadID) throws {
        lock.lock()
        guard let session = sessions.removeValue(forKey: threadId) else {
            lock.unlock()
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        session.isLive = false
        session.promptWritePermit.invalidate()
        let pending = Array(session.pendingPermissions.values)
        session.pendingPermissions.removeAll()
        lock.unlock()
        for request in pending {
            request.continuation.resume(throwing: AgentProviderAdapterError.sessionNotFound(threadId))
        }
        // Hard teardown must never queue behind the cooperative cancel write.
        // The first Stop already enqueued session/cancel; a second Stop owns
        // transport termination and goes straight to the process tree.
        session.client.stop()
    }

    public func recoverSession(
        _ request: AgentRunRequest,
        onEvent: @escaping @Sendable (AgentRunEvent) -> Void
    ) async throws {
        guard request.providerThreadId?.isEmpty == false else {
            throw AgentProviderAdapterError.unsupported("Distill ACP recovery requires providerThreadId")
        }
        _ = try await openSession(request, loadExisting: true, onEvent: onEvent, startPrompt: false)
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.map {
            AgentProviderSessionSummary(
                threadId: $0.threadId,
                provider: .distill,
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
            return session.history.readableEvents
        }
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        throw AgentProviderAdapterError.unsupported("Distill ACP 0.2.101 does not negotiate rollback")
    }

    public func stopAll() {
        lock.lock()
        let all = Array(sessions.values)
        all.forEach {
            $0.isLive = false
            $0.promptWritePermit.invalidate()
        }
        sessions.removeAll()
        lock.unlock()
        all.forEach { $0.client.stop() }
    }

    public func stopAllForAppTermination() {
        lock.lock()
        let all = Array(sessions.values)
        all.forEach {
            $0.isLive = false
            $0.promptWritePermit.invalidate()
        }
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
            : (binaryNameOverride ?? DistillProvisioner.binaryName)
        let bufferedNotifications = NotificationBuffer()
        let client: DistillACPClient
        do {
            let launchArguments = try DistillACPClient.launchArguments(for: request)
            let isForeignUser = request.runAsUser.map { $0.uid != getuid() } == true
            let askpass = isForeignUser
                ? RunAsUserProcessBootstrap.materializeAskpass(
                    targetUser: request.runAsUser!.shortName
                )
                : nil
            client = try DistillACPClient(
                binary: binary,
                cwd: request.cwd,
                environment: request.environment,
                launchArguments: launchArguments,
                runAsUser: request.runAsUser,
                askpassPath: askpass,
                notificationHandler: { method, params in
                    bufferedNotifications.append(method: method, params: params)
                }
            )
        } catch {
            throw DistillACPFailureTaxonomy.normalize(
                error,
                context: loadExisting ? .resume : .start
            )
        }
        do {
            let capabilities = try await client.initialize()
            guard capabilities.sessionReasoningModel else {
                throw AgentProviderAdapterError.unsupported(
                    "Distill ACP does not support per-conversation Reasoning model selection"
                )
            }
            let opened: DistillACPSessionOpenResult
            if loadExisting {
                guard capabilities.loadSession, let providerThreadId = request.providerThreadId, !providerThreadId.isEmpty else {
                    throw AgentProviderAdapterError.unsupported("Distill ACP session/load is not negotiated")
                }
                // Warm reattach + prompt: skip gateway replay cost (hydrate is local-only).
                // Recover without prompt: keep full replay so readThread has history.
                opened = try await client.loadSession(
                    sessionId: providerThreadId,
                    cwd: request.cwd,
                    noReplay: shouldStartPrompt,
                    yoloMode: request.permissionMode == .fullAccess,
                    modelId: request.model,
                    reasoningEffort: request.reasoningEffort,
                    reasoningModel: request.reasoningModel
                )
            } else {
                opened = try await client.newSession(
                    cwd: request.cwd,
                    yoloMode: request.permissionMode == .fullAccess,
                    modelId: request.model,
                    reasoningEffort: request.reasoningEffort,
                    reasoningModel: request.reasoningModel
                )
            }
            let mapper = DistillACPEventMapper(sessionId: opened.sessionId)
            // Seed mode so plan session updates can tell live progress from Plan review.
            let availableModeIDs = Set(opened.availableModes.map(\.id))
            let planModeID = Self.resolvedPlanModeID(
                availableModeIDs: availableModeIDs,
                advertisedPlanModeID: opened.planModeId
            )
            mapper.setCurrentModeId(opened.currentModeId)
            mapper.setPlanReviewModeId(planModeID)
            let seededEffort = DistillACPClient.seededReasoningEffort(
                models: opened.models,
                currentModelId: opened.currentModelId,
                currentEffortRaw: opened.currentReasoningEffortRaw
            )
            let advertisedEfforts = opened.advertisedReasoningEffortIds.compactMap(
                AgentReasoningEffort.init(rawValue:)
            )
            let session = Session(
                threadId: request.threadId,
                providerThreadId: opened.sessionId,
                client: client,
                capabilities: capabilities,
                mapper: mapper,
                model: opened.currentModelId ?? request.model,
                reasoningEffort: seededEffort,
                reasoningModel: request.reasoningModel,
                advertisesReasoningEffortConfig: opened.advertisesReasoningEffortConfig,
                advertisedEfforts: advertisedEfforts,
                availableModeIDs: availableModeIDs,
                planModeID: planModeID,
                mode: opened.currentModeId,
                maxReadableEvents: maxReadableEvents,
                maxReadableBytes: maxReadableBytes,
                onEvent: onEvent
            )
            client.notificationHandler = { [weak self, weak session] method, params in
                guard let self, let session else { return }
                self.handleNotification(method: method, params: params, session: session)
            }
            client.serverRequestHandler = { [weak self, weak session] id, method, params in
                guard let self, let session else { throw AgentProviderAdapterError.unsupported("Distill ACP adapter released") }
                return try await self.handleServerRequest(id: id, method: method, params: params, session: session)
            }
            client.terminationHandler = { [weak self, weak session] reason, status, error in
                guard let self, let session else { return }
                self.handleTermination(session: session, reason: reason, status: status, error: error)
            }
            let replaced = synchronized { () -> Session? in
                let replaced = sessions.updateValue(session, forKey: request.threadId)
                if let replaced {
                    replaced.isLive = false
                    replaced.promptWritePermit.invalidate()
                }
                return replaced
            }
            replaced?.client.stop()
            // session/load replays the full prior conversation as ordinary
            // session/update notifications (no reliable wire flag on every build).
            //
            // Contract: history is a *pull*
            // (`readThread`), never a push of historical tools into a live run.
            //
            // - load + prompt (sendTurn after process death): hydrate mapper
            //   state only — do not publish timeline items under the new bubble.
            // - load, no prompt (recoverSession): record replay into
            //   session.history for readThread, still no live onEvent push.
            // - session/new: publish pre-prompt notifications normally.
            // Then seal so beginTurn always mints a fresh user-facing turn.
            let loadNotifications = bufferedNotifications.drain()
            if loadExisting {
                for (method, params) in loadNotifications {
                    if shouldStartPrompt {
                        hydrateNotification(method: method, params: params, session: session)
                    } else {
                        recordHydratedTimeline(method: method, params: params, session: session)
                    }
                }
                // Silent/record paths discard mapper-emitted threadStarted; publish
                // identity once so resume-cursor persistence stays deterministic.
                emit(
                    .threadStarted(threadId: session.providerThreadId, providerThreadId: session.providerThreadId),
                    session: session
                )
            } else {
                for (method, params) in loadNotifications {
                    handleNotification(method: method, params: params, session: session)
                }
            }
            session.mapper.sealHydration()
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
            throw DistillACPFailureTaxonomy.normalize(
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
        let promptGeneration: UInt64 = try synchronized {
            guard sessions[request.threadId] === session, session.isLive else {
                throw AgentProviderAdapterError.sessionNotFound(request.threadId)
            }
            guard !session.inFlight else {
                throw AgentProviderAdapterError.unsupported("Distill ACP session already has an in-flight prompt")
            }
            session.inFlight = true
            session.promptAccepted = false
            session.promptWritePermit = AgentRunAcceptancePermit()
            session.cancelRequested = false
            session.forcedKillByUs = false
            session.turnTerminalEmitted = false
            session.turnWatchdogSynthesisInProgress = false
            session.forceKillWorkItem?.cancel()
            session.forceKillWorkItem = nil
            session.promptGeneration &+= 1
            session.onEvent = onEvent
            cancelTurnWatchdogLocked(session: session)
            return session.promptGeneration
        }

        do {
            let model = request.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let reasoningModel = request.reasoningModel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedReasoningModel = reasoningModel?.isEmpty == true ? nil : reasoningModel
            guard normalizedReasoningModel == nil || normalizedReasoningModel != model else {
                throw AgentProviderAdapterError.unsupported("Distill Reasoning model must differ from the Main model")
            }
            let currentModel = synchronized { session.model }
            let currentReasoningModel = synchronized { session.reasoningModel }
            let reasoningModelChanged = currentReasoningModel != normalizedReasoningModel
            let mainModelChanged = !model.isEmpty && model != currentModel
            let crossedSwap = reasoningModelChanged
                && mainModelChanged
                && normalizedReasoningModel == currentModel
                && model == currentReasoningModel
            if crossedSwap {
                try await session.client.setReasoningModel(
                    sessionId: session.providerThreadId,
                    modelId: nil
                )
                synchronized { session.reasoningModel = nil }
            }
            // Distill rejects Reasoning equal to active Main, so crossed pairs briefly clear Reasoning.
            let reasoningMustFollowMainChange = reasoningModelChanged
                && normalizedReasoningModel == currentModel
                && mainModelChanged
            if reasoningModelChanged && !crossedSwap && !reasoningMustFollowMainChange {
                try await session.client.setReasoningModel(
                    sessionId: session.providerThreadId,
                    modelId: normalizedReasoningModel
                )
                synchronized { session.reasoningModel = normalizedReasoningModel }
            }
            switch DistillACPClient.modelEffortBind(
                requestModel: request.model,
                sessionModel: session.model,
                requestEffort: request.reasoningEffort,
                sessionEffort: session.reasoningEffort,
                prefersConfigOptionEffort: session.advertisesReasoningEffortConfig,
                advertisedEfforts: session.advertisedEfforts
            ) {
            case .none:
                break
            case let .setConfigOption(configId, value, effort):
                try await session.client.setConfigOption(
                    sessionId: session.providerThreadId,
                    configId: configId,
                    value: value
                )
                synchronized {
                    session.reasoningEffort = effort
                }
            case let .setModel(modelId, reasoningEffort):
                try await session.client.setModel(
                    sessionId: session.providerThreadId,
                    modelId: modelId,
                    reasoningEffort: reasoningEffort
                )
                synchronized {
                    if !model.isEmpty { session.model = model }
                    session.reasoningEffort = reasoningEffort
                }
            }
            if reasoningMustFollowMainChange {
                try await session.client.setReasoningModel(
                    sessionId: session.providerThreadId,
                    modelId: normalizedReasoningModel
                )
                synchronized { session.reasoningModel = normalizedReasoningModel }
            }
            let requestedMode: String?
            if request.interactionMode == .plan {
                guard let planModeID = session.planModeID else {
                    throw AgentProviderAdapterError.unsupported("Distill ACP did not advertise Plan mode for this session")
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
                synchronized {
                    session.mode = requestedMode
                    // Keep mapper mode in sync even when the peer omits current_mode_update.
                    session.mapper.setCurrentModeId(requestedMode)
                }
            }
            let acceptance = PromptAcceptanceGate()
            beforePromptWriteForTesting?()
            try synchronized {
                guard sessions[request.threadId] === session, session.isLive else {
                    throw AgentProviderAdapterError.sessionNotFound(request.threadId)
                }
            }
            try await withCheckedThrowingContinuation { continuation in
                acceptance.install(continuation)
                Task { [weak self, weak session] in
                    guard let self, let session else {
                        acceptance.settle(.failure(AgentProviderAdapterError.sessionNotFound(request.threadId)))
                        return
                    }
                    do {
                        let response = try await session.client.prompt(
                            sessionId: session.providerThreadId,
                            request: request,
                            capabilities: session.capabilities,
                            writePermit: session.promptWritePermit,
                            beforeWrite: { [weak self] in
                                self?.beforePhysicalPromptWriteForTesting?()
                            },
                            onAccepted: { [weak self, weak session] in
                                guard let self, let session else {
                                    throw AgentProviderAdapterError.sessionNotFound(request.threadId)
                                }
                                try self.synchronized {
                                    guard self.sessions[request.threadId] === session,
                                          session.isLive else {
                                        throw AgentProviderAdapterError.sessionNotFound(request.threadId)
                                    }
                                    session.promptAccepted = true
                                    session.status = .running
                                    self.promptWriteAcceptanceCountForTestingStorage += 1
                                }
                                for event in session.mapper.beginTurn() {
                                    self.emit(event, session: session)
                                }
                                onEvent(.status(.running))
                                self.refreshTurnWatchdog(session: session, generation: promptGeneration)
                                acceptance.settle(.success(()))
                            }
                        )
                        self.handlePromptResponse(response, session: session, generation: promptGeneration)
                    } catch {
                        acceptance.settle(.failure(error))
                        self.finishTransportFailure(session: session, error: error, forced: false)
                    }
                }
            }
            afterPromptWriteForTesting?()
        } catch {
            synchronized {
                if session.promptGeneration == promptGeneration {
                    session.inFlight = false
                    cancelTurnWatchdogLocked(session: session)
                }
            }
            if error is AgentProviderAdapterError { throw error }
            throw DistillACPFailureTaxonomy.normalize(error, context: .turn)
        }
    }

    private func handleNotification(method: String, params: Any?, session: Session) {
        guard method == "session/update",
              let params = params as? [String: Any],
              params["sessionId"] as? String == session.providerThreadId,
              let update = params["update"] as? [String: Any] else {
            // Live grok-build emits `x.ai/*`; legacy/replay may use `_x.ai/*`.
            // Leader may nest live method under underscore envelope `{method,params}`.
            if Self.isDistillExtNotificationMethod(method) {
                let (resolvedMethod, resolvedPayload) = Self.unwrapDistillExtNotification(
                    method: method,
                    params: params
                )
                emit(Self.runtimeEvent(method: resolvedMethod, payload: resolvedPayload), session: session)
            }
            return
        }
        for event in session.mapper.consumeSessionUpdate(update) { emit(event, session: session) }
    }

    /// Live (`x.ai/…`) and legacy (`_x.ai/…`) distill ACP extension notifications.
    private static func isDistillExtNotificationMethod(_ method: String) -> Bool {
        method.hasPrefix("x.ai/") || method.hasPrefix("_x.ai/")
    }

    /// Unwrap leader nested form: outer `_x.ai/…` with params `{ method, params }`.
    private static func unwrapDistillExtNotification(
        method: String,
        params: Any?
    ) -> (method: String, params: Any?) {
        guard let dict = params as? [String: Any],
              let nestedMethod = dict["method"] as? String,
              isDistillExtNotificationMethod(nestedMethod),
              dict.keys.contains("params") else {
            return (method, params)
        }
        return (nestedMethod, dict["params"])
    }

    /// Apply load-time `session/update` to mapper session state only.
    /// Does not publish timeline events onto the follow-up run's onEvent path.
    private func hydrateNotification(method: String, params: Any?, session: Session) {
        guard method == "session/update",
              let params = params as? [String: Any],
              params["sessionId"] as? String == session.providerThreadId,
              let update = params["update"] as? [String: Any] else {
            // Load-time `_x.ai/*` subagent rows are dropped here intentionally:
            // they already exist in durable history and must not re-enter a run.
            return
        }
        // Discard timeline events; mode/commands/usage still land on the mapper.
        _ = session.mapper.consumeSessionUpdate(update)
        if update["sessionUpdate"] as? String == "current_mode_update",
           let modeId = update["currentModeId"] as? String {
            session.mode = modeId
        }
    }

    /// `session/load` replay for recoverSession: keep history for `readThread`
    /// without pushing into the live `onEvent` path (avoids durable stream
    /// pollution / wire re-rendering of historical text).
    private func recordHydratedTimeline(method: String, params: Any?, session: Session) {
        guard method == "session/update",
              let params = params as? [String: Any],
              params["sessionId"] as? String == session.providerThreadId,
              let update = params["update"] as? [String: Any] else {
            return
        }
        let events = session.mapper.consumeSessionUpdate(update)
        if update["sessionUpdate"] as? String == "current_mode_update",
           let modeId = update["currentModeId"] as? String {
            session.mode = modeId
        }
        guard !events.isEmpty else { return }
        lock.lock()
        session.history.append(contentsOf: events)
        lock.unlock()
    }

    private func handleServerRequest(
        id: DistillACPRequestID,
        method: String,
        params: Any?,
        session: Session
    ) async throws -> Any? {
        guard method == "session/request_permission" else {
            throw AgentProviderAdapterError.unsupported("Unhandled Distill ACP request: \(method)")
        }
        let request = try DistillACPPermissionRequest.parse(id: id, params: params)
        guard request.sessionId == session.providerThreadId else {
            throw AgentProviderAdapterError.unsupported("Distill ACP permission session mismatch")
        }
        return try await withCheckedThrowingContinuation { continuation in
            let key = id.stringValue
            let turnId = synchronized { () -> String? in
                session.pendingPermissions[key] = PendingPermission(request: request, continuation: continuation)
                return session.mapper.activeTurnId
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

    private func handlePromptResponse(
        _ response: [String: Any],
        session: Session,
        generation: UInt64
    ) {
        // Drop a stale result for a previous prompt after the inactivity
        // watchdog already released the turn (or a follow-up started).
        let stillCurrent = synchronized {
            session.promptGeneration == generation && !session.turnTerminalEmitted
        }
        guard stillCurrent else {
            distillAcpLog.info(
                "grok.turn.prompt_result.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
            return
        }
        let stopReason = response["stopReason"] as? String ?? "failed"
        let metadata = response["_meta"] as? [String: Any]
        let usage = metadata?["usage"] as? [String: Any]
        for event in session.mapper.finishTurn(stopReason: stopReason, usage: usage) { emit(event, session: session) }
        let status = DistillACPTerminalClassifier.status(stopReason: stopReason)
        if status == .failed {
            session.onEvent?(.error(DistillACPFailureTaxonomy.normalize(
                diagnostic: "Distill ACP stopped: \(stopReason)",
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
        let generation = session.promptGeneration
        let current = sessions[session.threadId] === session
        let active = current
            && session.inFlight
            && session.promptAccepted
            && !session.turnTerminalEmitted
        let forced = session.forcedKillByUs
        let cancelled = session.cancelRequested
        if current {
            sessions.removeValue(forKey: session.threadId)
        }
        session.isLive = false
        session.promptWritePermit.invalidate()
        session.forceKillWorkItem?.cancel()
        session.forceKillWorkItem = nil
        lock.unlock()
        guard active else {
            distillAcpLog.info(
                "grok.turn.termination.stale thread=\(session.threadId.value.uuidString, privacy: .public) generation=\(generation, privacy: .public)"
            )
            return
        }
        let terminal = DistillACPTerminalClassifier.status(
            promptResolved: false,
            cancelRequested: cancelled,
            forcedKillByUs: forced,
            terminationReason: reason,
            exitStatus: status
        )
        if terminal == .failed {
            session.onEvent?(.error(DistillACPFailureTaxonomy.normalize(error, context: .turn).message))
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
        let active = session.inFlight && session.promptAccepted && !session.turnTerminalEmitted
        lock.unlock()
        guard active else { return }
        if terminal == .failed {
            session.onEvent?(.error(DistillACPFailureTaxonomy.normalize(error, context: .turn).message))
        }
        for event in session.mapper.finishTurn(stopReason: terminal == .cancelled ? "cancelled" : "failed", usage: nil) {
            emit(event, session: session)
        }
        finishTurn(session: session, status: terminal)
    }

    private func finishTurn(session: Session, status: AgentRunStatus) {
        lock.lock()
        guard sessions[session.threadId] === session || !session.isLive else {
            lock.unlock()
            return
        }
        guard !session.turnTerminalEmitted else { lock.unlock(); return }
        session.turnTerminalEmitted = true
        session.turnWatchdogSynthesisInProgress = false
        session.inFlight = false
        session.status = status
        let shouldStopOwnedTree = status == .cancelled && session.cancelRequested
        if shouldStopOwnedTree {
            if sessions[session.threadId] === session {
                sessions.removeValue(forKey: session.threadId)
            }
            session.isLive = false
            session.promptWritePermit.invalidate()
        }
        session.forceKillWorkItem?.cancel()
        session.forceKillWorkItem = nil
        cancelTurnWatchdogLocked(session: session)
        let callback = session.onEvent
        let final = session.mapper.finalAssistantMessage
        let providerThreadId = session.providerThreadId
        let pending = Array(session.pendingPermissions.values)
        session.pendingPermissions.removeAll()
        lock.unlock()
        for request in pending {
            request.continuation.resume(throwing: AgentProviderAdapterError.unsupported("Distill ACP turn ended before permission response"))
        }
        if shouldStopOwnedTree {
            distillAcpLog.info(
                "distill.cancel.ack.tree_stop thread=\(session.threadId.value.uuidString, privacy: .public)"
            )
            session.client.stop()
        }
        callback?(.status(status))
        callback?(.finished(status, finalMessage: final, providerThreadId: providerThreadId))
    }

    /// (Re)arm the in-flight turn inactivity bound. No-op when the turn is no
    /// longer open. Stream/tool events fully reset the deadline so long-running
    /// goals stay live for as long as the provider keeps producing activity.
    private func refreshTurnWatchdog(session: Session, generation: UInt64) {
        lock.lock()
        guard sessions[session.threadId] === session,
              session.isLive,
              session.inFlight,
              session.promptAccepted,
              !session.turnTerminalEmitted,
              !session.turnWatchdogSynthesisInProgress,
              session.promptGeneration == generation else {
            lock.unlock()
            return
        }
        session.turnWatchdog?.cancel()
        let delay = turnInactivityTimeout
        let item = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session else { return }
            self.fireTurnInactivityWatchdog(session: session, generation: generation)
        }
        session.turnWatchdog = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelTurnWatchdogLocked(session: Session) {
        session.turnWatchdog?.cancel()
        session.turnWatchdog = nil
    }

    /// When `session/prompt` never returns after the model finished streaming
    /// *and* no further events arrive within the inactivity window, synthesize a
    /// terminal so coordinator ownership / Working release.
    /// Prefer `.completed` when the mapper already has speakable final text.
    private func fireTurnInactivityWatchdog(session: Session, generation: UInt64) {
        lock.lock()
        guard sessions[session.threadId] === session,
              session.isLive,
              session.inFlight,
              session.promptAccepted,
              !session.turnTerminalEmitted,
              !session.turnWatchdogSynthesisInProgress,
              session.promptGeneration == generation else {
            lock.unlock()
            return
        }
        // Claim synthesis before any emit. emit re-arms the watchdog; without
        // this flag that re-arm can re-enter fire and overflow the GCD worker
        // stack (crash: RemoteCode.SQLiteDB stack guard via EventBus).
        session.turnWatchdogSynthesisInProgress = true
        cancelTurnWatchdogLocked(session: session)
        lock.unlock()
        // Open tools mean quiet ≠ goal success — synthesize interrupted so the
        // host does not paint a green completed goal mid long silent shell/CI.
        // Speakable text alone is only enough when no tool_call is still open.
        let hasOpenTools = session.mapper.hasOpenToolCalls
        let hasFinal = session.mapper.hasSpeakableFinalContent
        let status: AgentRunStatus
        let stopReason: String
        if hasOpenTools {
            status = .interrupted
            stopReason = "interrupted"
        } else if hasFinal {
            status = .completed
            stopReason = "end_turn"
        } else {
            status = .failed
            stopReason = "failed"
        }
        distillAcpLog.info(
            "grok.turn.watchdog.synthesized thread=\(session.threadId.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) generation=\(generation, privacy: .public) openTools=\(hasOpenTools, privacy: .public)"
        )
        // Distinct runtime marker so field forensics can separate inferred
        // terminals from real session/prompt stopReason frames.
        emit(
            Self.runtimeEvent(
                method: "grok.turn.watchdog.synthesized",
                payload: [
                    "sessionId": session.providerThreadId,
                    "status": status.rawValue,
                    "stopReason": stopReason,
                    "hasSpeakableFinalContent": hasFinal,
                    "hasOpenToolCalls": hasOpenTools
                ]
            ),
            session: session
        )
        for event in session.mapper.finishTurn(stopReason: stopReason, usage: nil) {
            emit(event, session: session)
        }
        if status == .failed || status == .interrupted {
            session.onEvent?(.error(DistillACPFailureTaxonomy.normalize(
                diagnostic: hasOpenTools
                    ? "Distill ACP turn inactivity watchdog: open tool_call with no further events (session/prompt never returned)"
                    : "Distill ACP turn inactivity watchdog synthesized terminal (session/prompt never returned)",
                context: .turn
            ).message))
        }
        finishTurn(session: session, status: status)
    }

    private func emit(_ event: AssistantEvent, session: Session) {
        lock.lock()
        // Drop late ACP noise after the turn terminal was published. Post-finish
        // events were re-entering the coordinator with a cleared seq counter and
        // colliding on durable seq 1 (servers_updated vs turnStarted).
        if session.turnTerminalEmitted {
            lock.unlock()
            return
        }
        session.history.append(event)
        let generation = session.promptGeneration
        // Do not re-arm while the watchdog is synthesizing a terminal: that path
        // is what previously re-entered fireTurnInactivityWatchdog from emit.
        let shouldArmWatchdog = session.inFlight
            && session.promptAccepted
            && !session.turnWatchdogSynthesisInProgress
        let callback = session.onEvent
        lock.unlock()
        callback?(.event(event))
        if shouldArmWatchdog {
            refreshTurnWatchdog(session: session, generation: generation)
        }
    }

    private func handle(for runId: AgentRunID, session: Session) -> AgentRunHandle {
        AgentRunHandle(runId: runId, process: session.client.runningProcess) { [weak self, weak session] in
            guard let self, let session else { return }
            try? self.interruptTurn(threadId: session.threadId)
        }
    }

    /// CLI/ACP wire values accepted by the harness (`--permission-mode` / session/set_mode).
    static let defaultPermissionModes: [AgentPermissionMode] = AgentPermissionMode.allCases

    private static func mode(for permission: AgentPermissionMode) -> String {
        switch permission {
        case .supervised: return "default"
        case .autoAcceptEdits: return "acceptEdits"
        case .fullAccess: return "bypassPermissions"
        }
    }

    /// Map advertised ACP mode IDs to RemoteCode permission modes.
    /// Empty advertisement means the known CLI set is usable.
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

    /// Map advertised ACP mode IDs to interaction modes.
    /// Empty advertisement: Plan is open via wire id `plan`.
    /// When modes are advertised without plan, stay fail-closed.
    static func interactionModes(
        availableModeIDs: Set<String>,
        advertisedPlanModeID: String?
    ) -> [AgentInteractionMode] {
        if availableModeIDs.isEmpty {
            return [.default, .plan]
        }
        return advertisedPlanModeID != nil ? [.default, .plan] : [.default]
    }

    /// Wire mode id for Plan when the session omits availableModes.
    static let emptyCatalogPlanModeID = "plan"

    /// Resolve Plan mode to an ACP mode ID for session/set_mode.
    /// Empty catalog → known wire `"plan"`. Advertised without plan → nil (fail-closed).
    static func resolvedPlanModeID(
        availableModeIDs: Set<String>,
        advertisedPlanModeID: String?
    ) -> String? {
        if availableModeIDs.isEmpty {
            return emptyCatalogPlanModeID
        }
        return advertisedPlanModeID
    }

    /// Resolve a permission mode to an ACP mode ID for session/set_mode.
    /// When the session omits availableModes, still apply the known wire ID —
    /// the harness accepts set_mode without advertising the catalog.
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
            "Distill ACP did not advertise the \(permission.rawValue) permission mode for this session"
        )
    }

    private static func runtimeEvent(method: String, payload: Any?) -> AssistantEvent {
        let object = payload as? [String: Any] ?? [:]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return .providerRuntime(ProviderRuntimeEvent(
            provider: .distill,
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
