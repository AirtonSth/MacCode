import Foundation
import CoreModel
import CryptoKit

// MARK: - Evidence and claims

public enum TokenSaverEvidenceLevel: String, Codable, Sendable, CaseIterable {
    case providerUsage
    case providerTokenizedPayload
    case diagnosticHeuristic
    case hypothesis
    case unavailable
}

public struct TokenSaverClaimDecision: Sendable, Equatable {
    public let billingClaimAllowed: Bool
    public let technicalTokenClaimAllowed: Bool
    public let defaultPromotionAllowed: Bool
    public let label: String
}

public enum TokenSaverClaimPolicy {
    public static func evaluate(
        _ evidence: TokenSaverEvidenceLevel,
        attributionJoined: Bool = false,
        reconciliationPassed: Bool = false,
        usageSemanticsAvailable: Bool = false
    ) -> TokenSaverClaimDecision {
        switch evidence {
        case .providerUsage:
            guard attributionJoined, reconciliationPassed, usageSemanticsAvailable else {
                return TokenSaverClaimDecision(
                    billingClaimAllowed: false,
                    technicalTokenClaimAllowed: false,
                    defaultPromotionAllowed: false,
                    label: "provider usage is not joined and reconciled billing evidence"
                )
            }
            return TokenSaverClaimDecision(
                billingClaimAllowed: true,
                technicalTokenClaimAllowed: true,
                defaultPromotionAllowed: true,
                label: "provider usage evidence"
            )
        case .providerTokenizedPayload:
            return TokenSaverClaimDecision(
                billingClaimAllowed: false,
                technicalTokenClaimAllowed: true,
                defaultPromotionAllowed: false,
                label: "non-billing provider-tokenized delta"
            )
        case .diagnosticHeuristic:
            return TokenSaverClaimDecision(
                billingClaimAllowed: false,
                technicalTokenClaimAllowed: false,
                defaultPromotionAllowed: false,
                label: "diagnostic estimate; not billing evidence"
            )
        case .hypothesis:
            return TokenSaverClaimDecision(
                billingClaimAllowed: false,
                technicalTokenClaimAllowed: false,
                defaultPromotionAllowed: false,
                label: "unverified hypothesis"
            )
        case .unavailable:
            return TokenSaverClaimDecision(
                billingClaimAllowed: false,
                technicalTokenClaimAllowed: false,
                defaultPromotionAllowed: false,
                label: "provider evidence unavailable"
            )
        }
    }
}

public struct TokenSaverProjectRuntimeSnapshot: Sendable, Equatable {
    public let globallyEnabled: Bool
    public let hasExactProjectScope: Bool
    public let laneState: String?
    public let evidenceLevel: String?
    public let ownerRole: String?
    public let optedOut: Bool
    public let killSwitchActive: Bool
    public let attributionJoined: Bool
    public let reconciliationPassed: Bool
    public let usageSemanticsAvailable: Bool
    public let scorecardID: String?

    public init(
        globallyEnabled: Bool,
        hasExactProjectScope: Bool,
        laneState: String?,
        evidenceLevel: String?,
        ownerRole: String?,
        optedOut: Bool,
        killSwitchActive: Bool,
        attributionJoined: Bool = false,
        reconciliationPassed: Bool = false,
        usageSemanticsAvailable: Bool = false,
        scorecardID: String? = nil
    ) {
        self.globallyEnabled = globallyEnabled
        self.hasExactProjectScope = hasExactProjectScope
        self.laneState = laneState
        self.evidenceLevel = evidenceLevel
        self.ownerRole = ownerRole
        self.optedOut = optedOut
        self.killSwitchActive = killSwitchActive
        self.attributionJoined = attributionJoined
        self.reconciliationPassed = reconciliationPassed
        self.usageSemanticsAvailable = usageSemanticsAvailable
        self.scorecardID = scorecardID
    }
}

public enum TokenSaverProjectRuntimeAdmissionPolicy {
    public static func evaluate(_ snapshot: TokenSaverProjectRuntimeSnapshot) -> TokenSaverAdmissionDecision {
        guard snapshot.globallyEnabled else { return .init(allowed: false, reason: "globally_disabled") }
        guard snapshot.hasExactProjectScope else { return .init(allowed: false, reason: "missing_project_scope") }
        guard !snapshot.optedOut else { return .init(allowed: false, reason: "project_opted_out") }
        guard !snapshot.killSwitchActive else { return .init(allowed: false, reason: "kill_switch_active") }
        guard snapshot.laneState == "promoted" else { return .init(allowed: false, reason: "lane_not_promoted") }
        guard let rawEvidence = snapshot.evidenceLevel,
              let evidence = evidenceLevel(rawEvidence),
              evidence == .providerUsage else {
            return .init(allowed: false, reason: "evidence_not_authoritative")
        }
        let claim = TokenSaverClaimPolicy.evaluate(
            evidence,
            attributionJoined: snapshot.attributionJoined,
            reconciliationPassed: snapshot.reconciliationPassed,
            usageSemanticsAvailable: snapshot.usageSemanticsAvailable
        )
        guard claim.defaultPromotionAllowed else {
            return .init(allowed: false, reason: "promotion_receipt_not_reconciled")
        }
        guard let scorecardID = snapshot.scorecardID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scorecardID.isEmpty else {
            return .init(allowed: false, reason: "promotion_receipt_missing_scorecard")
        }
        guard let owner = snapshot.ownerRole, !owner.isEmpty, !owner.hasPrefix("unassigned:") else {
            return .init(allowed: false, reason: "owner_unassigned")
        }
        return .init(allowed: true, reason: "admitted")
    }

