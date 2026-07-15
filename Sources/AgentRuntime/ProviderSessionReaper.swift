import Foundation
import CoreModel
import Persistence

public struct ProviderSessionReaperResult: Sendable, Equatable {
    public let stoppedThreadIds: [AgentThreadID]
    public let skippedActiveThreadIds: [AgentThreadID]
    public let staledCallbackThreadIds: [AgentThreadID]

    public init(
        stoppedThreadIds: [AgentThreadID],
        skippedActiveThreadIds: [AgentThreadID],
        staledCallbackThreadIds: [AgentThreadID] = []
    ) {
        self.stoppedThreadIds = stoppedThreadIds
        self.skippedActiveThreadIds = skippedActiveThreadIds
        self.staledCallbackThreadIds = staledCallbackThreadIds
    }
}

public final class ProviderSessionReaper {
    private let sessionRepo: ProviderSessionRuntimeRepository
    private let pendingCallbackRepo: ProviderPendingCallbackRepository?
    private let activeThreadIds: @Sendable () -> Set<AgentThreadID>

    public init(
        sessionRepo: ProviderSessionRuntimeRepository,
        pendingCallbackRepo: ProviderPendingCallbackRepository? = nil,
        activeThreadIds: @escaping @Sendable () -> Set<AgentThreadID>
    ) {
        self.sessionRepo = sessionRepo
        self.pendingCallbackRepo = pendingCallbackRepo
        self.activeThreadIds = activeThreadIds
    }

    public func reapIdleSessions(olderThan cutoff: Date) throws -> ProviderSessionReaperResult {
        let active = activeThreadIds()
        let candidates = try sessionRepo.list(status: .completed, updatedBefore: cutoff)
        var stopped: [AgentThreadID] = []
        var skipped: [AgentThreadID] = []
        var staledCallbacks: [AgentThreadID] = []

        for session in candidates {
            if active.contains(session.threadId) {
                skipped.append(session.threadId)
                continue
            }
            try sessionRepo.markStopped(threadId: session.threadId, status: .interrupted)
            if try staleOpenCallbacks(threadId: session.threadId) {
                staledCallbacks.append(session.threadId)
            }
            stopped.append(session.threadId)
        }

        return ProviderSessionReaperResult(
            stoppedThreadIds: stopped,
            skippedActiveThreadIds: skipped,
            staledCallbackThreadIds: staledCallbacks
        )
    }

    private func staleOpenCallbacks(threadId: AgentThreadID) throws -> Bool {
        guard let pendingCallbackRepo else { return false }
        let openCallbacks = try pendingCallbackRepo.listOpen(threadId: threadId)
        guard !openCallbacks.isEmpty else { return false }
        let reason = "Provider session was reaped while this callback was still pending. Restart the turn to continue."
        for callback in openCallbacks {
            try pendingCallbackRepo.markStale(
                threadId: callback.threadId,
                requestId: callback.requestId,
                kind: callback.kind,
                reason: reason
            )
        }
        return true
    }
}
