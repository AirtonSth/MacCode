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
    private var providers: [AgentProvider: AgentProviderRunner]
    private var active: [AgentRunID: AgentRunHandle] = [:]
    private var activeThreads: [AgentThreadID: AgentRunID] = [:]
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

    public init(
        runRepo: AgentRunRepository,
        messageRepo: AgentMessageRepository,
        threadRepo: AgentThreadRepository,
        providers: [AgentProvider: AgentProviderRunner]
    ) {
        self.runRepo = runRepo
        self.messageRepo = messageRepo
        self.threadRepo = threadRepo
        self.providers = providers
    }

    public func replaceProvider(_ provider: AgentProvider, runner: AgentProviderRunner) {
        lock.lock(); defer { lock.unlock() }
        providers[provider] = runner
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

    @discardableResult
    public func startRun(_ request: AgentRunRequest) async throws -> AgentRunID {
        guard let runner = providers[request.provider] else {
            throw AgentRunError.missingBinary(request.provider.rawValue)
        }
        // persist user message
        let userMsg = AgentMessage(threadId: request.threadId, role: .user, content: request.prompt)
        try messageRepo.append(userMsg)
        // persist run
        let run = AgentRun(id: request.runId, threadId: request.threadId, provider: request.provider, model: request.model, status: .running)
        try runRepo.upsert(run)
        if var thread = try threadRepo.get(id: request.threadId) {
            thread.status = .running
            thread.updatedAt = Date()
            try threadRepo.upsert(thread)
        }
        onRunStarted?(request.threadId, request.runId)

        let runId = request.runId
        let coordinator = self
        let handle = try await runner.startRun(request) { ev in
            coordinator.handle(event: ev, runId: runId, threadId: request.threadId)
        }
        lock.lock()
        active[runId] = handle
        activeThreads[request.threadId] = runId
        seq[runId] = 0
        let shouldCancel = pendingThreadStops.remove(request.threadId) != nil
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
        if handle == nil {
            pendingThreadStops.insert(threadId)
        }
        lock.unlock()
        handle?.cancel()
    }

    public func latestStreamEvents(threadId: AgentThreadID) -> [AssistantEvent] {
        (try? runRepo.listLatestStreamEvents(threadId: threadId)) ?? []
    }

    private func persistAssistantIfMissing(_ text: String, threadId: AgentThreadID) {
        let text = AssistantTimelineState.cappedText(text)
        guard !text.isEmpty else { return }
        let existing = (try? messageRepo.list(threadId: threadId)) ?? []
        guard !existing.contains(where: { $0.role == .assistant && $0.content == text }) else { return }
        _ = try? messageRepo.append(AgentMessage(threadId: threadId, role: .assistant, content: text))
    }

    private func handle(event: AgentRunEvent, runId: AgentRunID, threadId: AgentThreadID) {
        switch event {
        case .event(let ev):
            lock.lock()
            let s = (seq[runId] ?? 0) + 1
            seq[runId] = s
            lock.unlock()
            // best-effort persist stream events
            if let data = try? JSONEncoder().encode(ev), let json = String(data: data, encoding: .utf8) {
                _ = try? runRepo.appendStreamEvent(runId: runId, seq: s, kind: ev.debugDescription, payloadJSON: json)
            }
            if case .turnCompleted(_, let finalMessage) = ev, let msg = finalMessage {
                persistAssistantIfMissing(msg, threadId: threadId)
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
                persistAssistantIfMissing(msg, threadId: threadId)
            }
            // update run row
            var run = AgentRun(id: runId, threadId: threadId, provider: .codex, model: "")
            run.status = status
            run.finishedAt = Date()
            _ = try? runRepo.upsert(run)
            // update thread status + provider thread id
            if let t = try? threadRepo.get(id: threadId) {
                var copy = t
                copy.status = status
                if let ptid = providerThreadId { copy.providerThreadId = ptid }
                copy.updatedAt = Date()
                _ = try? threadRepo.upsert(copy)
            }
            lock.lock()
            active.removeValue(forKey: runId)
            activeThreads.removeValue(forKey: threadId)
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
        }
    }

    private func observersSnapshot() -> [AgentRunObserver] {
        lock.lock()
        observerRefs.removeAll { $0.value == nil }
        let observers = observerRefs.compactMap(\.value)
        lock.unlock()
        return observers
    }
}

private final class WeakAgentRunObserver {
    weak var value: AgentRunObserver?

    init(_ value: AgentRunObserver) {
        self.value = value
    }
}