    private static func evidenceLevel(_ rawValue: String) -> TokenSaverEvidenceLevel? {
        if let exact = TokenSaverEvidenceLevel(rawValue: rawValue) { return exact }
        switch rawValue {
        case "provider_usage": return .providerUsage
        case "provider_tokenized_payload": return .providerTokenizedPayload
        case "diagnostic_heuristic": return .diagnosticHeuristic
        default: return nil
        }
    }
}

// MARK: - Global promotion scorecard

public enum TokenSaverLaneClass: String, Codable, Sendable, Equatable {
    case deterministic
    case encoder
    case auxiliaryMLX
    case mlxProviderHotPath
}

public enum TokenSaverPromotionState: String, Codable, Sendable, Equatable {
    case promoted
    case shadowOnly
    case off
}

public struct TokenSaverPromotionDecision: Sendable, Equatable {
    public let state: TokenSaverPromotionState
    public let reasons: [String]
}

public struct TokenSaverPromotionScorecard: Sendable, Equatable {
    public let laneClass: TokenSaverLaneClass
    public let attributionJoinCoverage: Double
    public let reconciliationError: Double
    public let statisticalPower: Double
    public let alpha: Double
    public let pairedTasksPerProviderLane: Int
    public let pairedTasksPerCriticalStratum: Int
    public let criticalFailures: Int
    public let taskSuccessDeltaLower95: Double
    public let retryTurnCorrectionRelativeIncreaseUpper95: Double
    public let p95Milliseconds: Double
    public let addressableInputShare: Double
    public let topRankedAddressableLane: Bool
    public let paybackMonths: Double
    public let recurringSupportShare: Double
    public let ownerAssigned: Bool
    public let exitPlanDefined: Bool
    public let providerVersionKnown: Bool
    public let currentAndPreviousCompatible: Bool

    public init(
        laneClass: TokenSaverLaneClass,
        attributionJoinCoverage: Double,
        reconciliationError: Double,
        statisticalPower: Double,
        alpha: Double,
        pairedTasksPerProviderLane: Int,
        pairedTasksPerCriticalStratum: Int,
        criticalFailures: Int,
        taskSuccessDeltaLower95: Double,
        retryTurnCorrectionRelativeIncreaseUpper95: Double,
        p95Milliseconds: Double,
        addressableInputShare: Double,
        topRankedAddressableLane: Bool,
        paybackMonths: Double,
        recurringSupportShare: Double,
        ownerAssigned: Bool,
        exitPlanDefined: Bool,
        providerVersionKnown: Bool,
        currentAndPreviousCompatible: Bool
    ) {
        self.laneClass = laneClass
        self.attributionJoinCoverage = attributionJoinCoverage
        self.reconciliationError = reconciliationError
        self.statisticalPower = statisticalPower
        self.alpha = alpha
        self.pairedTasksPerProviderLane = pairedTasksPerProviderLane
        self.pairedTasksPerCriticalStratum = pairedTasksPerCriticalStratum
        self.criticalFailures = criticalFailures
        self.taskSuccessDeltaLower95 = taskSuccessDeltaLower95
        self.retryTurnCorrectionRelativeIncreaseUpper95 = retryTurnCorrectionRelativeIncreaseUpper95
        self.p95Milliseconds = p95Milliseconds
        self.addressableInputShare = addressableInputShare
        self.topRankedAddressableLane = topRankedAddressableLane
        self.paybackMonths = paybackMonths
        self.recurringSupportShare = recurringSupportShare
        self.ownerAssigned = ownerAssigned
        self.exitPlanDefined = exitPlanDefined
        self.providerVersionKnown = providerVersionKnown
        self.currentAndPreviousCompatible = currentAndPreviousCompatible
    }

    public static func passingFixture(laneClass: TokenSaverLaneClass) -> TokenSaverPromotionScorecard {
        TokenSaverPromotionScorecard(
            laneClass: laneClass,
            attributionJoinCoverage: 0.995,
            reconciliationError: 0.01,
            statisticalPower: 0.85,
            alpha: 0.05,
            pairedTasksPerProviderLane: 30,
            pairedTasksPerCriticalStratum: 10,
            criticalFailures: 0,
            taskSuccessDeltaLower95: -0.019,
            retryTurnCorrectionRelativeIncreaseUpper95: 0.05,
            p95Milliseconds: min(40, TokenSaverPromotionPolicy.latencyBudget(for: laneClass)),
            addressableInputShare: 0.02,
            topRankedAddressableLane: true,
            paybackMonths: 6,
            recurringSupportShare: 0.10,
            ownerAssigned: true,
            exitPlanDefined: true,
            providerVersionKnown: true,
            currentAndPreviousCompatible: true
        )
    }

