import Foundation

/// Pure idle-exit policy for the Distill sidecar (plan-final W2).
///
/// `idleTimeoutMS` was accepted on the CLI but never consumed. This policy is
/// the single decision point: after `idleTimeout` without a request, exit cleanly
/// so the host can recreate the process on demand (weights leave RSS).
public enum DistillIdleDecision: String, Sendable, Equatable {
    case stayAlive
    case exitCleanIdle
}

public enum DistillIdlePolicy {
    /// - Parameters:
    ///   - now: evaluation instant
    ///   - lastRequestAt: last accepted request completion (or service start)
    ///   - idleTimeout: configured idle window
    ///   - activeRequestCount: in-flight requests (must be 0 to exit)
    public static func decide(
        now: Date,
        lastRequestAt: Date,
        idleTimeout: TimeInterval,
        activeRequestCount: Int
    ) -> DistillIdleDecision {
        guard activeRequestCount <= 0 else { return .stayAlive }
        let timeout = max(1, idleTimeout)
        if now.timeIntervalSince(lastRequestAt) >= timeout {
            return .exitCleanIdle
        }
        return .stayAlive
    }
}

/// Tracks last-request timestamps for idle evaluation.
public final class DistillIdleTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var lastRequestAt: Date
    public let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval, startedAt: Date = Date()) {
        self.idleTimeout = max(1, idleTimeout)
        self.lastRequestAt = startedAt
    }

    public func noteRequest(at date: Date = Date()) {
        lock.lock()
        lastRequestAt = date
        lock.unlock()
    }

    public func decision(now: Date = Date(), activeRequestCount: Int) -> DistillIdleDecision {
        lock.lock()
        let last = lastRequestAt
        lock.unlock()
        return DistillIdlePolicy.decide(
            now: now,
            lastRequestAt: last,
            idleTimeout: idleTimeout,
            activeRequestCount: activeRequestCount
        )
    }
}
