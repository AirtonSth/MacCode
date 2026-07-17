import Foundation
import CoreModel
import CryptoKit
import Persistence
import os

// QA-MAC_AGENT-010: structured run-lifecycle logging so field issues and test
// flakes (start/finish/duration, checkpoint outcomes) are diagnosable. Routes
// through the unified logging system, keyed by thread/run ids.
private let agentRunLog = Logger(subsystem: "io.remotecode.agent", category: "run")

/// Immutable host-authoritative view of the runs currently registered in the
/// coordinator. The list is sorted by run ID so consumers never inherit
/// dictionary iteration order when choosing a primary run.
public struct ActiveRunProjection: Equatable, Sendable {
    public struct Run: Equatable, Sendable {
        public let threadId: AgentThreadID
        public let runId: AgentRunID

        public init(threadId: AgentThreadID, runId: AgentRunID) {
            self.threadId = threadId
            self.runId = runId
        }
    }

    public let runs: [Run]

    public init(runs: [Run]) {
        self.runs = runs.sorted {
            $0.runId.value.uuidString < $1.runId.value.uuidString
        }
    }

    public var activeRunCount: Int { runs.count }
    public var primaryRunId: AgentRunID? { runs.first?.runId }
}

public enum ActiveRunProjectionCause: Equatable, Sendable {
    case started
    case finished(AgentRunStatus)
    case launchReconciliation
}

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
    private typealias RunMetadata = (provider: AgentProvider, providerInstanceId: String?, model: String, cwd: String, serviceTier: AgentServiceTier, runtimeMode: AgentPermissionMode, interactionMode: AgentInteractionMode, adapterKey: String, binaryIdentity: String?)
    private var activeRunMetadata: [AgentRunID: RunMetadata] = [:]
    private var activeTurnIds: [AgentRunID: String] = [:]
    private var activeAssistantMessageIds: [AgentRunID: AgentMessageID] = [:]
    private var activeProviderTextItemTypes: [AgentRunID: [String: AssistantItemType]] = [:]
    private var bufferedProviderTextItems: [AgentRunID: [String: BufferedProviderTextItem]] = [:]
    /// Stream humanization is asynchronous. A provider can emit its terminal
    /// callback before the translated item has been mirrored, so terminal
    /// cleanup must wait until every in-flight translation finishes.
    private var providerTextTranslationsInFlight: [AgentRunID: Int] = [:]
    private var deferredProviderTerminalEvents: [AgentRunID: DeferredProviderTerminalEvent] = [:]
    private var activeDistillOutputRuns: Set<AgentRunID> = []
    private var finishingRuns: Set<AgentRunID> = []
    /// Provider terminal payloads wait here until the final stream batch crosses
    /// the SQLite durability barrier. A transient writer lock must never let the
    /// terminal row or mirror notification overtake its preceding events.
    private var pendingTerminalEvents: [AgentRunID: PendingTerminalEvent] = [:]
    private var terminalRetryScheduled: Set<AgentRunID> = []
    /// A provider start can fail while SQLite is temporarily unavailable. Keep
    /// the complete failure transition until its run/thread/session/error graph
    /// commits; a new run on the same thread must not overtake it.
    private var pendingStartFailures: [AgentRunID: PendingStartFailure] = [:]
    private var startFailureRetryScheduled: Set<AgentRunID> = []
    private var pendingThreadStops: Set<AgentThreadID> = []
    /// Runs whose destructive caller is waiting for provider/process teardown.
    /// The matching terminal callback is recorded even when markStopRequested
    /// already made the durable run row terminal.
    private var awaitingTerminationRuns: Set<AgentRunID> = []
    private var providerTerminatedRuns: Set<AgentRunID> = []
    private var pendingGracefulStopFallbacks: Set<AgentRunID> = []
    /// Run start and native fork must not snapshot one parent concurrently.
    private var exclusiveThreadMutations: Set<AgentThreadID> = []
    /// Relaunch reconciliation for fork intents is asynchronous because the
    /// provider contract is asynchronous. `reconcileOnLaunch` schedules it
    /// after the synchronous run-state repair and tests may await the barrier.
    private var launchForkReconciliationTask: Task<Void, Never>?
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
    /// Run ownership for each buffered thread batch. Recovery may snapshot while
    /// `sendTurn` is still returning, before `activeThreads` is registered.
    private var pendingStreamRunIds: [AgentThreadID: AgentRunID] = [:]
    /// A prune requested by a buffered batch remains pending until that same
    /// batch commits. A failed SQLite transaction must not lose the prune intent.
    private var pendingStreamPrunes: Set<AgentThreadID> = []
    private var lastStreamFlushMs: [AgentThreadID: Int64] = [:]
    /// Once a drained batch loses an AssistantEvent, no later snapshot can
    /// honestly certify a watermark for that thread. Retain the first failure
    /// and fail recovery loudly instead of silently advancing iOS past the gap.
    private var mirrorPersistenceFailures: [AgentThreadID: Error] = [:]
    // UX-MAC_AGENT-BG-AWAIT: per-thread consecutive auto-continuation count and a
    // monotonic token used to cancel a scheduled continuation when the thread is
    // stopped or a fresh run starts. Both touched under `lock`. See
    // BackgroundAwaitContinuation: a full-access run that stalls awaiting a
    // background job it launched is auto-nudged (bounded) so it actually finishes.
    private var autoContinuationCounts: [AgentThreadID: Int] = [:]
    private var autoContinuationTokens: [AgentThreadID: Int] = [:]
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
    /// Serializes persisted AssistantEvent snapshots with their EventBus
    /// publication. The recursive form also tolerates persistence diagnostics
    /// emitted while a buffered snapshot is being flushed.
    private let mirrorEventLock = NSRecursiveLock()
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
    /// Fires only after `activeThreads` commits. Consumers can therefore project
    /// aggregate state without racing the provider's async start/finish path.
    public var onActiveRunProjectionChanged: ((ActiveRunProjection, ActiveRunProjectionCause) -> Void)?
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
    /// UX-MAC_AGENT-BG-AWAIT: delay before a full-access run that stalled awaiting a
    /// background job is auto-nudged to resume. Gives the background job time to make
    /// progress before the agent polls it. Injectable so tests drive it to ~0.
    public var backgroundAwaitContinuationDelay: TimeInterval = 45
    /// AG-002: normal provider shutdown gets two seconds before hard escalation;
    /// deletion never waits beyond five seconds without failing loud.
    var gracefulStopTimeout: TimeInterval = 2
    var hardStopTimeout: TimeInterval = 5

    /// Token Saver /distill hook: async transform applied to provider text
    /// detected as SR1 compressed language. The returned value is what gets
    /// persisted and shown to users. Must fail open by returning the input
    /// unchanged on any error.
    public var finalResponseTranslator: (@Sendable (_ response: String, _ provider: AgentProvider, _ threadId: AgentThreadID, _ runId: AgentRunID) async -> String)?

    /// Token Saver hook for RECOVERED sessions. The coordinator rebuilds the run request for a
    /// resumed session itself (`recoverAdapterSessionIfNeeded`), bypassing the app shell's
    /// `providerEnvironment`. Without this the recovered run loses `RC_TOKEN_SAVER_DISTILL_HINT`
    /// and silently stops piping `| distill` / speaking distill even with Token Saver on. Returns
    /// the Token Saver env vars to merge for the given provider; nil/empty => pre-fix behavior.
    public var recoveryEnvironmentProvider: (@Sendable (_ provider: AgentProvider) async -> [String: String])?

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
            copy.hasUnread = Self.hasUnread(for: .interrupted)
            copy.updatedAt = now
            try threadRepo.upsert(copy)
        }
        if let providerSessionRepo {
            let future = Date.distantFuture
            for session in try providerSessionRepo.list(status: .running, updatedBefore: future) {
                // A stale running session on an already-terminal thread is not a
                // relaunch interrupt. Align the session to the thread so pet/open
                // does not show "interrupted by an app restart" for finished work.
                let sessionStatus: AgentRunStatus
                if let thread = try? threadRepo.get(id: session.threadId),
                   Self.isTerminalThreadStatus(thread.status),
                   thread.status != .interrupted {
                    sessionStatus = thread.status
                } else {
                    sessionStatus = .interrupted
                }
                try providerSessionRepo.markStopped(threadId: session.threadId, status: sessionStatus, at: now)
            }
        }
        onActiveRunProjectionChanged?(ActiveRunProjection(runs: []), .launchReconciliation)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.reconcileForkIntentsOnLaunch()
        }
        lock.lock()
        launchForkReconciliationTask = task
        lock.unlock()
    }

    public func waitForForkReconciliation() async {
        let task = launchForkReconciliationTaskSnapshot()
        await task?.value
    }

    private func launchForkReconciliationTaskSnapshot() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return launchForkReconciliationTask
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

    public func runStartedAt(runId: AgentRunID) throws -> Date? {
        try runRepo.get(id: runId)?.startedAt
    }

    /// The currently-active run id for a thread (nil when idle). Lets a surface
    /// resync its per-surface `currentRunId` when it switches to an
    /// already-running thread, so Stop targets the right run.
    public func activeRunId(threadId: AgentThreadID) -> AgentRunID? {
        lock.lock(); defer { lock.unlock() }
        return activeThreads[threadId]
    }

    @discardableResult
    public func startRun(
        _ request: AgentRunRequest,
        isAutoContinuation: Bool = false,
        recordUserMessage: Bool = true
    ) async throws -> AgentRunID {
        let forkRecoveryPending = try threadRepo.hasRecoverableForkIntent(sourceThreadId: request.threadId)
        guard !forkRecoveryPending else {
            throw AgentProviderAdapterError.unsupported(
                "provider run start cannot overtake durable fork recovery for this thread"
            )
        }
        try beginExclusiveThreadMutation(request.threadId, operation: "provider run start")
        defer { endExclusiveThreadMutation(request.threadId) }
        lock.lock()
        let pendingStartFailureRunIds = pendingStartFailures.compactMap { runId, pending in
            pending.request.threadId == request.threadId ? runId : nil
        }
        lock.unlock()
        for pendingStartFailureRunId in pendingStartFailureRunIds {
            retryStartFailureCommit(runId: pendingStartFailureRunId)
        }
        lock.lock()
        let startFailureStillPending = pendingStartFailures.values.contains {
            $0.request.threadId == request.threadId
        }
        lock.unlock()
        if startFailureStillPending {
            throw NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 503,
                userInfo: [NSLocalizedDescriptionKey:
                    "A prior provider start failure is still waiting for durable persistence."]
            )
        }
        // AG-001: a prior run may have reached a terminal provider state while its
        // mirror batch was blocked by SQLite. Do not admit a new provider run on
        // this thread until that retained batch commits; otherwise the single
        // per-thread buffer would have two owners and the new run's first event
        // could be dropped while retrying the old owner.
        lock.lock()
        let priorBufferedRunId = pendingStreamRunIds[request.threadId]
        lock.unlock()
        if let priorBufferedRunId, priorBufferedRunId != request.runId,
           let error = flushPendingStreamWritesResult(runId: priorBufferedRunId, threadId: request.threadId) {
            throw error
        }
        // A user-initiated run ends any background-await auto-continuation streak;
        // the auto-nudge path passes `isAutoContinuation: true` to preserve the bound.
        // F37: it must also invalidate any ALREADY-SCHEDULED continuation (same
        // token bump as markStopRequested) — resetting only the count left the
        // stale nudge armed, so a user prompt that completed within the delay
        // window was followed by an unrequested autonomous "continue" turn built
        // from the old run's metadata.
        if !isAutoContinuation {
            resetAutoContinuationStreak(request.threadId)
            invalidateScheduledAutoContinuation(request.threadId)
        }
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
            extraArgs: request.extraArgs,
            runAsUser: request.runAsUser
        )
        guard let runner = providers[effectiveRequest.provider] else {
            throw AgentRunError.missingBinary(effectiveRequest.provider.rawValue)
        }
        let adapterKey = providerAdapterKey(runner)
        let binaryIdentity = providerBinaryIdentity(effectiveRequest.provider, adapter: runner)
        // persist user message
        if recordUserMessage {
            let userMsg = AgentMessage(
                id: AgentMessageID(effectiveRequest.runId.value),
                threadId: effectiveRequest.threadId,
                role: .user,
                content: effectiveRequest.userMessageContent ?? effectiveRequest.prompt,
                attachments: effectiveRequest.attachments
            )
            if try messageRepo.get(id: userMsg.id) == nil {
                try messageRepo.append(userMsg)
                onMessageAppended?(userMsg)
            }
        }
        // persist run
        let run = AgentRun(id: effectiveRequest.runId, threadId: effectiveRequest.threadId, provider: effectiveRequest.provider, providerInstanceId: effectiveRequest.providerInstanceId, model: effectiveRequest.model, status: .pending)
        try runRepo.upsert(run)
        if var thread = try threadRepo.get(id: effectiveRequest.threadId) {
            thread.status = .pending
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
            status: .pending,
            resumeCursor: effectiveRequest.providerThreadId,
            cwd: effectiveRequest.cwd,
            model: effectiveRequest.model,
            serviceTier: effectiveRequest.serviceTier,
            runtimeMode: effectiveRequest.permissionMode,
            lastRunId: effectiveRequest.runId,
            lastEventKind: "run.pending",
            runtimePayloadJSON: existingRuntimePayload
        ))
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
                binaryIdentity: binaryIdentity,
                preserveRecoverableSession: recoveryContext?.resumeCursor?.isEmpty == false
            )
            throw error
        }
        // `sendTurn` returning is the first provider-independent proof that a
        // handle exists. Keep the pre-handle graph pending, then atomically move
        // every durable projection to running. A provider may already have
        // emitted a terminal event synchronously; never overwrite that state.
        if var startedRun = try runRepo.get(id: runId), startedRun.status == .pending {
            startedRun.status = .running
            var startedThread = try threadRepo.get(id: effectiveRequest.threadId)
            startedThread?.status = .running
            startedThread?.updatedAt = Date()
            var startedSession = try providerSessionRepo?.get(threadId: effectiveRequest.threadId)
            startedSession?.status = .running
            startedSession?.lastEventKind = "run.started"
            startedSession?.updatedAt = Date()
            do {
                try runRepo.persistActiveGraph(
                    run: startedRun,
                    thread: startedThread,
                    providerSession: startedSession
                )
            } catch {
                clearDistillOutputMode(runId)
                handle.cancel()
                markStartFailure(
                    error,
                    request: effectiveRequest,
                    runId: runId,
                    adapterKey: adapterKey,
                    binaryIdentity: binaryIdentity,
                    preserveRecoverableSession: recoveryContext?.resumeCursor?.isEmpty == false
                )
                throw error
            }
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
        let activeProjection: ActiveRunProjection?
        if terminalStatus == nil {
            active[runId] = handle
            activeThreads[effectiveRequest.threadId] = runId
            activeRunMetadata[runId] = (effectiveRequest.provider, effectiveRequest.providerInstanceId, effectiveRequest.model, effectiveRequest.cwd, effectiveRequest.serviceTier, effectiveRequest.permissionMode, effectiveRequest.interactionMode, adapterKey, binaryIdentity)
            // A runner may emit synchronously before sendTurn returns. Preserve
            // the sequence already assigned to those buffered events instead of
            // resetting it and reusing seq 1 for a different event. Also seed
            // from durable rows so a recovered process cannot collide with
            // already-committed (run_id, seq) identities.
            if seq[runId] == nil {
                let durableHigh = (try? runRepo.maxStreamEventSeq(runId: runId)) ?? 0
                var high = durableHigh
                if pendingStreamRunIds[effectiveRequest.threadId] == runId,
                   let batch = pendingStreamWrites[effectiveRequest.threadId] {
                    high = max(high, batch.highestSeq)
                }
                seq[runId] = high
            }
            shouldCancel = pendingThreadStops.remove(effectiveRequest.threadId) != nil
            activeProjection = activeRunProjectionLocked()
        } else {
            pendingThreadStops.remove(effectiveRequest.threadId)
            shouldCancel = false
            activeProjection = nil
        }
        lock.unlock()
        if let activeProjection {
            onRunStarted?(effectiveRequest.threadId, effectiveRequest.runId)
            onActiveRunProjectionChanged?(activeProjection, .started)
        }
        if shouldCancel { handle.cancel() }
        return runId
    }

    public func stopRun(_ runId: AgentRunID) {
        lock.lock()
        let threadId = activeThreads.first(where: { $0.value == runId })?.key
        let handle = active[runId]
        lock.unlock()
        if let threadId {
            stopRun(threadId: threadId)
        } else {
            handle?.cancel()
        }
    }

    public func stopRun(threadId: AgentThreadID) {
        lock.lock()
        let runId = activeThreads[threadId]
        let handle = runId.flatMap { active[$0] }
        let terminalDurabilityPending = runId.map {
            pendingTerminalEvents[$0] != nil || deferredProviderTerminalEvents[$0] != nil
        } ?? false
        lock.unlock()
        if let runId, let handle {
            var deliveredNativeInterrupt = false
            if let adapter = try? adapterForThread(threadId) {
                lock.lock()
                pendingGracefulStopFallbacks.insert(runId)
                lock.unlock()
                do {
                    try adapter.interruptTurn(threadId: threadId)
                    deliveredNativeInterrupt = true
                } catch {
                    lock.lock()
                    pendingGracefulStopFallbacks.remove(runId)
                    providerTerminatedRuns.remove(runId)
                    lock.unlock()
                    deliveredNativeInterrupt = false
                }
            }
            if deliveredNativeInterrupt {
                // Provider-native interrupt must reach the live session before
                // handle cancellation can close its transport. Bound the grace
                // period, then force the exact still-active run if no terminal
                // callback arrived.
                let grace = max(0, gracefulStopTimeout)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [weak self, handle] in
                    guard let self else { return }
                    self.lock.lock()
                    self.pendingGracefulStopFallbacks.remove(runId)
                    let providerAcknowledged = self.providerTerminatedRuns.remove(runId) != nil
                    self.lock.unlock()
                    if !providerAcknowledged { handle.cancel() }
                }
            } else {
                handle.cancel()
            }
            // The provider has already acknowledged a terminal state, but its
            // buffered stream tail is still waiting for the SQLite durability
            // barrier. Stop may terminate any surviving provider process, but it
            // must not publish a competing `.cancelled` state ahead of the
            // retained terminal event.
            if terminalDurabilityPending { return }
            markStopRequested(threadId: threadId, runId: runId)
            return
        }
        // F19: nothing to stop unless the thread is actually running/pending. A
        // second Stop click, or a stop for a long-finished thread, previously fell
        // into the session/recover branches below and either re-broadcast a
        // spurious `.cancelled` (phantom "Thread cancelled" notification, queued
        // messages drained unprompted) or respawned a provider process for a dead
        // thread just to interrupt it. Guard BEFORE touching adapter sessions.
        guard let thread = try? threadRepo.get(id: threadId),
              thread.status == .running || thread.status == .pending else {
            lock.lock()
            pendingThreadStops.remove(threadId)
            lock.unlock()
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
                        // F19: the session was recovered only to deliver the
                        // interrupt — do not leave the respawned provider
                        // process resident after a stop. markStopRequested is
                        // NOT repeated here: the synchronous fall-through below
                        // already broadcast the cancel for this stop.
                        try? adapter.stopSession(threadId: threadId)
                    }
                } catch {
                    // Pending cancellation (recorded synchronously below) covers this;
                    // startRun will fail loudly if recovered state is insufficient.
                }
            }
        }
        lock.lock()
        pendingThreadStops.insert(threadId)
        lock.unlock()
        markStopRequested(threadId: threadId, runId: nil)
    }

    /// Stop a thread and do not return until the provider has acknowledged a
    /// terminal state and every process captured from its tree is dead. A normal
    /// cancel gets a two-second grace window; hard escalation is bounded by the
    /// five-second deadline. Destructive callers must abort deletion on error.
    public func stopAndAwaitTermination(threadId: AgentThreadID) async throws {
        lock.lock()
        let runId = activeThreads[threadId]
        let handle = runId.flatMap { active[$0] }
        if let runId { awaitingTerminationRuns.insert(runId) }
        lock.unlock()

        let adapter = try? adapterForThread(threadId)
        var processTracker: ProcessTerminator.TreeTracker? = {
            guard let process = handle?.process, process.processIdentifier > 0 else { return nil }
            return ProcessTerminator.TreeTracker(root: process.processIdentifier)
        }()
        let startedAt = Date()
        var escalated = false

        defer {
            if let runId {
                lock.lock()
                awaitingTerminationRuns.remove(runId)
                providerTerminatedRuns.remove(runId)
                lock.unlock()
            }
        }

        stopRun(threadId: threadId)

        while true {
            lock.lock()
            let providerTerminated = runId.map(providerTerminatedRuns.contains) ?? true
            lock.unlock()
            processTracker?.refresh()
            let survivingPIDs = processTracker?.survivingPIDs() ?? []
            let processTreeDead = survivingPIDs.isEmpty
            let terminationConfirmed = providerTerminated ||
                (processTracker != nil && processTreeDead) ||
                runId == nil

            // Terminal adapters can intentionally retain resumable sessions.
            // Deletion is different: once terminal is confirmed, release that
            // session before certifying that no provider child work remains.
            if terminationConfirmed && processTreeDead,
               adapter?.hasSession(threadId: threadId) == true {
                try? adapter?.stopSession(threadId: threadId)
            }
            let providerSessionAlive = adapter.map {
                providerSessionIsLive($0, threadId: threadId)
            } ?? false
            if terminationConfirmed && processTreeDead && !providerSessionAlive {
                return
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if !escalated && elapsed >= gracefulStopTimeout {
                escalated = true
                processTracker?.signalSurvivors(SIGTERM)
                handle?.cancel()
                try? adapter?.stopSession(threadId: threadId)
            }
            if escalated && elapsed >= gracefulStopTimeout + 0.25 {
                // Refresh immediately before KILL. This includes children born
                // during TERM handling and members reparented out of the tree.
                processTracker?.refresh()
                processTracker?.signalSurvivors(SIGKILL)
            }
            if elapsed >= hardStopTimeout {
                let pidList = survivingPIDs.map(String.init).joined(separator: ",")
                let survivingPIDDescription = pidList.isEmpty ? "none" : pidList
                throw NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 504,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Provider for thread \(threadId.value.uuidString) did not terminate within " +
                            "\(hardStopTimeout)s (surviving pids: \(survivingPIDDescription), " +
                            "session alive: \(providerSessionAlive))."
                    ]
                )
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Internal proof seam used by lifecycle tests.
    func hasProviderSession(threadId: AgentThreadID) -> Bool {
        guard let adapter = try? adapterForThread(threadId) else { return false }
        return providerSessionIsLive(adapter, threadId: threadId)
    }

    private func providerSessionIsLive(
        _ adapter: AgentProviderAdapter,
        threadId: AgentThreadID
    ) -> Bool {
        guard adapter.hasSession(threadId: threadId) else { return false }
        guard let summary = adapter.listSessions().first(where: { $0.threadId == threadId }) else {
            return true
        }
        return summary.status == .running || summary.status == .pending
    }

    /// F19: release a thread's resident provider adapter session WITHOUT emitting
    /// any run-lifecycle events. For the idle-session reaper: the reaped thread
    /// finished long ago, so routing the release through stopRun/markStopRequested
    /// broadcast a spurious `.cancelled` ("Thread cancelled" notification, status
    /// pill flip, queued-message drain) for a thread nobody stopped. No-op when the
    /// thread still has an active run or no live session.
    public func releaseProviderSession(threadId: AgentThreadID) {
        lock.lock()
        let hasActiveRun = activeThreads[threadId] != nil
        lock.unlock()
        guard !hasActiveRun else { return }
        guard let adapter = try? adapterForThread(threadId),
              adapter.hasSession(threadId: threadId) else { return }
        try? adapter.stopSession(threadId: threadId)
        try? providerSessionRepo?.markStopped(threadId: threadId)
    }

    private func markStopRequested(threadId: AgentThreadID, runId: AgentRunID?) {
        // F17: handle.cancel() can finish the run synchronously (the codex adapter
        // emits .finished(.cancelled) inside cancel), and the .finished path has
        // then already run the FULL terminal sequence — run row, thread row,
        // didFinish observers and onRunFinished. Re-broadcasting here would
        // double-fire didChangeStatus/onRunFinished for the same run (duplicate
        // notifications, two concurrent queue drains), so a run that is already
        // terminal is done.
        if let runId, (try? runRepo.get(id: runId))?.finishedAt != nil {
            return
        }
        if let runId {
            // A user Stop is a terminal event and must cross the same durability
            // barrier as provider completion. Claim the terminal slot atomically:
            // a provider terminal already in flight wins; otherwise cancellation
            // becomes the retained event and retries until the buffered stream tail
            // commits. This prevents Stop-first from evicting active ownership or
            // publishing `.cancelled` while SQLite still holds uncommitted events.
            lock.lock()
            guard !finishingRuns.contains(runId), pendingTerminalEvents[runId] == nil else {
                lock.unlock()
                return
            }
            finishingRuns.insert(runId)
            pendingTerminalEvents[runId] = PendingTerminalEvent(
                status: .cancelled,
                finalMessage: nil,
                providerThreadId: nil,
                assistantMessage: nil,
                finishedAt: Date(),
                providerTerminalAcknowledged: false
            )
            lock.unlock()
            handle(
                event: .finished(.cancelled, finalMessage: nil, providerThreadId: nil),
                runId: runId,
                threadId: threadId,
                allowFinalResponseTranslation: false,
                providerTerminalAcknowledged: false
            )
            return
        }
        let stoppedRunId = runId ?? AgentRunID()
        if let runId {
            try? runRepo.markStopped(id: runId, status: .cancelled)
        }
        if var thread = try? threadRepo.get(id: threadId), thread.status == .running || thread.status == .pending {
            thread.status = .cancelled
            thread.hasUnread = Self.hasUnread(for: .cancelled)
            thread.updatedAt = Date()
            try? threadRepo.upsert(thread)
        }
        try? providerSessionRepo?.markStopped(threadId: threadId)
        // PERF-MAC_AGENT-007: drain buffered stream writes for the genuine active
        // run before tearing it down, so a cancel does not drop the buffered tail.
        // The seq attribution requires the real runId, so only the runId-bearing
        // stop path flushes (the nil-runId paths had no live buffered events).
        let streamFlushError = runId.flatMap {
            flushPendingStreamWrites(runId: $0, threadId: threadId)
        }
        lock.lock()
        var activeProjection: ActiveRunProjection?
        if let runId {
            active.removeValue(forKey: runId)
            if activeThreads.removeValue(forKey: threadId) != nil {
                activeProjection = activeRunProjectionLocked()
            }
            activeRunMetadata.removeValue(forKey: runId)
            activeTurnIds.removeValue(forKey: runId)
            activeAssistantMessageIds.removeValue(forKey: runId)
            activeProviderTextItemTypes.removeValue(forKey: runId)
            bufferedProviderTextItems.removeValue(forKey: runId)
            activeDistillOutputRuns.remove(runId)
            finishingRuns.remove(runId)
            // Do not clear seq while a failed flush still owns a retryable batch.
            // Clearing here reissued seq 1 for late Grok ACP events (e.g.
            // prompt_complete after servers_updated) and blocked the next start.
            if streamFlushError == nil {
                seq.removeValue(forKey: runId)
            } else {
                clearStreamSequenceIfReleasedLocked(runId: runId, threadId: threadId)
            }
            pendingThreadStops.remove(threadId)
        }
        if streamFlushError == nil {
            streamEventsSincePrune.removeValue(forKey: threadId)
            pendingStreamWrites.removeValue(forKey: threadId)
            pendingStreamRunIds.removeValue(forKey: threadId)
            pendingStreamPrunes.remove(threadId)
            lastStreamFlushMs.removeValue(forKey: threadId)
        }
        // PERF-MAC_AGENT-008: thread closed -> evict the dedup cache entry so
        // cancelled threads do not retain their final-answer text indefinitely.
        lastPersistedAssistantContent.removeValue(forKey: threadId)
        // UX-MAC_AGENT-BG-AWAIT: a stop ends the streak and invalidates the token,
        // so any scheduled auto-continuation for this thread aborts when it fires.
        autoContinuationCounts.removeValue(forKey: threadId)
        autoContinuationTokens[threadId] = (autoContinuationTokens[threadId] ?? 0) + 1
        lock.unlock()
        if let activeProjection {
            onActiveRunProjectionChanged?(activeProjection, .finished(.cancelled))
        }
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didChangeStatus: .cancelled, runId: stoppedRunId, threadId: threadId)
        }
        onRunFinished?(threadId, stoppedRunId, .cancelled)
    }

    /// F9: drop a deleted thread's residual per-thread coordinator state (the
    /// auto-continuation streak counter and its generation token). These are the
    /// only per-thread maps not already evicted at run finish/stop, so without this
    /// they accumulate one Int entry per thread that ever ran for the life of the
    /// process. Safe to call on delete: a deleted thread can never auto-continue —
    /// any scheduled continuation fails its validity check once the token is gone
    /// and the thread row no longer reports `.completed`.
    public func forgetThread(_ threadId: AgentThreadID) {
        lock.lock()
        autoContinuationCounts.removeValue(forKey: threadId)
        autoContinuationTokens.removeValue(forKey: threadId)
        lock.unlock()
    }

    #if DEBUG
    // Test-only seam for the F9 per-thread eviction: seed and observe the
    // auto-continuation bookkeeping without driving a full stalled autonomous run.
    func seedAutoContinuationStateForTesting(_ threadId: AgentThreadID) {
        lock.lock(); autoContinuationCounts[threadId] = 1; autoContinuationTokens[threadId] = 1; lock.unlock()
    }
    var autoContinuationThreadIdsForTesting: Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        return Set(autoContinuationCounts.keys).union(autoContinuationTokens.keys)
    }
    #endif

    // MARK: - Background-await auto-continuation (UX-MAC_AGENT-BG-AWAIT)

    private func resetAutoContinuationStreak(_ threadId: AgentThreadID) {
        lock.lock(); autoContinuationCounts[threadId] = 0; lock.unlock()
    }

    /// F37: bump the thread's continuation token so any pending scheduled
    /// auto-continuation aborts its validity check when it fires. Called on
    /// user-initiated starts; markStopRequested does the same on stop.
    private func invalidateScheduledAutoContinuation(_ threadId: AgentThreadID) {
        lock.lock()
        autoContinuationTokens[threadId] = (autoContinuationTokens[threadId] ?? 0) + 1
        lock.unlock()
    }

    /// Decide, at run finish, whether a full-access run stalled awaiting a
    /// background job and should be auto-nudged to resume; if so, schedule a
    /// bounded re-invocation after `backgroundAwaitContinuationDelay`.
    private func maybeScheduleBackgroundAwaitContinuation(
        threadId: AgentThreadID,
        status: AgentRunStatus,
        finalMessage: String?,
        runMetadata: RunMetadata?,
        resumeCursor: String?
    ) {
        let isAutonomous = (runMetadata?.runtimeMode ?? (try? threadRepo.get(id: threadId))?.permissionMode) == .fullAccess
        lock.lock()
        let prior = autoContinuationCounts[threadId] ?? 0
        lock.unlock()
        guard BackgroundAwaitContinuation.shouldAutoContinue(
            status: status,
            finalMessage: finalMessage,
            isAutonomous: isAutonomous,
            priorAutoContinuations: prior
        ) else {
            // A completed run that did NOT stall (real progress, or non-autonomous)
            // clears the streak so a later genuine stall gets the full budget.
            if status == .completed { resetAutoContinuationStreak(threadId) }
            return
        }
        guard let runMetadata else { return }
        lock.lock()
        autoContinuationCounts[threadId] = prior + 1
        let token = (autoContinuationTokens[threadId] ?? 0) + 1
        autoContinuationTokens[threadId] = token
        lock.unlock()
        let attempt = prior + 1
        let delay = backgroundAwaitContinuationDelay
        let request = backgroundAwaitContinuationRequest(threadId: threadId, runMetadata: runMetadata, resumeCursor: resumeCursor)
        agentRunLog.info("run.autoContinue.scheduled thread=\(threadId.value.uuidString, privacy: .public) attempt=\(attempt, privacy: .public)")
        Task { [weak self] in
            guard let self else { return }
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64((delay * 1_000_000_000).rounded()))
            }
            guard self.backgroundAwaitContinuationStillValid(threadId: threadId, token: token) else { return }
            _ = try? await self.startRun(request, isAutoContinuation: true)
        }
    }

    /// True iff the scheduled continuation is still the latest one for the thread
    /// (token unchanged), the thread is idle (no live run), no stop is pending, and
    /// the user has not already driven the thread to a non-completed state.
    private func backgroundAwaitContinuationStillValid(threadId: AgentThreadID, token: Int) -> Bool {
        lock.lock()
        let ok = autoContinuationTokens[threadId] == token
            && activeThreads[threadId] == nil
            && !pendingThreadStops.contains(threadId)
        lock.unlock()
        guard ok else { return false }
        return (try? threadRepo.get(id: threadId))?.status == .completed
    }

    private func backgroundAwaitContinuationRequest(
        threadId: AgentThreadID,
        runMetadata: RunMetadata,
        resumeCursor: String?
    ) -> AgentRunRequest {
        let prompt = BackgroundAwaitContinuation.continuationPrompt
        let runAsUser = (try? threadRepo.get(id: threadId))?.runAsUser
        return AgentRunRequest(
            threadId: threadId,
            provider: runMetadata.provider,
            providerInstanceId: runMetadata.providerInstanceId,
            model: runMetadata.model,
            cwd: runMetadata.cwd,
            prompt: prompt,
            userMessageContent: prompt,
            providerThreadId: resumeCursor,
            permissionMode: runMetadata.runtimeMode,
            serviceTier: runMetadata.serviceTier,
            interactionMode: runMetadata.interactionMode,
            runAsUser: runAsUser
        )
    }

    private func markStartFailure(
        _ error: Error,
        request: AgentRunRequest,
        runId: AgentRunID,
        adapterKey: String,
        binaryIdentity: String?,
        preserveRecoverableSession: Bool
    ) {
        let message = String(describing: error)
        // RUN-LIFECYCLE-STREAM-002: if a DIFFERENT run is already live on this
        // thread (e.g. this start lost a race and the adapter rejected it as a
        // duplicate in-flight turn), do not clobber the live run's thread row,
        // provider session, or broadcast a false terminal status. Record only a
        // run-scoped failure so the survivor keeps streaming.
        lock.lock()
        let otherRunActive = activeThreads[request.threadId].map { $0 != runId } ?? false
        lock.unlock()
        let event = AssistantEvent.error(
            message: message,
            recoverable: !otherRunActive && preserveRecoverableSession
        )
        let payloadJSON: String
        do {
            let data = try JSONEncoder().encode(event)
            guard let json = String(data: data, encoding: .utf8) else {
                throw NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 422,
                    userInfo: [NSLocalizedDescriptionKey: "Start failure event JSON was not UTF-8."]
                )
            }
            payloadJSON = streamPayloadCompactor?(json) ?? json
        } catch {
            recordMirrorPersistenceFailure(error, threadId: request.threadId)
            emitPersistenceIssue("run.start_failure.encode", error: error, runId: runId, threadId: request.threadId)
            return
        }

        lock.lock()
        let eventSequence = allocateStreamSequenceLocked(runId: runId, threadId: request.threadId)
        pendingStartFailures[runId] = PendingStartFailure(
            request: request,
            adapterKey: adapterKey,
            binaryIdentity: binaryIdentity,
            preserveRecoverableSession: preserveRecoverableSession,
            otherRunActive: otherRunActive,
            message: message,
            event: event,
            streamEvent: AgentRunRepository.StreamWriteIntent(
                seq: eventSequence,
                kind: event.debugDescription,
                payloadJSON: payloadJSON,
                providerEvent: nil
            ),
            finishedAt: Date()
        )
        lock.unlock()

        retryStartFailureCommit(runId: runId)
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

    public func cancelUserInput(threadId: AgentThreadID, requestId: String) throws {
        let adapter = try adapterForThread(threadId)
        try adapter.cancelUserInput(threadId: threadId, requestId: requestId)
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        let adapter = try adapterForThread(threadId)
        try await recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
        return try await adapter.readThread(threadId: threadId)
    }

    @discardableResult
    public func forkThread(
        sourceThreadId: AgentThreadID,
        childThread: AgentThread
    ) async throws -> AgentThread {
        guard sourceThreadId != childThread.id else {
            throw AgentProviderAdapterError.unsupported("fork child must have a distinct local thread identity")
        }
        guard let sourceThread = try threadRepo.get(id: sourceThreadId) else {
            throw AgentProviderAdapterError.sessionNotFound(sourceThreadId)
        }
        guard sourceThread.provider == childThread.provider else {
            throw AgentProviderAdapterError.unsupported("fork child must use the parent provider")
        }
        guard childThread.providerThreadId == nil else {
            throw AgentProviderAdapterError.unsupported("fork child provider identity must be assigned by the durable fork operation")
        }

        let adapter = try adapterForThread(sourceThreadId)
        guard adapter.forkSafety(threadId: sourceThreadId).supportsDurableFork else {
            throw AgentProviderAdapterError.unsupported(
                "provider fork is not crash-safe: keyed idempotency and idempotent compensation are required"
            )
        }
        try beginExclusiveThreadMutation(sourceThreadId, operation: "provider fork", requiresIdleThread: true)
        defer { endExclusiveThreadMutation(sourceThreadId) }
        try await recoverAdapterSessionIfNeeded(threadId: sourceThreadId, adapter: adapter)
        guard adapter.forkSafety(threadId: sourceThreadId).supportsDurableFork else {
            throw AgentProviderAdapterError.unsupported(
                "provider fork schema changed after session recovery; keyed reconciliation is unavailable"
            )
        }
        let idempotencyKey = "remotecode-thread-fork:\(childThread.id.value.uuidString.lowercased())"
        let intent = try threadRepo.prepareForkIntent(
            sourceThreadId: sourceThreadId,
            childThread: childThread,
            idempotencyKey: idempotencyKey
        )
        return try await reconcileForkIntent(intent, adapter: adapter)
    }

    /// Replays every non-terminal fork intent. Provider calls are repeated only
    /// with the original stable key on adapters that guarantee idempotency.
    /// Local graph commit and the `local_committed` transition share one SQLite
    /// transaction, so neither can become visible without the other.
    public func reconcileForkIntentsOnLaunch() async {
        let intents: [AgentThreadForkIntent]
        do {
            intents = try threadRepo.listRecoverableForkIntents()
        } catch {
            agentRunLog.error("fork.reconcile.list_failed error=\(String(describing: error), privacy: .public)")
            return
        }
        for intent in intents {
            let adapter = providerAdapterSnapshot(for: intent.provider)
            guard let adapter, adapter.forkSafety(threadId: intent.sourceThreadId).supportsDurableFork else {
                try? threadRepo.recordForkIntentError(
                    childThreadId: intent.childThread.id,
                    error: "Provider no longer exposes crash-safe fork recovery."
                )
                continue
            }
            await reconcileForkIntentOnLaunch(intent, adapter: adapter)
        }
    }

    private func reconcileForkIntentOnLaunch(
        _ intent: AgentThreadForkIntent,
        adapter: AgentProviderAdapter
    ) async {
        do {
            try beginExclusiveThreadMutation(intent.sourceThreadId, operation: "fork recovery", requiresIdleThread: true)
        } catch {
            try? threadRepo.recordForkIntentError(
                childThreadId: intent.childThread.id,
                error: String(describing: error)
            )
            return
        }
        defer { endExclusiveThreadMutation(intent.sourceThreadId) }
        do {
            if intent.state != .compensating,
               try threadRepo.get(id: intent.sourceThreadId) != nil {
                try await recoverAdapterSessionIfNeeded(threadId: intent.sourceThreadId, adapter: adapter)
            }
            guard adapter.forkSafety(threadId: intent.sourceThreadId).supportsDurableFork else {
                throw AgentProviderAdapterError.unsupported(
                    "provider fork recovery schema is no longer compatible"
                )
            }
            _ = try await reconcileForkIntent(intent, adapter: adapter)
        } catch {
            try? threadRepo.recordForkIntentError(
                childThreadId: intent.childThread.id,
                error: String(describing: error)
            )
            agentRunLog.error(
                "fork.reconcile.failed child=\(intent.childThread.id.value.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func beginExclusiveThreadMutation(
        _ threadId: AgentThreadID,
        operation: String,
        requiresIdleThread: Bool = false
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard !exclusiveThreadMutations.contains(threadId),
              !requiresIdleThread || activeThreads[threadId] == nil else {
            throw AgentProviderAdapterError.unsupported(
                "\(operation) cannot begin while another provider mutation is active for this thread"
            )
        }
        exclusiveThreadMutations.insert(threadId)
    }

    private func endExclusiveThreadMutation(_ threadId: AgentThreadID) {
        lock.lock(); defer { lock.unlock() }
        exclusiveThreadMutations.remove(threadId)
    }

    private func providerAdapterSnapshot(for provider: AgentProvider) -> AgentProviderAdapter? {
        lock.lock(); defer { lock.unlock() }
        return providers[provider]
    }

    private func reconcileForkIntent(
        _ initialIntent: AgentThreadForkIntent,
        adapter: AgentProviderAdapter
    ) async throws -> AgentThread {
        var intent = try threadRepo.getForkIntent(childThreadId: initialIntent.childThread.id) ?? initialIntent
        let request = AgentProviderForkRequest(
            sourceThreadId: intent.sourceThreadId,
            childThreadId: intent.childThread.id,
            idempotencyKey: intent.idempotencyKey,
            workingDirectory: intent.childThread.worktreePath,
            sourceProviderThreadId: try threadRepo.get(id: intent.sourceThreadId)?.providerThreadId
        )

        if intent.state == .localCommitted {
            guard let child = try threadRepo.get(id: intent.childThread.id),
                  child.providerThreadId == intent.providerChildThreadId else {
                throw AgentThreadForkPersistenceError.childThreadConflict
            }
            return child
        }
        if intent.state == .compensated {
            throw AgentProviderAdapterError.unsupported("provider fork was compensated after local commit became impossible")
        }
        if intent.state == .abandoned {
            throw AgentProviderAdapterError.unsupported("provider fork was abandoned before provider creation")
        }
        if intent.state == .compensating {
            guard let providerChildThreadId = intent.providerChildThreadId else {
                throw AgentThreadForkPersistenceError.corruptIntent
            }
            try await adapter.compensateFork(request, providerChildThreadId: providerChildThreadId)
            try threadRepo.markForkCompensated(childThreadId: intent.childThread.id)
            throw AgentProviderAdapterError.unsupported("provider fork was compensated after local commit became impossible")
        }

        if intent.state == .prepared {
            guard try threadRepo.get(id: intent.sourceThreadId) != nil else {
                try threadRepo.markPreparedForkAbandoned(
                    childThreadId: intent.childThread.id,
                    error: "Source thread disappeared before provider creation."
                )
                throw AgentThreadForkPersistenceError.sourceThreadNotFound
            }
            let providerChildThreadId: String
            do {
                providerChildThreadId = try await adapter.forkThread(request)
            } catch {
                try? threadRepo.recordForkIntentError(
                    childThreadId: intent.childThread.id,
                    error: String(describing: error)
                )
                throw error
            }
            let sourceProviderThreadId = try threadRepo.get(id: intent.sourceThreadId)?.providerThreadId
            guard !providerChildThreadId.isEmpty,
                  providerChildThreadId != sourceProviderThreadId else {
                throw AgentProviderAdapterError.unsupported("provider-native fork did not return a distinct child session")
            }
            intent = try threadRepo.recordForkProviderCreated(
                childThreadId: intent.childThread.id,
                providerChildThreadId: providerChildThreadId
            )
        }

        guard intent.state == .providerCreated,
              let providerChildThreadId = intent.providerChildThreadId else {
            throw AgentThreadForkPersistenceError.invalidIntentState(intent.state)
        }
        var persistedChild = intent.childThread
        persistedChild.providerThreadId = providerChildThreadId
        persistedChild.status = .completed
        persistedChild.hasUnread = false
        persistedChild.updatedAt = Date()
        let sourceRuntime = try providerSessionRepo?.get(threadId: intent.sourceThreadId)
        let childRuntime = providerSessionRepo.map { _ in
            ProviderSessionRuntime(
                threadId: persistedChild.id,
                provider: persistedChild.provider,
                providerInstanceId: persistedChild.providerInstanceId,
                adapterKey: sourceRuntime?.adapterKey ?? providerAdapterKey(adapter),
                binaryIdentity: sourceRuntime?.binaryIdentity ?? providerBinaryIdentity(persistedChild.provider, adapter: adapter),
                status: .completed,
                resumeCursor: providerChildThreadId,
                cwd: sourceRuntime?.cwd ?? persistedChild.worktreePath,
                model: persistedChild.model,
                serviceTier: persistedChild.serviceTier,
                runtimeMode: persistedChild.permissionMode,
                lastEventKind: "thread/forked",
                updatedAt: persistedChild.updatedAt
            )
        }
        do {
            try threadRepo.persistForkedChildGraph(
                sourceThreadId: intent.sourceThreadId,
                childThread: persistedChild,
                providerSession: childRuntime,
                forkIntentChildThreadId: intent.childThread.id
            )
            return persistedChild
        } catch let error as AgentThreadForkPersistenceError
            where error == .sourceThreadNotFound || error == .childThreadConflict || error == .intentConflict {
            _ = try threadRepo.markForkCompensating(
                childThreadId: intent.childThread.id,
                error: String(describing: error)
            )
            try await adapter.compensateFork(request, providerChildThreadId: providerChildThreadId)
            try threadRepo.markForkCompensated(childThreadId: intent.childThread.id)
            throw error
        } catch {
            try? threadRepo.recordForkIntentError(
                childThreadId: intent.childThread.id,
                error: String(describing: error)
            )
            throw error
        }
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

    /// Returns the exact locally-processed AssistantEvent snapshot while
    /// preventing a matching EventBus publication from crossing the caller's
    /// watermark capture. This is the recovery contract used by iOS; unlike
    /// `readThread`, it never races a fresh provider-side mutable snapshot.
    public func withMirrorEventSnapshot<T>(
        threadId: AgentThreadID,
        _ body: ([AssistantEvent]) -> T
    ) throws -> T {
        mirrorEventLock.lock()
        defer { mirrorEventLock.unlock() }
        lock.lock()
        let priorFailure = mirrorPersistenceFailures[threadId]
        lock.unlock()
        if let priorFailure { throw priorFailure }
        lock.lock()
        let bufferedRunId = pendingStreamRunIds[threadId]
        lock.unlock()
        if let runId = bufferedRunId ?? activeRunId(threadId: threadId) {
            if let error = flushPendingStreamWritesResult(runId: runId, threadId: threadId) {
                throw error
            }
        }
        return body(try runRepo.listLatestStreamEvents(
            threadId: threadId,
            limit: .max,
            strictDecoding: true
        ))
    }

    public func activeThreadIdsSnapshot() -> Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        return Set(activeThreads.keys)
    }

    private func activeRunProjectionLocked() -> ActiveRunProjection {
        ActiveRunProjection(runs: activeThreads.map {
            ActiveRunProjection.Run(threadId: $0.key, runId: $0.value)
        })
    }

    /// Returns true when the thread was relaunch-interrupted and still has a
    /// recoverable provider session that the inline Continue action can resume.
    /// WHY: coordinator owns providerSessionRepo; surface should not reach
    /// through to the repo directly.
    ///
    /// Completed/cancelled/failed threads must never surface Continue even when
    /// a stale session row still has a resume cursor or an `interrupted` status
    /// left behind by launch reconciliation of a leftover running session.
    public func hasRecoverableContext(threadId: AgentThreadID) -> Bool {
        guard let thread = try? threadRepo.get(id: threadId),
              thread.status == .interrupted else {
            return false
        }
        guard let repo = providerSessionRepo else { return false }
        // recoveryState treats completed+cursor as recoverable for multi-turn
        // startRun resume. Continue is only for relaunch-interrupted sessions.
        switch (try? repo.recoveryState(threadId: threadId)) ?? .unrecoverable("no repo") {
        case .recoverable(let session):
            return session.status == .interrupted
        default:
            return false
        }
    }

    /// Terminal thread statuses that are not relaunch-interrupt recovery targets.
    nonisolated static func isTerminalThreadStatus(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
    }

    public func stopAllProviderSessions() {
        lock.lock()
        let adapters = Array(providers.values)
        lock.unlock()
        adapters.forEach { $0.stopAll() }
    }

    public func stopAllProviderSessionsForAppTermination() {
        lock.lock()
        let adapters = Array(providers.values)
        lock.unlock()
        adapters.forEach { $0.stopAllForAppTermination() }
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
        // Recovered sessions are rebuilt here, bypassing the app shell's providerEnvironment, so
        // re-derive the Token Saver env or distill silently turns off on resume. Always keep the
        // provider tag so `| distill` savings attribute to claude/codex (not "unknown").
        var environment = await recoveryEnvironmentProvider?(thread.provider) ?? [:]
        environment["REMOTE_CODE_AGENT_PROVIDER"] = thread.provider.rawValue
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
            environment: environment,
            extraArgs: activeTurnId.map { ["remotecode.recovery.activeTurnId=\($0)"] } ?? [],
            runAsUser: thread.runAsUser
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

    // PERF-MAC_AGENT-007 / AG-001: a snapshot of stream-event writes plus whether
    // a prune is due. The live buffer is acknowledged only after the repository
    // transaction commits, so a failed flush remains retryable byte-for-byte.
    private struct BatchFlush {
        var items: [StreamWriteItem]
        var pruneDue: Bool
    }

    /// Must be called with `lock` held. Snapshots without draining; commit
    /// acknowledgement removes this exact prefix later.
    private func takeStreamFlushLocked(threadId: AgentThreadID, pruneDue: Bool, nowMs: Int64) -> BatchFlush? {
        let effectivePruneDue = pruneDue || pendingStreamPrunes.contains(threadId)
        guard let batch = pendingStreamWrites[threadId], !batch.isEmpty else {
            if effectivePruneDue { return BatchFlush(items: [], pruneDue: true) }
            return nil
        }
        lastStreamFlushMs[threadId] = nowMs
        return BatchFlush(items: batch.snapshot(), pruneDue: effectivePruneDue)
    }

    /// Commits a batch atomically, then acknowledges the exact in-memory prefix.
    /// Repository writes are idempotent so a retry after an ambiguous boundary
    /// cannot duplicate a previously committed sequence.
    @discardableResult
    private func flushStreamWrites(
        _ flush: BatchFlush,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) -> Error? {
        do {
            try runRepo.persistStreamBatch(
                runId: runId,
                threadId: threadId,
                items: flush.items.map {
                    AgentRunRepository.StreamWriteIntent(
                        seq: $0.seq,
                        kind: $0.kind,
                        payloadJSON: $0.payloadJSON,
                        providerEvent: $0.providerEvent
                    )
                },
                shouldPruneStreamEvents: flush.pruneDue
            )
            if let lastKind = flush.items.last?.kind {
                try providerSessionRepo?.updateDiagnostics(threadId: threadId, lastEventKind: lastKind, lastErrorMessage: nil)
            }
            lock.lock()
            guard var batch = pendingStreamWrites[threadId],
                  batch.acknowledge(flush.items) else {
                lock.unlock()
                let error = NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 409,
                    userInfo: [NSLocalizedDescriptionKey: "Committed stream batch no longer matches its in-memory prefix."]
                )
                recordMirrorPersistenceFailure(error, threadId: threadId)
                emitPersistenceIssue("run.stream_event.acknowledge", error: error, runId: runId, threadId: threadId)
                return error
            }
            pendingStreamWrites[threadId] = batch
            if flush.pruneDue { pendingStreamPrunes.remove(threadId) }
            if batch.isEmpty {
                pendingStreamRunIds.removeValue(forKey: threadId)
            }
            lock.unlock()
            return nil
        } catch {
            // The repository transaction rolled back the entire batch. Keep the
            // in-memory prefix and owner intact so snapshot/start/terminal barriers
            // can retry. This is a transient durability failure, not a known gap.
            emitPersistenceIssue("run.stream_event.append", error: error, runId: runId, threadId: threadId)
            return error
        }
    }

    /// Drain and persist any buffered stream writes for a thread immediately. Used
    /// on terminal/stop paths so the tail of a fast stream is never stranded in the
    /// buffer once the run is no longer producing events.
    @discardableResult
    private func flushPendingStreamWrites(runId: AgentRunID, threadId: AgentThreadID) -> Error? {
        flushPendingStreamWritesResult(runId: runId, threadId: threadId)
    }

    private func flushPendingStreamWritesResult(
        runId: AgentRunID,
        threadId: AgentThreadID
    ) -> Error? {
        mirrorEventLock.lock()
        defer { mirrorEventLock.unlock() }
        lock.lock()
        if let bufferedRunId = pendingStreamRunIds[threadId], bufferedRunId != runId {
            lock.unlock()
            let error = NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey: "Buffered mirror events changed run ownership."]
            )
            recordMirrorPersistenceFailure(error, threadId: threadId)
            return error
        }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let flush = takeStreamFlushLocked(threadId: threadId, pruneDue: false, nowMs: nowMs)
        lock.unlock()
        if let flush, !flush.items.isEmpty {
            return flushStreamWrites(flush, runId: runId, threadId: threadId)
        }
        return nil
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

    /// Stable identity for a final message synthesized from a provider terminal
    /// payload. The transform is one-to-one for run UUIDs and cannot equal the
    /// same run's deterministic user-message ID.
    private static func terminalAssistantMessageId(runId: AgentRunID) -> AgentMessageID {
        var bytes = runId.value.uuid
        bytes.0 ^= 0xA5
        return AgentMessageID(UUID(uuid: bytes))
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
        allowFinalResponseTranslation: Bool = true,
        providerTerminalAcknowledged: Bool = true
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
                    lock.lock()
                    providerTextTranslationsInFlight[runId, default: 0] += 1
                    lock.unlock()
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
                        if let terminal = self.completeProviderTextTranslation(runId: runId) {
                            self.handle(
                                event: .finished(
                                    terminal.status,
                                    finalMessage: terminal.finalMessage,
                                    providerThreadId: terminal.providerThreadId
                                ),
                                runId: runId,
                                threadId: terminal.threadId,
                                allowFinalResponseTranslation: terminal.allowFinalResponseTranslation,
                                providerTerminalAcknowledged: terminal.providerTerminalAcknowledged
                            )
                        }
                    }
                    return
                }
            }
            mirrorEventLock.lock()
            defer { mirrorEventLock.unlock() }
            lock.lock()
            let priorBufferedRunId = pendingStreamRunIds[threadId].flatMap { owner in
                owner == runId ? nil : owner
            }
            lock.unlock()
            if let priorBufferedRunId {
                _ = flushPendingStreamWritesResult(
                    runId: priorBufferedRunId,
                    threadId: threadId
                )
            }
            lock.lock()
            let s = allocateStreamSequenceLocked(runId: runId, threadId: threadId)
            lock.unlock()
            let data: Data?
            do {
                data = try streamEventEncoder.encode(ev)
            } catch {
                recordMirrorPersistenceFailure(error, threadId: threadId)
                emitPersistenceIssue("run.stream_event.encode", error: error, runId: runId, threadId: threadId)
                data = nil
            }
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
                if let owner = pendingStreamRunIds[threadId], owner != runId {
                    lock.unlock()
                    let error = NSError(
                        domain: "RemoteCode.AgentRunCoordinator",
                        code: 409,
                        userInfo: [NSLocalizedDescriptionKey: "Buffered mirror events changed run ownership."]
                    )
                    recordMirrorPersistenceFailure(error, threadId: threadId)
                    emitPersistenceIssue("run.stream_event.owner", error: error, runId: runId, threadId: threadId)
                    return
                }
                var batch = pendingStreamWrites[threadId] ?? StreamWriteBatch()
                batch.append(StreamWriteItem(seq: s, kind: ev.debugDescription, payloadJSON: payloadJSON, providerEvent: providerEvent))
                pendingStreamWrites[threadId] = batch
                pendingStreamRunIds[threadId] = runId
                // Prune at most once per `streamEventPruneInterval` events per thread.
                let pruneCount = (streamEventsSincePrune[threadId] ?? 0) + 1
                let pruneDue = pruneCount >= Self.streamEventPruneInterval
                streamEventsSincePrune[threadId] = pruneDue ? 0 : pruneCount
                if pruneDue { pendingStreamPrunes.insert(threadId) }
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
            case .threadStarted(let eventThreadId, let providerThreadId):
                let resumeCursor = providerThreadId ?? eventThreadId
                do {
                    if var session = try providerSessionRepo?.get(threadId: threadId) {
                        var payload = ProviderSessionRuntimePayload.decode(session.runtimePayloadJSON)
                        session.resumeCursor = resumeCursor
                        payload.providerThreadId = resumeCursor
                        payload.updatedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
                        session.runtimePayloadJSON = payload.encoded()
                        session.updatedAt = Date()
                        try providerSessionRepo?.upsert(session)
                    }
                    if var thread = try threadRepo.get(id: threadId) {
                        thread.providerThreadId = resumeCursor
                        thread.updatedAt = Date()
                        try threadRepo.upsert(thread)
                    }
                } catch {
                    emitPersistenceIssue("provider_session.resume_cursor.update", error: error, runId: runId, threadId: threadId)
                }
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
            if data != nil {
                onAssistantEvent?(ev, threadId, runId)
            }
        case .status(let st):
            for observer in observersSnapshot() {
                observer.runCoordinator(self, didChangeStatus: st, runId: runId, threadId: threadId)
            }
        case .finished(let status, let rawFinalMessage, let providerThreadId):
            lock.lock()
            if (providerTextTranslationsInFlight[runId] ?? 0) > 0 {
                if var deferred = deferredProviderTerminalEvents[runId] {
                    deferred.providerTerminalAcknowledged = deferred.providerTerminalAcknowledged
                        || providerTerminalAcknowledged
                    deferredProviderTerminalEvents[runId] = deferred
                } else {
                    deferredProviderTerminalEvents[runId] = DeferredProviderTerminalEvent(
                        status: status,
                        finalMessage: rawFinalMessage,
                        providerThreadId: providerThreadId,
                        threadId: threadId,
                        allowFinalResponseTranslation: allowFinalResponseTranslation,
                        providerTerminalAcknowledged: providerTerminalAcknowledged
                    )
                }
                lock.unlock()
                return
            }
            lock.unlock()
            // AG-002: mark the provider-side terminal acknowledgement before the
            // durable-row dedupe guard. stopRun may already have marked the row
            // cancelled, but destructive callers still need proof the provider
            // callback arrived before deleting the thread and its caches.
            lock.lock()
            if providerTerminalAcknowledged,
               (awaitingTerminationRuns.contains(runId)
                || pendingGracefulStopFallbacks.contains(runId)) {
                providerTerminatedRuns.insert(runId)
            }
            lock.unlock()
            if let row = try? runRepo.get(id: runId), row.finishedAt != nil {
                return
            }
            lock.lock()
            let finishAlreadyInFlight = finishingRuns.contains(runId)
            if finishAlreadyInFlight && allowFinalResponseTranslation {
                lock.unlock()
                return
            }
            if !finishAlreadyInFlight {
                finishingRuns.insert(runId)
            }
            lock.unlock()

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
            lock.lock()
            if pendingTerminalEvents[runId] == nil {
                let assistantMessage: AgentMessage?
                if status == .completed, let finalMessage, !finalMessage.isEmpty {
                    assistantMessage = AgentMessage(
                        id: activeAssistantMessageIds[runId]
                            ?? Self.terminalAssistantMessageId(runId: runId),
                        threadId: threadId,
                        role: .assistant,
                        content: AssistantTimelineState.cappedText(finalMessage)
                    )
                } else {
                    assistantMessage = nil
                }
                pendingTerminalEvents[runId] = PendingTerminalEvent(
                    status: status,
                    finalMessage: finalMessage,
                    providerThreadId: providerThreadId,
                    assistantMessage: assistantMessage,
                    finishedAt: Date(),
                    providerTerminalAcknowledged: providerTerminalAcknowledged
                )
            }
            let pendingTerminal = pendingTerminalEvents[runId]!
            lock.unlock()
            // PERF-MAC_AGENT-007: drain any buffered stream writes before the run
            // tears down, so the tail of a fast stream is durably persisted (and
            // visible to latestStreamEvents/reload) once the run finishes.
            var streamFlushError = flushPendingStreamWrites(runId: runId, threadId: threadId)
            if streamFlushError != nil {
                // A provider terminal event is a durability barrier. SQLite's busy
                // timeout may expire while another process still owns the writer;
                // retry once before persisting/broadcasting terminal state so the
                // final status can never overtake its buffered provider events.
                streamFlushError = flushPendingStreamWrites(runId: runId, threadId: threadId)
            }
            if streamFlushError != nil {
                scheduleTerminalDurabilityRetry(runId: runId, threadId: threadId)
                return
            }
            let terminalPersistence: TerminalPersistenceContext
            do {
                terminalPersistence = try persistTerminalGraph(
                    pendingTerminal,
                    runId: runId,
                    threadId: threadId
                )
            } catch {
                emitPersistenceIssue("run.terminal_graph.commit", error: error, runId: runId, threadId: threadId)
                scheduleTerminalDurabilityRetry(runId: runId, threadId: threadId)
                return
            }
            let runMetadata = terminalPersistence.runMetadata
            let completedTurnId = terminalPersistence.completedTurnId
            let assistantMessageId = terminalPersistence.assistantMessageId
            let resumeCursor = terminalPersistence.resumeCursor
            if terminalPersistence.insertedAssistantMessage,
               let assistantMessage = pendingTerminal.assistantMessage {
                onMessageAppended?(assistantMessage)
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
            // UX-MAC_AGENT-BG-AWAIT: a full-access run that ends still awaiting a
            // background job it launched is auto-nudged (bounded) so it actually
            // finishes instead of silently sitting at "completed". Decided before
            // the run metadata is evicted below.
            maybeScheduleBackgroundAwaitContinuation(
                threadId: threadId,
                status: status,
                finalMessage: finalMessage,
                runMetadata: runMetadata,
                resumeCursor: resumeCursor
            )
            lock.lock()
            active.removeValue(forKey: runId)
            activeThreads.removeValue(forKey: threadId)
            activeRunMetadata.removeValue(forKey: runId)
            activeTurnIds.removeValue(forKey: runId)
            activeAssistantMessageIds.removeValue(forKey: runId)
            activeProviderTextItemTypes.removeValue(forKey: runId)
            bufferedProviderTextItems.removeValue(forKey: runId)
            activeDistillOutputRuns.remove(runId)
            finishingRuns.remove(runId)
            pendingTerminalEvents.removeValue(forKey: runId)
            terminalRetryScheduled.remove(runId)
            pendingThreadStops.remove(threadId)
            // PERF-MAC_AGENT-005: flush a final prune at run end so events queued
            // since the last cadence-prune don't linger unbounded.
            let pendingPrune = streamFlushError == nil && (streamEventsSincePrune[threadId] ?? 0) > 0
            if streamFlushError == nil {
                streamEventsSincePrune.removeValue(forKey: threadId)
                // The transactional flush committed and acknowledged the buffer;
                // only now may terminal cleanup release its ownership metadata.
                pendingStreamWrites.removeValue(forKey: threadId)
                pendingStreamRunIds.removeValue(forKey: threadId)
                pendingStreamPrunes.remove(threadId)
                lastStreamFlushMs.removeValue(forKey: threadId)
                seq.removeValue(forKey: runId)
            } else {
                clearStreamSequenceIfReleasedLocked(runId: runId, threadId: threadId)
            }
            // PERF-MAC_AGENT-008: thread closed -> evict the dedup cache entry so
            // finished threads do not retain their final-answer text indefinitely.
            lastPersistedAssistantContent.removeValue(forKey: threadId)
            let activeProjection = activeRunProjectionLocked()
            lock.unlock()
            onActiveRunProjectionChanged?(activeProjection, .finished(status))
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
            // F22: route the error through the .event path so it is PERSISTED as a
            // stream event (same batched appendStreamEvent flow as every other
            // timeline event) before notifying observers. Without this, a failed
            // run left no explanation after a thread switch or relaunch — replay
            // (latestStreamEvents) only restores persisted events, and errors for
            // non-selected threads were dropped entirely. Observer/onAssistantEvent
            // broadcasting is unchanged: the .event path performs both.
            // Provider callbacks may arrive concurrently. Serialize the resume
            // cursor read with `.threadStarted` persistence so a crash cannot be
            // mislabeled unrecoverable while its durable cursor is being stored.
            mirrorEventLock.lock()
            let persistedSession = try? providerSessionRepo?.get(threadId: threadId)
            let persistedThread = try? threadRepo.get(id: threadId)
            mirrorEventLock.unlock()
            let resumeCursor = (persistedSession?.resumeCursor ?? persistedThread?.providerThreadId)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let recoverable = resumeCursor?.isEmpty == false
            handle(
                event: .event(.error(message: m, recoverable: recoverable)),
                runId: runId,
                threadId: threadId,
                allowFinalResponseTranslation: false
            )
            try? providerSessionRepo?.updateDiagnostics(threadId: threadId, lastEventKind: "error", lastErrorMessage: m)
        }
    }

    private func persistTerminalGraph(
        _ pending: PendingTerminalEvent,
        runId: AgentRunID,
        threadId: AgentThreadID
    ) throws -> TerminalPersistenceContext {
        lock.lock()
        let runMetadata = activeRunMetadata[runId]
        let completedTurnId = activeTurnIds[runId]
        let priorAssistantMessageId = activeAssistantMessageIds[runId]
        lock.unlock()

        guard var run = try runRepo.get(id: runId) else {
            throw NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Run row missing while committing terminal state."]
            )
        }
        guard var thread = try threadRepo.get(id: threadId) else {
            throw NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Thread row missing while committing terminal state."]
            )
        }

        let finishedProvider = runMetadata?.provider ?? thread.provider
        let finishedProviderInstanceId = runMetadata?.providerInstanceId
            ?? thread.providerInstanceId
            ?? finishedProvider.rawValue
        let finishedModel = runMetadata?.model ?? thread.model
        run.status = pending.status
        run.finishedAt = pending.finishedAt
        run.errorMessage = nil

        thread.status = pending.status
        thread.hasUnread = Self.hasUnread(for: pending.status)
        if let providerThreadId = pending.providerThreadId {
            thread.providerThreadId = providerThreadId
        }
        thread.updatedAt = pending.finishedAt
        let resumeCursor = pending.providerThreadId ?? thread.providerThreadId

        let providerSession: ProviderSessionRuntime?
        if let providerSessionRepo {
            let existingPayload = try providerSessionRepo.get(threadId: threadId)?.runtimePayloadJSON
            let runtimePayload = providerSessionRuntimePayloadJSON(
                existingPayload,
                status: pending.status,
                resumeCursor: resumeCursor,
                completedTurnId: completedTurnId,
                model: finishedModel,
                serviceTier: runMetadata?.serviceTier ?? .auto,
                runtimeMode: runMetadata?.runtimeMode ?? .supervised,
                interactionMode: runMetadata?.interactionMode ?? .default,
                activeTurnId: nil,
                updatedAt: pending.finishedAt
            )
            providerSession = ProviderSessionRuntime(
                threadId: threadId,
                provider: finishedProvider,
                providerInstanceId: finishedProviderInstanceId,
                adapterKey: runMetadata?.adapterKey,
                binaryIdentity: runMetadata?.binaryIdentity,
                status: pending.status,
                resumeCursor: resumeCursor,
                cwd: runMetadata?.cwd,
                model: finishedModel,
                serviceTier: runMetadata?.serviceTier ?? .auto,
                runtimeMode: runMetadata?.runtimeMode ?? .supervised,
                lastRunId: runId,
                lastEventKind: "run.finished",
                runtimePayloadJSON: runtimePayload,
                updatedAt: pending.finishedAt
            )
        } else {
            providerSession = nil
        }

        let result = try runRepo.persistTerminalGraph(
            assistantMessage: pending.assistantMessage,
            run: run,
            thread: thread,
            providerSession: providerSession
        )

        lock.lock()
        if let assistantMessageId = result.assistantMessageId {
            activeAssistantMessageIds[runId] = assistantMessageId
        }
        if let assistantMessage = pending.assistantMessage,
           !Self.shouldEvictLastPersistedContent(
                threadClosed: false,
                entryByteCount: assistantMessage.content.utf8.count
           ) {
            // Update the memo only after the transaction commits. A failed
            // assistant INSERT must remain retryable and cannot poison dedup.
            lastPersistedAssistantContent[threadId] = assistantMessage.content
        }
        let assistantMessageId = result.assistantMessageId ?? priorAssistantMessageId
        lock.unlock()

        return TerminalPersistenceContext(
            runMetadata: runMetadata,
            completedTurnId: completedTurnId,
            assistantMessageId: assistantMessageId,
            resumeCursor: resumeCursor,
            insertedAssistantMessage: result.insertedAssistantMessage
        )
    }

    private func retryStartFailureCommit(runId: AgentRunID) {
        lock.lock()
        guard let pending = pendingStartFailures[runId] else {
            lock.unlock()
            return
        }
        let bufferedRunId = pendingStreamRunIds[pending.request.threadId]
        lock.unlock()

        if bufferedRunId == runId,
           flushPendingStreamWrites(runId: runId, threadId: pending.request.threadId) != nil {
            scheduleStartFailureDurabilityRetry(runId: runId)
            return
        }
        if let bufferedRunId, bufferedRunId != runId, !pending.otherRunActive {
            let error = NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 409,
                userInfo: [NSLocalizedDescriptionKey:
                    "A start failure cannot overtake another run's buffered mirror events."]
            )
            emitPersistenceIssue(
                "run.start_failure.stream_owner",
                error: error,
                runId: runId,
                threadId: pending.request.threadId
            )
            scheduleStartFailureDurabilityRetry(runId: runId)
            return
        }

        do {
            guard var run = try runRepo.get(id: runId) else {
                throw NSError(
                    domain: "RemoteCode.AgentRunCoordinator",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Run row missing while committing start failure."]
                )
            }
            run.status = .failed
            run.finishedAt = pending.finishedAt
            run.errorMessage = pending.message

            var terminalThread: AgentThread?
            var providerSession: ProviderSessionRuntime?
            if !pending.otherRunActive {
                guard var thread = try threadRepo.get(id: pending.request.threadId) else {
                    throw NSError(
                        domain: "RemoteCode.AgentRunCoordinator",
                        code: 404,
                        userInfo: [NSLocalizedDescriptionKey: "Thread row missing while committing start failure."]
                    )
                }
                thread.status = pending.preserveRecoverableSession ? .interrupted : .failed
                thread.hasUnread = Self.hasUnread(for: thread.status)
                thread.updatedAt = pending.finishedAt
                terminalThread = thread

                if let providerSessionRepo {
                    let existingPayload = try providerSessionRepo.get(threadId: pending.request.threadId)?.runtimePayloadJSON
                    providerSession = ProviderSessionRuntime(
                        threadId: pending.request.threadId,
                        provider: pending.request.provider,
                        providerInstanceId: pending.request.providerInstanceId,
                        adapterKey: pending.adapterKey,
                        binaryIdentity: pending.binaryIdentity,
                        status: pending.preserveRecoverableSession ? .interrupted : .failed,
                        resumeCursor: pending.request.providerThreadId,
                        cwd: pending.request.cwd,
                        model: pending.request.model,
                        serviceTier: pending.request.serviceTier,
                        runtimeMode: pending.request.permissionMode,
                        lastRunId: runId,
                        lastEventKind: pending.preserveRecoverableSession
                            ? "run.resume_start_failed"
                            : "run.start_failed",
                        lastErrorMessage: pending.message,
                        runtimePayloadJSON: existingPayload,
                        updatedAt: pending.finishedAt
                    )
                }
            }

            _ = try runRepo.persistTerminalGraph(
                assistantMessage: nil,
                run: run,
                thread: terminalThread,
                providerSession: providerSession,
                streamEvent: pending.streamEvent
            )
        } catch {
            emitPersistenceIssue(
                "run.start_failure.terminal_graph.commit",
                error: error,
                runId: runId,
                threadId: pending.request.threadId
            )
            scheduleStartFailureDurabilityRetry(runId: runId)
            return
        }

        lock.lock()
        pendingStartFailures.removeValue(forKey: runId)
        startFailureRetryScheduled.remove(runId)
        clearStreamSequenceIfReleasedLocked(runId: runId, threadId: pending.request.threadId)
        lock.unlock()

        if !pending.otherRunActive {
            for observer in observersSnapshot() {
                observer.runCoordinator(
                    self,
                    didChangeStatus: .failed,
                    runId: runId,
                    threadId: pending.request.threadId
                )
            }
        }
        for observer in observersSnapshot() {
            observer.runCoordinator(
                self,
                didReceive: pending.event,
                run: runId,
                threadId: pending.request.threadId
            )
        }
        onAssistantEvent?(pending.event, pending.request.threadId, runId)
        if !pending.otherRunActive {
            onRunFinished?(pending.request.threadId, runId, .failed)
        }
    }

    private func scheduleStartFailureDurabilityRetry(runId: AgentRunID) {
        lock.lock()
        guard pendingStartFailures[runId] != nil,
              startFailureRetryScheduled.insert(runId).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            self.lock.lock()
            self.startFailureRetryScheduled.remove(runId)
            let stillPending = self.pendingStartFailures[runId] != nil
            self.lock.unlock()
            if stillPending {
                self.retryStartFailureCommit(runId: runId)
            }
        }
    }

    private func scheduleTerminalDurabilityRetry(runId: AgentRunID, threadId: AgentThreadID) {
        lock.lock()
        guard pendingTerminalEvents[runId] != nil,
              terminalRetryScheduled.insert(runId).inserted else {
            lock.unlock()
            return
        }
        lock.unlock()

        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let self else { return }
            let pending = self.takePendingTerminalRetry(runId: runId)
            guard let pending else { return }
            self.handle(
                event: .finished(
                    pending.status,
                    finalMessage: pending.finalMessage,
                    providerThreadId: pending.providerThreadId
                ),
                runId: runId,
                threadId: threadId,
                allowFinalResponseTranslation: false,
                providerTerminalAcknowledged: pending.providerTerminalAcknowledged
            )
        }
    }

    private func takePendingTerminalRetry(runId: AgentRunID) -> PendingTerminalEvent? {
        lock.lock()
        defer { lock.unlock() }
        terminalRetryScheduled.remove(runId)
        return pendingTerminalEvents[runId]
    }

    private func shouldTranslateFinalResponse(_ text: String) -> Bool {
        finalResponseTranslator != nil && SR1ResponseDetector.isSR1(text)
    }

    private func completeProviderTextTranslation(runId: AgentRunID) -> DeferredProviderTerminalEvent? {
        lock.lock()
        defer { lock.unlock() }
        let remaining = max(0, (providerTextTranslationsInFlight[runId] ?? 1) - 1)
        if remaining > 0 {
            providerTextTranslationsInFlight[runId] = remaining
            return nil
        }
        providerTextTranslationsInFlight.removeValue(forKey: runId)
        return deferredProviderTerminalEvents.removeValue(forKey: runId)
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

    private static func hasUnread(for status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .interrupted:
            true
        case .pending, .running, .cancelled:
            false
        }
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
        var highestSeq: Int { items.map(\.seq).max() ?? 0 }

        mutating func append(_ item: StreamWriteItem) {
            items.append(item)
        }

        func snapshot() -> [StreamWriteItem] {
            items
        }

        /// Remove only the exact prefix that the repository committed. A mismatch
        /// means another lifecycle path changed ownership and must fail loud.
        mutating func acknowledge(_ committed: [StreamWriteItem]) -> Bool {
            guard committed.count <= items.count else { return false }
            for (current, persisted) in zip(items.prefix(committed.count), committed) {
                guard current.seq == persisted.seq,
                      current.kind == persisted.kind,
                      current.payloadJSON == persisted.payloadJSON,
                      current.providerEvent?.id == persisted.providerEvent?.id else {
                    return false
                }
            }
            items.removeFirst(committed.count)
            return true
        }

        mutating func drain() -> [StreamWriteItem] {
            let snapshot = items
            items.removeAll(keepingCapacity: true)
            return snapshot
        }
    }

    /// Next durable stream sequence for `runId`.
    ///
    /// Must be called with `lock` held. Uses the higher of the in-memory counter,
    /// any still-buffered seq for this run, and durable MAX(seq) when the
    /// in-memory counter was cleared (finish/stop) so a late Grok event cannot
    /// reissue seq 1 for a different event kind (which
    /// `persistStreamEventIdempotently` rejects as a conflicting identity).
    private func allocateStreamSequenceLocked(runId: AgentRunID, threadId: AgentThreadID) -> Int {
        var high = seq[runId] ?? 0
        if seq[runId] == nil {
            // Finish/stop clear `seq` while durable rows remain. Re-seed before
            // the next allocate so late providerRuntime/turnStarted cannot steal
            // an already-committed identity.
            high = max(high, (try? runRepo.maxStreamEventSeq(runId: runId)) ?? 0)
        }
        if pendingStreamRunIds[threadId] == runId,
           let batch = pendingStreamWrites[threadId] {
            high = max(high, batch.highestSeq)
        }
        let next = high + 1
        seq[runId] = next
        return next
    }

    /// Drop in-memory sequence only when this run no longer owns a retryable
    /// stream buffer. Must be called with `lock` held.
    private func clearStreamSequenceIfReleasedLocked(runId: AgentRunID, threadId: AgentThreadID) {
        if pendingStreamRunIds[threadId] == runId,
           let batch = pendingStreamWrites[threadId],
           !batch.isEmpty {
            return
        }
        seq.removeValue(forKey: runId)
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
        // A persistence diagnostic is intentionally local-only. Publishing an
        // event that cannot enter the durable snapshot would let remote mirrors
        // advance their EventBus watermark past unrecoverable history.
        onPersistenceIssue?(message, threadId, runId)
    }

    /// Persists coordinator-synthesized events before publishing them. Provider
    /// stream events use the normal batch path; start failures cannot because a
    /// second run may already own the same thread buffer and a failed start is
    /// never registered in `activeThreads` for snapshot-triggered flushing.
    private func publishImmediateAssistantEvent(
        _ event: AssistantEvent,
        threadId: AgentThreadID,
        runId: AgentRunID
    ) {
        mirrorEventLock.lock()
        defer { mirrorEventLock.unlock() }

        lock.lock()
        let eventSequence = allocateStreamSequenceLocked(runId: runId, threadId: threadId)
        lock.unlock()

        let data: Data
        do {
            data = try streamEventEncoder.encode(event)
        } catch {
            recordMirrorPersistenceFailure(error, threadId: threadId)
            emitPersistenceIssue("run.stream_event.encode", error: error, runId: runId, threadId: threadId)
            return
        }
        guard let json = String(data: data, encoding: .utf8) else {
            let error = NSError(
                domain: "RemoteCode.AgentRunCoordinator",
                code: 422,
                userInfo: [NSLocalizedDescriptionKey: "AssistantEvent JSON was not UTF-8."]
            )
            recordMirrorPersistenceFailure(error, threadId: threadId)
            emitPersistenceIssue("run.stream_event.encode", error: error, runId: runId, threadId: threadId)
            return
        }
        do {
            try runRepo.appendStreamEvent(
                runId: runId,
                seq: eventSequence,
                kind: event.debugDescription,
                payloadJSON: streamPayloadCompactor?(json) ?? json
            )
        } catch {
            recordMirrorPersistenceFailure(error, threadId: threadId)
            emitPersistenceIssue("run.stream_event.append", error: error, runId: runId, threadId: threadId)
            return
        }
        do {
            try providerSessionRepo?.updateDiagnostics(
                threadId: threadId,
                lastEventKind: event.debugDescription,
                lastErrorMessage: nil
            )
        } catch {
            emitPersistenceIssue("provider_session.diagnostics.update", error: error, runId: runId, threadId: threadId)
        }
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didReceive: event, run: runId, threadId: threadId)
        }
        onAssistantEvent?(event, threadId, runId)
    }

    private func recordMirrorPersistenceFailure(_ error: Error, threadId: AgentThreadID) {
        lock.lock()
        if mirrorPersistenceFailures[threadId] == nil {
            mirrorPersistenceFailures[threadId] = error
        }
        lock.unlock()
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

private struct PendingTerminalEvent {
    var status: AgentRunStatus
    var finalMessage: String?
    var providerThreadId: String?
    var assistantMessage: AgentMessage?
    var finishedAt: Date
    var providerTerminalAcknowledged: Bool
}

private struct DeferredProviderTerminalEvent {
    var status: AgentRunStatus
    var finalMessage: String?
    var providerThreadId: String?
    var threadId: AgentThreadID
    var allowFinalResponseTranslation: Bool
    var providerTerminalAcknowledged: Bool
}

private struct PendingStartFailure {
    var request: AgentRunRequest
    var adapterKey: String
    var binaryIdentity: String?
    var preserveRecoverableSession: Bool
    var otherRunActive: Bool
    var message: String
    var event: AssistantEvent
    var streamEvent: AgentRunRepository.StreamWriteIntent
    var finishedAt: Date
}

private struct TerminalPersistenceContext {
    var runMetadata: (provider: AgentProvider, providerInstanceId: String?, model: String, cwd: String, serviceTier: AgentServiceTier, runtimeMode: AgentPermissionMode, interactionMode: AgentInteractionMode, adapterKey: String, binaryIdentity: String?)?
    var completedTurnId: String?
    var assistantMessageId: AgentMessageID?
    var resumeCursor: String?
    var insertedAssistantMessage: Bool
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