    public func replacing(
        power: Double? = nil,
        p95Milliseconds: Double? = nil,
        providerVersionKnown: Bool? = nil
    ) -> TokenSaverPromotionScorecard {
        TokenSaverPromotionScorecard(
            laneClass: laneClass,
            attributionJoinCoverage: attributionJoinCoverage,
            reconciliationError: reconciliationError,
            statisticalPower: power ?? statisticalPower,
            alpha: alpha,
            pairedTasksPerProviderLane: pairedTasksPerProviderLane,
            pairedTasksPerCriticalStratum: pairedTasksPerCriticalStratum,
            criticalFailures: criticalFailures,
            taskSuccessDeltaLower95: taskSuccessDeltaLower95,
            retryTurnCorrectionRelativeIncreaseUpper95: retryTurnCorrectionRelativeIncreaseUpper95,
            p95Milliseconds: p95Milliseconds ?? self.p95Milliseconds,
            addressableInputShare: addressableInputShare,
            topRankedAddressableLane: topRankedAddressableLane,
            paybackMonths: paybackMonths,
            recurringSupportShare: recurringSupportShare,
            ownerAssigned: ownerAssigned,
            exitPlanDefined: exitPlanDefined,
            providerVersionKnown: providerVersionKnown ?? self.providerVersionKnown,
            currentAndPreviousCompatible: currentAndPreviousCompatible
        )
    }
}

public enum TokenSaverPromotionPolicy {
    public static func latencyBudget(for laneClass: TokenSaverLaneClass) -> Double {
        switch laneClass {
        case .deterministic: return 50
        case .encoder: return 300
        case .auxiliaryMLX: return 2_000
        case .mlxProviderHotPath: return 500
        }
    }

    public static func evaluate(_ scorecard: TokenSaverPromotionScorecard) -> TokenSaverPromotionDecision {
        guard scorecard.providerVersionKnown else {
            return TokenSaverPromotionDecision(state: .off, reasons: ["unknown_provider_version"])
        }

        var offReasons: [String] = []
        var shadowReasons: [String] = []

        if !scorecard.currentAndPreviousCompatible { offReasons.append("compatibility_matrix_failed") }
        if !scorecard.ownerAssigned { offReasons.append("owner_unassigned") }
        if !scorecard.exitPlanDefined { offReasons.append("exit_plan_missing") }
        if scorecard.criticalFailures > 0 { offReasons.append("critical_failure") }
        if scorecard.paybackMonths > 6 { offReasons.append("payback_over_six_months") }
        if scorecard.recurringSupportShare > 0.10 { offReasons.append("support_cost_over_10_percent") }
        if scorecard.addressableInputShare < 0.02 && !scorecard.topRankedAddressableLane {
            offReasons.append("addressable_share_below_2_percent")
        }

        if scorecard.attributionJoinCoverage < 0.99 { shadowReasons.append("attribution_join_below_0_99") }
        if scorecard.reconciliationError > 0.02 { shadowReasons.append("reconciliation_error_above_0_02") }
        if scorecard.statisticalPower < 0.80 { shadowReasons.append("power_below_0_80") }
        if scorecard.alpha > 0.05 { shadowReasons.append("alpha_above_0_05") }
        if scorecard.pairedTasksPerProviderLane < 30 { shadowReasons.append("paired_tasks_below_30") }
        if scorecard.pairedTasksPerCriticalStratum < 10 { shadowReasons.append("critical_stratum_below_10") }
        if scorecard.taskSuccessDeltaLower95 <= -0.02 { shadowReasons.append("task_success_lower_bound_failed") }
        if scorecard.retryTurnCorrectionRelativeIncreaseUpper95 > 0.05 { shadowReasons.append("retry_turn_upper_bound_failed") }
        if scorecard.p95Milliseconds > latencyBudget(for: scorecard.laneClass) {
            if scorecard.laneClass == .mlxProviderHotPath {
                offReasons.append("mlx_hot_path_latency_exceeded")
            } else {
                shadowReasons.append("lane_latency_exceeded")
            }
        }

        if !offReasons.isEmpty {
            return TokenSaverPromotionDecision(state: .off, reasons: offReasons + shadowReasons)
        }
        if !shadowReasons.isEmpty {
            return TokenSaverPromotionDecision(state: .shadowOnly, reasons: shadowReasons)
        }
        return TokenSaverPromotionDecision(state: .promoted, reasons: ["scorecard_passed"])
    }
}

// MARK: - Isolated crossover

public enum TokenSaverExperimentTaskClass: String, Codable, Sendable, Equatable {
    case readOnly
    case localResettable
    case externallyMutating
}

public struct TokenSaverCrossoverReceipt: Sendable, Equatable {
    public let taskClass: TokenSaverExperimentTaskClass
    public let baselineStateHash: String
    public let treatmentStateHash: String
    public let resetReceipt: String?
    public let authorizedExternalEffects: Int
    public let observedExternalEffects: Int
    public let shadowCompared: Bool

    public init(
        taskClass: TokenSaverExperimentTaskClass,
        baselineStateHash: String,
        treatmentStateHash: String,
        resetReceipt: String?,
        authorizedExternalEffects: Int,
        observedExternalEffects: Int,
        shadowCompared: Bool
    ) {
        self.taskClass = taskClass
        self.baselineStateHash = baselineStateHash
        self.treatmentStateHash = treatmentStateHash
        self.resetReceipt = resetReceipt
        self.authorizedExternalEffects = max(0, authorizedExternalEffects)
        self.observedExternalEffects = max(0, observedExternalEffects)
        self.shadowCompared = shadowCompared
    }
}

