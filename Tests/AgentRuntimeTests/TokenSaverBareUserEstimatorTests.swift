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
            actualProviderTokens: used,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: true
        )
        // O ≈ 100M * 0.007 = 700k; dialect V=2 → ~700k before caps
        XCTAssertLessThan(b.estimatedDialect, 2_000_000, "dialect must stay on output scale, not 44% of used")
        XCTAssertGreaterThan(b.estimatedDialect, 100_000)
        XCTAssertEqual(b.estimatedOrchestration, 0, "orch excluded from token total")
        XCTAssertEqual(b.totalCredible, measured + b.estimatedDialect + b.estimatedGraphify)
        // Attributed capped vs measured/used
        XCTAssertLessThanOrEqual(b.attributedOnly, Int(Double(measured) * 4.0) + 1)
    }

    func test_graphifyRequiresSignals() {
        let noHit = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 100_000,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: false,
            observation: TokenSaverBareUserObservation(
                windowProviderTokens: 50_000_000,
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
                graphifySignalCount: 40
            )
        )
        XCTAssertGreaterThan(withHits.estimatedGraphify, 0)
        XCTAssertLessThan(withHits.estimatedGraphify, 5_000_000, "graphify must not be 18% of all input")
    }

    func test_zeroMeasured_limitsAttributedFantasy() {
        // WHY: empty pipe day must not report tens of millions of "savings".
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 0,
            actualProviderTokens: 100_000_000,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: true
        )
        XCTAssertLessThanOrEqual(b.totalCredible, 2_000_000 + 1) // ≤2% of used
    }

    func test_liveSharePreferredWhenEnoughSamples() {
        let obs = TokenSaverBareUserObservation(
            windowProviderTokens: 10_000_000,
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
}
