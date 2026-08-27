import Foundation

/// Which attributed-cap component bound the dialect+graphify scale (audit).
/// Stored as TEXT on daily economy rows (`cap_binding`).
public enum TokenSaverAttributedCapBinding: String, Sendable, Equatable {
    case none
    case noProofAllowance = "no_proof_allowance"
    case measuredMultiple = "measured_multiple"
    case usageShare = "usage_share"
}

/// Counterfactual vs a **bare agent** (no RemoteCode: no pipes/dialect, no Graphify,
/// no model-auto, full tool re-reads every turn). Designed for a **daily-replicable
/// credible total**:
///
/// ```
/// totalCredible = measuredPipes
///               + dialect(from observed/calibrated output share)
///               + graphify(only with activity signals)
///               + cacheAmortization(measured × extra turns, uncapped)
///               + orchestration(Auto cheaper-model token-equivalent when active)
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
    /// Token-equivalent of model-auto (cheaper models at same quality) when active.
    public let estimatedOrchestration: Int
    /// Multi-turn cache re-read impact of earlier tool-output savings.
    public let estimatedCacheAmortization: Int
    /// Output-share actually used in the dialect leg (for telemetry/UI).
    public let appliedOutputShare: Double
    /// True when dialect/graphify used calibrated defaults vs live stream shares.
    public let usedCalibratedDefaults: Bool
    /// Pre-cap dialect estimate (evidence; may exceed post-cap dialect).
    public let dialectRawTokens: Int
    /// Pre-cap graphify estimate (evidence).
    public let graphifyRawTokens: Int
    /// Which cap bound the attributed scale (audit).
    public let capBinding: TokenSaverAttributedCapBinding
    /// Billed units used for usage-anchored legs; nil when unknown.
    public let windowUsageBilledUnits: Double?
    /// False when billed units were unknown — usage-anchored allowances refused.
    public let usageAnchoredAvailable: Bool

    public init(
        measuredToolOutput: Int,
        estimatedDialect: Int,
        estimatedGraphify: Int,
        estimatedOrchestration: Int = 0,
        estimatedCacheAmortization: Int = 0,
        appliedOutputShare: Double = 0,
        usedCalibratedDefaults: Bool = true,
        dialectRawTokens: Int = 0,
        graphifyRawTokens: Int = 0,
        capBinding: TokenSaverAttributedCapBinding = .none,
        windowUsageBilledUnits: Double? = nil,
        usageAnchoredAvailable: Bool = false
    ) {
        self.measuredToolOutput = max(0, measuredToolOutput)
        self.estimatedDialect = max(0, estimatedDialect)
        self.estimatedGraphify = max(0, estimatedGraphify)
        self.estimatedOrchestration = max(0, estimatedOrchestration)
        self.estimatedCacheAmortization = max(0, estimatedCacheAmortization)
        self.appliedOutputShare = min(max(appliedOutputShare, 0), 1)
        self.usedCalibratedDefaults = usedCalibratedDefaults
        self.dialectRawTokens = max(0, dialectRawTokens)
        self.graphifyRawTokens = max(0, graphifyRawTokens)
        self.capBinding = capBinding
        self.windowUsageBilledUnits = windowUsageBilledUnits.map { max(0, $0) }
        self.usageAnchoredAvailable = usageAnchoredAvailable
    }

    /// Credible total for headline/chip: measured pipes + dialect + graphify +
    /// multi-turn cache impact + Auto orchestration token-equivalent.
    public var totalCredible: Int {
        TokenSaverBareUserEstimator.saturatingAdd(
            measuredToolOutput,
            estimatedDialect,
            estimatedGraphify,
            estimatedOrchestration,
            estimatedCacheAmortization
        )
    }

    /// Alias for product UI — full bare-user counterfactual stack.
    public var totalEstimatedVsBareUser: Int { totalCredible }

    public var attributedOnly: Int {
        TokenSaverBareUserEstimator.saturatingAdd(
            estimatedDialect,
            estimatedGraphify,
            estimatedOrchestration,
            estimatedCacheAmortization
        )
    }

    public static let empty = TokenSaverBareUserBreakdown(
        measuredToolOutput: 0,
        estimatedDialect: 0,
        estimatedGraphify: 0,
        estimatedOrchestration: 0,
        estimatedCacheAmortization: 0,
        appliedOutputShare: 0,
        usedCalibratedDefaults: true
    )
}