public struct TokenSaverCrossoverDecision: Sendable, Equatable {
    public let eligibleForPromotion: Bool
    public let reasons: [String]
}

public enum TokenSaverCrossoverPolicy {
    public static func evaluate(_ receipt: TokenSaverCrossoverReceipt) -> TokenSaverCrossoverDecision {
        var reasons: [String] = []
        if receipt.observedExternalEffects > receipt.authorizedExternalEffects {
            reasons.append("duplicated_external_effect")
        }
        switch receipt.taskClass {
        case .readOnly:
            if receipt.baselineStateHash != receipt.treatmentStateHash {
                reasons.append("unexplained_state_delta")
            }
        case .localResettable:
            if receipt.resetReceipt?.isEmpty != false {
                reasons.append("reset_receipt_missing")
            }
        case .externallyMutating:
            if !receipt.shadowCompared {
                reasons.append("external_mutation_requires_shadow")
            }
            if receipt.authorizedExternalEffects > 1 {
                reasons.append("multiple_external_effects_not_allowed")
            }
        }
        return TokenSaverCrossoverDecision(eligibleForPromotion: reasons.isEmpty, reasons: reasons)
    }
}

// MARK: - Scope, envelope, outbox, and admission

public struct TokenSaverRecoveryScope: Codable, Sendable, Hashable {
    public let workspaceID: String
    public let projectID: String
    public let threadID: String
    public let provider: String
    public let attemptID: String

    public init(workspaceID: String, projectID: String, threadID: String, provider: String, attemptID: String) {
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.threadID = threadID
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.attemptID = attemptID
    }

    public func authorizes(_ requested: TokenSaverRecoveryScope) -> Bool { self == requested }
}

public enum TokenSaverEnvelopeKind: String, Codable, Sendable, Equatable {
    case toolOutput
    case repeatedBlock
    case rolloverCapsule
    case attachment
}

public enum TokenSaverRecoveryMode: String, Codable, Sendable, Equatable {
    case verbatim
    case scopedCapability
    case providerVisibleFile
}

public struct TokenSaverEnvelope: Codable, Sendable, Equatable {
    public static let currentVersion = 2
    public let version: Int
    public let kind: TokenSaverEnvelopeKind
    public let scope: TokenSaverRecoveryScope
    public let expiresAtMilliseconds: Int64?
    public let attemptID: String
    public let integritySHA256: String
    public let recoveryMode: TokenSaverRecoveryMode
    public let payloadReference: String
}

public enum TokenSaverEnvelopeCompatibility {
    public static func supports(version: Int) -> Bool {
        version == TokenSaverEnvelope.currentVersion || version == TokenSaverEnvelope.currentVersion - 1
    }
}

public enum TokenSaverMarkerCodec {
    private static let escapedPrefix = "⟦⟦literal-rc:"

    public static func escapeLiterals(in text: String) -> String {
        text.replacingOccurrences(of: "[[rc:", with: escapedPrefix)
    }

    public static func unescapeLiterals(in text: String) -> String {
        text.replacingOccurrences(of: escapedPrefix, with: "[[rc:")
    }
}

public enum TokenSaverOutboxState: String, Codable, Sendable, Equatable {
    case prepared
    case delivered
    case acked
}

public enum TokenSaverTransportOutcome: String, Codable, Sendable, Equatable {
    case notSent
    case sentUnknown
    case acked
    case failed
}

public enum TokenSaverOutboxPolicy {
    public static func canTransition(from: TokenSaverOutboxState, to: TokenSaverOutboxState) -> Bool {
        switch (from, to) {
        case (.prepared, .delivered), (.delivered, .acked): return true
        default: return false
        }
    }

    public static func mayReplayMutation(after outcome: TokenSaverTransportOutcome) -> Bool {
        outcome == .notSent || outcome == .failed
    }
}

public struct TokenSaverAdmissionSnapshot: Sendable, Equatable {
    public let objectBytes: Int64
    public let threadBytes: Int64
    public let projectBytes: Int64
    public let globalBytes: Int64
    public let freeDiskBytes: Int64
    public let totalDiskBytes: Int64

    public init(objectBytes: Int64, threadBytes: Int64, projectBytes: Int64, globalBytes: Int64, freeDiskBytes: Int64, totalDiskBytes: Int64) {
        self.objectBytes = objectBytes
        self.threadBytes = threadBytes
        self.projectBytes = projectBytes
        self.globalBytes = globalBytes
        self.freeDiskBytes = freeDiskBytes
        self.totalDiskBytes = totalDiskBytes
    }

    public func replacing(
        objectBytes: Int64? = nil,
        threadBytes: Int64? = nil,
        projectBytes: Int64? = nil,
        globalBytes: Int64? = nil,
        freeDiskBytes: Int64? = nil
    ) -> TokenSaverAdmissionSnapshot {
        TokenSaverAdmissionSnapshot(
            objectBytes: objectBytes ?? self.objectBytes,
            threadBytes: threadBytes ?? self.threadBytes,
            projectBytes: projectBytes ?? self.projectBytes,
            globalBytes: globalBytes ?? self.globalBytes,
            freeDiskBytes: freeDiskBytes ?? self.freeDiskBytes,
            totalDiskBytes: totalDiskBytes
        )
    }
}

