import Foundation
import CoreModel
import CryptoKit
import Persistence
import os

// QA-MAC_AGENT-010: structured run-lifecycle logging so field issues and test
// flakes (start/finish/duration, checkpoint outcomes) are diagnosable. Routes
// through the unified logging system, keyed by thread/run ids.
private let agentRunLog = Logger(subsystem: "io.remotecode.agent", category: "run")

public protocol AgentRunObserver: AnyObject {
    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID, threadId: AgentThreadID)
    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, threadId: AgentThreadID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)
    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID, threadId: AgentThreadID)
}

public final class AgentRunCoordinator: @unchecked Sendable {
    private let runRepo: AgentRunRepository
    private let messageRepo: AgentMessageRepository
    private let threadRepo: AgentThreadRepository
    private let providerSessionRepo: ProviderSessionRuntimeRepository?
    private let checkpointRepo: AgentTurnCheckpointRepository?
    private var providers: [AgentProvider: AgentProviderAdapter]
    private var active: [AgentRunID: AgentRunHandle] = [:]
    private var activeThreads: [AgentThreadID: AgentRunID] = [:]
    private var activeRunMetadata: [AgentRunID: (provider: AgentProvider, providerInstanceId: String?, model: String, cwd: String, serviceTier: AgentServiceTier, runtimeMode: AgentPermissionMode, interactionMode: AgentInteractionMode, adapterKey: String, binaryIdentity: String?)] = [:]
    private var activeTurnIds: [AgentRunID: String] = [:]
    private var activeAssistantMessageIds: [AgentRunID: AgentMessageID] = [:]
    private var activeProviderTextItemTypes: [AgentRunID: [String: AssistantItemType]] = [:]
    private var bufferedProviderTextItems: [AgentRunID: [String: BufferedProviderTextItem]] = [:]
    private var activeDistillOutputRuns: Set<AgentRunID> = []
    private var pendingThreadStops: Set<AgentThreadID> = []
    private var seq: [AgentRunID: Int] = [:]
    // PERF-MAC_AGENT-005: reuse one encoder instead of allocating per stream
    // event, and prune on a cadence rather than every event. Both are touched
    // under `lock` (encode is serialized there) so they stay thread-safe.
    private let streamEventEncoder = JSONEncoder()
    private var streamEventsSincePrune: [AgentThreadID: Int] = [:]
    private static let streamEventPruneInterval = 25
    // PERF-MAC_AGENT-007: per-thread buffer of pending stream-event writes plus
    // the timestamp of the last flush, so 2-3 writes/event collapse into batched
    // flushes (see shouldFlushStreamBatch). All touched under `lock`.
    private var pendingStreamWrites: [AgentThreadID: StreamWriteBatch] = [:]
    private var lastStreamFlushMs: [AgentThreadID: Int64] = [:]
    // PERF-MAC_AGENT-006: last assistant text persisted per thread, to dedup the
    // turnCompleted/finished pair without reloading the whole thread history.
    private var lastPersistedAssistantContent: [AgentThreadID: String] = [:]
    // UX-MAC-CHECKPOINT-REVERT-UNDO: transient snapshot of the most recent
    // checkpoint revert, captured pre-destruction. Non-nil only inside the undo
    // window; cleared on a successful undo. Lock-guarded like other coord state.
    private var lastCheckpointRevertUndo: CheckpointRevertUndo?
    /// Seconds a checkpoint revert stays reversible after it runs.
    public static let checkpointRevertUndoWindow: TimeInterval = 10
    private let lock = NSLock()
    private var observerRefs: [WeakAgentRunObserver] = []
    public var observer: AgentRunObserver? {
        get {
            lock.lock(); defer { lock.unlock() }
            return observerRefs.compactMap(\.value).first
        }
        set {
            if let newValue { addObserver(newValue) }
        }
    }

    /// GAP-7: bridge agent run lifecycle + timeline to the network event
    /// bus so the iOS mirror receives streaming agent output in real
    /// time. Kept as primitive closures (no SocketServer dependency in
    /// this module); AppShell maps them onto EventBus.
    public var onRunStarted: ((AgentThreadID, AgentRunID) -> Void)?
    public var onAssistantEvent: ((AssistantEvent, AgentThreadID, AgentRunID) -> Void)?
    public var onRunFinished: ((AgentThreadID, AgentRunID, AgentRunStatus) -> Void)?
    public var onMessageAppended: ((AgentMessage) -> Void)?
    public var onPersistenceIssue: ((String, AgentThreadID, AgentRunID) -> Void)?

    /// Token Saver hook: async transform applied to the outbound provider
    /// prompt only. The original text is always preserved as the displayed
    /// user message. Must be fail-open — return the input unchanged on any
    /// error or when Token Saver is disabled.
    public var promptCompressor: (@Sendable (_ prompt: String, _ provider: AgentProvider, _ threadId: AgentThreadID) async -> String)?
    /// Token Saver hook for free-form follow-up answers. Defaults to
    /// `promptCompressor` when nil, but app shells can provide a separate hook
    /// to tag telemetry as `prompt_followup`.
    public var followUpPromptCompressor: (@Sendable (_ prompt: String, _ provider: AgentProvider, _ threadId: AgentThreadID) async -> String)?
    /// P3: optionally compact large tool output in a persisted stream-event payload before it
    /// is written (CCR-backed, structure-preserving). nil => payloads stored verbatim.
    public var streamPayloadCompactor: (@Sendable (_ payloadJSON: String) -> String)?

    /// Token Saver /distill hook: async transform applied to provider text
    /// detected as SR1 compressed language. The returned value is what gets
    /// persisted and shown to users. Must fail open by returning the input
    /// unchanged on any error.
    public var finalResponseTranslator: (@Sendable (_ response: String, _ provider: AgentProvider, _ threadId: AgentThreadID, _ runId: AgentRunID) async -> String)?

    /// Fired (on an arbitrary executor) when a final assistant message was SR1-translated
    /// and persisted. Callers can use the id to badge the message in the UI.
    /// Not fired when translation is a no-op (finalResponseTranslator absent or text unchanged).
    public var onSR1TranslatedMessageId: (@Sendable (AgentMessageID) -> Void)?

    public init(
        runRepo: AgentRunRepository,
        messageRepo: AgentMessageRepository,
        threadRepo: AgentThreadRepository,
        providerSessionRepo: ProviderSessionRuntimeRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        providers: [AgentProvider: AgentProviderRunner]
    ) {
        self.runRepo = runRepo
        self.messageRepo = messageRepo
        self.threadRepo = threadRepo
        self.providerSessionRepo = providerSessionRepo
        self.checkpointRepo = checkpointRepo
        self.providers = providers.mapValues { OneShotProviderAdapter(runner: $0) }
    }

    public convenience init(
        runRepo: AgentRunRepository,
        messageRepo: AgentMessageRepository,
        threadRepo: AgentThreadRepository,
        providerSessionRepo: ProviderSessionRuntimeRepository? = nil,
        checkpointRepo: AgentTurnCheckpointRepository? = nil,
        providerAdapters: [AgentProvider: AgentProviderAdapter]
    ) {
        self.init(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providerSessionRepo: providerSessionRepo,
            checkpointRepo: checkpointRepo,
            providers: [:]
        )
        self.providers = providerAdapters
    }

    public func replaceProvider(_ provider: AgentProvider, runner: AgentProviderRunner) {
        lock.lock(); defer { lock.unlock() }
        providers[provider] = OneShotProviderAdapter(runner: runner)
    }

    public func replaceProviderAdapter(_ provider: AgentProvider, adapter: AgentProviderAdapter) {
        lock.lock(); defer { lock.unlock() }
        providers[provider] = adapter
    }

    public func addObserver(_ observer: AgentRunObserver) {
        lock.lock()
        observerRefs.removeAll { $0.value == nil }
        if !observerRefs.contains(where: { $0.value === observer }) {
            observerRefs.append(WeakAgentRunObserver(observer))
        }
        lock.unlock()
    }

    public func reconcileOnLaunch() throws {
        _ = try runRepo.reconcileRunningOnLaunch()
        let now = Date()
        for thread in try threadRepo.list() where thread.status == .running {
            var copy = thread
            copy.status = .interrupted
            copy.updatedAt = now
            try threadRepo.upsert(copy)
        }
        if let providerSessionRepo {
            let future = Date.distantFuture
            for session in try providerSessionRepo.list(status: .running, updatedBefore: future) {
                try providerSessionRepo.markStopped(threadId: session.threadId, at: now)
            }
        }
    }

    public func runStatus(_ runId: AgentRunID) throws -> AgentRunStatus? {
        try runRepo.get(id: runId)?.status
    }

    /// Returns the persisted start time of the active run for `threadId`, or
    /// nil when no active run is recorded.
    /// WHY: the Mac is the host and owns the authoritative run clock; callers
    /// must use this instead of `Date()` so elapsed-time display is correct
    /// even when the view reloads mid-run (e.g. selectThread after app relaunch).
    /// CONTRACT PIN (iOS): iOS must use `agent.run.started` from the host
    /// mirror event (or the `started_at` field in the run record broadcast)
    /// to match this value across the connection.
    public func runStartedAt(threadId: AgentThreadID) throws -> Date? {
        lock.lock()
        let runId = activeThreads[threadId]
        lock.unlock()
        guard let runId else { return nil }
        return try runRepo.get(id: runId)?.startedAt
    }

