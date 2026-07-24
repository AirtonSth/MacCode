import Foundation

/// Counterfactual vs a **bare agent** (no RemoteCode: no pipes/dialect, no Graphify,
/// no model-auto). Designed for a **daily-replicable credible total**:
///
/// ```
/// totalCredible = measuredPipes
///               + dialect(from observed/calibrated output share)
///               + graphify(only with activity signals, capped)
/// // model-auto is NOT mixed into the token total (different unit / weak evidence)
/// ```
///
/// Factors below are calibrated from live coding-agent streams on this product
/// (output share ≈ 0.5–0.7% of tokens, not 22%). Labels must say estimate/not billed.
public struct TokenSaverBareUserBreakdown: Sendable, Equatable {
    /// Ledger tool-output (and similar) savings in the same window.
    public let measuredToolOutput: Int
    /// Distill dialect vs more verbose bare answers (output-side only).
    public let estimatedDialect: Int
    /// Graphify query-first vs broader file exploration (capped; needs signals).
    public let estimatedGraphify: Int
    /// Token-equivalent of model-auto — **excluded from totalCredible** (shown only
    /// as a separate diagnostic when non-zero).
    public let estimatedOrchestration: Int
    /// Output-share actually used in the dialect leg (for telemetry/UI).
    public let appliedOutputShare: Double
    /// True when dialect/graphify used calibrated defaults vs live stream shares.
    public let usedCalibratedDefaults: Bool

    public init(
        measuredToolOutput: Int,
        estimatedDialect: Int,
        estimatedGraphify: Int,
        estimatedOrchestration: Int = 0,
        appliedOutputShare: Double = 0,
        usedCalibratedDefaults: Bool = true
    ) {
        self.measuredToolOutput = max(0, measuredToolOutput)
        self.estimatedDialect = max(0, estimatedDialect)
        self.estimatedGraphify = max(0, estimatedGraphify)
        self.estimatedOrchestration = max(0, estimatedOrchestration)
        self.appliedOutputShare = min(max(appliedOutputShare, 0), 1)
        self.usedCalibratedDefaults = usedCalibratedDefaults
    }

    /// Credible total for headline/ring: measured + dialect + graphify only.
    public var totalCredible: Int {
        measuredToolOutput + estimatedDialect + estimatedGraphify
    }

    /// Alias for product UI — bare-user total is the credible stack, not orch.
    public var totalEstimatedVsBareUser: Int { totalCredible }

    public var attributedOnly: Int {
        estimatedDialect + estimatedGraphify
    }

    public static let empty = TokenSaverBareUserBreakdown(
        measuredToolOutput: 0,
        estimatedDialect: 0,
        estimatedGraphify: 0,
        estimatedOrchestration: 0,
        appliedOutputShare: 0,
        usedCalibratedDefaults: true
    )
}

/// Window-aligned usage + optional stream observations for daily replication.
public struct TokenSaverBareUserObservation: Sendable, Equatable {
    /// Provider tokens in the **same** calendar window as measured savings.
    public let windowProviderTokens: Int
    /// Sum of outputTokens from provider stream samples in the window (optional).
    public let observedOutputTokens: Int?
    /// Sum of inputTokens from the same samples (optional).
    public let observedInputTokens: Int?
    /// Number of stream samples contributing to observed in/out (quality gate).
    public let observationSampleCount: Int
    /// Assistant message character count in window (fallback for dialect floor).
    public let assistantChars: Int
    /// Graphify-related activity signals in window (queries/events). 0 = no credit.
    public let graphifySignalCount: Int
    /// Sum of Graphify tool-result tokens in the window (Phase 2 measured leg).
    public let graphifyAnswerTokens: Int
    /// Median tokens of local Read/Grep/Glob exploration samples (Phase 2).
    /// nil → use calibrated exploration fallback (still clamped).
    public let medianExplorationTokens: Int?