public struct TokenSaverAdmissionDecision: Sendable, Equatable {
    public let allowed: Bool
    public let reason: String

    public init(allowed: Bool, reason: String) {
        self.allowed = allowed
        self.reason = reason
    }
}

public enum TokenSaverAdmissionPolicy {
    public static let maxObjectBytes: Int64 = 32 * 1_024 * 1_024
    public static let maxThreadBytes: Int64 = 512 * 1_024 * 1_024
    public static let maxProjectBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let maxGlobalBytes: Int64 = 5 * 1_024 * 1_024 * 1_024
    public static let minimumFreeDiskBytes: Int64 = 5 * 1_024 * 1_024 * 1_024

    public static func evaluate(_ snapshot: TokenSaverAdmissionSnapshot) -> TokenSaverAdmissionDecision {
        if snapshot.objectBytes > maxObjectBytes { return .init(allowed: false, reason: "object_quota") }
        if snapshot.threadBytes > maxThreadBytes { return .init(allowed: false, reason: "thread_quota") }
        if snapshot.projectBytes > maxProjectBytes { return .init(allowed: false, reason: "project_quota") }
        if snapshot.globalBytes > maxGlobalBytes { return .init(allowed: false, reason: "global_quota") }
        let diskFloor = max(minimumFreeDiskBytes, snapshot.totalDiskBytes / 10)
        if snapshot.freeDiskBytes < diskFloor || snapshot.objectBytes > snapshot.freeDiskBytes - diskFloor {
            return .init(allowed: false, reason: "free_disk_floor")
        }
        return .init(allowed: true, reason: "admitted")
    }
}

// MARK: - Safety ABI and compatibility

public enum TokenSaverSafetyABI {
    public static let block = TokenSaverProviderSafetyABI.block

    public static func isRouteEquivalent(effectiveInstruction: String) -> Bool {
        effectiveInstruction.components(separatedBy: block).count - 1 == 1
    }
}

public struct TokenSaverProviderCompatibilityEntry: Sendable, Equatable {
    public let provider: String
    public let current: String
    public let previous: String

    public init(provider: String, current: String, previous: String) {
        self.provider = provider.lowercased()
        self.current = current
        self.previous = previous
    }
}

public struct TokenSaverProviderCompatibilityMatrix: Sendable, Equatable {
    private let entries: [TokenSaverProviderCompatibilityEntry]

    public init(entries: [TokenSaverProviderCompatibilityEntry]) {
        self.entries = entries
    }

    public func supports(provider: String, version: String) -> Bool {
        guard let entry = entries.first(where: { $0.provider == provider.lowercased() }) else { return false }
        return version == entry.current || version == entry.previous
    }
}

// MARK: - Provider-native and exact-repetition gates

public struct TokenSaverProviderNativeDecision: Sendable, Equatable {
    public let state: TokenSaverPromotionState
    public let toolSearchAllowed: Bool
    public let promptCacheOptimizationAllowed: Bool
    public let lowVerbosityCanaryAllowed: Bool
    public let removedCLIFlagsAllowed: Bool
}

public enum TokenSaverProviderNativePolicy {
    public static func evaluate(
        provider: String,
        providerVersionKnown: Bool,
        toolSearchExposedByActiveAdapter: Bool,
        promptCacheBehaviorProven: Bool,
        recoveryProven: Bool
    ) -> TokenSaverProviderNativeDecision {
        guard providerVersionKnown else {
            return .init(
                state: .off,
                toolSearchAllowed: false,
                promptCacheOptimizationAllowed: false,
                lowVerbosityCanaryAllowed: false,
                removedCLIFlagsAllowed: false
            )
        }
        return .init(
            state: .shadowOnly,
            toolSearchAllowed: provider.lowercased() == "codex" && toolSearchExposedByActiveAdapter,
            promptCacheOptimizationAllowed: promptCacheBehaviorProven,
            lowVerbosityCanaryAllowed: recoveryProven,
            removedCLIFlagsAllowed: false
        )
    }
}

public enum TokenSaverFileFingerprintAction: Sendable, Equatable {
    case sendFull
    case unchanged(fingerprint: String)
}

public struct TokenSaverFileFingerprintRegistry: Sendable, Equatable {
    private let protectedRecentCount: Int
    private var fingerprints: [String: String] = [:]
    private var recentKeys: [String] = []

    public init(protectedRecentCount: Int) {
        self.protectedRecentCount = max(0, protectedRecentCount)
    }

    public mutating func register(
        path: String,
        bytes: Data,
        scope: TokenSaverRecoveryScope
    ) -> TokenSaverFileFingerprintAction {
        let key = [scope.workspaceID, scope.projectID, scope.threadID, scope.provider, path]
            .joined(separator: "\u{1f}")
        let fingerprint = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let prior = fingerprints[key]
        let protected = recentKeys.suffix(protectedRecentCount).contains(key)
        fingerprints[key] = fingerprint
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
        return prior == fingerprint && !protected ? .unchanged(fingerprint: fingerprint) : .sendFull
    }
}

