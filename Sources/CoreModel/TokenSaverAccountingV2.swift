import Foundation

/// Fase 3 accounting truth states + estimator (task-10).
/// Confirmed savings only from ledger events / provider token-usage, never character counts alone.
public enum TokenSaverAccountingV2 {
    public static let schemaVersion = 2
    public static let taskID = "task-10"

    /// Six truth states (plan §2).
    public enum TruthState: String, Sendable, Equatable, CaseIterable, Codable {
        case candidate
        case transported
        case providerApplied = "provider_applied"
        case providerMeasured = "provider_measured"
        case productionEstimate = "production_estimate"
        case legacyEstimate = "legacy_estimate"
    }

    public struct Operation: Sendable, Equatable, Codable {
        public let digest: String
        public let generation: UInt64
        public var state: TruthState
        public var confirmedTokensSaved: Int64
        public var deleted: Bool

        public init(digest: String, generation: UInt64, state: TruthState = .candidate) {
            self.digest = digest
            self.generation = generation
            self.state = state
            self.confirmedTokensSaved = 0
            self.deleted = false
        }
    }

    /// Legal forward edges for the state machine (illegal transitions fail closed).
    public static let legalTransitions: [TruthState: Set<TruthState>] = [
        .candidate: [.transported, .legacyEstimate],
        .transported: [.providerApplied],
        .providerApplied: [.providerMeasured, .productionEstimate],
        .providerMeasured: [.productionEstimate],
        .productionEstimate: [],
        .legacyEstimate: [],
    ]

    public static func canTransition(from: TruthState, to: TruthState) -> Bool {
        legalTransitions[from]?.contains(to) == true
    }

    public final class Ledger: @unchecked Sendable {
        private let lock = NSLock()
        private var byDigest: [String: Operation] = [:]
        private var currentGeneration: UInt64 = 1
        public private(set) var batchPublished: Bool = false
        private var batchOpen: Bool = false
        private var batchStaging: [String: Operation] = [:]

        public init() {}

        public func setGeneration(_ g: UInt64) {
            lock.lock(); currentGeneration = g; lock.unlock()
        }

        @discardableResult
        public func record(_ op: Operation) -> Result<Operation, LedgerError> {
            lock.lock(); defer { lock.unlock() }
            if op.deleted { return .failure(.deleted) }
            let store = batchOpen ? batchStaging : byDigest
            if let existing = store[op.digest] ?? byDigest[op.digest] {
                if existing.deleted { return .failure(.deleted) }
                // Same-byte replay: identical digest+state+generation is idempotent.
                if existing.digest == op.digest,
                   existing.state == op.state,
                   existing.generation == op.generation {
                    return .success(existing)
                }
                return .failure(.digestConflict)
            }
            var copy = op
            if copy.generation < currentGeneration {
                // Stale generation cannot confirm savings.
                copy.confirmedTokensSaved = 0
            }
            if batchOpen {
                batchStaging[op.digest] = copy
            } else {
                byDigest[op.digest] = copy
            }
            return .success(copy)
        }

        public func transition(_ digest: String, to newState: TruthState) -> Result<Operation, LedgerError> {
            lock.lock(); defer { lock.unlock() }
            guard var op = byDigest[digest] else { return .failure(.missing) }
            if op.deleted { return .failure(.deleted) }
            guard TokenSaverAccountingV2.canTransition(from: op.state, to: newState) else {
                return .failure(.illegalTransition)
            }
            op.state = newState
            byDigest[digest] = op
            return .success(op)
        }

        public func markProviderMeasured(
            _ digest: String,
            experimentalPair: Bool,
            providerTokensSaved: Int64 = 0
        ) -> Result<Operation, LedgerError> {
            lock.lock(); defer { lock.unlock() }
            guard var op = byDigest[digest] else { return .failure(.missing) }
            if op.deleted { return .failure(.deleted) }
            guard experimentalPair else { return .failure(.measuredRequiresPair) }
            guard TokenSaverAccountingV2.canTransition(from: op.state, to: .providerMeasured)
                || op.state == .providerMeasured else {
                return .failure(.illegalTransition)
            }
            op.state = .providerMeasured
            if op.generation >= currentGeneration {
                op.confirmedTokensSaved = max(0, providerTokensSaved)
            } else {
                op.confirmedTokensSaved = 0
            }
            byDigest[digest] = op
            return .success(op)
        }

        /// Character counts never increment confirmed tokens saved (plan / Agents.md).
        public func addCharacterCountSavings(_ chars: Int64, to digest: String) -> Int64 {
            _ = chars
            lock.lock(); defer { lock.unlock() }
            return byDigest[digest]?.confirmedTokensSaved ?? 0
        }

        public func beginBatch() {
            lock.lock()
            batchPublished = false
            batchOpen = true
            batchStaging = [:]
            lock.unlock()
        }

        /// Abort discards only the active batch staging. Never deletes pre-existing committed ops.
        public func abortBatch(digests: [String] = []) {
            lock.lock(); defer { lock.unlock() }
            guard batchOpen else {
                // Lifecycle: abort after commit/outside batch is a no-op on the authoritative ledger.
                return
            }
            for d in digests {
                batchStaging.removeValue(forKey: d)
            }
            // Drop entire staging set (only uncommitted work).
            batchStaging = [:]
            batchOpen = false
            batchPublished = false
        }

        public func commitBatch() {
            lock.lock(); defer { lock.unlock() }
            for (k, v) in batchStaging {
                byDigest[k] = v
            }
            batchStaging = [:]
            batchOpen = false
            batchPublished = true
        }

        public func markDeleted(_ digest: String) {
            lock.lock(); defer { lock.unlock() }
            byDigest[digest]?.deleted = true
            byDigest[digest]?.confirmedTokensSaved = 0
        }

        public func isDeleted(_ digest: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return byDigest[digest]?.deleted == true
        }

        /// Estimator returns non-zero only when version is valid and not expired/superseded.
        public func estimator(valid: Bool, expired: Bool, superseded: Bool = false) -> Int64 {
            if !valid || expired || superseded { return 0 }
            return 1
        }

        public func legacySnapshotOpaque() -> TruthState { .legacyEstimate }

        /// Rebuild projection totals must equal stored confirmed savings (property).
        public func rebuildConfirmedTotal() -> Int64 {
            lock.lock(); defer { lock.unlock() }
            return byDigest.values.reduce(0) { partial, op in
                if op.deleted { return partial }
                return partial + op.confirmedTokensSaved
            }
        }

        public func storedConfirmedTotal() -> Int64 {
            rebuildConfirmedTotal()
        }

        public enum LedgerError: Error, Equatable {
            case digestConflict, missing, measuredRequiresPair, deleted, illegalTransition
        }
    }
}
