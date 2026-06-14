import Foundation

public enum TokenSaverModelMigrationAction: String, Codable, Sendable, Equatable {
    case keepInstalled
    case downloadCandidate
    case activateCandidate
    case raiseMemoryThreshold
}

public struct TokenSaverModelMigrationDecision: Codable, Sendable, Equatable {
    public let action: TokenSaverModelMigrationAction
    public let reason: String

    public init(action: TokenSaverModelMigrationAction, reason: String) {
        self.action = action
        self.reason = reason
    }
}

public struct TokenSaverModelPerfEnvelope: Codable, Sendable, Equatable {
    public let warmupPassed: Bool
    public let p95Milliseconds: Double?
    public let p95BudgetMilliseconds: Double
    public let measuredFootprintBytes: UInt64?
    public let memoryBudgetBytes: UInt64

    public init(
        warmupPassed: Bool,
        p95Milliseconds: Double?,
        p95BudgetMilliseconds: Double,
        measuredFootprintBytes: UInt64?,
        memoryBudgetBytes: UInt64
    ) {
        self.warmupPassed = warmupPassed
        self.p95Milliseconds = p95Milliseconds
        self.p95BudgetMilliseconds = max(1, p95BudgetMilliseconds)
        self.measuredFootprintBytes = measuredFootprintBytes
        self.memoryBudgetBytes = memoryBudgetBytes
    }
}

public enum TokenSaverModelMigrationPolicy {
    public static func decision(
        installed: TokenSaverApprovedModel?,
        selected: TokenSaverApprovedModel,
        candidateArtifactAvailable: Bool,
        perf: TokenSaverModelPerfEnvelope?
    ) -> TokenSaverModelMigrationDecision {
        guard installed?.id != selected.id else {
            return TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "selected_model_already_installed")
        }
        guard candidateArtifactAvailable else {
            return TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "candidate_artifact_unavailable")
        }
        guard let perf else {
            return TokenSaverModelMigrationDecision(action: .downloadCandidate, reason: "candidate_needs_warmup_and_perf_measurement")
        }
        guard perf.warmupPassed else {
            return TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "candidate_warmup_failed")
        }
        guard let measuredFootprint = perf.measuredFootprintBytes else {
            return TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "candidate_footprint_unmeasured")
        }
        guard measuredFootprint <= perf.memoryBudgetBytes else {
            return TokenSaverModelMigrationDecision(action: .raiseMemoryThreshold, reason: "candidate_footprint_exceeds_budget")
        }
        guard let p95 = perf.p95Milliseconds, p95.isFinite else {
            return TokenSaverModelMigrationDecision(action: .keepInstalled, reason: "candidate_p95_unmeasured")
        }
        guard p95 <= perf.p95BudgetMilliseconds else {
            return TokenSaverModelMigrationDecision(action: .raiseMemoryThreshold, reason: "candidate_p95_exceeds_budget")
        }
        return TokenSaverModelMigrationDecision(action: .activateCandidate, reason: "candidate_passed_warmup_and_perf")
    }
}
