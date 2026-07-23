import Foundation

/// Capacity profile, ops freshness, kill switch, rollback policy (task-11).
public enum TokenSaverCapacityOps {
    public static let schemaVersion = 1
    public static let taskID = "task-11"

    public struct CapacityProfile: Sendable, Equatable {
        public let concurrency: Int
        public let maxBytesPerTurn: Int64
        public let maxRSSBytes: Int64
        public let expiresAt: Date
        public let signed: Bool

        public init(concurrency: Int, maxBytesPerTurn: Int64, maxRSSBytes: Int64, expiresAt: Date, signed: Bool) {
            self.concurrency = concurrency
            self.maxBytesPerTurn = maxBytesPerTurn
            self.maxRSSBytes = maxRSSBytes
            self.expiresAt = expiresAt
            self.signed = signed
        }

        public func isValid(now: Date = Date()) -> Bool {
            signed
                && expiresAt > now
                && concurrency > 0
                && maxBytesPerTurn > 0
                && maxRSSBytes > 0
        }
    }

    public enum Admission: Sendable, Equatable {
        case allow
        case offMissingOrExpiredProfile
        case rawBreach
        case rawKillSwitch
    }

    public final class Runtime: @unchecked Sendable {
        private let lock = NSLock()
        private var killSwitchActive = false
        private var generationFence: UInt64 = 0
        /// Monotonic project-delete epoch; late outcomes below this are rejected.
        private var deleteEpoch: UInt64 = 0
        public private(set) var lastProviderTerminated = false
        public private(set) var opsTelemetryFresh = true

        public init() {}

        public func setOpsTelemetryFresh(_ fresh: Bool) {
            lock.lock(); opsTelemetryFresh = fresh; lock.unlock()
        }

        public func evaluate(profile: CapacityProfile?, rss: Int64, bytes: Int64, now: Date = Date()) -> Admission {
            lock.lock()
            let kill = killSwitchActive
            lock.unlock()
            guard let profile, profile.isValid(now: now) else { return .offMissingOrExpiredProfile }
            if kill { return .rawKillSwitch }
            if rss > profile.maxRSSBytes || bytes > profile.maxBytesPerTurn { return .rawBreach }
            return .allow
        }

        public func activateKillSwitch() {
            lock.lock()
            killSwitchActive = true
            generationFence += 1
            lock.unlock()
        }

        public func nextInvocationIsRaw() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return killSwitchActive
        }

        public func currentDeleteEpoch() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return deleteEpoch
        }

        /// Advance delete epoch (project deletion). Irreversible for late outcomes.
        public func advanceDeleteEpoch() {
            lock.lock()
            deleteEpoch += 1
            lock.unlock()
        }

        public func rollback(terminateHealthyProvider: Bool, contractAllows: Bool) {
            // Never terminate healthy provider without explicit contract.
            lastProviderTerminated = terminateHealthyProvider && contractAllows
        }

        public func promotionBlockedByStaleOps() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !opsTelemetryFresh
        }

        /// Late outcome fencing against monotonic delete epoch.
        /// outcomeEpoch must be the epoch observed when the work started.
        public func lateOutcome(outcomeEpoch: UInt64, revocationNormal: Bool) -> String {
            lock.lock()
            let current = deleteEpoch
            lock.unlock()
            if outcomeEpoch < current { return "rejected" }
            if revocationNormal { return "quarantine" }
            return "unknown"
        }
    }
}