    public init(
        windowProviderTokens: Int,
        observedOutputTokens: Int? = nil,
        observedInputTokens: Int? = nil,
        observationSampleCount: Int = 0,
        assistantChars: Int = 0,
        graphifySignalCount: Int = 0,
        graphifyAnswerTokens: Int = 0,
        medianExplorationTokens: Int? = nil
    ) {
        self.windowProviderTokens = max(0, windowProviderTokens)
        self.observedOutputTokens = observedOutputTokens.map { max(0, $0) }
        self.observedInputTokens = observedInputTokens.map { max(0, $0) }
        self.observationSampleCount = max(0, observationSampleCount)
        self.assistantChars = max(0, assistantChars)
        self.graphifySignalCount = max(0, graphifySignalCount)
        self.graphifyAnswerTokens = max(0, graphifyAnswerTokens)
        self.medianExplorationTokens = medianExplorationTokens.map { max(0, $0) }
    }

    public static let empty = TokenSaverBareUserObservation(windowProviderTokens: 0)
}

/// Pure, daily-replicable estimator. Prefer live stream shares when sample count
/// clears the floor; otherwise use product-calibrated defaults from multi-day
/// coding-agent telemetry (out_share median ≈ 0.007).
public enum TokenSaverBareUserEstimator {
    // MARK: - Calibrated defaults (research: 7d RemoteCode coding streams)

    /// Median out/(in+out) from multi-day provider stream samples (~0.5–0.7%).
    public static let calibratedDefaultOutputShare: Double = 0.007

    /// Clamp for live shares so a weird day cannot reinflate dialect to 20%+.
    public static let minOutputShare: Double = 0.003
    public static let maxOutputShare: Double = 0.04

    /// Minimum stream samples before trusting observed share over the default.
    public static let minSamplesForLiveShare: Int = 8

    /// Bare agent ≈ this × dialect answer length. Crível uses 2.0 (not 3.0):
    /// dialect is sparse, but not always 1/3 of a full essay on every turn.
    public static let dialectVerbosityMultiplier: Double = 2.0

    /// Chars→tokens for assistant-message floor (same family as TokenEstimator ~4).
    public static let charsPerToken: Double = 4.0

    /// Graphify: fraction of **input** avoided when query-first is active **and**
    /// the window has graphify signals. Much lower than v1's 18%.
    public static let graphifyInputAvoidanceRate: Double = 0.04

    /// Soft-cap graphify intensity: hits / this → intensity ∈ (0,1].
    public static let graphifySignalSoftCap: Double = 40

    /// Bare-agent reads replaced per Graphify query (documented constant k=2).
    public static let graphifyReplacedExplorationFactor: Double = 2.0

    /// Fallback median exploration tokens when fewer than minSamples exist.
    public static let graphifyDefaultExplorationTokens: Int = 2_000

    /// Clamp band for per-query replaced exploration tokens.
    public static let graphifyExplorationMinTokens: Int = 400
    public static let graphifyExplorationMaxTokens: Int = 8_000

    /// Attributed (dialect+graphify) ≤ max(measured × this, …).
    public static let attributedCapMultipleOfMeasured: Double = 4.0

    /// Attributed ≤ this × window usage (hard ceiling for credibility).
    public static let attributedCapShareOfUsed: Double = 0.12

    // MARK: - Estimate

    /// Backward-compatible entry: usage-only, calibrated defaults, no live stream.
    public static func estimate(
        measuredToolOutputSaved: Int,
        actualProviderTokens: Int,
        tokenSaverEnabled: Bool,
        graphifyActive: Bool,
        orchestrationActive: Bool
    ) -> TokenSaverBareUserBreakdown {
        estimate(
            measuredToolOutputSaved: measuredToolOutputSaved,
            tokenSaverEnabled: tokenSaverEnabled,
            graphifyActive: graphifyActive,
            orchestrationActive: orchestrationActive,
            observation: TokenSaverBareUserObservation(windowProviderTokens: actualProviderTokens)
        )
    }