public struct TokenSaverLexicalScorecard: Sendable, Equatable {
    public let optedIn: Bool
    public let repeatedReadShare: Double
    public let netTokenReductionPerTask: Double
    public let recallAt5: Double
    public let p95Milliseconds: Double
    public let crossScopeLeaks: Int

    public init(
        optedIn: Bool,
        repeatedReadShare: Double,
        netTokenReductionPerTask: Double,
        recallAt5: Double,
        p95Milliseconds: Double,
        crossScopeLeaks: Int
    ) {
        self.optedIn = optedIn
        self.repeatedReadShare = repeatedReadShare
        self.netTokenReductionPerTask = netTokenReductionPerTask
        self.recallAt5 = recallAt5
        self.p95Milliseconds = p95Milliseconds
        self.crossScopeLeaks = crossScopeLeaks
    }

    public func replacing(optedIn: Bool? = nil, recallAt5: Double? = nil) -> TokenSaverLexicalScorecard {
        .init(
            optedIn: optedIn ?? self.optedIn,
            repeatedReadShare: repeatedReadShare,
            netTokenReductionPerTask: netTokenReductionPerTask,
            recallAt5: recallAt5 ?? self.recallAt5,
            p95Milliseconds: p95Milliseconds,
            crossScopeLeaks: crossScopeLeaks
        )
    }
}

public struct TokenSaverLexicalPromotionDecision: Sendable, Equatable {
    public let promotable: Bool
    public let reasons: [String]
}

public enum TokenSaverLexicalPromotionPolicy {
    public static func evaluate(_ scorecard: TokenSaverLexicalScorecard) -> TokenSaverLexicalPromotionDecision {
        var reasons: [String] = []
        if !scorecard.optedIn { reasons.append("project_opt_in_required") }
        if scorecard.repeatedReadShare < 0.05 { reasons.append("repeated_reads_below_0_05") }
        if scorecard.netTokenReductionPerTask < 0.03 { reasons.append("net_reduction_below_0_03") }
        if scorecard.recallAt5 < 0.95 { reasons.append("recall_at_5_below_0_95") }
        if scorecard.p95Milliseconds > 100 { reasons.append("p95_above_100ms") }
        if scorecard.crossScopeLeaks != 0 { reasons.append("cross_scope_leak") }
        return .init(promotable: reasons.isEmpty, reasons: reasons)
    }
}

public enum TokenSaverEmbeddingPromotionPolicy {
    public static func mayPrototype(
        lexicalGapProven: Bool,
        manifestApproved: Bool,
        noBuildControlPassed: Bool
    ) -> Bool {
        lexicalGapProven && manifestApproved && noBuildControlPassed
    }
}

public struct TokenSaverReadMaskingDecision: Sendable, Equatable {
    public let allowed: Bool
}

public enum TokenSaverReadMaskingPolicy {
    public static func evaluate(
        scopedCapabilityAvailable: Bool,
        criticalFailures: Int,
        recentWorkingSetProtected: Bool,
        breakerActive: Bool
    ) -> TokenSaverReadMaskingDecision {
        .init(allowed: scopedCapabilityAvailable && criticalFailures == 0 && recentWorkingSetProtected && !breakerActive)
    }
}

// MARK: - Long-session controls

public struct TokenSaverCapsuleMessage: Sendable, Equatable {
    public let role: String
    public let text: String

    public init(role: String, text: String) {
        self.role = role
        self.text = text
    }
}

public struct TokenSaverRolloverCapsule: Sendable, Equatable {
    public let parentThreadID: String
    public let childThreadID: String
    public let text: String
}

public enum TokenSaverRolloverCapsuleError: Error, Equatable {
    case byteBudgetTooSmall
}

public enum TokenSaverRolloverCapsuleBuilder {
    public static func build(
        parentThreadID: String,
        childThreadID: String,
        messages: [TokenSaverCapsuleMessage],
        maxBytes: Int
    ) throws -> TokenSaverRolloverCapsule {
        guard maxBytes >= 128 else { throw TokenSaverRolloverCapsuleError.byteBudgetTooSmall }
        let encodedMessages = messages.map {
            "\($0.role.uppercased()): \(TokenSaverMarkerCodec.escapeLiterals(in: $0.text))"
        }
        func render(_ selected: [String]) -> String {
            let omittedCount = encodedMessages.count - selected.count
            let prefix = """
            ROLLOVER_CAPSULE_V1
            PARENT: \(parentThreadID)
            TRUNCATED: \(omittedCount > 0 ? "true" : "false")
            OMITTED_OLDER_MESSAGES: \(omittedCount)
            RECENT_MESSAGES:
            """
            return selected.isEmpty ? prefix : prefix + "\n" + selected.joined(separator: "\n")
        }

        var selected: [String] = []
        for message in encodedMessages.reversed() {
            let candidate = [message] + selected
            guard render(candidate).utf8.count <= maxBytes else { break }
            selected = candidate
        }
        var text = render(selected)
        if selected.isEmpty, let newest = encodedMessages.last {
            let tailMarker = "\nOVERSIZED_NEWEST_MESSAGE_TAIL:\n"
            let base = render([]) + tailMarker
            guard base.utf8.count < maxBytes else { throw TokenSaverRolloverCapsuleError.byteBudgetTooSmall }
            let available = maxBytes - base.utf8.count
            let tail = utf8SafeSuffix(newest, maxBytes: available)
            text = base + tail
        }
        guard text.utf8.count <= maxBytes else { throw TokenSaverRolloverCapsuleError.byteBudgetTooSmall }
        return TokenSaverRolloverCapsule(parentThreadID: parentThreadID, childThreadID: childThreadID, text: text)
    }

