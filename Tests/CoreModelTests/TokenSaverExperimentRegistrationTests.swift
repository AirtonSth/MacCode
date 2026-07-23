import XCTest
@testable import CoreModel

final class TokenSaverExperimentRegistrationTests: XCTestCase {
    private func binding() -> TokenSaverBindingID {
        TokenSaverBindingID(
            trigger: "structured_json",
            provider: "claude",
            providerAdapterVersion: "2.1.216",
            toolShape: "mcp.json",
            model: "claude-sonnet",
            cachePolicy: "default",
            triggerPolicyClassifierRecipeIndexVersion: "policy-v1",
            billingCohort: "same-user-agent",
            hardwareTier: "apple-silicon",
            consentVersion: "exact-v1"
        )
    }

    private func completeStats() -> TokenSaverExperimentRegistration.Statistics {
        .init(
            primaryOutcome: "provider_input_tokens",
            minimumDetectableEffect: 0.05,
            margins: .init(taskSuccessDelta: 0.02, correctionsDelta: 0.05, criticalSuppressionDelta: 0.01),
            oneSidedAlpha: 0.025,
            power: 0.8,
            multiplicityAdjustment: "holm",
            missingnessRule: "abort_as_stop"
        )
    }

    func test_incompleteRegistration_cannotSeal() {
        let incomplete = TokenSaverExperimentRegistration.Statistics(
            primaryOutcome: "",
            minimumDetectableEffect: 0.05,
            margins: .init(taskSuccessDelta: 0.02, correctionsDelta: 0.05, criticalSuppressionDelta: 0.01),
            oneSidedAlpha: 0.025,
            power: 0.8,
            multiplicityAdjustment: "holm",
            missingnessRule: "abort_as_stop"
        )
        let reg = TokenSaverExperimentRegistration(binding: binding(), statistics: incomplete)
        XCTAssertFalse(reg.canSeal)
        XCTAssertNil(reg.sealed())
    }

    func test_missingDeltaMargins_cannotSeal() {
        let badMargins = TokenSaverExperimentRegistration.DeltaMargins(
            taskSuccessDelta: .nan,
            correctionsDelta: 0.05,
            criticalSuppressionDelta: 0.01
        )
        XCTAssertFalse(badMargins.isComplete)
        let stats = TokenSaverExperimentRegistration.Statistics(
            primaryOutcome: "x",
            minimumDetectableEffect: 0.05,
            margins: badMargins,
            oneSidedAlpha: 0.025,
            power: 0.8,
            multiplicityAdjustment: "holm",
            missingnessRule: "abort"
        )
        XCTAssertFalse(stats.isComplete)
    }

    func test_seal_thenStatisticsImmutable() {
        let reg = TokenSaverExperimentRegistration(binding: binding(), statistics: completeStats())
        let sealed = reg.sealed()
        XCTAssertNotNil(sealed)
        XCTAssertTrue(sealed!.isSealed)
        let mutated = sealed!.replacingStatistics(completeStats())
        XCTAssertNil(mutated, "sealed registration must reject statistics replacement")
    }

    func test_inconclusive_isStopNotGo() {
        XCTAssertEqual(TokenSaverExperimentRegistration.decision(for: .inconclusive), .stop)
        XCTAssertEqual(TokenSaverExperimentRegistration.decision(for: .stop), .stop)
        XCTAssertEqual(TokenSaverExperimentRegistration.decision(for: .go), .go)
    }

    func test_schemaRequiresAllThreeDeltas() {
        let m = completeStats().margins
        XCTAssertTrue(m.isComplete)
        XCTAssertGreaterThanOrEqual(m.taskSuccessDelta, 0)
        XCTAssertGreaterThanOrEqual(m.correctionsDelta, 0)
        XCTAssertGreaterThanOrEqual(m.criticalSuppressionDelta, 0)
    }

    func test_neverPromotesBindingID() {
        XCTAssertFalse(TokenSaverExperimentRegistration.promotesBindingID(binding()))
    }

    func test_publicInit_alwaysUnsealedEvenWithCompleteStats() {
        let reg = TokenSaverExperimentRegistration(binding: binding(), statistics: completeStats())
        XCTAssertFalse(reg.isSealed)
        // There is no public way to construct a sealed incomplete registration.
        XCTAssertNotNil(reg.sealed())
    }
}