    /// Preferred entry: same-window observation so every day replays the same rules.
    public static func estimate(
        measuredToolOutputSaved: Int,
        tokenSaverEnabled: Bool,
        graphifyActive: Bool,
        orchestrationActive: Bool,
        observation: TokenSaverBareUserObservation
    ) -> TokenSaverBareUserBreakdown {
        let measured = max(0, measuredToolOutputSaved)
        guard tokenSaverEnabled else {
            return TokenSaverBareUserBreakdown(
                measuredToolOutput: measured,
                estimatedDialect: 0,
                estimatedGraphify: 0,
                estimatedOrchestration: 0,
                appliedOutputShare: 0,
                usedCalibratedDefaults: true
            )
        }

        let used = max(0, observation.windowProviderTokens)
        let (share, usedDefault) = resolveOutputShare(observation)
        let outputTokens = resolveOutputTokens(used: used, share: share, observation: observation)

        // dialect_saved = O × (V − 1). With V=2 → save one bare-equivalent of output.
        let dialectRaw = Int((Double(outputTokens) * max(0, dialectVerbosityMultiplier - 1)).rounded())

        let graphifyRaw: Int
        if graphifyActive, observation.graphifySignalCount > 0, used > 0 {
            graphifyRaw = estimateGraphifyRaw(
                signalCount: observation.graphifySignalCount,
                used: used,
                share: share,
                answerTokensSum: observation.graphifyAnswerTokens,
                medianExplorationTokens: observation.medianExplorationTokens
            )
        } else {
            graphifyRaw = 0
        }

        let (dialect, graphify) = applyAttributedCaps(
            measured: measured,
            used: used,
            dialect: dialectRaw,
            graphify: graphifyRaw
        )

        // Orchestration: keep 0 in credible token total. Field reserved for a future
        // cost chip; do not invent token-equivalent without pricing join.
        _ = orchestrationActive
        let orchestration = 0

        return TokenSaverBareUserBreakdown(
            measuredToolOutput: measured,
            estimatedDialect: dialect,
            estimatedGraphify: graphify,
            estimatedOrchestration: orchestration,
            appliedOutputShare: share,
            usedCalibratedDefaults: usedDefault
        )
    }

    // MARK: - Window helpers (UI)

    /// Sum provider usage from `TokenSaverDayUsage` buckets for Today vs Week.
    /// Prefer this over all-time `snapshot.usedTokens` / session fields.
    public static func windowProviderTokens(
        daily: [TokenSaverDayUsage],
        includeDayStartingAtOrAfter earliest: Date?,
        includeDayStartingBefore latestExclusive: Date?,
        calendar: Calendar = .current
    ) -> Int {
        daily.reduce(0) { partial, day in
            if let earliest, day.dayStart < calendar.startOfDay(for: earliest) {
                return partial
            }
            if let latestExclusive, day.dayStart >= calendar.startOfDay(for: latestExclusive) {
                return partial
            }
            return partial + max(0, day.actualProviderTokens)
        }
    }