    @discardableResult
    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunID {
        let recoveryContext = request.providerThreadId == nil ? try recoverableResumeContext(for: request) : nil
        let resumeCursor = request.providerThreadId ?? recoveryContext?.resumeCursor
        // Token Saver: compress only the text sent to the provider; the
        // original prompt is preserved verbatim as the displayed user message.
        let preservedUserContent = request.userMessageContent ?? request.prompt
        var outboundPrompt = request.prompt
        if let promptCompressor {
            outboundPrompt = await promptCompressor(request.prompt, request.provider, request.threadId)
        }
        let effectiveRequest = AgentRunRequest(
            runId: request.runId,
            threadId: request.threadId,
            provider: request.provider,
            providerInstanceId: request.providerInstanceId,
            model: request.model,
            cwd: request.cwd,
            prompt: outboundPrompt,
            userMessageContent: preservedUserContent,
            attachments: request.attachments,
            providerThreadId: resumeCursor,
            permissionMode: recoveryContext?.runtimeMode ?? request.permissionMode,
            reasoningEffort: request.reasoningEffort,
            serviceTier: recoveryContext?.serviceTier ?? request.serviceTier,
            interactionMode: recoveryContext?.interactionMode ?? request.interactionMode,
            providerBinary: request.providerBinary,
            environment: request.environment,
            extraArgs: request.extraArgs
        )
        guard let runner = providers[effectiveRequest.provider] else {
            throw AgentRunError.missingBinary(effectiveRequest.provider.rawValue)
        }
        let adapterKey = providerAdapterKey(runner)
        let binaryIdentity = providerBinaryIdentity(effectiveRequest.provider, adapter: runner)
        // persist user message
        let userMsg = AgentMessage(threadId: effectiveRequest.threadId, role: .user, content: effectiveRequest.userMessageContent ?? effectiveRequest.prompt)
        try messageRepo.append(userMsg)
        onMessageAppended?(userMsg)
        // persist run
        let run = AgentRun(id: effectiveRequest.runId, threadId: effectiveRequest.threadId, provider: effectiveRequest.provider, providerInstanceId: effectiveRequest.providerInstanceId, model: effectiveRequest.model, status: .running)
        try runRepo.upsert(run)
        if var thread = try threadRepo.get(id: effectiveRequest.threadId) {
            thread.status = .running
            thread.hasUnread = false
            thread.updatedAt = Date()
            try threadRepo.upsert(thread)
        }
        let existingRuntimePayload = try providerSessionRepo?.get(threadId: effectiveRequest.threadId)?.runtimePayloadJSON
        try providerSessionRepo?.upsert(ProviderSessionRuntime(
            threadId: effectiveRequest.threadId,
            provider: effectiveRequest.provider,
            providerInstanceId: effectiveRequest.providerInstanceId,
            adapterKey: adapterKey,
            binaryIdentity: binaryIdentity,
            status: .running,
            resumeCursor: effectiveRequest.providerThreadId,
            cwd: effectiveRequest.cwd,
            model: effectiveRequest.model,
            serviceTier: effectiveRequest.serviceTier,
            runtimeMode: effectiveRequest.permissionMode,
            lastEventKind: "run.started",
            runtimePayloadJSON: existingRuntimePayload
        ))
        onRunStarted?(effectiveRequest.threadId, effectiveRequest.runId)
        agentRunLog.info("run.started thread=\(effectiveRequest.threadId.value.uuidString, privacy: .public) run=\(effectiveRequest.runId.value.uuidString, privacy: .public) provider=\(effectiveRequest.provider.rawValue, privacy: .public) model=\(effectiveRequest.model, privacy: .public)")

        let runId = effectiveRequest.runId
        let coordinator = self
        let handle: AgentRunHandle
        let expectsDistillOutput = Self.promptInvokesDistill(effectiveRequest.prompt) ||
            Self.promptInvokesDistill(effectiveRequest.userMessageContent)
        if expectsDistillOutput {
            markDistillOutputMode(runId)
        }
        do {
            handle = try await runner.sendTurn(effectiveRequest) { ev in
                coordinator.handle(event: ev, runId: runId, threadId: effectiveRequest.threadId)
            }
        } catch {
            clearDistillOutputMode(runId)
            markStartFailure(
                error,
                request: effectiveRequest,
                runId: runId,
                adapterKey: adapterKey,
                binaryIdentity: binaryIdentity
            )
            throw error
        }
        let terminalStatus = (try? runRepo.get(id: runId)?.status).flatMap { status -> AgentRunStatus? in
            status == .running || status == .pending ? nil : status
        }
        if terminalStatus == .cancelled {
            clearDistillOutputMode(runId)
            handle.cancel()
            return runId
        }
        lock.lock()
        let shouldCancel: Bool
        if terminalStatus == nil {
            active[runId] = handle
            activeThreads[effectiveRequest.threadId] = runId
            activeRunMetadata[runId] = (effectiveRequest.provider, effectiveRequest.providerInstanceId, effectiveRequest.model, effectiveRequest.cwd, effectiveRequest.serviceTier, effectiveRequest.permissionMode, effectiveRequest.interactionMode, adapterKey, binaryIdentity)
            seq[runId] = 0
            shouldCancel = pendingThreadStops.remove(effectiveRequest.threadId) != nil
        } else {
            pendingThreadStops.remove(effectiveRequest.threadId)
            shouldCancel = false
        }
        lock.unlock()
        if shouldCancel { handle.cancel() }
        return runId
    }

    public func stopRun(_ runId: AgentRunID) {
        lock.lock()
        let h = active[runId]
        lock.unlock()
        h?.cancel()
    }

