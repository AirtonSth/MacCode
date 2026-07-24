import XCTest
@testable import CoreModel

final class TokenSaverWaveLiveRolloutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TokenSaverWaveLiveRollout.resetForTesting()
    }

    override func tearDown() {
        TokenSaverWaveLiveRollout.resetForTesting()
        super.tearDown()
    }

    func test_activateWaveA_setsTriggersActive() {
        XCTAssertEqual(TokenSaverWaveALossless.defaults[.repeatedLog], .shadow)
        TokenSaverWaveLiveRollout.activate(.waveA)
        XCTAssertTrue(TokenSaverWaveLiveRollout.isLive(.waveA))
        XCTAssertEqual(TokenSaverWaveALossless.defaults[.repeatedLog], .active)
        XCTAssertEqual(TokenSaverWaveALossless.defaults[.structuredJSON], .active)
    }

    func test_activateCrushers_enablesRegistry() {
        TokenSaverWaveLiveRollout.activate(.waveBCrushers)
        XCTAssertTrue(TokenSaverWaveLiveRollout.isLive(.waveBCrushers))
        XCTAssertTrue(TokenSaverTypedCrushers.sharedRegistry.isEnabled(.pytest, bindingDigest: "deadbeef"))
    }

    func test_policyFacadesReflectLiveGate() {
        XCTAssertFalse(TokenSaverCacheGuard.isLive)
        TokenSaverWaveLiveRollout.activate(.waveBCache)
        XCTAssertTrue(TokenSaverCacheGuard.isLive)

        TokenSaverWaveLiveRollout.activate(.waveBRecovery)
        XCTAssertTrue(TokenSaverRecoveryProjections.isLive)

        TokenSaverWaveLiveRollout.activate(.waveCQueue)
        XCTAssertTrue(TokenSaverQueueCoalesce.isLive)

        TokenSaverWaveLiveRollout.activate(.waveCRollover)
        XCTAssertTrue(TokenSaverRolloverHandoff.isLive)

        TokenSaverWaveLiveRollout.activate(.waveD)
        XCTAssertTrue(TokenSaverWaveDFamilies.isLive)

        TokenSaverWaveLiveRollout.activate(.prefetch)
        XCTAssertTrue(TokenSaverTurnBatchPrefetch.isLive)

        TokenSaverWaveLiveRollout.activate(.canary)
        XCTAssertTrue(TokenSaverPromotionCanary.isLive)
    }

    func test_permanentDisableBlocksReactivate() {
        TokenSaverWaveLiveRollout.permanentlyDisable(.waveD, reason: "e2e unfixable")
        TokenSaverWaveLiveRollout.activate(.waveD)
        XCTAssertFalse(TokenSaverWaveLiveRollout.isLive(.waveD))
        XCTAssertTrue(TokenSaverWaveLiveRollout.permanentlyDisabled.contains(.waveD))
    }

    func test_cacheGuardAdmitRequiresLive() {
        let sys = Data("SYSTEM".utf8)
        let live = Data("LIVEZONE".utf8)
        let candidate = Data("SYSTEMLIVEZONE".utf8)
        XCTAssertFalse(TokenSaverCacheGuard.admit(
            systemBytes: sys, liveBytes: live, candidate: candidate,
            beforeHitRate: 0.5, afterHitRate: 0.6
        ))
        TokenSaverWaveLiveRollout.activate(.waveBCache)
        XCTAssertTrue(TokenSaverCacheGuard.isLive)
        XCTAssertTrue(TokenSaverCacheGuard.admit(
            systemBytes: sys, liveBytes: live, candidate: candidate,
            beforeHitRate: 0.5, afterHitRate: 0.6
        ))
    }

    func test_recoveryAndPrefetchAdmitWhenLive() {
        XCTAssertFalse(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "abc", resultScopeDigest: "abc"
        ))
        TokenSaverWaveLiveRollout.activate(.waveBRecovery)
        XCTAssertTrue(TokenSaverRecoveryProjections.admitSearch(
            queryScopeDigest: "abc", resultScopeDigest: "abc"
        ))

        XCTAssertFalse(TokenSaverTurnBatchPrefetch.prefetchAllowed(
            readOnly: true, noNetwork: true, inWorkspace: true
        ))
        TokenSaverWaveLiveRollout.activate(.prefetch)
        XCTAssertTrue(TokenSaverTurnBatchPrefetch.prefetchAllowed(
            readOnly: true, noNetwork: true, inWorkspace: true
        ))
        XCTAssertTrue(TokenSaverTurnBatchPrefetch.batchMayContinue(
            unknownOutputAffectsDownstream: false,
            mutationApproved: true,
            isMutation: false
        ))
    }

    func test_queueCoalesceRuntimeSavesWhenLiveAndOptIn() {
        TokenSaverWaveLiveRollout.activate(.waveCQueue)
        let rt = TokenSaverQueueCoalesceRuntime()
        rt.live = true
        rt.setOptIn(true)
        let a = TokenSaverQueueCoalesceRuntime.QueuedIntent(
            id: "1", userID: "u", threadID: "t", provider: "claude", model: "m",
            generation: 1, kind: .additive,
            canonicalText: Data(("hello world " + String(repeating: "x", count: 200)).utf8),
            dispatchStarted: false
        )
        let b = TokenSaverQueueCoalesceRuntime.QueuedIntent(
            id: "2", userID: "u", threadID: "t", provider: "claude", model: "m",
            generation: 1, kind: .additive,
            canonicalText: Data(("hello world " + String(repeating: "y", count: 200)).utf8),
            dispatchStarted: false
        )
        let decision = rt.decideCoalesce(a, b)
        // Same scope → may coalesce or keep; not .notLive
        XCTAssertNotEqual(decision, TokenSaverQueueCoalesceRuntime.CoalesceDecision.notLive)
    }
}
