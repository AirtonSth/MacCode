import Foundation
import CoreModel
import Persistence

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
    private var pendingThreadStops: Set<AgentThreadID> = []
    private var seq: [AgentRunID: Int] = [:]
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
    }

    public func runStatus(_ runId: AgentRunID) throws -> AgentRunStatus? {
        try runRepo.get(id: runId)?.status
    }

    @discardableResult
    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunID {
        let recoveryContext = request.providerThreadId == nil ? try recoverableResumeContext(for: request) : nil
        let resumeCursor = request.providerThreadId ?? recoveryContext?.resumeCursor
        let effectiveRequest = AgentRunRequest(
            runId: request.runId,
            threadId: request.threadId,
            provider: request.provider,
            providerInstanceId: request.providerInstanceId,
            model: request.model,
            cwd: request.cwd,
            prompt: request.prompt,
            userMessageContent: request.userMessageContent,
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

        let runId = effectiveRequest.runId
        let coordinator = self
        let handle = try await runner.sendTurn(effectiveRequest) { ev in
            coordinator.handle(event: ev, runId: runId, threadId: effectiveRequest.threadId)
        }
        let terminalStatus = (try? runRepo.get(id: runId)?.status).flatMap { status -> AgentRunStatus? in
            status == .running || status == .pending ? nil : status
        }
        if terminalStatus == .cancelled {
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
        if let adapter = try? adapterForThread(threadId) {
            do {
                try recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
                if adapter.hasSession(threadId: threadId) {
                    try adapter.interruptTurn(threadId: threadId)
                    markStopRequested(threadId: threadId, runId: nil)
                    return
                }
            } catch {
                // Fall through to pending cancellation; startRun will fail loudly
                // if the recovered state is not sufficient to continue.
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
        lock.lock()
        if let runId {
            active.removeValue(forKey: runId)
            activeThreads.removeValue(forKey: threadId)
            activeRunMetadata.removeValue(forKey: runId)
            activeTurnIds.removeValue(forKey: runId)
            activeAssistantMessageIds.removeValue(forKey: runId)
            seq.removeValue(forKey: runId)
            pendingThreadStops.remove(threadId)
        }
        lock.unlock()
        for observer in observersSnapshot() {
            observer.runCoordinator(self, didChangeStatus: .cancelled, runId: stoppedRunId, threadId: threadId)
        }
        onRunFinished?(threadId, stoppedRunId, .cancelled)
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) throws {
        let adapter = try adapterForThread(threadId)
        try adapter.respondToRequest(threadId: threadId, requestId: requestId, response: response)
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        let adapter = try adapterForThread(threadId)
        try adapter.respondToUserInput(threadId: threadId, requestId: requestId, text: text)
    }

    public func readThread(threadId: AgentThreadID) throws -> [AssistantEvent] {
        let adapter = try adapterForThread(threadId)
        try recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
        return try adapter.readThread(threadId: threadId)
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) throws {
        let adapter = try adapterForThread(threadId)
        try recoverAdapterSessionIfNeeded(threadId: threadId, adapter: adapter)
        try adapter.rollbackThread(threadId: threadId, toTurnId: toTurnId)
    }

    @discardableResult
    public func revertThreadToCheckpoint(threadId: AgentThreadID, checkpointTurnCount: Int, cwd: String) throws -> AgentTurnCheckpointSummary {
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
        try rollbackThread(threadId: threadId, toTurnId: checkpoint.turnId)
        try restoreWorkspace(to: checkpoint, newerCheckpoints: newer, cwd: cwd)
        try messageRepo.delete(ids: newer.compactMap(\.assistantMessageId))
        try checkpointRepo.deleteAfter(threadId: threadId, checkpointTurnCount: checkpointTurnCount)
        return checkpoint
    }

    public func latestStreamEvents(threadId: AgentThreadID) -> [AssistantEvent] {
        (try? runRepo.listLatestStreamEvents(threadId: threadId)) ?? []
    }

    public func activeThreadIdsSnapshot() -> Set<AgentThreadID> {
        lock.lock(); defer { lock.unlock() }
        return Set(activeThreads.keys)
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
            throw AgentProviderAdapterError.unsupported("Provider session for this thread is stopped; start a new thread or rerun from a valid checkpoint.")
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

    private func recoverAdapterSessionIfNeeded(threadId: AgentThreadID, adapter: AgentProviderAdapter) throws {
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
            extraArgs: activeTurnId.map { ["remotecode.recovery.activeTurnId=\($0)"] } ?? []
        )
        try adapter.recoverSession(request) { _ in }
    }

    private func providerBinaryIdentity(_ provider: AgentProvider, adapter: AgentProviderAdapter) -> String? {
        guard adapter is OneShotProviderAdapter else { return providerAdapterKey(adapter) }
        let binaryName = provider.rawValue
        if let path = ProcessLocator.resolve(binaryName) {
            return "\(binaryName):\(path)"
        }
        return "\(binaryName):unresolved"
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
        let text = AssistantTimelineState.cappedText(text)
        guard !text.isEmpty else { return nil }
        let existing: [AgentMessage]
        do {
            existing = try messageRepo.list(threadId: threadId)
        } catch {
            emitPersistenceIssue("message.list", error: error, runId: runId, threadId: threadId)
            return nil
        }
        guard !existing.contains(where: { $0.role == .assistant && $0.content == text }) else { return nil }
        let message = AgentMessage(threadId: threadId, role: .assistant, content: text)
        do {
            try messageRepo.append(message)
        } catch {
            emitPersistenceIssue("message.append.assistant", error: error, runId: runId, threadId: threadId)
            return nil
        }
        onMessageAppended?(message)
        return message
    }

    private func handle(event: AgentRunEvent, runId: AgentRunID, threadId: AgentThreadID) {
        switch event {
        case .event(let ev):
            lock.lock()
            let s = (seq[runId] ?? 0) + 1
            seq[runId] = s
            lock.unlock()
            if let data = try? JSONEncoder().encode(ev), let json = String(data: data, encoding: .utf8) {
                do {
                    try runRepo.appendStreamEvent(runId: runId, seq: s, kind: ev.debugDescription, payloadJSON: json)
                    if case .providerRuntime(let runtimeEvent) = ev {
                        try runRepo.appendProviderEventLog(threadId: threadId, runId: runId, event: runtimeEvent)
                    }
                    try runRepo.pruneStreamEvents(threadId: threadId)
                    try providerSessionRepo?.updateDiagnostics(threadId: threadId, lastEventKind: ev.debugDescription, lastErrorMessage: nil)
                } catch {
                    emitPersistenceIssue("run.stream_event.append", error: error, runId: runId, threadId: threadId)
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
        case .finished(let status, let finalMessage, let providerThreadId):
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
            pendingThreadStops.remove(threadId)
            seq.removeValue(forKey: runId)
            lock.unlock()
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
            return AgentTurnCheckpointFileSnapshot(path: file.path, kind: file.kind, contentsBase64: data.base64EncodedString())
        }
    }

    private func captureFileDiffs(files: [AgentTurnCheckpointFile], cwd: String) -> [AgentTurnCheckpointFileDiff] {
        files.map { file in
            let patch = GitDiff.diff(in: cwd, path: file.path)
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
