import Foundation

public enum TokenSaverCircuitBreakerAction: String, Sendable, Equatable {
    case keepEnabled
    case demoteToPassThrough
    case disableLane
    case disableForSession
    case blockModel
    case revertAggressiveRatios
}

public struct TokenSaverCircuitBreakerDecision: Sendable, Equatable {
    public let action: TokenSaverCircuitBreakerAction
    public let reason: String

    public init(action: TokenSaverCircuitBreakerAction, reason: String) {
        self.action = action
        self.reason = reason
    }

    public static let keepEnabled = TokenSaverCircuitBreakerDecision(action: .keepEnabled, reason: "within_threshold")
}

public enum TokenSaverCircuitBreaker {
    public static func toolProfile(
        retrieveCount: Int,
        compressedCount: Int,
        threshold: Double = 0.05
    ) -> TokenSaverCircuitBreakerDecision {
        guard compressedCount > 0 else { return .keepEnabled }
        let rate = Double(max(0, retrieveCount)) / Double(compressedCount)
        return rate > threshold
            ? TokenSaverCircuitBreakerDecision(action: .demoteToPassThrough, reason: "retrieve_rate_above_threshold")
            : .keepEnabled
    }

    public static func netBilledCost(netUnits: Double) -> TokenSaverCircuitBreakerDecision {
        netUnits < 0
            ? TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "negative_net_billed_units")
            : .keepEnabled
    }

    public static func encoderLifecycle(
        consecutiveDeadlineTimeouts: Int,
        evictReloadThrashes: Int,
        deadlineTimeoutLimit: Int = 3,
        thrashLimit: Int = 0
    ) -> TokenSaverCircuitBreakerDecision {
        if consecutiveDeadlineTimeouts >= max(1, deadlineTimeoutLimit) {
            return TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "encoder_deadline_timeout_latch")
        }
        if evictReloadThrashes > max(0, thrashLimit) {
            return TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "encoder_evict_reload_thrash")
        }
        return .keepEnabled
    }

    public static func masking(
        retrieveRoundTrips: Int,
        turnCount: Int,
        retrieveFailures: Int,
        netUnits: Double,
        mcpRetrieveAvailable: Bool
    ) -> TokenSaverCircuitBreakerDecision {
        guard mcpRetrieveAvailable else {
            return TokenSaverCircuitBreakerDecision(action: .disableForSession, reason: "rc_retrieve_unavailable")
        }
        guard retrieveFailures == 0 else {
            return TokenSaverCircuitBreakerDecision(action: .disableForSession, reason: "masked_retrieve_failure")
        }
        if turnCount > 0, Double(retrieveRoundTrips) / Double(turnCount) > 0.2 {
            return TokenSaverCircuitBreakerDecision(action: .disableForSession, reason: "masking_retrieve_rate_above_threshold")
        }
        if netUnits < 0 {
            return TokenSaverCircuitBreakerDecision(action: .disableForSession, reason: "masking_negative_net_billed_units")
        }
        return .keepEnabled
    }

    public static func nliCanary(
        falseAcceptRate: Double,
        maxFalseAcceptRate: Double,
        omissionRecall: Double,
        minOmissionRecall: Double
    ) -> TokenSaverCircuitBreakerDecision {
        if falseAcceptRate > maxFalseAcceptRate {
            return TokenSaverCircuitBreakerDecision(action: .revertAggressiveRatios, reason: "canary_false_accept_rate")
        }
        if omissionRecall < minOmissionRecall {
            return TokenSaverCircuitBreakerDecision(action: .revertAggressiveRatios, reason: "canary_omission_recall")
        }
        return .keepEnabled
    }

    public static func modelArtifact(
        parityCIPassed: Bool,
        outputVariancePassed: Bool,
        licenseMatched: Bool
    ) -> TokenSaverCircuitBreakerDecision {
        guard parityCIPassed else {
            return TokenSaverCircuitBreakerDecision(action: .blockModel, reason: "parity_ci_failed")
        }
        guard outputVariancePassed else {
            return TokenSaverCircuitBreakerDecision(action: .blockModel, reason: "output_variance_failed")
        }
        guard licenseMatched else {
            return TokenSaverCircuitBreakerDecision(action: .blockModel, reason: "license_mismatch")
        }
        return .keepEnabled
    }

    public static func abRegression(
        rerunDelta: Double,
        turnCountDelta: Double,
        maxRerunDelta: Double,
        maxTurnCountDelta: Double
    ) -> TokenSaverCircuitBreakerDecision {
        if rerunDelta > maxRerunDelta {
            return TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "same_command_rerun_delta")
        }
        if turnCountDelta > maxTurnCountDelta {
            return TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "turn_count_delta")
        }
        return .keepEnabled
    }

    public static func latency(p95Milliseconds: Double, budgetMilliseconds: Double) -> TokenSaverCircuitBreakerDecision {
        p95Milliseconds > budgetMilliseconds
            ? TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "p95_latency_budget_exceeded")
            : .keepEnabled
    }

    public static func fixedCorpus(hasCorpus: Bool, regressionCount: Int) -> TokenSaverCircuitBreakerDecision {
        guard hasCorpus else {
            return TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "fixed_corpus_missing")
        }
        return regressionCount > 0
            ? TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "fixed_corpus_regression")
            : .keepEnabled
    }

    public static func flagOffParity(
        byteIdentical: Bool,
        p95Ratio: Double,
        maxP95Ratio: Double = 1.05
    ) -> TokenSaverCircuitBreakerDecision {
        guard byteIdentical else {
            return TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "flag_off_output_changed")
        }
        return p95Ratio > maxP95Ratio
            ? TokenSaverCircuitBreakerDecision(action: .disableLane, reason: "flag_off_p95_regressed")
            : .keepEnabled
    }
}
