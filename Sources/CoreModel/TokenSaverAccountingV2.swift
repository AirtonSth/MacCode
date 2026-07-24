import Foundation

/// Fase 3 accounting truth states + estimator (task-10).
/// Confirmed savings only from ledger events / provider token-usage, never character counts alone.
///
/// **Forgeability invariant:** no *public* CoreModel API accepts raw token scalars and writes
/// `providerMeasured` / confirmed savings. `Ledger.markProviderMeasured` is `internal` (visible
/// only inside CoreModel + `@testable` tests). External modules can read `measuredSnapshot` /
/// mint receipts only after a trusted same-module adapter (future AgentRuntime/Distill wiring)
/// records the measurement.
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
        /// Confirmed savings — only written by `Ledger.markProviderMeasured`, never by callers.
        public private(set) var confirmedTokensSaved: Int64
        /// Binding that owns this measurement. Set only via `markProviderMeasured`.
        public private(set) var bindingDigest: String
        /// Optional evidence digest (e.g. prefetch stdout) bound at measure time.
        public private(set) var evidenceDigest: String
        public var deleted: Bool

        public init(digest: String, generation: UInt64, state: TruthState = .candidate) {
            self.digest = digest
            self.generation = generation
            // Measured state cannot be invented on construct; record() also rejects it.
            precondition(state != .providerMeasured, "providerMeasured only via markProviderMeasured")
            self.state = state
            self.confirmedTokensSaved = 0
            self.bindingDigest = ""
            self.evidenceDigest = ""
            self.deleted = false
        }

        /// Same-file ledger mutation path for measured confirmation.
        fileprivate mutating func applyMeasured(tokens: Int64, binding: String, evidence: String) {
            state = .providerMeasured
            confirmedTokensSaved = max(0, tokens)
            bindingDigest = binding
            evidenceDigest = evidence
        }

        fileprivate mutating func clearSavings() {
            confirmedTokensSaved = 0
            bindingDigest = ""
            evidenceDigest = ""
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
        private var deletedDigests: Set<String> = []
        private var currentGeneration: UInt64 = 1
        private var _batchPublished: Bool = false
        private var batchOpen: Bool = false
        private var batchStaging: [String: Operation] = [:]

        public init() {}

        public var batchPublished: Bool {
            lock.lock(); defer { lock.unlock() }
            return _batchPublished
        }

        @discardableResult
        public func setGeneration(_ g: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard g >= currentGeneration else { return false }
            currentGeneration = g
            return true
        }

        @discardableResult
        public func record(_ op: Operation) -> Result<Operation, LedgerError> {
            lock.lock(); defer { lock.unlock() }
            guard !op.digest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure(.invalidDigest)
            }
            if deletedDigests.contains(op.digest) { return .failure(.deleted) }
            if op.deleted { return .failure(.deleted) }
            // Measured savings cannot be smuggled in via record(); only markProviderMeasured writes them.
            if op.state == .providerMeasured {
                return .failure(.illegalTransition)
            }
            let store = batchOpen ? batchStaging : byDigest
            if let existing = store[op.digest] ?? byDigest[op.digest] {
                if existing.deleted { return .failure(.deleted) }
                // Same-byte replay: identical digest+state+generation is idempotent.
                if existing.digest == op.digest,
                   existing.state == op.state,
                   existing.generation == op.generation,
                   existing.confirmedTokensSaved == 0,
                   existing.bindingDigest.isEmpty {
                    return .success(existing)
                }
                return .failure(.digestConflict)
            }
            var copy = op
            // Strip any residual savings fields (private(set) cleared here).
            copy.clearSavings()
            if batchOpen {
                batchStaging[op.digest] = copy
            } else {
                byDigest[op.digest] = copy
            }
            return .success(copy)
        }

        public func transition(_ digest: String, to newState: TruthState) -> Result<Operation, LedgerError> {
            lock.lock(); defer { lock.unlock() }
            if deletedDigests.contains(digest) { return .failure(.deleted) }
            guard var op = byDigest[digest] else { return .failure(.missing) }
            if op.deleted { return .failure(.deleted) }
            // Measured savings are not a public state hop: only markProviderMeasured (internal)
            // may enter providerMeasured with binding + tokens.
            if newState == .providerMeasured {
                return .failure(.illegalTransition)
            }
            guard TokenSaverAccountingV2.canTransition(from: op.state, to: newState) else {
                return .failure(.illegalTransition)
            }
            op.state = newState
            byDigest[digest] = op
            return .success(op)
        }

        /// Record provider-measured savings. **Not part of the public CoreModel surface** —
        /// `internal` so external modules cannot forge credits from raw scalars.
        /// Production wiring must live in a trusted same-module adapter (or `@testable` tests).
        /// Requires experimental pair, non-empty binding, and a legal applied→measured edge.
        @discardableResult
        internal func markProviderMeasured(
            _ digest: String,
            experimentalPair: Bool,
            providerTokensSaved: Int64 = 0,
            bindingDigest: String,
            evidenceDigest: String = ""
        ) -> Result<Operation, LedgerError> {
            lock.lock(); defer { lock.unlock() }
            if deletedDigests.contains(digest) { return .failure(.deleted) }
            guard var op = byDigest[digest] else { return .failure(.missing) }
            if op.deleted { return .failure(.deleted) }
            guard experimentalPair else { return .failure(.measuredRequiresPair) }
            let binding = bindingDigest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !binding.isEmpty else { return .failure(.missingBinding) }
            let evidence = evidenceDigest.trimmingCharacters(in: .whitespacesAndNewlines)
            let measuredTokens = op.generation >= currentGeneration ? max(0, providerTokensSaved) : 0
            if op.state == .providerMeasured {
                guard op.confirmedTokensSaved == measuredTokens,
                      op.bindingDigest == binding,
                      op.evidenceDigest == evidence else {
                    return .failure(.digestConflict)
                }
                return .success(op)
            }
            guard TokenSaverAccountingV2.canTransition(from: op.state, to: .providerMeasured) else {
                return .failure(.illegalTransition)
            }
            // Stale generation may reach measured for reconciliation, but confirms zero.
            op.applyMeasured(tokens: measuredTokens, binding: binding, evidence: evidence)
            byDigest[digest] = op
            return .success(op)
        }

        /// Character counts never increment confirmed tokens saved (plan / Agents.md).
        public func addCharacterCountSavings(_ chars: Int64, to digest: String) -> Int64 {
            _ = chars
            lock.lock(); defer { lock.unlock() }
            return byDigest[digest]?.confirmedTokensSaved ?? 0
        }

        /// Authoritative measured snapshot for receipt minting.
        /// Nil unless op exists, not deleted, providerMeasured, and binding is non-empty.
        public func measuredSnapshot(for digest: String) -> (tokens: Int64, bindingDigest: String, evidenceDigest: String)? {
            lock.lock(); defer { lock.unlock() }
            guard let op = byDigest[digest],
                  !op.deleted,
                  op.state == .providerMeasured,
                  !op.bindingDigest.isEmpty else {
                return nil
            }
            return (op.confirmedTokensSaved, op.bindingDigest, op.evidenceDigest)
        }

        /// Tokens only (binding available via measuredSnapshot).
        public func measuredConfirmedTokens(for digest: String) -> Int64? {
            measuredSnapshot(for: digest)?.tokens
        }

        @discardableResult
        public func beginBatch() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !batchOpen else { return false }
            _batchPublished = false
            batchOpen = true
            batchStaging = [:]
            return true
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
            _batchPublished = false
        }

        @discardableResult
        public func commitBatch() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard batchOpen else { return false }
            for (k, v) in batchStaging {
                if !deletedDigests.contains(k) {
                    byDigest[k] = v
                }
            }
            batchStaging = [:]
            batchOpen = false
            _batchPublished = true
            return true
        }

        public func markDeleted(_ digest: String) {
            lock.lock(); defer { lock.unlock() }
            let canonical = digest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty else { return }
            deletedDigests.insert(canonical)
            batchStaging.removeValue(forKey: canonical)
            if var op = byDigest[canonical] {
                op.deleted = true
                op.clearSavings()
                byDigest[canonical] = op
            }
        }

        public func isDeleted(_ digest: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return deletedDigests.contains(digest) || byDigest[digest]?.deleted == true
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
                let (sum, overflow) = partial.addingReportingOverflow(op.confirmedTokensSaved)
                return overflow ? .max : sum
            }
        }

        public func storedConfirmedTotal() -> Int64 {
            rebuildConfirmedTotal()
        }

        public enum LedgerError: Error, Equatable {
            case digestConflict, missing, measuredRequiresPair, deleted, illegalTransition, missingBinding
            case invalidDigest
        }
    }
}