/// Window-aligned usage + optional stream observations for daily replication.
public struct TokenSaverBareUserObservation: Sendable, Equatable {
    /// Provider tokens in the **same** calendar window as measured savings (raw count).
    public let windowProviderTokens: Int
    /// Known **billed** provider units for the same window (cache reads ~0.1×).
    /// WHY: cap legs and dialect output-share base must use billed units, not raw.
    /// nil = unknown — do **not** fall back to raw; usage-anchored legs are unavailable.
    public let windowProviderBilledTokenUnits: Double?
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
    /// Agent turns in the window (for multi-turn cache amortization of tool-output savings).
    /// 0/1 → no amortization credit.
    public let turnCount: Int
    /// Provider `cacheReadInputTokens` in the window when known (raw, not billed units).
    public let cacheReadInputTokens: Int

    public init(
        windowProviderTokens: Int,
        windowProviderBilledTokenUnits: Double? = nil,
        observedOutputTokens: Int? = nil,
        observedInputTokens: Int? = nil,
        observationSampleCount: Int = 0,
        assistantChars: Int = 0,
        graphifySignalCount: Int = 0,
        graphifyAnswerTokens: Int = 0,
        medianExplorationTokens: Int? = nil,
        turnCount: Int = 0,
        cacheReadInputTokens: Int = 0
    ) {
        self.windowProviderTokens = max(0, windowProviderTokens)
        self.windowProviderBilledTokenUnits = windowProviderBilledTokenUnits.map { max(0, $0) }
        self.observedOutputTokens = observedOutputTokens.map { max(0, $0) }
        self.observedInputTokens = observedInputTokens.map { max(0, $0) }
        self.observationSampleCount = max(0, observationSampleCount)
        self.assistantChars = max(0, assistantChars)
        self.graphifySignalCount = max(0, graphifySignalCount)
        self.graphifyAnswerTokens = max(0, graphifyAnswerTokens)
        self.medianExplorationTokens = medianExplorationTokens.map { max(0, $0) }
        self.turnCount = max(0, turnCount)
        self.cacheReadInputTokens = max(0, cacheReadInputTokens)
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

    /// Historical dialect/graphify ceilings. Kept only so older tests can name
    /// the values that Estimated save must no longer apply.
    public static let attributedCapMultipleOfMeasured: Double = 4.0
    public static let attributedCapShareOfUsed: Double = 0.12
    public static let noProofAttributedShareOfUsed: Double = 0.02

    // MARK: - Estimate

    /// Backward-compatible entry: usage-only, calibrated defaults, no live stream.
    /// Billed units are **unknown** here — usage-anchored legs are refused (not raw-token based).
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
                estimatedCacheAmortization: 0,
                appliedOutputShare: 0,
                usedCalibratedDefaults: true,
                dialectRawTokens: 0,
                graphifyRawTokens: 0,
                capBinding: .none,
                windowUsageBilledUnits: observation.windowProviderBilledTokenUnits,
                usageAnchoredAvailable: observation.windowProviderBilledTokenUnits != nil
            )
        }

        // WHY: every usage-derived quantity uses BILLED units. When billed is
        // unknown, refuse raw-token fallback — allowance and share-base become 0.
        // Non-finite / astronomical JSON doubles must degrade, not trap on Int().
        let billedKnown = observation.windowProviderBilledTokenUnits
        let usageAnchoredAvailable = billedKnown != nil
        let usedBilled = billedKnown.map { sanitizedNonNegativeFinite($0) } ?? 0
        let usedBilledInt = clampedInt(from: usedBilled)

        let (share, usedDefault) = resolveOutputShare(observation)
        let outputTokens = resolveOutputTokens(
            usedBilled: usedBilled,
            share: share,
            observation: observation,
            usageAnchoredAvailable: usageAnchoredAvailable
        )

        // dialect_saved = O × (V − 1). With V=2 → save one bare-equivalent of output.
        let dialectRaw = clampedInt(from: Double(outputTokens) * max(0, dialectVerbosityMultiplier - 1))

        let graphifyRaw: Int
        if graphifyActive, observation.graphifySignalCount > 0, usageAnchoredAvailable, usedBilledInt > 0 {
            graphifyRaw = estimateGraphifyRaw(
                signalCount: observation.graphifySignalCount,
                used: usedBilledInt,
                share: share,
                answerTokensSum: observation.graphifyAnswerTokens,
                medianExplorationTokens: observation.medianExplorationTokens
            )
        } else {
            graphifyRaw = 0
        }

        // Auto / model routing: cheaper models at same quality. Token-equivalent is
        // a bounded share of measured pipes (not a pricing join).
        let orchestration = orchestrationActive
            ? estimateOrchestrationTokens(measured: measured)
            : 0

        // Multi-turn: compressed tool results would otherwise re-enter every later
        // turn's context / cache. Credit measured once per extra turn.
        let cacheAmort = estimateCacheAmortizationTokens(
            measured: measured,
            turnCount: observation.turnCount,
            cacheReadInputTokens: observation.cacheReadInputTokens
        )

        return TokenSaverBareUserBreakdown(
            measuredToolOutput: measured,
            estimatedDialect: dialectRaw,
            estimatedGraphify: graphifyRaw,
            estimatedOrchestration: orchestration,
            estimatedCacheAmortization: cacheAmort,
            appliedOutputShare: share,
            usedCalibratedDefaults: usedDefault,
            dialectRawTokens: dialectRaw,
            graphifyRawTokens: graphifyRaw,
            capBinding: .none,
            windowUsageBilledUnits: billedKnown,
            usageAnchoredAvailable: usageAnchoredAvailable
        )
    }

    // MARK: - Cache amortization / Auto

    /// Historical extra-turn ceiling. Estimated save must not apply this.
    public static let cacheAmortizationMaxExtraTurns: Int = 50

    /// Historical day-measured multiple. Production callers must not pass it.
    public static let cacheAmortizationMaxMultipleOfMeasured: Int = 200

    /// Fraction of measured pipes credited as Auto cheaper-model token-equivalent.
    public static let orchestrationShareOfMeasured: Double = 0.25

    /// Multi-turn cache impact of earlier tool-output savings.
    ///
    /// Primary: `measured × max(0, turns − 1)` — each subsequent turn would
    /// re-read the avoided full tool payload. Extra turns are never capped.
    /// Floor from known `cacheReadInputTokens`: when the provider reports large
    /// cache reads and we have measured pipes, credit a billed-weighted slice
    /// (cache reads are ~0.1× uncached in Anthropic-style billing).
    public static func estimateCacheAmortizationTokens(
        measured: Int,
        turnCount: Int,
        cacheReadInputTokens: Int = 0
    ) -> Int {
        let m = max(0, measured)
        guard m > 0 else { return 0 }
        let extraTurns = max(0, turnCount - 1)
        let fromTurns = saturatingMul(m, extraTurns)
        let fromCacheReads = clampedInt(from: Double(max(0, cacheReadInputTokens)) * 0.1)
        return max(fromTurns, fromCacheReads)
    }

    public static func estimateOrchestrationTokens(measured: Int) -> Int {
        let m = max(0, measured)
        guard m > 0 else { return 0 }
        return clampedInt(from: Double(m) * orchestrationShareOfMeasured)
    }

    /// Sum multi-turn cache impact across threads active in a day/week window.
    /// Inputs are **permanent** thread saved/runs for threads with window activity
    /// (see `threadCacheAmortizationInputs`). `runs` is treated as the turn count
    /// for `saved × max(0, runs − 1)` — matching the thread-footer stack.
    public static func sumThreadCacheAmortization(
        savedTokens: Int,
        runs: Int
    ) -> Int {
        let turnCount = max(0, runs)
        return estimateCacheAmortizationTokens(
            measured: savedTokens,
            turnCount: turnCount,
            cacheReadInputTokens: 0
        )
    }

    /// Map compress-event counts to a turn proxy (kept for tests / diagnostics).
    /// Production amort uses raw `runs` as turn count (see sumThreadCacheAmortization).
    public static func weakTurnProxy(fromCompressEventCount runs: Int, hasSavings: Bool) -> Int {
        let r = max(0, runs)
        if r <= 0 { return hasSavings ? 1 : 0 }
        return r
    }

    public static func sumThreadCacheAmortization(
        inputs: [(savedTokens: Int, runs: Int)]
    ) -> Int {
        sumThreadCacheAmortization(inputs: inputs, windowMeasuredTokens: nil)
    }

    /// Sum per-thread amort. `windowMeasuredTokens` is ignored — Estimated save
    /// is never capped against day-measured pipes.
    public static func sumThreadCacheAmortization(
        inputs: [(savedTokens: Int, runs: Int)],
        windowMeasuredTokens: Int?
    ) -> Int {
        _ = windowMeasuredTokens
        var total = 0
        for row in inputs {
            total = saturatingAdd(total, sumThreadCacheAmortization(
                savedTokens: row.savedTokens,
                runs: row.runs
            ))
        }
        return total
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

    /// Known billed units for the window, or nil if any contributing day is unknown.
    /// WHY: fail-closed — never sum partial known days or fall back to raw tokens.
    public static func windowProviderBilledTokenUnits(
        daily: [TokenSaverDayUsage],
        includeDayStartingAtOrAfter earliest: Date?,
        includeDayStartingBefore latestExclusive: Date?,
        calendar: Calendar = .current
    ) -> Double? {
        var total: Double = 0
        for day in daily {
            if let earliest, day.dayStart < calendar.startOfDay(for: earliest) {
                continue
            }
            if let latestExclusive, day.dayStart >= calendar.startOfDay(for: latestExclusive) {
                continue
            }
            guard let billed = day.actualProviderBilledTokenUnits else {
                return nil
            }
            total += max(0, billed)
        }
        return total
    }

    /// Today's known billed units, or nil when today's bucket is unknown.
    /// WHY: estimator usage-anchored legs require known billed — never raw.
    public static func todayProviderBilledTokenUnits(
        daily: [TokenSaverDayUsage],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Double? {
        let start = calendar.startOfDay(for: now)
        var total: Double = 0
        var sawDay = false
        for day in daily where calendar.isDate(day.dayStart, inSameDayAs: start) {
            sawDay = true
            guard let billed = day.actualProviderBilledTokenUnits else {
                return nil
            }
            total += max(0, billed)
        }
        // No day row yet → known empty window (0), not unknown.
        return sawDay ? total : 0
    }

    /// Week known billed units across retained daily buckets, or nil if any day unknown.
    /// WHY: fail-closed — a single historical day without billed must not be raw-filled.
    public static func weekProviderBilledTokenUnits(daily: [TokenSaverDayUsage]) -> Double? {
        var total: Double = 0
        for day in daily {
            guard let billed = day.actualProviderBilledTokenUnits else {
                return nil
            }
            total += max(0, billed)
        }
        return total
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
        usedBilled: Double,
        share: Double,
        observation: TokenSaverBareUserObservation,
        usageAnchoredAvailable: Bool
    ) -> Int {
        // WHY: dialect output-share base is usage-derived → billed only; unknown billed → 0.
        let fromShare: Int
        if usageAnchoredAvailable {
            fromShare = clampedInt(from: usedBilled * share)
        } else {
            fromShare = 0
        }
        let fromAssistant = clampedInt(from: Double(observation.assistantChars) / charsPerToken)
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
    /// Prefer the larger of share-model and measured avoided exploration.
    /// No answer data → share model only (never invent answers).
    /// `used` must be **billed** units (caller responsibility).
    public static func estimateGraphifyRaw(
        signalCount: Int,
        used: Int,
        share: Double,
        answerTokensSum: Int,
        medianExplorationTokens: Int?
    ) -> Int {
        let count = max(0, signalCount)
        guard count > 0, used > 0 else { return 0 }
        let intensity = Double(count) / graphifySignalSoftCap
        let inputTokens = Double(used) * (1.0 - min(max(share, 0), 1))
        let shareModel = clampedInt(from: inputTokens * graphifyInputAvoidanceRate * intensity)

        let median = medianExplorationTokens ?? graphifyDefaultExplorationTokens
        let replacedPerQuery = clampExploration(
            clampedInt(from: Double(median) * graphifyReplacedExplorationFactor)
        )
        let avoided = max(0, count * replacedPerQuery - max(0, answerTokensSum))
        if answerTokensSum > 0 {
            return max(shareModel, avoided)
        }
        return max(shareModel, 0)
    }

    public static func clampExploration(_ tokens: Int) -> Int {
        min(max(tokens, graphifyExplorationMinTokens), graphifyExplorationMaxTokens)
    }

    /// Non-finite → 0; otherwise non-negative finite.
    private static func sanitizedNonNegativeFinite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }

    /// Rounded Double→Int that never traps on NaN/Inf/out-of-range values.
    static func clampedInt(from value: Double) -> Int {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded >= Double(Int.max) { return Int.max }
        if rounded <= Double(Int.min) { return Int.min }
        return Int(rounded)
    }

    /// Non-negative Int addition that saturates at `Int.max` instead of trapping.
    public static func saturatingAdd(_ values: Int...) -> Int {
        var total = 0
        for value in values {
            let v = max(0, value)
            let (sum, overflow) = total.addingReportingOverflow(v)
            if overflow { return Int.max }
            total = sum
        }
        return total
    }

    /// Non-negative Int multiply that saturates at `Int.max`.
    public static func saturatingMul(_ a: Int, _ b: Int) -> Int {
        let x = max(0, a)
        let y = max(0, b)
        let (product, overflow) = x.multipliedReportingOverflow(by: y)
        if overflow { return Int.max }
        return product
    }

    private static func clampShare(_ share: Double) -> Double {
        min(max(share, minOutputShare), maxOutputShare)
    }
}
