import Foundation

/// Fase 0C authority plane (task-06): default-off registry, release gate validator,
/// consent split, presentation receipt schema, revocation epochs.
/// Zero replacement until a BindingID is explicitly allowed after full coverage.
public enum TokenSaverAuthorityPlane {
    public static let schemaVersion = 1
    public static let taskID = "task-06"

    public enum ConsentKind: String, Sendable, Equatable {
        case exactLossless = "exact_lossless"
        case semanticLocalAI = "semantic_local_ai"
    }

    public enum CoverageCellStatus: String, Sendable, Equatable, CaseIterable {
        case present
        case missing
        case stale
        case skipped
        case inconclusive
    }

    public struct PresentationReceipt: Sendable, Equatable {
        public let binding: TokenSaverBindingID
        public let operationID: String
        public let handle: String
        public let recoveryState: String
        public let expiry: Date?

        public init(binding: TokenSaverBindingID, operationID: String, handle: String, recoveryState: String, expiry: Date?) {
            self.binding = binding
            self.operationID = operationID
            self.handle = handle
            self.recoveryState = recoveryState
            self.expiry = expiry
        }

        public var isWellFormed: Bool {
            !operationID.isEmpty && !handle.isEmpty && !recoveryState.isEmpty
        }
    }

    public struct CoverageManifest: Sendable, Equatable {
        /// Required cell IDs for a complete coverage manifest (fail-closed if any absent).
        public static let requiredCellIDs: [String] = [
            "unit_tests",
            "adapter_current",
            "adapter_n_minus_1",
            "presentation_parity",
            "capacity_profile",
            "rollback_drill",
        ]

        public let cells: [String: CoverageCellStatus]

        public init(cells: [String: CoverageCellStatus]) {
            self.cells = cells
        }

        public var hasBlockingCell: Bool {
            for id in Self.requiredCellIDs {
                guard let status = cells[id] else { return true }
                if status != .present { return true }
            }
            // Any extra cell that is not present also blocks.
            return cells.values.contains { $0 != .present }
        }
    }

    public struct ConsentState: Sendable, Equatable {
        public let exactLossless: Bool
        public let semanticLocalAI: Bool
        public let isLegacyPreference: Bool

        public init(exactLossless: Bool, semanticLocalAI: Bool, isLegacyPreference: Bool) {
            self.exactLossless = exactLossless
            // Legacy preference must never enable semantic/BERT/MLX.
            self.semanticLocalAI = isLegacyPreference ? false : semanticLocalAI
            self.isLegacyPreference = isLegacyPreference
        }

        public var allowsSemanticLossy: Bool { semanticLocalAI && !isLegacyPreference }
    }

    public final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var replacementAllowed: [String: Bool] = [:]
        private var revocationEpoch: [String: UInt64] = [:]

        public init() {}

        /// Default-off: unknown BindingID denies replacement.
        public func allowsReplacement(for binding: TokenSaverBindingID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let digest = binding.digestHex
            if let epoch = revocationEpoch[digest], epoch > 0 {
                return false
            }
            return replacementAllowed[digest] ?? false
        }

        public func setReplacementAllowed(_ allowed: Bool, for binding: TokenSaverBindingID) {
            lock.lock()
            defer { lock.unlock() }
            replacementAllowed[binding.digestHex] = allowed
        }

        public func revoke(binding: TokenSaverBindingID) {
            lock.lock()
            defer { lock.unlock() }
            let d = binding.digestHex
            revocationEpoch[d, default: 0] += 1
            replacementAllowed[d] = false
        }

        public func epoch(for binding: TokenSaverBindingID) -> UInt64 {
            lock.lock()
            defer { lock.unlock() }
            return revocationEpoch[binding.digestHex] ?? 0
        }
    }

    public enum ReleaseGateDecision: Sendable, Equatable {
        case allowReplacement
        case denyUnknownBinding
        case denyCoverage
        case denyRevoked
        case denySemanticWithoutConsent
    }

    public static func evaluateRelease(
        binding: TokenSaverBindingID,
        registry: Registry,
        manifest: CoverageManifest,
        consent: ConsentState,
        requiresSemantic: Bool
    ) -> ReleaseGateDecision {
        if registry.epoch(for: binding) > 0 && !registry.allowsReplacement(for: binding) {
            // After revoke, even re-enable requires fresh epoch handling; deny if not allowed.
        }
        if !registry.allowsReplacement(for: binding) {
            // Distinguishing unknown vs revoked: revoked has epoch > 0
            if registry.epoch(for: binding) > 0 { return .denyRevoked }
            return .denyUnknownBinding
        }
        if manifest.hasBlockingCell { return .denyCoverage }
        if requiresSemantic && !consent.allowsSemanticLossy { return .denySemanticWithoutConsent }
        return .allowReplacement
    }

    /// Shadow path: never confirms savings headline.
    public static let shadowHeadlineConfirmedSavings: Int = 0
}
