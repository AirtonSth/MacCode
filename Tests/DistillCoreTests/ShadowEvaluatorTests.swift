import XCTest
@testable import DistillCore

/// I3.5 / I3.8 / I6.9 / I9.8 / I10.9: shadow-mode + harm-proxy mechanism.
final class ShadowEvaluatorTests: XCTestCase {
    func test_harmProxyMissRateGatesFlagOn() async {
        let shadow = ShadowEvaluator()
        await shadow.recordShadowPrune(lane: "diff", spanIDs: ["a", "b", "c", "d", "e"])
        // 1 of 5 shadow-pruned spans was later retrieved → 20% miss-rate → flag-on refused.
        await shadow.recordRetrieve(spanID: "b")
        let mr = await shadow.missRate
        XCTAssertEqual(mr, 0.2, accuracy: 0.0001)
        let recommend = await shadow.flagOnRecommended(maxMissRate: 0.01)
        XCTAssertFalse(recommend, "20% miss-rate is far above the 1% gate")
    }

    func test_flagOnRecommendedWhenNoHarmAndNoSuppression() async {
        let shadow = ShadowEvaluator()
        await shadow.recordShadowPrune(lane: "log", spanIDs: ["x", "y", "z"])
        // no retrieves, no failure suppression → recommend.
        let recommend = await shadow.flagOnRecommended(maxMissRate: 0.01)
        XCTAssertTrue(recommend)
    }

    func test_failureSuppressionBlocksFlagOn() async {
        let shadow = ShadowEvaluator()
        await shadow.recordShadowPrune(lane: "test_report", spanIDs: ["p"])
        await shadow.recordFailureSuppression(lane: "test_report")
        let recommend = await shadow.flagOnRecommended()
        XCTAssertFalse(recommend, "any failure-suppression event blocks flag-on (I10.9)")
        let events = await shadow.totalFailureSuppressionEvents
        XCTAssertEqual(events, 1)
    }

    // I10.9: deterministic failure-suppression detection.
    func test_detectsFailureLineDroppedFromShadowOutput() {
        let original = "running suite\nFAILED test_login: assert 401 == 200\nall other checks ok"
        let dropped = "running suite\nall other checks ok"   // the FAILED line vanished
        let kept = original + "\nfolded 12 passing-test lines [[rc:h]]"  // adds, drops nothing
        XCTAssertTrue(ShadowEvaluator.suppressesFailure(original: original, shadowOutput: dropped))
        XCTAssertFalse(ShadowEvaluator.suppressesFailure(original: original, shadowOutput: kept))
    }

    // I9.8: nominate/dispose accounting.
    func test_nominateDisposeAccounting() async {
        let shadow = ShadowEvaluator()
        await shadow.recordNominate()
        await shadow.recordNominate()
        await shadow.recordDispose()
        let nd = await shadow.nominateDispose
        XCTAssertEqual(nd.nominate, 2)
        XCTAssertEqual(nd.dispose, 1)
    }
}
