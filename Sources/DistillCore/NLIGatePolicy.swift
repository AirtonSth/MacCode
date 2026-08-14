import Foundation

/// I8.6 / I8.7 / I8.8 / I8.9: the gating policy around the (optional) NLI faithfulness
/// lane. Aggressive compression ratios are DECOUPLED from the NLI model — they are
/// permitted only when seeded-corruption canaries are healthy AND a real NLI lane is
/// proven healthy. With no NLI lane (the shipped default), everything stays conservative.
/// All thresholds reject-toward-conservative.
public enum NLIGatePolicy {
    public struct RatioFloor: Sendable, Equatable {
        public let maxRatio: Double   // e.g. 2.5 conservative, 4.0 aggressive
        public let floorChars: Int    // e.g. 2000 conservative, 800 aggressive
        public let aggressive: Bool
    }

    public static let conservative = RatioFloor(maxRatio: 2.5, floorChars: 2000, aggressive: false)
    public static let aggressive = RatioFloor(maxRatio: 4.0, floorChars: 800, aggressive: true)

    /// I8.6 + I8.9: aggressive only when canaries pass AND the NLI lane is healthy AND the
    /// prompt is OUTSIDE the sensitive 800–2000 char band (which stays conservative until
    /// canaries prove it). Any unhealthy signal auto-reverts to conservative.
    public static func ratioAndFloor(
        canaryHealthy: Bool,
        nliLaneHealthy: Bool,
        promptChars: Int,
        netBilledNonNegative: Bool = true
    ) -> RatioFloor {
        guard canaryHealthy, nliLaneHealthy, netBilledNonNegative else { return conservative }
        // The 800–2000 char prompt class stays conservative (constraint-pinning) until proven.
        if promptChars >= 800, promptChars <= 2000 { return conservative }
        return aggressive
    }

    /// I8.7: OOD eval on compressed semantic outputs. Go only if the gate's
    /// discrimination AUC clears the bar on the OOD set; else no-go (stay deterministic).
    public static func oodEvalGoNoGo(auc: Double, minimumAUC: Double = 0.85) -> Bool {
        auc.isFinite && auc >= minimumAUC
    }

    /// I8.8: hysteresis — once flipped to conservative on a bad p95, require a clearly
    /// better p95 (with margin) before returning to aggressive, to avoid thrash.
    public static func allowsAggressiveLatency(
        p95Millis: Double,
        budgetMillis: Double,
        currentlyAggressive: Bool,
        hysteresisMargin: Double = 0.2
    ) -> Bool {
        if currentlyAggressive { return p95Millis <= budgetMillis }
        return p95Millis <= budgetMillis * (1.0 - hysteresisMargin)
    }
}
