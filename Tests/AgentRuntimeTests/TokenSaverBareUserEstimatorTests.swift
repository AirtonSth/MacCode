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
        XCTAssertEqual(b.estimatedOrchestration, 0)
        XCTAssertEqual(b.totalEstimatedVsBareUser, 50_000)
    }

    func test_fullStack_includesDialectGraphifyOrchestration() {
        // WHY: bare-user counterfactual must credit all RemoteCode techniques, not only pipes.
        let used = 100_000
        let measured = 1_000
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: measured,
            actualProviderTokens: used,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: true
        )
        let expectedDialect = Int((Double(used) * 0.22 * 2.0).rounded())
        let expectedGraphify = Int((Double(used) * 0.78 * 0.18).rounded())
        let expectedOrch = Int((Double(used) * 0.08).rounded())
        XCTAssertEqual(b.measuredToolOutput, measured)
        XCTAssertEqual(b.estimatedDialect, expectedDialect)
        XCTAssertEqual(b.estimatedGraphify, expectedGraphify)
        XCTAssertEqual(b.estimatedOrchestration, expectedOrch)
        XCTAssertEqual(
            b.totalEstimatedVsBareUser,
            measured + expectedDialect + expectedGraphify + expectedOrch
        )
        XCTAssertGreaterThan(b.totalEstimatedVsBareUser, measured)
    }

    func test_graphifyOff_zeroGraphifyComponent() {
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 100,
            actualProviderTokens: 50_000,
            tokenSaverEnabled: true,
            graphifyActive: false,
            orchestrationActive: true
        )
        XCTAssertEqual(b.estimatedGraphify, 0)
        XCTAssertGreaterThan(b.estimatedDialect, 0)
        XCTAssertGreaterThan(b.estimatedOrchestration, 0)
    }

    func test_zeroUsage_noAttributedInflation() {
        let b = TokenSaverBareUserEstimator.estimate(
            measuredToolOutputSaved: 12,
            actualProviderTokens: 0,
            tokenSaverEnabled: true,
            graphifyActive: true,
            orchestrationActive: true
        )
        XCTAssertEqual(b.totalEstimatedVsBareUser, 12)
    }
}