    private static func utf8SafeSuffix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var result = ""
        var used = 0
        for character in text.reversed() {
            let value = String(character)
            let bytes = value.utf8.count
            guard used + bytes <= maxBytes else { break }
            result.insert(contentsOf: value, at: result.startIndex)
            used += bytes
        }
        return result
    }
}

public struct TokenSaverSessionLearnRecord: Sendable, Equatable {
    public let id: String
    public let scope: TokenSaverRecoveryScope
    public let text: String

    public init(id: String, scope: TokenSaverRecoveryScope, text: String) {
        self.id = id
        self.scope = scope
        self.text = text
    }
}

public enum TokenSaverSessionLearnSelector {
    public static func select(
        records: [TokenSaverSessionLearnRecord],
        scope: TokenSaverRecoveryScope,
        query: String,
        topK: Int,
        byteBudget: Int
    ) -> [TokenSaverSessionLearnRecord] {
        let queryTerms = terms(query)
        let ranked = records
            .filter { $0.scope.authorizes(scope) }
            .map { record in
                (record, terms(record.text).intersection(queryTerms).count)
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 == $1.1 { return $0.0.id < $1.0.id }
                return $0.1 > $1.1
            }

        var selected: [TokenSaverSessionLearnRecord] = []
        var used = 0
        for (record, _) in ranked.prefix(max(0, topK)) {
            let bytes = record.text.utf8.count
            guard used + bytes <= max(0, byteBudget) else { continue }
            selected.append(record)
            used += bytes
        }
        return selected
    }

    private static func terms(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}

// MARK: - Experimental semantic, effort, and visual lanes

public enum TokenSaverSemanticContentType: String, Codable, Sendable, CaseIterable {
    case prose
    case code
    case diff
    case command
    case exactLiteral
    case stackTrace
    case permissionText
    case destructivePrompt
}

public struct TokenSaverModelManifest: Sendable, Equatable {
    public let revision: String
    public let licenseApproved: Bool
    public let bomApproved: Bool
    public let signatureValid: Bool
    public let checksumValid: Bool
    public let languages: Set<String>
    public let domains: Set<String>

    public var isActivatable: Bool {
        !revision.isEmpty && licenseApproved && bomApproved && signatureValid && checksumValid && !languages.isEmpty && !domains.isEmpty
    }

    public static func approvedFixture() -> TokenSaverModelManifest {
        TokenSaverModelManifest(
            revision: "immutable-revision",
            licenseApproved: true,
            bomApproved: true,
            signatureValid: true,
            checksumValid: true,
            languages: ["en"],
            domains: ["prose"]
        )
    }

    public func replacing(
        licenseApproved: Bool? = nil,
        bomApproved: Bool? = nil,
        signatureValid: Bool? = nil,
        checksumValid: Bool? = nil
    ) -> TokenSaverModelManifest {
        TokenSaverModelManifest(
            revision: revision,
            licenseApproved: licenseApproved ?? self.licenseApproved,
            bomApproved: bomApproved ?? self.bomApproved,
            signatureValid: signatureValid ?? self.signatureValid,
            checksumValid: checksumValid ?? self.checksumValid,
            languages: languages,
            domains: domains
        )
    }
}

public struct TokenSaverSemanticShadowDecision: Sendable, Equatable {
    public let input: String
    public let liveOutput: String
    public let shadowCandidate: String?
    public let reason: String
}

public enum TokenSaverAcceleratorThermalState: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

public struct TokenSaverAcceleratorSnapshot: Sendable, Equatable {
    public let hardwareSupported: Bool
    public let thermalState: TokenSaverAcceleratorThermalState
    public let availableMemoryBytes: Int64
    public let requiredMemoryBytes: Int64

    public init(
        hardwareSupported: Bool,
        thermalState: TokenSaverAcceleratorThermalState,
        availableMemoryBytes: Int64,
        requiredMemoryBytes: Int64
    ) {
        self.hardwareSupported = hardwareSupported
        self.thermalState = thermalState
        self.availableMemoryBytes = max(0, availableMemoryBytes)
        self.requiredMemoryBytes = max(0, requiredMemoryBytes)
    }

    public func replacing(
        thermalState: TokenSaverAcceleratorThermalState? = nil,
        availableMemoryBytes: Int64? = nil
    ) -> TokenSaverAcceleratorSnapshot {
        .init(
            hardwareSupported: hardwareSupported,
            thermalState: thermalState ?? self.thermalState,
            availableMemoryBytes: availableMemoryBytes ?? self.availableMemoryBytes,
            requiredMemoryBytes: requiredMemoryBytes
        )
    }
}

public struct TokenSaverAcceleratorDecision: Sendable, Equatable {
    public let admitted: Bool
    public let reason: String