    public func stopRun(threadId: AgentThreadID) {
        lock.lock()
        let runId = activeThreads[threadId]
        let handle = runId.flatMap { active[$0] }
        lock.unlock()
        if let handle {
            handle.cancel()
            if let adapter = try? adapterForThread(threadId) {
                try? adapter.interruptTurn(threadId: threadId)
            }
            markStopRequested(threadId: threadId, runId: runId)
            return
        }
        if let adapter = try? adapterForThread(threadId), adapter.hasSession(threadId: threadId) {
            do {
                try adapter.stopSession(threadId: threadId)
                markStopRequested(threadId: threadId, runId: nil)
                return
            } catch {
                // One-shot runners can expose a session before the local run handle exists.
                // Keep the pending stop so handle registration cancels the run.
            }
        }
        if let adapter = try? adapterForThread(threadId), !adapter.hasSession(threadId: threadId) {
            // recoverAdapterSessionIfNeeded is now async (its provider-session
            // recovery no longer blocks the caller on a semaphore). stopRun must
            // stay synchronous for its many non-async callers, so drive the
            // best-effort recover-then-interrupt off the calling thread. The
            // synchronous pendingThreadStops fall-through below remains the stop
            // guarantee; the interrupt here is best-effort exactly as before.
            //
            // Only attempted when there is NO live session: a session that exists
            // without a registered handle is the one-shot-before-handle race, and
            // its interrupt would throw sessionNotFound. That case must fall
            // through to the synchronous pendingThreadStops insertion below so
            // handle registration cancels the run -- it must NOT early-return.
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
                    if adapter.hasSession(threadId: threadId) {
                        try adapter.interruptTurn(threadId: threadId)
                        self.markStopRequested(threadId: threadId, runId: nil)
                    }
                } catch {
                    // Pending cancellation (recorded synchronously below) covers this;
                    // startRun will fail loudly if recovered state is insufficient.
                }
            }
        }
        guard let thread = try? threadRepo.get(id: threadId),
              thread.status == .running || thread.status == .pending else {
            lock.lock()
            pendingThreadStops.remove(threadId)
            lock.unlock()
            return
        }
        lock.lock()
        pendingThreadStops.insert(threadId)
        lock.unlock()
        markStopRequested(threadId: threadId, runId: nil)
    }

    private func markStopRequested(threadId: AgentThreadID, runId: AgentRunID?) {
        let stoppedRunId = runId ?? AgentRunID()
        if let runId {
            try? runRepo.markStopped(id: runId, status: .cancelled)
        }
        if var thread = try? threadRepo.get(id: threadId), thread.status == .running || thread.status == .pending {
            thread.status = .cancelled
            thread.updatedAt = Date()
            try? threadRepo.upsert(thread)
        }
        try? providerSessionRepo?.markStopped(threadId: threadId)
        // PERF-MAC_AGENT-007: drain buffered stream writes for the genuine active
        // run before tearing it down, so a cancel does not drop the buffered tail.
        // The seq attribution requires the real runId, so only the runId-bearing
        // stop path flushes (the nil-runId paths had no live buffered events).
        if let runId {
            flushPendingStreamWrites(runId: runId, threadId: threadId)
        }
        lock.lock()
        if let runId {
            active.removeValue(forKey: runId)
            activeThreads.removeValue(forKey: threadId)
            activeRunMetadata.removeValue(forKey: runId)
            activeTurnIds.removeValue(forKey: runId)
            activeAssistantMessageIds.removeValue(forKey: runId)
            activeProviderTextItemTypes.removeValue(forKey: runId)
            bufferedProviderTextItems.removeValue(forKey: runId)
            activeDistillOutputRuns.remove(runId)
            seq.removeValue(forKey: runId)
            pendingThreadStops.remove(threadId)
        }
        streamEventsSincePrune.removeValue(forKey: threadId)
        pendingStreamWrites.removeValue(forKey: threadId)
        lastStreamFlushMs.removeValue(forKey: threadId)
        // PERF-MAC_AGENT-008: thread closed -> evict the dedup cache entry so
        // cancelled threads do not retain their final-answer text indefinitely.
        lastPersistedAssistantContent.removeValue(forKey: threadId)
        lock.unlock()
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didChangeStatus: .cancelled, runId: stoppedRunId, threadId: threadId)
        }
        onRunFinished?(threadId, stoppedRunId, .cancelled)
    }

    private func markStartFailure(_ error: Error, request: AgentRunRequest, runId: AgentRunID, adapterKey: String, binaryIdentity: String?) {
        let message = String(describing: error)
        var run = AgentRun(
            id: runId,
            threadId: request.threadId,
            provider: request.provider,
            providerInstanceId: request.providerInstanceId,
            model: request.model,
            status: .failed,
            finishedAt: Date(),
            errorMessage: message
        )
        run.startedAt = Date()
        try? runRepo.upsert(run)
        if var thread = try? threadRepo.get(id: request.threadId) {
            thread.status = .failed
            thread.updatedAt = Date()
            try? threadRepo.upsert(thread)
        }
        try? providerSessionRepo?.upsert(ProviderSessionRuntime(
            threadId: request.threadId,
            provider: request.provider,
            providerInstanceId: request.providerInstanceId,
            adapterKey: adapterKey,
            binaryIdentity: binaryIdentity,
            status: .failed,
            resumeCursor: request.providerThreadId,
            cwd: request.cwd,
            model: request.model,
            serviceTier: request.serviceTier,
            runtimeMode: request.permissionMode,
            lastEventKind: "run.start_failed",
            lastErrorMessage: message
        ))
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didChangeStatus: .failed, runId: runId, threadId: request.threadId)
            observer.runCoordinator(self, didReceive: .error(message: message, recoverable: false), run: runId, threadId: request.threadId)
        }
        onAssistantEvent?(.error(message: message, recoverable: false), request.threadId, runId)
        onRunFinished?(request.threadId, runId, .failed)
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        let adapter = try adapterForThread(threadId)
        try await adapter.respondToRequest(threadId: threadId, requestId: requestId, response: response)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) async throws {
        let adapter = try adapterForThread(threadId)
        let outboundText: String
        if let followUpPromptCompressor {
            outboundText = await followUpPromptCompressor(text, adapter.provider, threadId)
        } else if let promptCompressor {
            outboundText = await promptCompressor(text, adapter.provider, threadId)
        } else {
            outboundText = text
        }
        try adapter.respondToUserInput(threadId: threadId, requestId: requestId, verbatimText: text, outboundText: outboundText)
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        let adapter = try adapterForThread(threadId)
        try await recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
        return try await adapter.readThread(threadId: threadId)
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        let adapter = try adapterForThread(threadId)
        try await recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
        try await adapter.rollbackThread(threadId: threadId, toTurnId: toTurnId)
    }

    @discardableResult
    public func revertThreadToCheckpoint(threadId: AgentThreadID, checkpointTurnCount: Int, cwd: String) async throws -> AgentTurnCheckpointSummary {
        guard let checkpointRepo else {
            throw AgentProviderAdapterError.unsupported("checkpoint repository is unavailable")
        }
        guard let checkpoint = try checkpointRepo.get(threadId: threadId, checkpointTurnCount: checkpointTurnCount) else {
            throw AgentProviderAdapterError.unsupported("checkpoint \(checkpointTurnCount) not found")
        }
        guard checkpoint.status == .ready else {
            throw AgentProviderAdapterError.unsupported("checkpoint \(checkpointTurnCount) is \(checkpoint.status.rawValue)")
        }
        guard !checkpoint.fileSnapshots.isEmpty || checkpoint.files.isEmpty else {
            throw AgentProviderAdapterError.unsupported("checkpoint \(checkpointTurnCount) has no restorable file snapshot")
        }
        guard GitDiff.isGit(cwd) else {
            throw AgentProviderAdapterError.unsupported("checkpoint revert requires a git workspace")
        }

        let newer = try checkpointRepo.listAfter(threadId: threadId, checkpointTurnCount: checkpointTurnCount)
        try validateRestorableSnapshots(in: checkpoint, newerCheckpoints: newer, cwd: cwd)
        // UX-MAC-CHECKPOINT-REVERT-UNDO: capture the forward state the revert is
        // about to DESTROY — pre-revert on-disk bytes for every affected path and
        // the message rows about to be deleted — BEFORE restoreWorkspace + the
        // deletes run. This must happen here (post-validate, pre-mutation) or it
        // would snapshot the reverted state. Pure read + store; revert behavior
        // below is unchanged.
        captureCheckpointRevertUndo(threadId: threadId, target: checkpoint, newer: newer, cwd: cwd)
        try await rollbackThread(threadId: threadId, toTurnId: checkpoint.turnId)
        try restoreWorkspace(to: checkpoint, newerCheckpoints: newer, cwd: cwd)
        try messageRepo.delete(ids: newer.compactMap(\.assistantMessageId))
        try checkpointRepo.deleteAfter(threadId: threadId, checkpointTurnCount: checkpointTurnCount)
        // PERF-MAC_AGENT-006: assistant rows were just deleted — drop the dedup
        // cache so a re-run can legitimately re-persist matching text.
        lock.lock(); lastPersistedAssistantContent.removeValue(forKey: threadId); lock.unlock()
        return checkpoint
    }

    /// Replay the ENTIRE persisted thread, not just the last 500 events. The DB is already
    /// pruned to ~5000 events/thread (pruneStreamEvents), so this is bounded; capping the
    /// replay at 500 here was truncating the reopened transcript to its last few turns.
    public func latestStreamEvents(threadId: AgentThreadID) -> [AssistantEvent] {
        (try? runRepo.listLatestStreamEvents(threadId: threadId, limit: .max)) ?? []
    }

    public func activeThreadIdsSnapshot() -> Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        return Set(activeThreads.keys)
    }

    /// Returns true when the thread has a recoverable provider session (was
    /// interrupted by relaunch and can be resumed via startRun). Used by the
    /// surface to decide whether to show the inline Continue action.
    /// WHY: coordinator owns providerSessionRepo; surface should not reach
    /// through to the repo directly.
    public func hasRecoverableContext(threadId: AgentThreadID) -> Bool {
        guard let repo = providerSessionRepo else { return false }
        switch (try? repo.recoveryState(threadId: threadId)) ?? .unrecoverable("no repo") {
        case .recoverable:
            return true
        default:
            return false
        }
    }

    public func stopAllProviderSessions() {
        lock.lock()
        let adapters = Array(providers.values)
        lock.unlock()
        adapters.forEach { $0.stopAll() }
    }

    private func adapterForThread(_ threadId: AgentThreadID) throws -> AgentProviderAdapter {
        guard let thread = try threadRepo.get(id: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        lock.lock()
        let adapter = providers[thread.provider]
        lock.unlock()
        guard let adapter else {
            throw AgentRunError.missingBinary(thread.provider.rawValue)
        }
        return adapter
    }

    private func recoverableResumeContext(for request: AgentRunRequest) throws -> ProviderRecoveryContext? {
        if let liveSession = liveAdapterSession(for: request) {
            return ProviderRecoveryContext(resumeCursor: liveSession.providerThreadId)
        }
        guard let providerSessionRepo else { return nil }
        switch try providerSessionRepo.recoveryState(threadId: request.threadId) {
        case .recoverable(let session) where session.provider == request.provider:
            return ProviderRecoveryContext(session: session)
        case .active(let session) where session.provider == request.provider:
            if session.resumeCursor?.isEmpty == false {
                return ProviderRecoveryContext(session: session)
            }
            if let thread = try threadRepo.get(id: request.threadId), thread.providerThreadId?.isEmpty == false {
                throw AgentProviderAdapterError.unsupported("Provider session is marked active but no live provider session or resume cursor is available; restart recovery cannot safely continue this thread.")
            }
            return nil
        case .stopped(let session) where session.provider == request.provider:
            if session.resumeCursor?.isEmpty != false,
               let thread = try threadRepo.get(id: request.threadId),
               thread.providerThreadId?.isEmpty != false {
                return nil
            }
            throw AgentProviderAdapterError.unsupported("Session was stopped. Tap Continue to resume from the last checkpoint, or start a new thread.")
        case .unrecoverable(let reason):
            if let thread = try threadRepo.get(id: request.threadId), thread.providerThreadId?.isEmpty == false {
                throw AgentProviderAdapterError.unsupported(reason)
            }
            return nil
        default:
            return nil
        }
    }

    private func liveAdapterSession(for request: AgentRunRequest) -> AgentProviderSessionSummary? {
        lock.lock()
        let adapter = providers[request.provider]
        lock.unlock()
        return adapter?.listSessions().first { session in
            session.threadId == request.threadId && session.provider == request.provider
        }
    }

    private func providerAdapterKey(_ adapter: AgentProviderAdapter) -> String {
        let adapterType = String(describing: type(of: adapter))
        if let oneShot = adapter as? OneShotProviderAdapter {
            return "\(adapterType):\(String(describing: type(of: oneShot.runner)))"
        }
        return adapterType
    }

    private func recoverAdapterSessionIfNeeded(threadId: AgentThreadID, adapter: AgentProviderAdapter) async throws {
        guard !adapter.hasSession(threadId: threadId) else { return }
        guard let thread = try threadRepo.get(id: threadId) else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let session = try providerSessionRepo?.get(threadId: threadId),
              session.provider == thread.provider,
              let resumeCursor = session.resumeCursor,
              !resumeCursor.isEmpty else {
            return
        }
        let cwd = session.cwd ?? thread.worktreePath
        guard let cwd, !cwd.isEmpty else {
            throw AgentProviderAdapterError.unsupported("Provider session recovery requires cwd")
        }
        let activeTurnId = ProviderSessionRuntimePayload.decode(session.runtimePayloadJSON).activeTurnId
        let request = AgentRunRequest(
            threadId: threadId,
            provider: thread.provider,
            providerInstanceId: thread.providerInstanceId,
            model: session.model ?? thread.model,
            cwd: cwd,
            prompt: "",
            providerThreadId: resumeCursor,
            permissionMode: session.runtimeMode,
            reasoningEffort: thread.reasoningEffort,
            serviceTier: session.serviceTier,
            interactionMode: .default,
            // Tag the recovered session's environment with the provider so `| distill`
            // tool calls attribute Token Saver savings correctly (not "unknown").
            environment: ["REMOTE_CODE_AGENT_PROVIDER": thread.provider.rawValue],
            extraArgs: activeTurnId.map { ["remotecode.recovery.activeTurnId=\($0)"] } ?? []
        )
        try await adapter.recoverSession(request) { _ in }
    }

    private func providerBinaryIdentity(_ provider: AgentProvider, adapter: AgentProviderAdapter) -> String? {
        guard adapter is OneShotProviderAdapter else { return providerAdapterKey(adapter) }
        let binaryName = provider.rawValue
        if let path = ProcessLocator.resolve(binaryName) {
            return "\(binaryName):\(path)"
        }
        return "\(binaryName):unresolved"
    }

    // PERF-MAC_AGENT-007: a drained batch of stream-event writes plus whether a
    // prune is due, ready to be replayed against the repos outside `lock`.
    private struct BatchFlush {
        var items: [StreamWriteItem]
        var pruneDue: Bool
    }

    /// Must be called with `lock` held. Drains the per-thread buffer and resets the
    /// flush clock so the next event starts a fresh time budget.
    private func takeStreamFlushLocked(threadId: AgentThreadID, pruneDue: Bool, nowMs: Int64) -> BatchFlush? {
        guard var batch = pendingStreamWrites[threadId], !batch.isEmpty else {
            if pruneDue { return BatchFlush(items: [], pruneDue: true) }
            return nil
        }
        let items = batch.drain()
        pendingStreamWrites[threadId] = batch
        lastStreamFlushMs[threadId] = nowMs
        return BatchFlush(items: items, pruneDue: pruneDue)
    }

    /// Replays a drained batch: inserts each stream event (and provider-event log)
    /// in seq order, optionally prunes, then writes diagnostics ONCE using the last
    /// event's kind. This preserves the persisted content/order of the old per-event
    /// path while collapsing 2-3 writes/event into one batched flush.
    private func flushStreamWrites(_ flush: BatchFlush, runId: AgentRunID, threadId: AgentThreadID) {
        do {
            for item in flush.items {
                try runRepo.appendStreamEvent(runId: runId, seq: item.seq, kind: item.kind, payloadJSON: item.payloadJSON)
                if let providerEvent = item.providerEvent {
                    try runRepo.appendProviderEventLog(threadId: threadId, runId: runId, event: providerEvent)
                }
            }
            if flush.pruneDue {
                try runRepo.pruneStreamEvents(threadId: threadId)
            }
            if let lastKind = flush.items.last?.kind {
                try providerSessionRepo?.updateDiagnostics(threadId: threadId, lastEventKind: lastKind, lastErrorMessage: nil)
            }
        } catch {
            emitPersistenceIssue("run.stream_event.append", error: error, runId: runId, threadId: threadId)
        }
    }

    /// Drain and persist any buffered stream writes for a thread immediately. Used
    /// on terminal/stop paths so the tail of a fast stream is never stranded in the
    /// buffer once the run is no longer producing events.
    private func flushPendingStreamWrites(runId: AgentRunID, threadId: AgentThreadID) {
        lock.lock()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let flush = takeStreamFlushLocked(threadId: threadId, pruneDue: false, nowMs: nowMs)
        lock.unlock()
        if let flush, !flush.items.isEmpty {
            flushStreamWrites(flush, runId: runId, threadId: threadId)
        }
    }

    private func updateProviderRuntimePayload(
        threadId: AgentThreadID,
        runId: AgentRunID,
        mutate: (inout ProviderSessionRuntimePayload) -> Void
    ) {
        do {
            guard var session = try providerSessionRepo?.get(threadId: threadId) else { return }
            var payload = ProviderSessionRuntimePayload.decode(session.runtimePayloadJSON)
            mutate(&payload)
            session.runtimePayloadJSON = payload.encoded()
            session.updatedAt = Date()
            try providerSessionRepo?.upsert(session)
        } catch {
            emitPersistenceIssue("provider_session.runtime_payload.update", error: error, runId: runId, threadId: threadId)
        }
    }

    private func updateProviderRuntimePayloadFromProviderEvent(
        _ event: ProviderRuntimeEvent,
        threadId: AgentThreadID,
        runId: AgentRunID
    ) {
        guard event.provider == .claude,
              event.method == "claude.session.snapshot",
              let data = event.payloadJSON.data(using: .utf8),
              let snapshot = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
            if let providerThreadId = snapshot["providerThreadId"] as? String ?? snapshot["resume"] as? String {
                payload.providerThreadId = providerThreadId
            }
            if let lastCompletedTurnId = snapshot["lastCompletedTurnId"] as? String {
                payload.lastCompletedTurnId = lastCompletedTurnId
            }
            if let turnCount = snapshot["turnCount"] as? Int {
                payload.turnCount = max(payload.turnCount, turnCount)
            }
            if let model = snapshot["model"] as? String {
                payload.model = model
            }
            payload.activeTurnId = snapshot["activeTurnId"] as? String
            payload.claudeResumeSessionAt = snapshot["resumeSessionAt"] as? String
                ?? snapshot["lastAssistantUuid"] as? String
                ?? payload.claudeResumeSessionAt
            payload.claudeInFlightToolIds = snapshot["inFlightToolIds"] as? [String] ?? payload.claudeInFlightToolIds
            payload.pendingApprovalRequestIds = snapshot["pendingApprovalRequestIds"] as? [String] ?? payload.pendingApprovalRequestIds
            payload.pendingUserInputRequestIds = snapshot["pendingUserInputRequestIds"] as? [String] ?? payload.pendingUserInputRequestIds
            payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        }
    }

    @discardableResult
    private func persistAssistantIfMissing(_ text: String, threadId: AgentThreadID, runId: AgentRunID) -> AgentMessage? {
        let text = AssistantTimelineState.cappedText(sanitizeFinalAssistantText(text))
        guard !text.isEmpty else { return nil }
        // PERF-MAC_AGENT-006: the common duplicate is the same turn's final
        // message arriving via both `turnCompleted` and `finished`. Skip the
        // full-history load when the text matches the last one we persisted;
        // only fall back to the O(history) scan on a cache miss (which still
        // guards the rare cross-turn duplicate before appending).
        lock.lock()
        let cachedLast = lastPersistedAssistantContent[threadId]
        lock.unlock()
        if cachedLast == text { return nil }
        let existing: [AgentMessage]
        do {
            existing = try messageRepo.list(threadId: threadId)
        } catch {
            emitPersistenceIssue("message.list", error: error, runId: runId, threadId: threadId)
            return nil
        }
        guard !existing.contains(where: { $0.role == .assistant && $0.content == text }) else {
            // Warm the cache on history-scan hit too, subject to the same size cap.
            let byteCountHit = text.utf8.count
            if !Self.shouldEvictLastPersistedContent(threadClosed: false, entryByteCount: byteCountHit) {
                lock.lock(); lastPersistedAssistantContent[threadId] = text; lock.unlock()
            }
            return nil
        }
        let message = AgentMessage(threadId: threadId, role: .assistant, content: text)
        do {
            try messageRepo.append(message)
        } catch {
            emitPersistenceIssue("message.append.assistant", error: error, runId: runId, threadId: threadId)
            return nil
        }
        // PERF-MAC_AGENT-008: only cache if the entry is within the byte cap;
        // oversized entries skip the cache and rely on the full-history scan for
        // dedup, bounding per-entry retained memory for very long responses.
        let byteCount = text.utf8.count
        if !Self.shouldEvictLastPersistedContent(threadClosed: false, entryByteCount: byteCount) {
            lock.lock(); lastPersistedAssistantContent[threadId] = text; lock.unlock()
        }
        onMessageAppended?(message)
        return message
    }

    private func sanitizeFinalAssistantText(_ text: String) -> String {
        RetrieveHandleSanitizer.strip(text)
    }

    private func sanitizeFinalAssistantText(_ text: String?) -> String? {
        text.map(sanitizeFinalAssistantText)
    }

    private func sanitizeFinalAssistantEvent(_ ev: AssistantEvent) -> AssistantEvent {
        if case .turnCompleted(let turnId, let finalMessage) = ev {
            return .turnCompleted(turnId: turnId, finalMessage: sanitizeFinalAssistantText(finalMessage))
        }
        return ev
    }

    private func handle(
        event: AgentRunEvent,
        runId: AgentRunID,
        threadId: AgentThreadID,
        allowFinalResponseTranslation: Bool = true
    ) {
        switch event {
        case .event(let rawEvent):
            let ev = sanitizeFinalAssistantEvent(rawEvent)
            if allowFinalResponseTranslation,
               case .turnCompleted(let turnId, let finalMessage) = ev,
               let finalMessage,
               shouldTranslateFinalResponse(finalMessage) {
                rememberCompletedTurn(turnId, runId: runId)
                return
            }
            if let decision = interceptProviderTextEvent(ev, runId: runId, threadId: threadId) {
                switch decision {
                case .hold:
                    return
                case .emit(let events):
                    for event in events {
                        handle(
                            event: .event(event),
                            runId: runId,
                            threadId: threadId,
                            allowFinalResponseTranslation: false
                        )
                    }
                    return
                case .translate(let itemId, let text, let target, let finalState):
                    Task { [weak self] in
                        guard let self else { return }
                        let translated = await self.translateSR1Response(text, runId: runId, threadId: threadId)
                        if translated != text {
                            self.handle(
                                event: .event(.sr1Translation(AssistantSR1Translation(
                                    itemId: itemId,
                                    originalText: text,
                                    rewrittenText: translated
                                ))),
                                runId: runId,
                                threadId: threadId,
                                allowFinalResponseTranslation: false
                            )
                        }
                        let delta: AssistantEvent
                        switch target {
                        case .body:
                            delta = .itemDelta(itemId: itemId, bodyAppend: translated, outputAppend: nil, summary: nil)
                        case .output:
                            delta = .itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: translated, summary: nil)
                        }
                        self.handle(
                            event: .event(delta),
                            runId: runId,
                            threadId: threadId,
                            allowFinalResponseTranslation: false
                        )
                        self.handle(
                            event: .event(.itemCompleted(itemId: itemId, finalState: finalState)),
                            runId: runId,
                            threadId: threadId,
                            allowFinalResponseTranslation: false
                        )
                    }
                    return
                }
            }
            lock.lock()
            let s = (seq[runId] ?? 0) + 1
            seq[runId] = s
            let data = try? streamEventEncoder.encode(ev)
            lock.unlock()
            // PERF-MAC_AGENT-007: buffer the per-event writes (stream event +
            // optional provider-event log) and flush them in batches instead of
            // 2-3 synchronous transactions per delta. Prune cadence and diagnostics
            // are coalesced into the flush. The payload compactor runs outside the
            // lock (as before) since it is an external, structure-preserving call.
            if let data, let json = String(data: data, encoding: .utf8) {
                let payloadJSON = streamPayloadCompactor?(json) ?? json
                let providerEvent: ProviderRuntimeEvent?
                if case .providerRuntime(let runtimeEvent) = ev { providerEvent = runtimeEvent } else { providerEvent = nil }
                lock.lock()
                var batch = pendingStreamWrites[threadId] ?? StreamWriteBatch()
                batch.append(StreamWriteItem(seq: s, kind: ev.debugDescription, payloadJSON: payloadJSON, providerEvent: providerEvent))
                pendingStreamWrites[threadId] = batch
                // Prune at most once per `streamEventPruneInterval` events per thread.
                let pruneCount = (streamEventsSincePrune[threadId] ?? 0) + 1
                let pruneDue = pruneCount >= Self.streamEventPruneInterval
                streamEventsSincePrune[threadId] = pruneDue ? 0 : pruneCount
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let lastMs = lastStreamFlushMs[threadId] ?? nowMs
                lastStreamFlushMs[threadId] = lastStreamFlushMs[threadId] ?? nowMs
                var flushNow: BatchFlush?
                if Self.shouldFlushStreamBatch(pendingCount: batch.count, sinceLastFlushMs: nowMs - lastMs) || pruneDue {
                    flushNow = takeStreamFlushLocked(threadId: threadId, pruneDue: pruneDue, nowMs: nowMs)
                }
                lock.unlock()
                if let flushNow {
                    flushStreamWrites(flushNow, runId: runId, threadId: threadId)
                }
            }
            switch ev {
            case .providerRuntime(let runtimeEvent):
                updateProviderRuntimePayloadFromProviderEvent(runtimeEvent, threadId: threadId, runId: runId)
            case .turnStarted(let turnId):
                lock.lock()
                activeTurnIds[runId] = turnId
                lock.unlock()
                updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                    payload.activeTurnId = turnId
                    payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                }
            case .requestOpened(let request):
                updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                    if !payload.pendingApprovalRequestIds.contains(request.id) {
                        payload.pendingApprovalRequestIds.append(request.id)
                    }
                    payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                }
            case .requestResolved(let requestId, _):
                updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                    payload.pendingApprovalRequestIds.removeAll { $0 == requestId }
                    payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                }
            case .userInputRequested(let request):
                updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                    if !payload.pendingUserInputRequestIds.contains(request.id) {
                        payload.pendingUserInputRequestIds.append(request.id)
                    }
                    payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                }
            case .userInputResolved(let requestId, _):
                updateProviderRuntimePayload(threadId: threadId, runId: runId) { payload in
                    payload.pendingUserInputRequestIds.removeAll { $0 == requestId }
                    payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                }
            case .turnCompleted(let turnId, let finalMessage):
                lock.lock()
                activeTurnIds[runId] = turnId
                lock.unlock()
                if let msg = finalMessage,
                   let persisted = persistAssistantIfMissing(msg, threadId: threadId, runId: runId) {
                    lock.lock()
                    activeAssistantMessageIds[runId] = persisted.id
                    lock.unlock()
                }
            default:
                break
            }
            for observer in observersSnapshot() {
                observer.runCoordinator(self, didReceive: ev, run: runId, threadId: threadId)
            }
            onAssistantEvent?(ev, threadId, runId)
        case .status(let st):
            for observer in observersSnapshot() {
                observer.runCoordinator(self, didChangeStatus: st, runId: runId, threadId: threadId)
            }
        case .finished(let status, let rawFinalMessage, let providerThreadId):
            let finalMessage = sanitizeFinalAssistantText(rawFinalMessage)
            if allowFinalResponseTranslation,
               status == .completed,
               let finalMessage,
               shouldTranslateFinalResponse(finalMessage) {
                Task { [weak self] in
                    guard let self else { return }
                    let translated = await self.translateFinalResponse(finalMessage, runId: runId, threadId: threadId)
                    if let completedTurnId = self.completedTurnId(runId: runId) {
                        self.handle(
                            event: .event(.turnCompleted(turnId: completedTurnId, finalMessage: translated)),
                            runId: runId,
                            threadId: threadId,
                            allowFinalResponseTranslation: false
                        )
                    }
                    self.lock.lock()
                    let translatedMsgId = self.activeAssistantMessageIds[runId]
                    self.lock.unlock()
                    if let mid = translatedMsgId, translated != finalMessage {
                        self.handle(
                            event: .event(.sr1Translation(AssistantSR1Translation(
                                messageId: mid.value.uuidString,
                                originalText: finalMessage,
                                rewrittenText: translated
                            ))),
                            runId: runId,
                            threadId: threadId,
                            allowFinalResponseTranslation: false
                        )
                    }
                    self.handle(
                        event: .finished(status, finalMessage: translated, providerThreadId: providerThreadId),
                        runId: runId,
                        threadId: threadId,
                        allowFinalResponseTranslation: false
                    )
                    // Signal callers that a translated message was persisted.
                    // activeAssistantMessageIds[runId] is set by the turnCompleted
                    // handle above (persistAssistantIfMissing -> activeAssistantMessageIds).
                    if let mid = translatedMsgId {
                        self.onSR1TranslatedMessageId?(mid)
                    }
                }
	                return
	            }
            // PERF-MAC_AGENT-007: drain any buffered stream writes before the run
            // tears down, so the tail of a fast stream is durably persisted (and
            // visible to latestStreamEvents/reload) once the run finishes.
            flushPendingStreamWrites(runId: runId, threadId: threadId)
            // persist final assistant message only on success
            if status == .completed, let msg = finalMessage, !msg.isEmpty {
                if let persisted = persistAssistantIfMissing(msg, threadId: threadId, runId: runId) {
                    lock.lock()
                    activeAssistantMessageIds[runId] = persisted.id
                    lock.unlock()
                }
            }
            lock.lock()
            let runMetadata = activeRunMetadata[runId]
            let completedTurnId = activeTurnIds[runId]
            let assistantMessageId = activeAssistantMessageIds[runId]
            lock.unlock()
            let fallbackThread = try? threadRepo.get(id: threadId)
            let finishedProvider = runMetadata?.provider ?? fallbackThread?.provider ?? .codex
            let finishedProviderInstanceId = runMetadata?.providerInstanceId ?? fallbackThread?.providerInstanceId ?? finishedProvider.rawValue
            let finishedModel = runMetadata?.model ?? fallbackThread?.model ?? ""
            // update run row
            var run = AgentRun(id: runId, threadId: threadId, provider: finishedProvider, providerInstanceId: finishedProviderInstanceId, model: finishedModel)
            run.status = status
            run.finishedAt = Date()
            do {
                try runRepo.upsert(run)
            } catch {
                emitPersistenceIssue("run.upsert.finished", error: error, runId: runId, threadId: threadId)
            }
            // update thread status + provider thread id
            do {
                guard let t = try threadRepo.get(id: threadId) else {
                    throw NSError(domain: "RemoteCode.AgentRunCoordinator", code: 404, userInfo: [
                        NSLocalizedDescriptionKey: "Thread row missing while finishing run."
                    ])
                }
                var copy = t
                copy.status = status
                if let ptid = providerThreadId { copy.providerThreadId = ptid }
                copy.updatedAt = Date()
                try threadRepo.upsert(copy)
            } catch {
                emitPersistenceIssue("thread.upsert.finished", error: error, runId: runId, threadId: threadId)
            }
            let resumeCursor = providerThreadId ?? fallbackThread?.providerThreadId
            do {
                let existingPayload = try providerSessionRepo?.get(threadId: threadId)?.runtimePayloadJSON
                let runtimePayload = providerSessionRuntimePayloadJSON(
                    existingPayload,
                    status: status,
                    resumeCursor: resumeCursor,
                    completedTurnId: completedTurnId,
                    model: finishedModel,
                    serviceTier: runMetadata?.serviceTier ?? .auto,
                    runtimeMode: runMetadata?.runtimeMode ?? .supervised,
                    interactionMode: runMetadata?.interactionMode ?? .default,
                    activeTurnId: nil,
                    updatedAt: Date()
                )
                try providerSessionRepo?.upsert(ProviderSessionRuntime(
                    threadId: threadId,
                    provider: finishedProvider,
                    providerInstanceId: finishedProviderInstanceId,
                    adapterKey: runMetadata?.adapterKey,
                    binaryIdentity: runMetadata?.binaryIdentity,
                    status: status,
                    resumeCursor: resumeCursor,
                    cwd: runMetadata?.cwd,
                    model: finishedModel,
                    serviceTier: runMetadata?.serviceTier ?? .auto,
                    runtimeMode: runMetadata?.runtimeMode ?? .supervised,
                    lastEventKind: "run.finished",
                    runtimePayloadJSON: runtimePayload
                ))
            } catch {
                emitPersistenceIssue("provider_session.upsert.finished", error: error, runId: runId, threadId: threadId)
            }
            if status == .completed {
                captureCheckpoint(
                    threadId: threadId,
                    runId: runId,
                    turnId: completedTurnId,
                    cwd: runMetadata?.cwd,
                    assistantMessageId: assistantMessageId
                )
            }
            lock.lock()
            active.removeValue(forKey: runId)
            activeThreads.removeValue(forKey: threadId)
            activeRunMetadata.removeValue(forKey: runId)
            activeTurnIds.removeValue(forKey: runId)
            activeAssistantMessageIds.removeValue(forKey: runId)
            activeProviderTextItemTypes.removeValue(forKey: runId)
            bufferedProviderTextItems.removeValue(forKey: runId)
            activeDistillOutputRuns.remove(runId)
            pendingThreadStops.remove(threadId)
            seq.removeValue(forKey: runId)
            // PERF-MAC_AGENT-005: flush a final prune at run end so events queued
            // since the last cadence-prune don't linger unbounded.
            let pendingPrune = (streamEventsSincePrune[threadId] ?? 0) > 0
            streamEventsSincePrune.removeValue(forKey: threadId)
            // PERF-MAC_AGENT-007: buffer was drained by flushPendingStreamWrites
            // above; drop the per-thread batch + flush clock so they don't leak.
            pendingStreamWrites.removeValue(forKey: threadId)
            lastStreamFlushMs.removeValue(forKey: threadId)
            // PERF-MAC_AGENT-008: thread closed -> evict the dedup cache entry so
            // finished threads do not retain their final-answer text indefinitely.
            lastPersistedAssistantContent.removeValue(forKey: threadId)
            lock.unlock()
            if pendingPrune {
                do {
                    try runRepo.pruneStreamEvents(threadId: threadId)
                } catch {
                    emitPersistenceIssue("run.stream_event.prune.finish", error: error, runId: runId, threadId: threadId)
                }
            }
            // PERF-MAC_AGENT-009: prune provider event logs unconditionally at run
            // finish so they are bounded to the default 10,000 per thread. Provider
            // events are written at lower frequency than stream events, so a per-event
            // cadence gate is not needed; one DELETE at run-end is cheap and bounded.
            do {
                try runRepo.pruneProviderEventLogs(threadId: threadId)
            } catch {
                emitPersistenceIssue("run.provider_event.prune.finish", error: error, runId: runId, threadId: threadId)
            }
            let durationMs = (try? runRepo.get(id: runId)).flatMap { row -> Int64? in
                guard let finished = row.finishedAt else { return nil }
                return Int64(finished.timeIntervalSince(row.startedAt) * 1000)
            } ?? -1
            agentRunLog.info("run.finished thread=\(threadId.value.uuidString, privacy: .public) run=\(runId.value.uuidString, privacy: .public) status=\(status.rawValue, privacy: .public) durationMs=\(durationMs, privacy: .public)")
            for observer in observersSnapshot() {
                observer.runCoordinator(self, didFinish: runId, threadId: threadId, status: status, finalMessage: finalMessage, providerThreadId: providerThreadId)
            }
            onRunFinished?(threadId, runId, status)
        case .error(let m):
            for observer in observersSnapshot() {
                observer.runCoordinator(self, didReceive: .error(message: m, recoverable: false), run: runId, threadId: threadId)
            }
            onAssistantEvent?(.error(message: m, recoverable: false), threadId, runId)
            try? providerSessionRepo?.updateDiagnostics(threadId: threadId, lastEventKind: "error", lastErrorMessage: m)
        }
    }

    private func shouldTranslateFinalResponse(_ text: String) -> Bool {
        finalResponseTranslator != nil && SR1ResponseDetector.isSR1(text)
    }

    private enum ProviderTextTarget {
        case body
        case output
    }

    private struct BufferedProviderTextItem {
        var text: String
        var target: ProviderTextTarget
        var itemType: AssistantItemType
    }

    private enum ProviderTextDecision {
        case hold
        case emit([AssistantEvent])
        case translate(itemId: String, text: String, target: ProviderTextTarget, finalState: AssistantItemState)
    }

    private func interceptProviderTextEvent(_ ev: AssistantEvent, runId: AgentRunID, threadId: AgentThreadID) -> ProviderTextDecision? {
        guard finalResponseTranslator != nil else { return nil }
        switch ev {
        case .itemStarted(let item):
            if isProviderTextItem(item.type) {
                lock.lock()
                var items = activeProviderTextItemTypes[runId] ?? [:]
                items[item.id] = item.type
                activeProviderTextItemTypes[runId] = items
                lock.unlock()
            }
            return nil
        case .itemDelta(let itemId, let bodyAppend, let outputAppend, _):
            let itemType = providerTextItemType(runId: runId, itemId: itemId)
            guard let itemType, isProviderTextItem(itemType) else { return nil }
            let rawTarget: ProviderTextTarget?
            let delta: String?
            if let bodyAppend {
                rawTarget = .body
                delta = bodyAppend
            } else if let outputAppend {
                rawTarget = .output
                delta = outputAppend
            } else {
                rawTarget = nil
                delta = nil
            }
            guard let rawTarget, let delta, !delta.isEmpty else { return nil }
            let target = itemType == .reasoning ? ProviderTextTarget.body : rawTarget

            lock.lock()
            var runBuffers = bufferedProviderTextItems[runId] ?? [:]
            if var buffered = runBuffers[itemId] {
                buffered.text = AssistantTimelineState.cappedText(buffered.text + delta)
                runBuffers[itemId] = buffered
                bufferedProviderTextItems[runId] = runBuffers
                lock.unlock()
                return .hold
            }
            let shouldBuffer = shouldBufferProviderTextPrefix(delta)
            if shouldBuffer {
                runBuffers[itemId] = BufferedProviderTextItem(
                    text: AssistantTimelineState.cappedText(delta),
                    target: target,
                    itemType: itemType
                )
                bufferedProviderTextItems[runId] = runBuffers
                lock.unlock()
                return .hold
            }
            lock.unlock()
            return nil
        case .itemCompleted(let itemId, let finalState):
            lock.lock()
            var runBuffers = bufferedProviderTextItems[runId] ?? [:]
            let buffered = runBuffers.removeValue(forKey: itemId)
            if runBuffers.isEmpty {
                bufferedProviderTextItems.removeValue(forKey: runId)
            } else {
                bufferedProviderTextItems[runId] = runBuffers
            }
            var itemTypes = activeProviderTextItemTypes[runId] ?? [:]
            itemTypes.removeValue(forKey: itemId)
            if itemTypes.isEmpty {
                activeProviderTextItemTypes.removeValue(forKey: runId)
            } else {
                activeProviderTextItemTypes[runId] = itemTypes
            }
            lock.unlock()
            guard let buffered else { return nil }
            if shouldTranslateProviderText(buffered.text, runId: runId) {
                let target = buffered.itemType == .reasoning ? ProviderTextTarget.body : buffered.target
                return .translate(itemId: itemId, text: buffered.text, target: target, finalState: finalState)
            }
            let delta: AssistantEvent
            switch buffered.target {
            case .body:
                delta = .itemDelta(itemId: itemId, bodyAppend: buffered.text, outputAppend: nil, summary: nil)
            case .output:
                delta = .itemDelta(itemId: itemId, bodyAppend: nil, outputAppend: buffered.text, summary: nil)
            }
            return .emit([delta, .itemCompleted(itemId: itemId, finalState: finalState)])
        default:
            return nil
        }
    }

    private func providerTextItemType(runId: AgentRunID, itemId: String) -> AssistantItemType? {
        lock.lock()
        defer { lock.unlock() }
        return activeProviderTextItemTypes[runId]?[itemId]
    }

    private func isProviderTextItem(_ type: AssistantItemType) -> Bool {
        type == .assistantMessage || type == .reasoning
    }

    private func shouldBufferProviderTextPrefix(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pure-whitespace deltas are not SR1 signals; stream them live so a
        // normal reply whose first chunk is "\n" does not appear all-at-once.
        guard !trimmed.isEmpty else { return false }
        if SR1ResponseDetector.isSR1(trimmed) { return true }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("sr1") || lower.hasPrefix("dict") { return true }
        guard let first = trimmed.first?.uppercased().first,
              "SCDRONP".contains(first) else {
            return false
        }
        let rest = trimmed.dropFirst()
        guard let delimiter = rest.first else { return true }
        return delimiter == ":" || delimiter == "=" || delimiter == " " || delimiter == "\t"
    }

    private func shouldTranslateProviderText(_ text: String, runId: AgentRunID) -> Bool {
        if SR1ResponseDetector.isSR1(text) {
            markDistillOutputMode(runId)
            return true
        }
        let allowOutcomeSpace = runUsesDistillOutputMode(runId)
        if SR1ResponseDetector.isSingleSemanticLine(text, allowSpaceDelimitedOutcome: allowOutcomeSpace) {
            markDistillOutputMode(runId)
            return true
        }
        return false
    }

    private func markDistillOutputMode(_ runId: AgentRunID) {
        lock.lock()
        activeDistillOutputRuns.insert(runId)
        lock.unlock()
    }

    private func clearDistillOutputMode(_ runId: AgentRunID) {
        lock.lock()
        activeDistillOutputRuns.remove(runId)
        lock.unlock()
    }

    private func runUsesDistillOutputMode(_ runId: AgentRunID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeDistillOutputRuns.contains(runId)
    }

    private static func promptInvokesDistill(_ text: String?) -> Bool {
        guard let text else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("/distill") else { return false }
        guard trimmed.count > "/distill".count else { return true }
        let boundary = trimmed.index(trimmed.startIndex, offsetBy: "/distill".count)
        return trimmed[boundary].isWhitespace
    }

    private func rememberCompletedTurn(_ turnId: String, runId: AgentRunID) {
        lock.lock()
        activeTurnIds[runId] = turnId
        lock.unlock()
    }

    private func completedTurnId(runId: AgentRunID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return activeTurnIds[runId]
    }

    private func translateFinalResponse(_ response: String, runId: AgentRunID, threadId: AgentThreadID) async -> String {
        await translateSR1Response(response, runId: runId, threadId: threadId)
    }

    private func translateSR1Response(_ response: String, runId: AgentRunID, threadId: AgentThreadID) async -> String {
        guard let finalResponseTranslator else { return response }
        let provider: AgentProvider = {
            lock.lock()
            let activeProvider = activeRunMetadata[runId]?.provider
            lock.unlock()
            if let activeProvider { return activeProvider }
            return (try? threadRepo.get(id: threadId)?.provider) ?? .codex
        }()
        let translated = await finalResponseTranslator(response, provider, threadId, runId)
        let trimmed = sanitizeFinalAssistantText(translated).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? response : trimmed
    }

    private func captureCheckpoint(
        threadId: AgentThreadID,
        runId: AgentRunID,
        turnId rawTurnId: String?,
        cwd: String?,
        assistantMessageId: AgentMessageID?
    ) {
        guard let checkpointRepo else { return }
        let turnId = rawTurnId?.isEmpty == false ? rawTurnId! : "run-\(runId.value.uuidString)"
        let count: Int
        do {
            count = try checkpointRepo.nextTurnCount(threadId: threadId)
        } catch {
            emitPersistenceIssue("checkpoint.next_turn_count", error: error, runId: runId, threadId: threadId)
            return
        }
        let checkpointRef = "local-diff:\(runId.value.uuidString):\(turnId)"
        let summary: AgentTurnCheckpointSummary
        if let cwd, !cwd.isEmpty {
            let gitSummary = GitDiff.summary(in: cwd)
            if gitSummary.isGitRepo {
                let files = gitSummary.files.map {
                    AgentTurnCheckpointFile(
                        path: $0.path,
                        kind: $0.status.rawValue,
                        additions: $0.additions,
                        deletions: $0.deletions
                    )
                }
                summary = AgentTurnCheckpointSummary(
                    threadId: threadId,
                    runId: runId,
                    turnId: turnId,
                    checkpointTurnCount: count,
                    checkpointRef: checkpointRef,
                    status: .ready,
                    files: files,
                    fileSnapshots: captureFileSnapshots(files: files, cwd: cwd),
                    diffPatch: GitDiff.diff(in: cwd, path: nil),
                    fileDiffs: captureFileDiffs(files: files, cwd: cwd),
                    assistantMessageId: assistantMessageId
                )
            } else {
                summary = AgentTurnCheckpointSummary(
                    threadId: threadId,
                    runId: runId,
                    turnId: turnId,
                    checkpointTurnCount: count,
                    checkpointRef: checkpointRef,
                    status: .missing,
                    files: [],
                    assistantMessageId: assistantMessageId,
                    errorMessage: "Not a git repository."
                )
            }
        } else {
            summary = AgentTurnCheckpointSummary(
                threadId: threadId,
                runId: runId,
                turnId: turnId,
                checkpointTurnCount: count,
                checkpointRef: checkpointRef,
                status: .missing,
                files: [],
                assistantMessageId: assistantMessageId,
                errorMessage: "Run workspace is missing."
            )
        }
        do {
            try checkpointRepo.upsert(summary)
            agentRunLog.info("checkpoint.captured thread=\(threadId.value.uuidString, privacy: .public) run=\(runId.value.uuidString, privacy: .public) count=\(count, privacy: .public) status=\(summary.status.rawValue, privacy: .public) files=\(summary.files.count, privacy: .public)")
        } catch {
            emitPersistenceIssue("checkpoint.upsert", error: error, runId: runId, threadId: threadId)
        }
    }

    private func captureFileSnapshots(files: [AgentTurnCheckpointFile], cwd: String) -> [AgentTurnCheckpointFileSnapshot] {
        files.map { file in
            guard file.kind != GitFileStatus.deleted.rawValue,
                  let url = safeWorkspaceURL(cwd: cwd, relativePath: file.path),
                  let data = try? Data(contentsOf: url) else {
                return AgentTurnCheckpointFileSnapshot(path: file.path, kind: file.kind, contentsBase64: nil)
            }
            // P2: cap transient allocation + DB row size. Large or binary files
            // are not base64'd into the checkpoint; we store a nil-content marker
            // (same restore path as a deleted file -> restore from HEAD) and log
            // a content hash so the skip is diagnosable.
            let decision = Self.checkpointSnapshotDecision(
                byteCount: data.count,
                isBinary: Self.dataLooksBinary(data),
                cap: Self.checkpointSnapshotByteCap,
                hash: { Self.sha256Hex(data) }
            )
            switch decision {
            case .snapshot:
                return AgentTurnCheckpointFileSnapshot(path: file.path, kind: file.kind, contentsBase64: data.base64EncodedString())
            case .skipMarker(let hash):
                agentRunLog.info("checkpoint.snapshot.skipped path=\(file.path, privacy: .public) bytes=\(data.count, privacy: .public) hash=\(hash, privacy: .public)")
                return AgentTurnCheckpointFileSnapshot(path: file.path, kind: file.kind, contentsBase64: nil)
            }
        }
    }

    /// P2: per-file checkpoint snapshot decision. Pure + nonisolated so it is
    /// directly unit-testable without standing up a coordinator. A file is only
    /// base64-snapshotted when it is text AND within the byte cap; otherwise the
    /// caller stores a content-hash skip marker instead of the bytes.
    enum CheckpointSnapshotDecision: Equatable {
        case snapshot
        case skipMarker(hash: String)
    }

    /// 1 MiB. Files at or under this (and not binary) are snapshotted inline.
    nonisolated static let checkpointSnapshotByteCap = 1 << 20

    nonisolated static func checkpointSnapshotDecision(
        byteCount: Int,
        isBinary: Bool,
        cap: Int,
        hash: () -> String
    ) -> CheckpointSnapshotDecision {
        if isBinary || byteCount > cap {
            return .skipMarker(hash: hash())
        }
        return .snapshot
    }

    /// Matches the repo's text/binary convention (GitDiff): a NUL byte anywhere
    /// means the content cannot be treated as text.
    nonisolated static func dataLooksBinary(_ data: Data) -> Bool {
        data.contains(0)
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // PERF-MAC_AGENT-007: fast streaming was emitting 2-3 synchronous SQLite
    // writes per stream event (appendStreamEvent + optional appendProviderEventLog
    // + updateDiagnostics), each its own transaction. We now buffer those writes
    // and flush them on a cadence. The buffer + the flush decision are pure and
    // unit-testable so the batching latency/size bounds are pinned by tests.
    struct StreamWriteItem {
        var seq: Int
        var kind: String
        var payloadJSON: String
        var providerEvent: ProviderRuntimeEvent?
    }

    struct StreamWriteBatch {
        private var items: [StreamWriteItem] = []

        var isEmpty: Bool { items.isEmpty }
        var count: Int { items.count }

        mutating func append(_ item: StreamWriteItem) {
            items.append(item)
        }

        mutating func drain() -> [StreamWriteItem] {
            let snapshot = items
            items.removeAll(keepingCapacity: true)
            return snapshot
        }
    }

    // PERF-MAC_AGENT-008: the lastPersistedAssistantContent dedup cache stores one
    // String per thread and is only removed on revertThreadToCheckpoint. In
    // multi-thread sessions the dead entries accumulate and can retain MBs of final-
    // answer text. Evict the entry on thread close/idle (finished or cancelled) and
    // refuse to cache entries whose UTF-8 byte count exceeds the cap (they fall back
    // to the full-history dedup scan, which is correct and rare).
    //
    // lastPersistedAssistantContentSizeCap: entries larger than this are not held in
    // the cache, bounding the per-entry overhead for extremely long responses.
    nonisolated static let lastPersistedAssistantContentSizeCap = 32_768

    /// Pure eviction decision for the lastPersistedAssistantContent dedup cache.
    /// Evict when the thread is no longer active (closed/idle) OR when the entry
    /// is oversized. nonisolated so it is directly unit-testable.
    nonisolated static func shouldEvictLastPersistedContent(
        threadClosed: Bool,
        entryByteCount: Int,
        sizeCapBytes: Int = lastPersistedAssistantContentSizeCap
    ) -> Bool {
        threadClosed || entryByteCount > sizeCapBytes
    }

    /// How many buffered stream events force a flush. Bounds both the in-memory
    /// buffer and the lock-held replay size on a single flush.
    nonisolated static let streamFlushCountThreshold = 16
    /// Max latency (ms) a buffered stream event may wait before being flushed,
    /// so a slow trickle still reaches the DB (and survives reload/crash).
    nonisolated static let streamFlushTimeThresholdMs: Int64 = 250

    /// Pure flush-cadence decision: flush when there is pending work AND either the
    /// count cap is reached or the time budget has elapsed. nonisolated so it is
    /// directly unit-testable without standing up a coordinator.
    nonisolated static func shouldFlushStreamBatch(
        pendingCount: Int,
        sinceLastFlushMs: Int64,
        countThreshold: Int = streamFlushCountThreshold,
        timeThresholdMs: Int64 = streamFlushTimeThresholdMs
    ) -> Bool {
        guard pendingCount > 0 else { return false }
        return pendingCount >= countThreshold || sinceLastFlushMs >= timeThresholdMs
    }

    private func captureFileDiffs(files: [AgentTurnCheckpointFile], cwd: String) -> [AgentTurnCheckpointFileDiff] {
        let paths = files.map(\.path)
        let patchByPath = GitDiff.diffAll(in: cwd, paths: paths)
        return files.map { file in
            let patch = patchByPath[file.path] ?? ""
            return AgentTurnCheckpointFileDiff(path: file.path, patch: patch.isEmpty ? "Untracked file captured in checkpoint: \(file.path)" : patch)
        }
    }

    private func restoreWorkspace(to checkpoint: AgentTurnCheckpointSummary, newerCheckpoints: [AgentTurnCheckpointSummary], cwd: String) throws {
        let targetPaths = Set(checkpoint.fileSnapshots.map(\.path))
        let newerOnlyPaths = Set(newerCheckpoints.flatMap { $0.fileSnapshots.map(\.path) }).subtracting(targetPaths)
        for path in newerOnlyPaths {
            try restoreHeadOrRemove(path: path, cwd: cwd)
        }
        for snapshot in checkpoint.fileSnapshots {
            guard let url = safeWorkspaceURL(cwd: cwd, relativePath: snapshot.path) else {
                throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(snapshot.path)")
            }
            if snapshot.kind == GitFileStatus.deleted.rawValue || snapshot.contentsBase64 == nil {
                try restoreHeadOrRemove(path: snapshot.path, cwd: cwd)
                continue
            }
            guard let encoded = snapshot.contentsBase64,
                  let data = Data(base64Encoded: encoded) else {
                throw AgentProviderAdapterError.unsupported("checkpoint snapshot is corrupt: \(snapshot.path)")
            }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    /// UX-MAC-CHECKPOINT-REVERT-UNDO: snapshot the forward state a revert is
    /// about to destroy. Reads the CURRENT on-disk bytes for every affected path
    /// (nil = absent) and fetches the to-be-deleted message rows, then stores it
    /// under `lock`. Best-effort: a read failure for a single path records it as
    /// absent rather than aborting the revert.
    private func captureCheckpointRevertUndo(
        threadId: AgentThreadID,
        target: AgentTurnCheckpointSummary,
        newer: [AgentTurnCheckpointSummary],
        cwd: String
    ) {
        let paths = CheckpointRevertUndo.affectedPaths(target: target, newer: newer)
        let forwardFiles: [CheckpointRevertUndo.CapturedFile] = paths.sorted().map { path in
            guard let url = safeWorkspaceURL(cwd: cwd, relativePath: path),
                  FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url) else {
                return CheckpointRevertUndo.CapturedFile(path: path, contentsBase64: nil)
            }
            return CheckpointRevertUndo.CapturedFile(path: path, contentsBase64: data.base64EncodedString())
        }
        let deletedMessages: [AgentMessage] = newer
            .compactMap(\.assistantMessageId)
            .compactMap { try? messageRepo.get(id: $0) }
        let undo = CheckpointRevertUndo(
            threadId: threadId,
            checkpointTurnCount: target.checkpointTurnCount,
            capturedAt: Date(),
            forwardFiles: forwardFiles,
            deletedCheckpoints: newer,
            deletedMessages: deletedMessages
        )
        lock.lock(); lastCheckpointRevertUndo = undo; lock.unlock()
    }

    /// UX-MAC-CHECKPOINT-REVERT-UNDO: reverse the most recent checkpoint revert,
    /// provided the undo window has not lapsed. Restores files (writing back
    /// captured bytes, or removing files that were absent pre-revert) and
    /// re-inserts the deleted checkpoint + message rows FK-safe (checkpoints
    /// before messages; both reference the still-existing thread). Throws if no
    /// matching undo exists or the window lapsed; on those paths nothing is
    /// mutated. Provider state is intentionally left as rolled-back — the DB and
    /// files move forward while the provider conversation stays at the target
    /// turn; this desync is the same best-effort stance as the thread-delete
    /// undo and is NOT reconciled here.
    public func undoLastCheckpointRevert(threadId: AgentThreadID, cwd: String, now: Date = Date()) throws {
        lock.lock()
        let stored = lastCheckpointRevertUndo
        lock.unlock()
        guard let undo = stored, undo.threadId == threadId else {
            throw AgentProviderAdapterError.unsupported("no checkpoint revert to undo for this thread")
        }
        guard CheckpointRevertUndo.isWithinUndoWindow(
            capturedAt: undo.capturedAt,
            now: now,
            window: Self.checkpointRevertUndoWindow
        ) else {
            throw AgentProviderAdapterError.unsupported("checkpoint revert undo window has lapsed")
        }
        // (a) FILES: write back pre-revert bytes, or remove files that were absent.
        for file in undo.forwardFiles {
            guard let url = safeWorkspaceURL(cwd: cwd, relativePath: file.path) else {
                throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(file.path)")
            }
            if let encoded = file.contentsBase64 {
                guard let data = Data(base64Encoded: encoded) else {
                    throw AgentProviderAdapterError.unsupported("captured snapshot is corrupt: \(file.path)")
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        // (b) DB FK-safe: re-insert checkpoints first, then messages. agent_messages
        // and the checkpoint rows both reference agent_threads(id); the thread row
        // still exists, so the only ordering constraint is parent-before-child.
        for checkpoint in undo.deletedCheckpoints {
            try checkpointRepo?.upsert(checkpoint)
        }
        for message in undo.deletedMessages {
            try messageRepo.append(message)
        }
        lock.lock(); lastCheckpointRevertUndo = nil; lock.unlock()
    }

    private func validateRestorableSnapshots(in checkpoint: AgentTurnCheckpointSummary, newerCheckpoints: [AgentTurnCheckpointSummary], cwd: String) throws {
        let snapshots = checkpoint.fileSnapshots + newerCheckpoints.flatMap(\.fileSnapshots)
        for snapshot in snapshots {
            guard safeWorkspaceURL(cwd: cwd, relativePath: snapshot.path) != nil else {
                throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(snapshot.path)")
            }
            if snapshot.kind != GitFileStatus.deleted.rawValue,
               let encoded = snapshot.contentsBase64,
               Data(base64Encoded: encoded) == nil {
                throw AgentProviderAdapterError.unsupported("checkpoint snapshot is corrupt: \(snapshot.path)")
            }
        }
    }

    private func restoreHeadOrRemove(path: String, cwd: String) throws {
        if GitDiff.restorePathToHead(in: cwd, path: path).ok { return }
        guard let url = safeWorkspaceURL(cwd: cwd, relativePath: path) else {
            throw AgentProviderAdapterError.unsupported("checkpoint path escapes workspace: \(path)")
        }
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func safeWorkspaceURL(cwd: String, relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let root = URL(fileURLWithPath: cwd).standardizedFileURL
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { return nil }
        return url
    }

    private func emitPersistenceIssue(_ operation: String, error: Error, runId: AgentRunID, threadId: AgentThreadID) {
        let message = "Persistence failure during \(operation): \(error)"
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didReceive: .error(message: message, recoverable: false), run: runId, threadId: threadId)
        }
        onAssistantEvent?(.error(message: message, recoverable: false), threadId, runId)
        onPersistenceIssue?(message, threadId, runId)
    }

    private func observersSnapshot() -> [AgentRunObserver] {
        lock.lock()
        observerRefs.removeAll { $0.value == nil }
        let observers = observerRefs.compactMap(\.value)
        lock.unlock()
        return observers
    }

    private func providerSessionRuntimePayloadJSON(
        _ existingJSON: String?,
        status: AgentRunStatus,
        resumeCursor: String?,
        completedTurnId: String?,
        model: String,
        serviceTier: AgentServiceTier,
        runtimeMode: AgentPermissionMode,
        interactionMode: AgentInteractionMode,
        activeTurnId: String?,
        updatedAt: Date
    ) -> String? {
        var payload = ProviderSessionRuntimePayload.decode(existingJSON)
        if status == .completed, let completedTurnId, completedTurnId != payload.lastCompletedTurnId {
            payload.turnCount += 1
        }
        payload.providerThreadId = resumeCursor
        payload.lastCompletedTurnId = completedTurnId ?? payload.lastCompletedTurnId
        payload.model = model
        payload.serviceTier = serviceTier
        payload.runtimeMode = runtimeMode
        payload.interactionMode = interactionMode
        payload.activeTurnId = activeTurnId
        payload.updatedAtMs = Int64(updatedAt.timeIntervalSince1970 * 1000)
        return payload.encoded()
    }
}

private struct ProviderRecoveryContext {
    var resumeCursor: String?
    var runtimeMode: AgentPermissionMode?
    var serviceTier: AgentServiceTier?
    var interactionMode: AgentInteractionMode?

    init(resumeCursor: String?) {
        self.resumeCursor = resumeCursor
    }

    init(session: ProviderSessionRuntime) {
        self.resumeCursor = session.resumeCursor
        self.runtimeMode = session.runtimeMode
        self.serviceTier = session.serviceTier
        self.interactionMode = ProviderSessionRuntimePayload.decode(session.runtimePayloadJSON).interactionMode
    }
}

private final class WeakAgentRunObserver {
    weak var value: AgentRunObserver?

    init(_ value: AgentRunObserver) {
        self.value = value
    }
}

private struct ProviderSessionRuntimePayload: Codable, Equatable {
    var providerThreadId: String?
    var lastCompletedTurnId: String?
    var turnCount: Int
    var model: String?
    var serviceTier: AgentServiceTier?
    var runtimeMode: AgentPermissionMode?
    var interactionMode: AgentInteractionMode?
    var activeTurnId: String?
    var pendingApprovalRequestIds: [String] = []
    var pendingUserInputRequestIds: [String] = []
    var claudeResumeSessionAt: String?
    var claudeInFlightToolIds: [String] = []
    var updatedAtMs: Int64?

    private enum CodingKeys: String, CodingKey {
        case providerThreadId, lastCompletedTurnId, turnCount, model, serviceTier, runtimeMode, interactionMode, activeTurnId, pendingApprovalRequestIds, pendingUserInputRequestIds, claudeResumeSessionAt, claudeInFlightToolIds, updatedAtMs
    }

    init(turnCount: Int = 0) {
        self.turnCount = turnCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerThreadId = try container.decodeIfPresent(String.self, forKey: .providerThreadId)
        lastCompletedTurnId = try container.decodeIfPresent(String.self, forKey: .lastCompletedTurnId)
        turnCount = try container.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        model = try container.decodeIfPresent(String.self, forKey: .model)
        serviceTier = try container.decodeIfPresent(AgentServiceTier.self, forKey: .serviceTier)
        runtimeMode = try container.decodeIfPresent(AgentPermissionMode.self, forKey: .runtimeMode)
        interactionMode = try container.decodeIfPresent(AgentInteractionMode.self, forKey: .interactionMode)
        activeTurnId = try container.decodeIfPresent(String.self, forKey: .activeTurnId)
        pendingApprovalRequestIds = try container.decodeIfPresent([String].self, forKey: .pendingApprovalRequestIds) ?? []
        pendingUserInputRequestIds = try container.decodeIfPresent([String].self, forKey: .pendingUserInputRequestIds) ?? []
        claudeResumeSessionAt = try container.decodeIfPresent(String.self, forKey: .claudeResumeSessionAt)
        claudeInFlightToolIds = try container.decodeIfPresent([String].self, forKey: .claudeInFlightToolIds) ?? []
        updatedAtMs = try container.decodeIfPresent(Int64.self, forKey: .updatedAtMs)
    }

    static func decode(_ json: String?) -> ProviderSessionRuntimePayload {
        guard let json,
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(ProviderSessionRuntimePayload.self, from: data) else {
            return ProviderSessionRuntimePayload(turnCount: 0)
        }
        return payload
    }

    func encoded() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
