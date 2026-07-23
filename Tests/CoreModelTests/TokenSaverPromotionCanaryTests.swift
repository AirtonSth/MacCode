import XCTest
@testable import CoreModel

final class TokenSaverPromotionCanaryTests: XCTestCase {
    private final class Hours {
        var value: Int
        init(_ v: Int) { value = v }
    }

    private func tempDir() -> URL {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ts-canary-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeRuntime(
        user: String = "u",
        bind: String = "bind",
        hours: Hours = Hours(0)
    ) -> (TokenSaverPromotionCanaryRuntime, Hours, URL) {
        let dir = tempDir()
        let rt = TokenSaverPromotionCanaryRuntime(boundUserID: user, bindingDigest: bind, durableDirectory: dir)
        rt.nowHours = { hours.value }
        return (rt, hours, dir)
    }

    func test_defaultOffAndLedgerReceiptOnly() {
        XCTAssertFalse(TokenSaverPromotionCanary.defaultEnabled)
        let (rt, _, dir) = makeRuntime(bind: "bind")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(rt.uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: true))
        XCTAssertEqual(rt.confirmedTotal(receipt: nil, creditBindingDigest: "bind"), 0)
        rt.live = true
        let led = TokenSaverAccountingV2.Ledger()
        _ = led.record(TokenSaverAccountingV2.Operation(digest: "op", generation: 1, state: .providerApplied))
        _ = led.markProviderMeasured("op", experimentalPair: true, providerTokensSaved: 10, bindingDigest: "bind")
        let r = TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(ledger: led, operationDigest: "op")
        XCTAssertEqual(rt.confirmedTotal(receipt: r, creditBindingDigest: "bind"), 10)
        XCTAssertEqual(rt.confirmedTotal(receipt: r, creditBindingDigest: "other"), 0)
    }

    func test_canaryRequiresOutcomesAndDwell() {
        let (rt, hours, dir) = makeRuntime()
        defer { try? FileManager.default.removeItem(at: dir) }
        rt.live = true
        rt.recordOutcomes(10)
        // Stamp step entry at hour 0, then dwell.
        XCTAssertEqual(rt.advanceCanary(), .one)
        hours.value += 24
        XCTAssertEqual(rt.advanceCanary(), .five)
        rt.recordOutcomes(40)
        XCTAssertEqual(rt.advanceCanary(), .five) // needs 72h from five entry
        hours.value += 72
        XCTAssertEqual(rt.advanceCanary(), .twentyFive)
        rt.recordOutcomes(150)
        hours.value += 72
        XCTAssertEqual(rt.advanceCanary(), .complete)
    }

    func test_attributionHoldAndRevoke() {
        let (rt, hours, dir) = makeRuntime()
        defer { try? FileManager.default.removeItem(at: dir) }
        rt.live = true
        rt.recordOutcomes(10)
        _ = rt.advanceCanary() // stamp entry at 0
        hours.value += 24
        rt.setAttribution(0.5)
        XCTAssertEqual(rt.advanceCanary(), .one)
        rt.setAttribution(0.99)
        XCTAssertEqual(rt.advanceCanary(), .five)
        rt.revokeCanary()
        XCTAssertEqual(rt.currentStep(), .one)
    }

    func test_promotionRequiresBoundGateAndSameUser() {
        let (rt, hours, dir) = makeRuntime(user: "alice", bind: "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        rt.live = true
        rt.recordOutcomes(10)
        _ = rt.advanceCanary() // stamp entry
        hours.value += 24
        XCTAssertEqual(rt.advanceCanary(), .five)
        rt.recordOutcomes(40)
        hours.value += 72
        XCTAssertEqual(rt.advanceCanary(), .twentyFive)

        let wrongBind = TokenSaverPromotionCanaryRuntime.PromotionGate.seal(
            coverageCellsComplete: true, presentationParityOK: true, modelBOMComplete: true,
            semanticConsent: true, rollbackDrillOK: true, bindingDigest: "other", registryEpoch: 1, revoked: false
        )!
        XCTAssertFalse(rt.mayPromote(gate: wrongBind, requestingUserID: "alice"))

        let gate = TokenSaverPromotionCanaryRuntime.PromotionGate.seal(
            coverageCellsComplete: true, presentationParityOK: true, modelBOMComplete: true,
            semanticConsent: true, rollbackDrillOK: true, bindingDigest: "b", registryEpoch: 1, revoked: false
        )!
        XCTAssertFalse(rt.mayPromote(gate: gate, requestingUserID: "bob"))
        XCTAssertTrue(rt.mayPromote(gate: gate, requestingUserID: "alice"))
        XCTAssertTrue(rt.storeOriginal(handle: "h1", bytes: Data("orig".utf8), requestingUserID: "alice"))
        XCTAssertEqual(rt.viewOriginal(handle: "h1", requestingUserID: "alice"), Data("orig".utf8))
        XCTAssertNil(rt.viewOriginal(handle: "h1", requestingUserID: "bob"))
    }

    func test_originalSurvivesRelaunchAndCrossUserDenied() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rt1 = TokenSaverPromotionCanaryRuntime(boundUserID: "u", bindingDigest: "b", durableDirectory: dir)
        XCTAssertTrue(rt1.storeOriginal(handle: "h1", bytes: Data("durable-orig".utf8), requestingUserID: "u"))
        let rt2 = TokenSaverPromotionCanaryRuntime(boundUserID: "u", bindingDigest: "b", durableDirectory: dir)
        XCTAssertEqual(rt2.viewOriginal(handle: "h1", requestingUserID: "u"), Data("durable-orig".utf8))
        let other = TokenSaverPromotionCanaryRuntime(boundUserID: "other", bindingDigest: "b", durableDirectory: dir)
        XCTAssertNil(other.viewOriginal(handle: "h1", requestingUserID: "other"))
    }
}
