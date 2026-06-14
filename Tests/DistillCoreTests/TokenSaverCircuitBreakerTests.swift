import XCTest
@testable import DistillCore

final class TokenSaverCircuitBreakerTests: XCTestCase {
    func test_toolRetrieveRateDemotesProfileAboveFivePercent() {
        XCTAssertEqual(
            TokenSaverCircuitBreaker.toolProfile(retrieveCount: 6, compressedCount: 100).action,
            .demoteToPassThrough
        )
        XCTAssertEqual(
            TokenSaverCircuitBreaker.toolProfile(retrieveCount: 5, compressedCount: 100).action,
            .keepEnabled
        )
    }

    func test_negativeNetBilledUnitsDisableLane() {
        XCTAssertEqual(TokenSaverCircuitBreaker.netBilledCost(netUnits: -0.1).action, .disableLane)
        XCTAssertEqual(TokenSaverCircuitBreaker.netBilledCost(netUnits: 0).action, .keepEnabled)
    }

    func test_encoderLifecycleLatchesAfterTimeoutsOrThrash() {
        XCTAssertEqual(
            TokenSaverCircuitBreaker.encoderLifecycle(consecutiveDeadlineTimeouts: 3, evictReloadThrashes: 0).reason,
            "encoder_deadline_timeout_latch"
        )
        XCTAssertEqual(
            TokenSaverCircuitBreaker.encoderLifecycle(consecutiveDeadlineTimeouts: 0, evictReloadThrashes: 1).reason,
            "encoder_evict_reload_thrash"
        )
    }

    func test_maskingDisablesWhenRetrieveUnavailableFailuresHighRateOrNegativeNet() {
        XCTAssertEqual(
            TokenSaverCircuitBreaker.masking(
                retrieveRoundTrips: 0,
                turnCount: 10,
                retrieveFailures: 0,
                netUnits: 1,
                mcpRetrieveAvailable: false
            ).reason,
            "rc_retrieve_unavailable"
        )
        XCTAssertEqual(
            TokenSaverCircuitBreaker.masking(
                retrieveRoundTrips: 0,
                turnCount: 10,
                retrieveFailures: 1,
                netUnits: 1,
                mcpRetrieveAvailable: true
            ).reason,
            "masked_retrieve_failure"
        )
        XCTAssertEqual(
            TokenSaverCircuitBreaker.masking(
                retrieveRoundTrips: 3,
                turnCount: 10,
                retrieveFailures: 0,
                netUnits: 1,
                mcpRetrieveAvailable: true
            ).reason,
            "masking_retrieve_rate_above_threshold"
        )
        XCTAssertEqual(
            TokenSaverCircuitBreaker.masking(
                retrieveRoundTrips: 0,
                turnCount: 10,
                retrieveFailures: 0,
                netUnits: -0.01,
                mcpRetrieveAvailable: true
            ).reason,
            "masking_negative_net_billed_units"
        )
    }

    func test_canaryModelABLatencyCorpusAndFlagOffGates() {
        XCTAssertEqual(
            TokenSaverCircuitBreaker.nliCanary(falseAcceptRate: 0.02, maxFalseAcceptRate: 0.01, omissionRecall: 0.99, minOmissionRecall: 0.98).action,
            .revertAggressiveRatios
        )
        XCTAssertEqual(
            TokenSaverCircuitBreaker.modelArtifact(parityCIPassed: true, outputVariancePassed: false, licenseMatched: true).action,
            .blockModel
        )
        XCTAssertEqual(
            TokenSaverCircuitBreaker.abRegression(rerunDelta: 0.2, turnCountDelta: 0, maxRerunDelta: 0.1, maxTurnCountDelta: 0.1).reason,
            "same_command_rerun_delta"
        )
        XCTAssertEqual(TokenSaverCircuitBreaker.latency(p95Milliseconds: 350, budgetMilliseconds: 300).reason, "p95_latency_budget_exceeded")
        XCTAssertEqual(TokenSaverCircuitBreaker.fixedCorpus(hasCorpus: false, regressionCount: 0).reason, "fixed_corpus_missing")
        XCTAssertEqual(TokenSaverCircuitBreaker.fixedCorpus(hasCorpus: true, regressionCount: 1).reason, "fixed_corpus_regression")
        XCTAssertEqual(TokenSaverCircuitBreaker.flagOffParity(byteIdentical: false, p95Ratio: 1).reason, "flag_off_output_changed")
        XCTAssertEqual(TokenSaverCircuitBreaker.flagOffParity(byteIdentical: true, p95Ratio: 1.1).reason, "flag_off_p95_regressed")
    }
}
