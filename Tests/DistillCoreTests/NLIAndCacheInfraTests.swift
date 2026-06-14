import XCTest
@testable import DistillCore

/// I8.6-8.9 NLI gating + I4.3/I4.7/I4.8 cache infra.
final class NLIAndCacheInfraTests: XCTestCase {
    // I8.6/I8.9: aggressive ratio only with healthy canaries + NLI lane + outside the
    // sensitive 800-2000 char band; otherwise conservative.
    func test_ratioStaysConservativeWithoutHealthyNLI() {
        XCTAssertFalse(NLIGatePolicy.ratioAndFloor(canaryHealthy: true, nliLaneHealthy: false, promptChars: 5000).aggressive)
        XCTAssertFalse(NLIGatePolicy.ratioAndFloor(canaryHealthy: false, nliLaneHealthy: true, promptChars: 5000).aggressive)
        // healthy + outside band → aggressive
        let agg = NLIGatePolicy.ratioAndFloor(canaryHealthy: true, nliLaneHealthy: true, promptChars: 5000)
        XCTAssertTrue(agg.aggressive)
        XCTAssertEqual(agg.maxRatio, 4.0)
        XCTAssertEqual(agg.floorChars, 800)
        // healthy but in 800-2000 band → conservative (I8.9)
        XCTAssertFalse(NLIGatePolicy.ratioAndFloor(canaryHealthy: true, nliLaneHealthy: true, promptChars: 1500).aggressive)
        // net negative → conservative
        XCTAssertFalse(NLIGatePolicy.ratioAndFloor(canaryHealthy: true, nliLaneHealthy: true, promptChars: 5000, netBilledNonNegative: false).aggressive)
    }

    func test_oodEvalGoNoGo() {
        XCTAssertTrue(NLIGatePolicy.oodEvalGoNoGo(auc: 0.9))
        XCTAssertFalse(NLIGatePolicy.oodEvalGoNoGo(auc: 0.7))
    }

    // I8.8: hysteresis — harder to (re)enter aggressive than to stay.
    func test_latencyHysteresis() {
        XCTAssertTrue(NLIGatePolicy.allowsAggressiveLatency(p95Millis: 290, budgetMillis: 300, currentlyAggressive: true))
        // not currently aggressive: needs margin (≤240) to enter
        XCTAssertFalse(NLIGatePolicy.allowsAggressiveLatency(p95Millis: 290, budgetMillis: 300, currentlyAggressive: false))
        XCTAssertTrue(NLIGatePolicy.allowsAggressiveLatency(p95Millis: 230, budgetMillis: 300, currentlyAggressive: false))
    }

    // I4.3: only deterministic non-compressible verdicts enter; transient errors never do.
    func test_skipSetRecordsDeterministicOnly() {
        var skip = DeterministicSkipSet(ttlTurns: 10)
        skip.recordIfDeterministic(input: "abc", routerReturnedNil: true, belowGainFloor: true, now: 0)
        XCTAssertTrue(skip.shouldSkip(input: "abc", now: 1))
        // router found a route → not recorded
        skip.recordIfDeterministic(input: "json", routerReturnedNil: false, belowGainFloor: true, now: 0)
        XCTAssertFalse(skip.shouldSkip(input: "json", now: 1))
        // transient error → never recorded (the trap the plan forbids)
        skip.recordTransientError(input: "timed-out")
        XCTAssertFalse(skip.shouldSkip(input: "timed-out", now: 1))
        // TTL expiry
        XCTAssertFalse(skip.shouldSkip(input: "abc", now: 100))
    }

    // I4.7: yield predictor is skip-only — never forces, epsilon always attempts.
    func test_yieldPredictorIsSkipOnly() {
        XCTAssertEqual(YieldPredictor.recommend(inputChars: 10, isStructured: false, priorAcceptRate: 0.9), .skipLowYield)
        XCTAssertEqual(YieldPredictor.recommend(inputChars: 5000, isStructured: false, priorAcceptRate: 0.01), .skipLowYield)
        XCTAssertEqual(YieldPredictor.recommend(inputChars: 5000, isStructured: true, priorAcceptRate: 0.01), .attempt)
        // epsilon exploration overrides skip → attempt (keeps labels unbiased)
        XCTAssertEqual(YieldPredictor.recommend(inputChars: 10, isStructured: false, priorAcceptRate: 0.9, explore: true), .attempt)
    }

    // I4.8: cache key is byte-exact — volatile-only differences are NOT normalized away.
    func test_cacheKeyByteExactNoVolatileNormalization() {
        let a = DistillRequest(mode: .longText, input: "deploy at 2026-06-14T01:00:00Z done")
        let b = DistillRequest(mode: .longText, input: "deploy at 2026-06-14T09:30:00Z done")
        let ka = DistillResultCacheKey(request: a)
        let kb = DistillResultCacheKey(request: b)
        XCTAssertNotEqual(ka, kb, "timestamps must NOT be normalized to inflate hit-rate (I4.8)")
    }
}