    public static func todayProviderTokens(
        daily: [TokenSaverDayUsage],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: now)
        return daily
            .filter { calendar.isDate($0.dayStart, inSameDayAs: start) }
            .reduce(0) { $0 + max(0, $1.actualProviderTokens) }
    }

    public static func weekProviderTokens(daily: [TokenSaverDayUsage]) -> Int {
        daily.reduce(0) { $0 + max(0, $1.actualProviderTokens) }
    }

    // MARK: - Internals

    static func resolveOutputShare(
        _ observation: TokenSaverBareUserObservation
    ) -> (share: Double, usedDefault: Bool) {
        if observation.observationSampleCount >= minSamplesForLiveShare,
           let o = observation.observedOutputTokens,
           let i = observation.observedInputTokens,
           i + o > 0 {
            let raw = Double(o) / Double(i + o)
            return (clampShare(raw), false)
        }
        return (clampShare(calibratedDefaultOutputShare), true)
    }

    static func resolveOutputTokens(
        used: Int,
        share: Double,
        observation: TokenSaverBareUserObservation
    ) -> Int {
        let fromShare = Int((Double(used) * share).rounded())
        let fromAssistant = Int((Double(observation.assistantChars) / charsPerToken).rounded())
        // Prefer max(share-scaled usage, assistant floor) so a quiet stream day
        // with real assistant text still gets some dialect credit.
        return max(0, max(fromShare, fromAssistant))
    }

    /// Share-model ceiling + measured-anchored counterfactual (Phase 2).
    ///
    /// ```
    /// shareModel = input × 0.04 × intensity(count/40)
    /// avoided    = max(0, count × replacedExploration − answerTokensSum)
    /// graphify   = min(shareModel, avoided) when answer sum > 0, else shareModel
    /// ```
    /// Prefer under-count: no answer data → share model only (never invent answers).
    public static func estimateGraphifyRaw(
        signalCount: Int,
        used: Int,
        share: Double,
        answerTokensSum: Int,
        medianExplorationTokens: Int?
    ) -> Int {
        let count = max(0, signalCount)
        guard count > 0, used > 0 else { return 0 }
        let intensity = min(1.0, Double(count) / graphifySignalSoftCap)
        let inputTokens = Double(used) * (1.0 - min(max(share, 0), 1))
        let shareModel = Int((inputTokens * graphifyInputAvoidanceRate * intensity).rounded())
        guard shareModel > 0 else { return 0 }

        let median = medianExplorationTokens ?? graphifyDefaultExplorationTokens
        let replacedPerQuery = clampExploration(
            Int((Double(median) * graphifyReplacedExplorationFactor).rounded())
        )
        let avoided = max(0, count * replacedPerQuery - max(0, answerTokensSum))
        // When we have no measured answers yet, keep share-model only so a day of
        // pending tool_results does not get full exploration credit by accident.
        if answerTokensSum > 0 {
            return min(shareModel, avoided)
        }
        return shareModel
    }

    public static func clampExploration(_ tokens: Int) -> Int {
        min(max(tokens, graphifyExplorationMinTokens), graphifyExplorationMaxTokens)
    }

    static func applyAttributedCaps(
        measured: Int,
        used: Int,
        dialect: Int,
        graphify: Int
    ) -> (dialect: Int, graphify: Int) {
        var d = max(0, dialect)
        var g = max(0, graphify)
        let attributed = d + g
        let capMeasured = Int((Double(measured) * attributedCapMultipleOfMeasured).rounded())
        let capUsed = Int((Double(used) * attributedCapShareOfUsed).rounded())
        // Credible ceiling:
        // - no pipe proof → at most 2% of used (stops 66%×usage fantasy)
        // - with pipes → min(4× measured, 12% of used)
        let tightCap: Int
        if measured == 0 && used == 0 {
            tightCap = 0
        } else if measured == 0 {
            tightCap = min(capUsed, Int((Double(used) * 0.02).rounded()))
        } else if capUsed > 0 {
            tightCap = min(max(capMeasured, measured), capUsed)
        } else {
            tightCap = max(capMeasured, measured)
        }
        if attributed <= tightCap { return (d, g) }
        if attributed == 0 || tightCap == 0 { return (0, 0) }
        let scale = Double(tightCap) / Double(attributed)
        d = Int((Double(d) * scale).rounded())
        g = Int((Double(g) * scale).rounded())
        let drift = (d + g) - tightCap
        if drift > 0 { d = max(0, d - drift) }
        return (d, g)
    }

    private static func clampShare(_ share: Double) -> Double {
        min(max(share, minOutputShare), maxOutputShare)
    }
}
