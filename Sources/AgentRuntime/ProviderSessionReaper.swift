import Foundation
import CoreModel
import Persistence

public struct ProviderSessionReaperResult: Sendable, Equatable {
    public let stoppedThreadIds: [AgentThreadID]
    public let skippedActiveThreadIds: [AgentThreadID]
    public let staledCallbackThreadIds: [AgentThreadID]
    /// Idle threads released only to bring resident sessions back under the cap.
    public let cappedThreadIds: [AgentThreadID]
    /// Released threads whose durable session status must stay as it is: a
    /// failed or cancelled session is not a completed one, and an interrupted
    /// row may be the Continue target of a relaunch.
    public let statusPreservedThreadIds: Set<AgentThreadID>

    public init(
        stoppedThreadIds: [AgentThreadID],
        skippedActiveThreadIds: [AgentThreadID],
        staledCallbackThreadIds: [AgentThreadID] = [],
        cappedThreadIds: [AgentThreadID] = [],
        statusPreservedThreadIds: Set<AgentThreadID> = []
    ) {
        self.stoppedThreadIds = stoppedThreadIds
        self.skippedActiveThreadIds = skippedActiveThreadIds
        self.staledCallbackThreadIds = staledCallbackThreadIds
        self.cappedThreadIds = cappedThreadIds
        self.statusPreservedThreadIds = statusPreservedThreadIds
    }
}

public final class ProviderSessionReaper {
    /// Resident provider sessions kept once their threads go idle. Active
    /// threads count toward it but are never released, so a user running more
    /// agents than this is never refused or interrupted.
    public static let providerRootCap = 8

    private let sessionRepo: ProviderSessionRuntimeRepository
    private let pendingCallbackRepo: ProviderPendingCallbackRepository?
    private let liveSessions: @Sendable () -> [AgentProviderSessionSummary]
    private let providerRootCap: Int
    private let activeThreadIds: @Sendable () -> Set<AgentThreadID>

    public init(
        sessionRepo: ProviderSessionRuntimeRepository,
        pendingCallbackRepo: ProviderPendingCallbackRepository? = nil,
        liveSessions: @escaping @Sendable () -> [AgentProviderSessionSummary] = { [] },
        providerRootCap: Int = ProviderSessionReaper.providerRootCap,
        activeThreadIds: @escaping @Sendable () -> Set<AgentThreadID>
    ) {
        self.sessionRepo = sessionRepo
        self.pendingCallbackRepo = pendingCallbackRepo
        self.liveSessions = liveSessions
        self.providerRootCap = max(0, providerRootCap)
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

        // A run that ends failed, cancelled or interrupted never gets a
        // `completed` row, so the scan above never saw its process. Every
        // resident adapter session decides instead, whatever its row status:
        // idle past the cutoff, or the least recently used beyond the cap.
        // A session whose turn the host ended with a tool call still open is
        // kept: that tool may still be running (a long silent build). It counts
        // toward the cap and becomes releasable once its prompt returns.
        let live = liveSessions()
        var released = Set(stopped)
        var statusPreserved = Set<AgentThreadID>()
        var capped: [AgentThreadID] = []
        var underCap: [(threadId: AgentThreadID, updatedAt: Date)] = []
        let releasable = Set(live.filter {
            !active.contains($0.threadId) && Self.isTerminal($0.status) && !$0.toolsMayStillRun
        }.map(\.threadId)).subtracting(released)
        let lastUsed = releasable.isEmpty ? [:] : try sessionRepo.updatedAt(threadIds: Array(releasable))
        for threadId in releasable.sorted(by: { $0.value.uuidString < $1.value.uuidString }) {
            // An undated session cannot be ranked as idle; it is kept.
            guard let updatedAt = lastUsed[threadId] else { continue }
            guard updatedAt < cutoff else {
                underCap.append((threadId, updatedAt))
                continue
            }
            if try staleOpenCallbacks(threadId: threadId) {
                staledCallbacks.append(threadId)
            }
            stopped.append(threadId)
            released.insert(threadId)
            statusPreserved.insert(threadId)
        }

        var residentCount = Set(live.map(\.threadId)).subtracting(released).count
        let leastRecentlyUsed = underCap.sorted {
            $0.updatedAt == $1.updatedAt
                ? $0.threadId.value.uuidString < $1.threadId.value.uuidString
                : $0.updatedAt < $1.updatedAt
        }
        for candidate in leastRecentlyUsed where residentCount > providerRootCap {
            if try staleOpenCallbacks(threadId: candidate.threadId) {
                staledCallbacks.append(candidate.threadId)
            }
            capped.append(candidate.threadId)
            statusPreserved.insert(candidate.threadId)
            residentCount -= 1
        }

        return ProviderSessionReaperResult(
            stoppedThreadIds: stopped,
            skippedActiveThreadIds: skipped,
            staledCallbackThreadIds: staledCallbacks,
            cappedThreadIds: capped,
            statusPreservedThreadIds: statusPreserved
        )
    }

    /// An adapter session still inside a turn is never released.
    private static func isTerminal(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
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
