import Foundation
import CoreModel
import Persistence

public protocol AgentRunObserver: AnyObject {
    func runCoordinator(_ c: AgentRunCoordinator, didReceive event: AssistantEvent, run: AgentRunID)
    func runCoordinator(_ c: AgentRunCoordinator, didFinish runId: AgentRunID, status: AgentRunStatus, finalMessage: String?, providerThreadId: String?)
    func runCoordinator(_ c: AgentRunCoordinator, didChangeStatus status: AgentRunStatus, runId: AgentRunID)
}

public final class AgentRunCoordinator: @unchecked Sendable {
    private let runRepo: AgentRunRepository
    private let messageRepo: AgentMessageRepository
    private let threadRepo: AgentThreadRepository
    private var providers: [AgentProvider: AgentProviderRunner]
    private var active: [AgentRunID: AgentRunHandle] = [:]
    private var seq: [AgentRunID: Int] = [:]
    private let lock = NSLock()
    public weak var observer: AgentRunObserver?

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

        let runId = request.runId
        let coordinator = self
        let handle = try await runner.startRun(request) { ev in
            coordinator.handle(event: ev, runId: runId, threadId: request.threadId)
        }
        lock.lock()
        active[runId] = handle
        seq[runId] = 0
        lock.unlock()
        return runId
    }

    public func stopRun(_ runId: AgentRunID) {
        lock.lock()
        let h = active[runId]
        lock.unlock()
        h?.cancel()
    }

    private func persistAssistantIfMissing(_ text: String, threadId: AgentThreadID) {
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
            observer?.runCoordinator(self, didReceive: ev, run: runId)
        case .status(let st):
            observer?.runCoordinator(self, didChangeStatus: st, runId: runId)
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
            seq.removeValue(forKey: runId)
            lock.unlock()
            observer?.runCoordinator(self, didFinish: runId, status: status, finalMessage: finalMessage, providerThreadId: providerThreadId)
        case .error(let m):
            observer?.runCoordinator(self, didReceive: .error(message: m, recoverable: false), run: runId)
        }
    }
}
