import XCTest
@testable import AgentRuntime

final class TokenSaverBareUserEstimatorTests: XCTestCase {
    func test_disabledTokenSaver_onlyMeasuredSurvives() {
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 50_000,
            actualProviderTokens: 10_000_000,
            tokenSaverEnabled: false,
            graphifyActive: true,
            orchestrationActive: true
        )
        XCTAssertEqual(b.measuredToolOutput, 50_000)
        XCTAssertEqual(b.estimatedDialect, 0)
        XCTAssertEqual(b.estimatedGraphify, 0)
        XCTAssertEqual(b.totalCredible, 50_000)
    }

    func test_calibratedDialect_usesSmallOutputShareNotTwentyTwoPercent() {
        // WHY: live coding streams show ~0.7% output share; v1's 22% invented ~56M dialect.
        let used = 100_000_000
        let measured = 200_000
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: true,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: used,
                windowProviderBilledTokenUnits: Double(used)
            )
        )
        // O ≈ 100M * 0.007 = 700k; dialect V=2 → ~700k before caps
        XCTAssertLessThan(b.estimatedDialect, 2_000_000, "dialect must stay on output scale, not 44% of used")
        XCTAssertGreaterThan(b.estimatedDialect, 100_000)
        // Auto active → orchestration = 25% of measured enters totalCredible
        XCTAssertEqual(b.estimatedOrchestration, measured / 4)
        XCTAssertEqual(
            b.totalCredible,
            measured + b.estimatedDialect + b.estimatedGraphify
                + b.estimatedOrchestration + b.estimatedCacheAmortization
        )
    }

    func test_cacheAmortization_scalesWithTurnsAndCaps() {
        // WHY: multi-turn re-read of compressed tool output must raise the figure.
        let measured = 5_000
        let none = TokenSaverBareUserEstimator.estimateCacheAmortizationTokens(
            measured: measured, turnCount: 1
        )
        XCTAssertEqual(none, 0)
        let multi = TokenSaverBareUserEstimator.estimateCacheAmortizationTokens(
            measured: measured, turnCount: 77
        )
        XCTAssertEqual(multi, measured * TokenSaverBareUserEstimator.cacheAmortizationMaxExtraTurns)
        let fromCache = TokenSaverBareUserEstimator.estimateCacheAmortizationTokens(
            measured: measured, turnCount: 0, cacheReadInputTokens: 1_000_000
        )
        // 0.1 × 1M = 100k, capped at measured × 50 = 250k → 100k
        XCTAssertEqual(fromCache, 100_000)
    }

    func test_orchestration_shareOfMeasuredWhenActive() {
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 8_000,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: true,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 50_000,
                windowProviderBilledTokenUnits: 50_000
            )
        )
        XCTAssertEqual(b.estimatedOrchestration, 2_000)
        XCTAssertGreaterThanOrEqual(b.totalCredible, 8_000 + 2_000)
    }

    func test_graphifyRequiresSignals() {
        let noHit = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 100_000,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 50_000_000,
                windowProviderBilledTokenUnits: 50_000_000,
                graphifySignalCount: 0
            )
        )
        XCTAssertEqual(noHit.estimatedGraphify, 0)

        let withHits = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 100_000,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 50_000_000,
                windowProviderBilledTokenUnits: 50_000_000,
                graphifySignalCount: 40
            )
        )
        XCTAssertGreaterThan(withHits.estimatedGraphify, 0)
        XCTAssertLessThan(withHits.estimatedGraphify, 5_000_000, "graphify must not be 18% of all input")
    }

    func test_graphifyPhase2_minOfShareAndMeasuredAvoided() {
        // WHY: when answer sizes are known, counterfactual must not exceed share-model
        // and must use measured avoided exploration — never preference-on alone.
        let used = 10_000_000
        let share = TokenSaverBareUserEstimator.calibratedDefaultOutputShare
        let shareOnly = TokenSaverBareUserEstimator.estimateGraphifyRaw(
            signalCount: 10,
            used: used,
            share: share,
            answerTokensSum: 0,
            medianExplorationTokens: 2_000
        )
        XCTAssertGreaterThan(shareOnly, 0)

        // Huge answers → avoided near 0 → min pulls graphify down.
        let hugeAnswers = TokenSaverBareUserEstimator.estimateGraphifyRaw(
            signalCount: 10,
            used: used,
            share: share,
            answerTokensSum: 10 * 50_000,
            medianExplorationTokens: 2_000
        )
        XCTAssertLessThanOrEqual(hugeAnswers, shareOnly)
        XCTAssertEqual(hugeAnswers, 0, "if answers ≥ replaced exploration, no graphify credit")

        let modest = TokenSaverBareUserEstimator.estimateGraphifyRaw(
            signalCount: 10,
            used: used,
            share: share,
            answerTokensSum: 500,
            medianExplorationTokens: 2_000
        )
        XCTAssertGreaterThan(modest, 0)
        XCTAssertLessThanOrEqual(modest, shareOnly)
    }

    func test_zeroMeasured_limitsAttributedFantasy() {
        // WHY: empty pipe day must not report tens of millions of "savings".
        let used = 100_000_000
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 0,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: true,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: used,
                windowProviderBilledTokenUnits: Double(used)
            )
        )
        XCTAssertLessThanOrEqual(b.totalCredible, 2_000_000 + 1) // ≤2% of used
    }

    func test_liveSharePreferredWhenEnoughSamples() {
        let obs = TokenSaverBareUserObservation(
            windowProviderTokens: 10_000_000,
            windowProviderBilledTokenUnits: 10_000_000,
            observedOutputTokens: 100_000,
            observedInputTokens: 9_900_000,
            observationSampleCount: 20,
            assistantChars: 0,
            graphifySignalCount: 0
        )
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 50_000,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: false,
            observation: obs
        )
        XCTAssertFalse(b.usedCalibratedDefaults)
        XCTAssertEqual(b.appliedOutputShare, 0.01, accuracy: 0.000_1)
    }

    func test_todayProviderTokens_filtersCalendarDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 24, hour: 12).date)
        let yesterday = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 23, hour: 12).date)
        let daily = [
            TokenSaverDayUsage(dayStart: cal.startOfDay(for: yesterday), actualProviderTokens: 1_000),
            TokenSaverDayUsage(dayStart: cal.startOfDay(for: today), actualProviderTokens: 5_000)
        ]
        XCTAssertEqual(TokenSaverBareUserEstimator.todayProviderTokens(daily: daily, now: today, calendar: cal), 5_000)
        XCTAssertEqual(TokenSaverBareUserEstimator.weekProviderTokens(daily: daily), 6_000)
    }

    func test_todayProviderBilledTokenUnits_knownDayReportsKnownWindow() throws {
        // WHY: known billed deltas must surface as a known window denominator so
        // usage-anchored legs are available (fail-open only when billed is known).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 24, hour: 12).date)
        let yesterday = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 23, hour: 12).date)
        let daily = [
            TokenSaverDayUsage(
                dayStart: cal.startOfDay(for: yesterday),
                actualProviderTokens: 8_000,
                actualProviderBilledTokenUnits: 1_000
            ),
            TokenSaverDayUsage(
                dayStart: cal.startOfDay(for: today),
                actualProviderTokens: 40_000,
                actualProviderBilledTokenUnits: 5_000
            )
        ]
        XCTAssertEqual(
            TokenSaverBareUserEstimator.todayProviderBilledTokenUnits(daily: daily, now: today, calendar: cal) ?? -1,
            5_000,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TokenSaverBareUserEstimator.weekProviderBilledTokenUnits(daily: daily) ?? -1,
            6_000,
            accuracy: 0.001
        )
    }

    func test_unknownDayBilled_windowNil_andEstimatorZerosUsageAnchored() throws {
        // WHY: any unknown day contribution → window billed nil → zero usage-anchored
        // allowance. Never fall back to raw tokens (~8× overstatement).
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 24, hour: 12).date)
        let daily = [
            TokenSaverDayUsage(
                dayStart: cal.startOfDay(for: today),
                actualProviderTokens: 78_658_351,
                actualProviderBilledTokenUnits: nil
            )
        ]
        XCTAssertNil(
            TokenSaverBareUserEstimator.todayProviderBilledTokenUnits(daily: daily, now: today, calendar: cal)
        )
        XCTAssertNil(TokenSaverBareUserEstimator.weekProviderBilledTokenUnits(daily: daily))

        let windowBilled = TokenSaverBareUserEstimator.todayProviderBilledTokenUnits(
            daily: daily,
            now: today,
            calendar: cal
        )
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 0,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 78_658_351,
                windowProviderBilledTokenUnits: windowBilled,
                graphifySignalCount: 40
            )
        )
        XCTAssertFalse(b.usageAnchoredAvailable)
        XCTAssertEqual(b.estimatedDialect, 0)
        XCTAssertEqual(b.estimatedGraphify, 0)
        XCTAssertEqual(b.totalCredible, 0)
    }

    func test_mixedKnownUnknownDay_weekBilledIsNil() throws {
        // WHY: fail-closed — one historical day without billed poisons the week sum.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let today = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 24, hour: 12).date)
        let yesterday = try XCTUnwrap(DateComponents(calendar: cal, timeZone: cal.timeZone, year: 2026, month: 7, day: 23, hour: 12).date)
        let daily = [
            TokenSaverDayUsage(
                dayStart: cal.startOfDay(for: yesterday),
                actualProviderTokens: 8_000,
                actualProviderBilledTokenUnits: nil
            ),
            TokenSaverDayUsage(
                dayStart: cal.startOfDay(for: today),
                actualProviderTokens: 40_000,
                actualProviderBilledTokenUnits: 5_000
            )
        ]
        XCTAssertEqual(
            TokenSaverBareUserEstimator.todayProviderBilledTokenUnits(daily: daily, now: today, calendar: cal) ?? -1,
            5_000,
            accuracy: 0.001,
            "today alone stays known when only today has billed"
        )
        XCTAssertNil(
            TokenSaverBareUserEstimator.weekProviderBilledTokenUnits(daily: daily),
            "week must be nil when any contributing day is unknown"
        )
    }

    // MARK: - v4: monotonicity, billed denominator, displacement

    func test_totalCredible_isMonotoneNonDecreasingInMeasured() {
        // WHY (must fail on pre-change / v3 code): with fixed usage, measured=0 kept a
        // 2% no-proof allowance (~1.57M for this fixture) while measured=2 dropped the
        // floor and scaled dialect to ~8, collapsing totalCredible ~55,061×. Recording
        // real pipe tokens must never shrink the reported total.
        let usedBilled = 78_658_351.0
        let measuredValues = [0, 1, 2, 10, 1_000, 100_000, 550_608]
        var previous = -1
        for measured in measuredValues {
            let b = TokenSaverBareUserEstimator.estimate(
                measuredToolOutputSaved: measured,
                tokenSaverEnabled: true,
                graphifyActive: false,
                orchestrationActive: false,
                observation: TokenSaverBareUserObservation(
                    windowProviderTokens: Int(usedBilled),
                    windowProviderBilledTokenUnits: usedBilled
                )
            )
            XCTAssertGreaterThanOrEqual(
                b.totalCredible,
                previous,
                "totalCredible must be non-decreasing in measured; broke at measured=\(measured) (prev=\(previous), now=\(b.totalCredible))"
            )
            previous = b.totalCredible
        }
    }

    func test_unknownBilledUnits_refusesUsageAnchoredAllowance() {
        // WHY: raw cache-weighted tokens re-inflate the denominator (~8× on Claude live
        // data). When billed is unknown, usage-anchored legs must be unavailable — not
        // silently computed from raw windowProviderTokens.
        let raw = 78_658_351
        let unknown = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 0,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: raw,
                windowProviderBilledTokenUnits: nil,
                graphifySignalCount: 40
            )
        )
        XCTAssertFalse(unknown.usageAnchoredAvailable)
        XCTAssertEqual(unknown.estimatedDialect, 0, "no billed → no usage-share dialect base")
        XCTAssertEqual(unknown.estimatedGraphify, 0, "no billed → no graphify share model")
        XCTAssertEqual(unknown.totalCredible, 0)

        let known = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 0,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: raw,
                windowProviderBilledTokenUnits: Double(raw)
            )
        )
        XCTAssertTrue(known.usageAnchoredAvailable)
        XCTAssertGreaterThan(known.estimatedDialect, 0, "known billed restores no-proof dialect allowance")
    }

    func test_displacementBound_reducesEstimatesByAtMostOnePerMeasured() {
        // WHY: estimated legs may drop when measured rises, but never by more than 1:1.
        let usedBilled = 10_000_000.0
        let base = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 0,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: Int(usedBilled),
                windowProviderBilledTokenUnits: usedBilled
            )
        )
        let withMeasured = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 50,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: Int(usedBilled),
                windowProviderBilledTokenUnits: usedBilled
            )
        )
        let rawAttributed = base.dialectRawTokens + base.graphifyRawTokens
        let finalAttributed = withMeasured.estimatedDialect + withMeasured.estimatedGraphify
        let reduction = max(0, rawAttributed - finalAttributed)
        XCTAssertLessThanOrEqual(reduction, 50, "displacement: ≤1 estimated token per measured token")
    }

    func test_usageStore_knownBilledDistinguishesDefaultedFromExplicit() {
        // WHY: actualProviderBilledTokenUnits defaults missing values to raw; estimator
        // callers must use knownActualProviderBilledTokenUnits / store accessor instead.
        let defaulted = TokenSaverProviderUsage(
            provider: .claude,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 1_200
        )
        XCTAssertNil(defaulted.knownActualProviderBilledTokenUnits)
        XCTAssertEqual(defaulted.actualProviderBilledTokenUnits, 1_000, accuracy: 0.001)

        let explicit = TokenSaverProviderUsage(
            provider: .claude,
            actualProviderTokens: 1_000,
            estimatedRawTokens: 1_200,
            actualProviderBilledTokenUnits: 250
        )
        XCTAssertEqual(explicit.knownActualProviderBilledTokenUnits ?? -1, 250, accuracy: 0.001)
    }

    // MARK: - Displacement floor + safe Double→Int

    func test_displacementFloor_neverExceedsNoProofOrUsageCeiling() {
        // WHY (must fail on pre-fix code): displacement used uncapped raw estimate, so
        // measured>=1 set effectiveCap ≈ attributed − m and bypassed credibility ceilings.
        // Granted attributed must stay ≤ capUsed and ≤ max(no-proof, min(4×m, capUsed)).
        let usedBilled = 1_000_000.0
        let measured = 1
        let capUsed = Int((usedBilled * TokenSaverBareUserEstimator.attributedCapShareOfUsed).rounded())
        let noProof = Int((usedBilled * TokenSaverBareUserEstimator.noProofAttributedShareOfUsed).rounded())
        let measuredBound = max(Int((Double(measured) * TokenSaverBareUserEstimator.attributedCapMultipleOfMeasured).rounded()), measured)
        let credibleCeiling = max(noProof, min(measuredBound, capUsed))

        // Large assistant text → huge dialect raw, independent of output-share coincidence.
        let hugeAssistantChars = 50_000_000
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: Int(usedBilled),
                windowProviderBilledTokenUnits: usedBilled,
                assistantChars: hugeAssistantChars,
                graphifySignalCount: 40
            )
        )
        XCTAssertGreaterThan(
            b.dialectRawTokens + b.graphifyRawTokens,
            credibleCeiling,
            "fixture must produce raw attributed above the credible ceiling"
        )
        XCTAssertLessThanOrEqual(b.attributedOnly, capUsed, "granted estimate must stay under usage ceiling")
        XCTAssertLessThanOrEqual(
            b.attributedOnly,
            credibleCeiling,
            "granted estimate must not exceed max(no-proof, min(4×measured, capUsed))"
        )
        // Displacement must not mislabel a no-proof / usage-bound result as measuredMultiple.
        XCTAssertNotEqual(
            b.capBinding,
            .measuredMultiple,
            "cap_binding must report the component that actually bound (not displacement of raw)"
        )
    }

    func test_largeAssistantChars_cannotExceedUsageCeiling() {
        // WHY: assistantChars is a public observation input; unbounded floor must still
        // be clipped by attributedCapShareOfUsed so the UI cannot show fantasy totals.
        let usedBilled = 500_000.0
        let capUsed = Int((usedBilled * TokenSaverBareUserEstimator.attributedCapShareOfUsed).rounded())
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 100,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: Int(usedBilled),
                windowProviderBilledTokenUnits: usedBilled,
                assistantChars: 200_000_000
            )
        )
        XCTAssertGreaterThan(b.dialectRawTokens, capUsed, "fixture needs raw dialect above capUsed")
        XCTAssertLessThanOrEqual(b.attributedOnly, capUsed)
        XCTAssertLessThanOrEqual(b.estimatedDialect, capUsed)
    }

    func test_totalCredible_isMonotoneNonDecreasingInMeasured_withGraphifyActive() {
        // WHY: existing monotone property only covered graphifyActive=false; graphify
        // raw adds another attributed leg that must not re-introduce measured cliffs.
        let usedBilled = 78_658_351.0
        let measuredValues = [0, 1, 2, 10, 1_000, 100_000, 550_608]
        var previous = -1
        for measured in measuredValues {
            let b = TokenSaverBareUserEstimator.estimate(
                measuredToolOutputSaved: measured,
                tokenSaverEnabled: true,
                graphifyActive: true,
                orchestrationActive: false,
                observation: TokenSaverBareUserObservation(
                    windowProviderTokens: Int(usedBilled),
                    windowProviderBilledTokenUnits: usedBilled,
                    graphifySignalCount: 40
                )
            )
            XCTAssertGreaterThanOrEqual(
                b.totalCredible,
                previous,
                "totalCredible must be non-decreasing in measured with graphify; broke at measured=\(measured) (prev=\(previous), now=\(b.totalCredible))"
            )
            previous = b.totalCredible
        }
    }

    func test_nonFiniteOrAstronomicalBilled_doesNotTrap() {
        // WHY: actualProviderBilledTokenUnits is Double from usage.json; 1e300 / NaN /
        // Inf are valid JSON numbers that used to trap on Int(double.rounded()).
        let corruptValues: [Double] = [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            1e300,
            -1e300,
            Double.greatestFiniteMagnitude
        ]
        for billed in corruptValues {
            let b = TokenSaverBareUserEstimator.estimate(
                measuredToolOutputSaved: 10,
                tokenSaverEnabled: true,
                graphifyActive: true,
                orchestrationActive: false,
                observation: TokenSaverBareUserObservation(
                    windowProviderTokens: 1_000,
                    windowProviderBilledTokenUnits: billed,
                    assistantChars: 10_000,
                    graphifySignalCount: 5
                )
            )
            // Degrade: finite non-negative breakdown fields (no trap).
            XCTAssertGreaterThanOrEqual(b.measuredToolOutput, 0)
            XCTAssertGreaterThanOrEqual(b.estimatedDialect, 0)
            XCTAssertGreaterThanOrEqual(b.estimatedGraphify, 0)
            XCTAssertGreaterThanOrEqual(b.totalCredible, 0)
            XCTAssertGreaterThanOrEqual(b.attributedOnly, 0)
        }

        // Direct conversion helper must not trap either.
        XCTAssertEqual(TokenSaverBareUserEstimator.clampedInt(from: Double.nan), 0)
        XCTAssertEqual(TokenSaverBareUserEstimator.clampedInt(from: Double.infinity), 0)
        XCTAssertEqual(TokenSaverBareUserEstimator.clampedInt(from: 1e300), Int.max)
        XCTAssertEqual(TokenSaverBareUserEstimator.clampedInt(from: -1e300), Int.min)
    }
}
