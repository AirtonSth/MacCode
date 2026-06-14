import Foundation
import CoreModel

public final class ClaudeCLIAdapter: AgentProviderAdapter, @unchecked Sendable {
    public let runner: AgentProviderRunner
    private let lock = NSLock()
    private var sessions: [AgentThreadID: AgentProviderSessionSummary] = [:]
    private var handles: [AgentThreadID: AgentRunHandle] = [:]
    private var events: [AgentThreadID: [AssistantEvent]] = [:]
    private let maxReadableEvents: Int
    private let maxSessions: Int
    /// Insertion-ordered list of finished threads eligible for cap-based eviction.
    private var finishedOrder: [AgentThreadID] = []
    /// Threads that have had rollbackThread called; exempt from cap eviction.
    private var rolledBackThreadIds: Set<AgentThreadID> = []

    public var provider: AgentProvider { .claude }

    public init(runner: AgentProviderRunner, maxReadableEvents: Int = 5_000, maxSessions: Int = 200) {
        self.runner = runner
        self.maxReadableEvents = max(1, maxReadableEvents)
        self.maxSessions = max(1, maxSessions)
    }

    public func listModels() async -> [AgentModelDescriptor] {
        await runner.listModels()
    }

    public func startSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        try await sendTurn(request, onEvent: onEvent)
    }

    public func sendTurn(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle {
        lock.lock()
        sessions[request.threadId] = AgentProviderSessionSummary(threadId: request.threadId, provider: .claude, status: .running, providerThreadId: request.providerThreadId)
        lock.unlock()

        let handle = try await runner.startRun(request) { [weak self] event in
            self?.record(event: event, threadId: request.threadId)
            onEvent(event)
        }
        lock.lock()
        handles[request.threadId] = handle
        lock.unlock()
        return handle
    }

    public func interruptTurn(threadId: AgentThreadID) throws {
        lock.lock()
        let handle = handles[threadId]
        lock.unlock()
        guard let handle else { throw AgentProviderAdapterError.sessionNotFound(threadId) }
        handle.cancel()
    }

    public func respondToRequest(threadId: AgentThreadID, requestId: String, response: AgentProviderRequestResponse) async throws {
        throw AgentProviderAdapterError.unsupported("Approvals are not available in one-shot CLI mode. Use supervised or streaming mode to approve tool requests.")
    }

    public func respondToUserInput(threadId: AgentThreadID, requestId: String, text: String) throws {
        throw AgentProviderAdapterError.unsupported("User input responses are not available in one-shot CLI mode. Use supervised or streaming mode.")
    }

    public func stopSession(threadId: AgentThreadID) throws {
        try interruptTurn(threadId: threadId)
        lock.lock()
        sessions.removeValue(forKey: threadId)
        handles.removeValue(forKey: threadId)
        finishedOrder.removeAll { $0 == threadId }
        rolledBackThreadIds.remove(threadId)
        lock.unlock()
    }

    public func recoverSession(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws {
        throw AgentProviderAdapterError.unsupported("Claude CLI session recovery requires Claude SDK session support")
    }

    public func listSessions() -> [AgentProviderSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return Array(sessions.values)
    }

    public func hasSession(threadId: AgentThreadID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessions[threadId] != nil
    }

    public func readThread(threadId: AgentThreadID) async throws -> [AssistantEvent] {
        lock.lock(); defer { lock.unlock() }
        guard sessions[threadId] != nil || events[threadId] != nil else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        return events[threadId] ?? []
    }

    public func rollbackThread(threadId: AgentThreadID, toTurnId: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard var stream = events[threadId] else {
            throw AgentProviderAdapterError.sessionNotFound(threadId)
        }
        guard let index = stream.lastIndex(where: { $0.completedTurnId == toTurnId || $0.startedTurnId == toTurnId }) else {
            throw AgentProviderAdapterError.unsupported("The rollback target was not found in the current session history. The session may have been reset or the checkpoint is no longer available.")
        }
        stream = Array(stream.prefix(through: index))
        events[threadId] = stream
        rolledBackThreadIds.insert(threadId)
    }

    public func stopAll() {
        lock.lock()
        let activeHandles = Array(handles.values)
        sessions.removeAll()
        handles.removeAll()
        finishedOrder.removeAll()
        rolledBackThreadIds.removeAll()
        lock.unlock()
        activeHandles.forEach { $0.cancel() }
    }

    public func streamEvents(threadId: AgentThreadID, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) throws {
        throw AgentProviderAdapterError.unsupported("streamEvents")
    }

    private func record(event: AgentRunEvent, threadId: AgentThreadID) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .event(let assistantEvent):
            if shouldAppend(assistantEvent, threadId: threadId) {
                events[threadId, default: []].append(assistantEvent)
                pruneReadableEvents(threadId: threadId)
            }
            if case .threadStarted(_, let providerThreadId) = assistantEvent {
                let current = sessions[threadId]
                sessions[threadId] = AgentProviderSessionSummary(threadId: threadId, provider: .claude, status: current?.status ?? .running, providerThreadId: providerThreadId)
            }
        case .finished(let status, _, let providerThreadId):
            let current = sessions[threadId]
            sessions[threadId] = AgentProviderSessionSummary(threadId: threadId, provider: .claude, status: status, providerThreadId: providerThreadId ?? current?.providerThreadId)
            handles.removeValue(forKey: threadId)
            if !finishedOrder.contains(threadId) {
                finishedOrder.append(threadId)
            }
            pruneSessionsIfNeeded()
        default:
            break
        }
    }

    private func shouldAppend(_ event: AssistantEvent, threadId: AgentThreadID) -> Bool {
        guard case .turnStarted(let turnId) = event else { return true }
        let synthetic = events[threadId]?.last?.startedTurnId
        return synthetic != turnId
    }

    private func pruneReadableEvents(threadId: AgentThreadID) {
        guard let stream = events[threadId], stream.count > maxReadableEvents else { return }
        events[threadId] = Array(stream.suffix(maxReadableEvents))
    }

    /// Called under lock after a thread finishes. Evicts oldest eligible threads when over cap.
    private func pruneSessionsIfNeeded() {
        let toEvict = ClaudeCLIAdapter.pruneEligible(
            finishedOrder: finishedOrder,
            rolledBackThreadIds: rolledBackThreadIds,
            cap: maxSessions
        )
        for threadId in toEvict {
            sessions.removeValue(forKey: threadId)
            events.removeValue(forKey: threadId)
            finishedOrder.removeAll { $0 == threadId }
        }
    }

    /// Pure helper: returns finished thread IDs to evict, oldest first, skipping rollback-reachable threads.
    /// Called under lock; extracted as static so it can be unit-tested without adapter state.
    nonisolated static func pruneEligible(
        finishedOrder: [AgentThreadID],
        rolledBackThreadIds: Set<AgentThreadID>,
        cap: Int
    ) -> [AgentThreadID] {
        let eligible = finishedOrder.filter { !rolledBackThreadIds.contains($0) }
        let excess = finishedOrder.count - cap
        guard excess > 0 else { return [] }
        return Array(eligible.prefix(excess))
    }
}

private extension AssistantEvent {
    var startedTurnId: String? {
        if case .turnStarted(let turnId) = self { return turnId }
        return nil
    }

    var completedTurnId: String? {
        if case .turnCompleted(let turnId, _) = self { return turnId }
        return nil
    }
}
