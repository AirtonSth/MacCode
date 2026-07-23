import XCTest
@testable import CoreModel

final class TokenSaverPromotionCanaryTests: XCTestCase {
    func test_defaultOffAndLedgerReceiptOnly() {
        XCTAssertFalse(TokenSaverPromotionCanary.defaultEnabled)
        let rt = TokenSaverPromotionCanaryRuntime(boundUserID: "u", bindingDigest: "bind")
        XCTAssertFalse(rt.uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: true))
        // Without ledger-minted receipt → 0 even when live
        XCTAssertEqual(rt.confirmedTotal(receipt: nil, creditBindingDigest: "bind"), 0)
        rt.live = true
        XCTAssertEqual(rt.confirmedTotal(receipt: nil, creditBindingDigest: "bind"), 0)

        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "op", generation: 1, state: .providerApplied))
        _ = led.markProviderMeasured("op", experimentalPair: true, providerTokensSaved: 10, bindingDigest: "bind")
        let r = TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: led, operationDigest: "op")
        XCTAssertEqual(rt.confirmedTotal(receipt: r, creditBindingDigest: "bind"), 10)
        XCTAssertEqual(rt.confirmedTotal(receipt: r, creditBindingDigest: "other"), 0)
    }

    func test_canaryRequiresOutcomesAndDwell() {
        let rt = TokenSaverPromotionCanaryRuntime(boundUserID: "u", bindingDigest: "b")
        rt.live = true
        rt.recordOutcomes(10)
        // Outcomes met but no dwell → stay at one
        XCTAssertEqual(rt.advanceCanary(), .one)
        rt.advanceClock(hours: 24)
        XCTAssertEqual(rt.advanceCanary(), .five)
        rt.recordOutcomes(40)
        XCTAssertEqual(rt.advanceCanary(), .five) // need 72h dwell
        rt.advanceClock(hours: 72)
        XCTAssertEqual(rt.advanceCanary(), .twentyFive)
        rt.recordOutcomes(150)
        rt.advanceClock(hours: 72)
        XCTAssertEqual(rt.advanceCanary(), .complete)
    }

    func test_attributionHoldAndRevoke() {
        let rt = TokenSaverPromotionCanaryRuntime(boundUserID: "u", bindingDigest: "b")
        rt.live = true
        rt.recordOutcomes(10)
        rt.advanceClock(hours: 24)
        rt.setAttribution(0.5)
        XCTAssertEqual(rt.advanceCanary(), .one) // hold
        rt.setAttribution(0.99)
        XCTAssertEqual(rt.advanceCanary(), .five)
        rt.revokeCanary()
        XCTAssertEqual(rt.currentStep(), .one)
    }

    func test_promotionRequiresInternalGateAndSameUser() {
        let rt = TokenSaverPromotionCanaryRuntime(boundUserID: "alice", bindingDigest: "b")
        rt.live = true
        // Reach .twentyFive with staged outcomes + dwell (promote-eligible)
        rt.recordOutcomes(10)
        rt.advanceClock(hours: 24)
        XCTAssertEqual(rt.advanceCanary(), .five)
        rt.recordOutcomes(40)
        rt.advanceClock(hours: 72)
        XCTAssertEqual(rt.advanceCanary(), .twentyFive)
        // No public free-boolean path
        XCTAssertNil(TokenSaverPromotionCanaryRuntime.PromotionGate.seal(
            coverageCellsComplete: false, presentationParityOK: true, modelBOMComplete: true,
            semanticConsent: true, rollbackDrillOK: true, bindingDigest: "b", registryEpoch: 1, revoked: false
        ))
        let gate = TokenSaverPromotionCanaryRuntime.PromotionGate.seal(
            coverageCellsComplete: true, presentationParityOK: true, modelBOMComplete: true,
            semanticConsent: true, rollbackDrillOK: true, bindingDigest: "b", registryEpoch: 1, revoked: false
        )!
        XCTAssertFalse(rt.mayPromote(gate: gate, requestingUserID: "bob"))
        XCTAssertTrue(rt.mayPromote(gate: gate, requestingUserID: "alice"))
        XCTAssertTrue(rt.storeOriginal(handle: "h1", bytes: Data("orig".utf8), requestingUserID: "alice"))
        XCTAssertEqual(rt.viewOriginal(handle: "h1", requestingUserID: "alice"), Data("orig".utf8))
        XCTAssertNil(rt.viewOriginal(handle: "h1", requestingUserID: "bob"))
        XCTAssertFalse(rt.storeOriginal(handle: "h1", bytes: Data("x".utf8), requestingUserID: "alice"))
    }

    func test_originalSurvivesRelaunchViaDurableDir() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ts-canary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rt1 = TokenSaverPromotionCanaryRuntime(boundUserID: "u", bindingDigest: "b", durableDirectory: dir)
        XCTAssertTrue(rt1.storeOriginal(handle: "h1", bytes: Data("durable-orig".utf8), requestingUserID: "u"))
        let rt2 = TokenSaverPromotionCanaryRuntime(boundUserID: "u", bindingDigest: "b", durableDirectory: dir)
        XCTAssertEqual(rt2.viewOriginal(handle: "h1", requestingUserID: "u"), Data("durable-orig".utf8))
    }
}