    public init(admitted: Bool, reason: String) {
        self.admitted = admitted
        self.reason = reason
    }
}

/// One shared lease for every optional local semantic/vision accelerator lane.
public actor TokenSaverAcceleratorScheduler {
    public static let shared = TokenSaverAcceleratorScheduler()
    private var busy = false

    public init() {}

    public func acquire(_ snapshot: TokenSaverAcceleratorSnapshot) -> TokenSaverAcceleratorDecision {
        guard snapshot.hardwareSupported else { return .init(admitted: false, reason: "hardware_unsupported") }
        switch snapshot.thermalState {
        case .serious: return .init(admitted: false, reason: "thermal_serious")
        case .critical: return .init(admitted: false, reason: "thermal_critical")
        case .unknown: return .init(admitted: false, reason: "thermal_unknown")
        case .nominal, .fair: break
        }
        guard snapshot.availableMemoryBytes >= snapshot.requiredMemoryBytes else {
            return .init(admitted: false, reason: "insufficient_memory")
        }
        guard !busy else { return .init(admitted: false, reason: "accelerator_busy") }
        busy = true
        return .init(admitted: true, reason: "admitted")
    }

    public func release() { busy = false }
}

public enum TokenSaverSemanticShadowOrchestrator {
    public static func evaluate(
        input: String,
        candidate: String,
        contentType: TokenSaverSemanticContentType,
        language: String,
        hardwareAvailable: Bool,
        acceleratorDecision: TokenSaverAcceleratorDecision,
        manifest: TokenSaverModelManifest,
        classifierSucceeded: Bool
    ) -> TokenSaverSemanticShadowDecision {
        guard contentType == .prose else {
            return .init(input: input, liveOutput: input, shadowCandidate: nil, reason: "protected_content_type")
        }
        guard hardwareAvailable else {
            return .init(input: input, liveOutput: input, shadowCandidate: nil, reason: "hardware_unavailable")
        }
        guard acceleratorDecision.admitted else {
            return .init(input: input, liveOutput: input, shadowCandidate: nil, reason: acceleratorDecision.reason)
        }
        guard manifest.isActivatable,
              manifest.languages.contains(language.lowercased()),
              manifest.domains.contains("prose") else {
            return .init(input: input, liveOutput: input, shadowCandidate: nil, reason: "manifest_or_allowlist_blocked")
        }
        guard classifierSucceeded else {
            return .init(input: input, liveOutput: input, shadowCandidate: nil, reason: "classifier_failed_open")
        }
        return .init(input: input, liveOutput: input, shadowCandidate: candidate, reason: "shadow_only")
    }
}

public enum TokenSaverAdaptiveTaskClass: String, Codable, Sendable, Equatable {
    case mechanical
    case reasoning
}

public enum TokenSaverAdaptiveEffortAction: String, Codable, Sendable, Equatable {
    case preserveUserOverride
    case shadowSuggestion
    case noChange
}

public struct TokenSaverAdaptiveEffortDecision: Sendable, Equatable {
    public let action: TokenSaverAdaptiveEffortAction
}

public enum TokenSaverAdaptiveEffortPolicy {
    public static func evaluate(
        taskClass: TokenSaverAdaptiveTaskClass,
        confidence: Double,
        persistentUserOverride: String?
    ) -> TokenSaverAdaptiveEffortDecision {
        if persistentUserOverride?.isEmpty == false { return .init(action: .preserveUserOverride) }
        if taskClass == .mechanical && confidence >= 0.95 { return .init(action: .shadowSuggestion) }
        return .init(action: .noChange)
    }
}

public enum TokenSaverImageDedupAction: String, Codable, Sendable, Equatable {
    case sendOriginal
    case deduplicateExact
}

public struct TokenSaverImageDedupRegistry: Sendable, Equatable {
    private var hashesByThread: Set<String> = []

    public init() {}

    public mutating func register(
        hash: String,
        scope: TokenSaverRecoveryScope,
        explicitResend: Bool
    ) -> TokenSaverImageDedupAction {
        let key = [scope.workspaceID, scope.projectID, scope.threadID, scope.provider, hash].joined(separator: "\u{1f}")
        if explicitResend {
            hashesByThread.insert(key)
            return .sendOriginal
        }
        if hashesByThread.contains(key) { return .deduplicateExact }
        hashesByThread.insert(key)
        return .sendOriginal
    }
}

public struct TokenSaverVisualMaterialityDecision: Sendable, Equatable {
    public let eligibleForExperiment: Bool
    public let mayReplaceOriginal: Bool
    public let evidenceLevel: TokenSaverEvidenceLevel
}

public enum TokenSaverVisualMaterialityPolicy {
    public static let minimumShare = 0.05

    public static func evaluate(
        visualProviderTokens: Int,
        totalProviderTokens: Int
    ) -> TokenSaverVisualMaterialityDecision {
        let visual = max(0, visualProviderTokens)
        let total = max(0, totalProviderTokens)
        let eligible = total > 0 && Double(visual) / Double(total) >= minimumShare
        return .init(
            eligibleForExperiment: eligible,
            mayReplaceOriginal: false,
            evidenceLevel: .providerUsage
        )
    }
}
