import XCTest
@testable import CoreModel

final class TokenSaverPromotionCanaryTests: XCTestCase {
    private var keyProviders: [String: TokenSaverInMemoryProjectKeyProvider] = [:]
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
        let rt = TokenSaverPromotionCanaryRuntime(
            boundUserID: user,
            bindingDigest: bind,
            originalStore: try! makeOriginalStore(at: dir, user: user, binding: bind)
        )
        rt.nowHours = { hours.value }
        return (rt, hours, dir)
    }

    private func makeOriginalStore(
        at dir: URL,
        user: String,
        binding: String
    ) throws -> TokenSaverEncryptedOriginalStore {
        let provider = keyProviders[dir.path] ?? TokenSaverInMemoryProjectKeyProvider()
        keyProviders[dir.path] = provider
        let store = try TokenSaverEncryptedStore(projectRoot: dir, keyProvider: provider)
        try store.markMigrationComplete()
        let scope = TokenSaverEncryptedStore.Scope(
            uid: 501,
            workspaceID: "w",
            projectID: binding,
            threadID: user,
            provider: "test",
            sessionGeneration: 1
        )
        return TokenSaverEncryptedOriginalStore(store: store, scope: scope)
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
        XCTAssertEqual(rt.confirmedTotal(receipt: r, creditBindingDigest: "bind"), 0)
        XCTAssertEqual(rt.confirmedTotal(receipt: r, creditBindingDigest: "other"), 0)
    }

    func test_canaryRequiresOutcomesAndDwell() {
        let (rt, hours, dir) = makeRuntime()
        defer { try? FileManager.default.removeItem(at: dir) }
        rt.live = true
        rt.setAttribution(0.99)
        rt.setReconciliation(0.02)
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
        rt.setAttribution(0.99)
        rt.setReconciliation(0.02)
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
        rt.setAttribution(0.99)
        rt.setReconciliation(0.02)
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
        XCTAssertTrue(rt.activatePromotion(gate: gate, requestingUserID: "alice"))
        XCTAssertTrue(rt.uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: true))
        let ledger = TokenSaverAccountingV2.Ledger()
        _ = ledger.record(.init(digest: "promoted", generation: 1, state: .providerApplied))
        _ = ledger.markProviderMeasured(
            "promoted",
            experimentalPair: true,
            providerTokensSaved: 12,
            bindingDigest: "b"
        )
        let receipt = TokenSaverRecoveryProjections.ReceiptFactory.fromLocalLedger(
            ledger: ledger,
            operationDigest: "promoted"
        )
        XCTAssertEqual(rt.confirmedTotal(receipt: receipt, creditBindingDigest: "b"), 12)
        rt.setAttribution(.nan)
        XCTAssertFalse(rt.uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: true))
        XCTAssertEqual(rt.confirmedTotal(receipt: receipt, creditBindingDigest: "b"), 0)
        XCTAssertTrue(rt.storeOriginal(handle: "h1", bytes: Data("orig".utf8), requestingUserID: "alice"))
        XCTAssertTrue(
            rt.storeOriginal(handle: "h1", bytes: Data("orig".utf8), requestingUserID: "alice"),
            "same-byte replay must remain idempotent"
        )
        XCTAssertFalse(
            rt.storeOriginal(handle: "h1", bytes: Data("conflict".utf8), requestingUserID: "alice"),
            "same handle must never overwrite a different original"
        )
        XCTAssertEqual(rt.viewOriginal(handle: "h1", requestingUserID: "alice"), Data("orig".utf8))
        XCTAssertNil(rt.viewOriginal(handle: "h1", requestingUserID: "bob"))
    }

    func test_missingAttributionOrReconciliation_holdsCanaryAndPromotion() {
        let (rt, hours, dir) = makeRuntime(user: "alice", bind: "b")
        defer { try? FileManager.default.removeItem(at: dir) }
        rt.live = true
        rt.recordOutcomes(200)
        _ = rt.advanceCanary()
        hours.value = 500

        XCTAssertEqual(rt.advanceCanary(), .one)

        let gate = TokenSaverPromotionCanaryRuntime.PromotionGate.seal(
            coverageCellsComplete: true, presentationParityOK: true, modelBOMComplete: true,
            semanticConsent: true, rollbackDrillOK: true, bindingDigest: "b", registryEpoch: 1, revoked: false
        )!
        XCTAssertFalse(rt.mayPromote(gate: gate, requestingUserID: "alice"))
        rt.setAttribution(0.99)
        XCTAssertFalse(rt.mayPromote(gate: gate, requestingUserID: "alice"))
        rt.setReconciliation(0.02)
        XCTAssertEqual(rt.advanceCanary(), .five)
    }

    func test_originalSurvivesRelaunchAndCrossUserDenied() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let rt1 = TokenSaverPromotionCanaryRuntime(
            boundUserID: "u",
            bindingDigest: "b",
            originalStore: try makeOriginalStore(at: dir, user: "u", binding: "b")
        )
        XCTAssertTrue(rt1.storeOriginal(handle: "h1", bytes: Data("durable-orig".utf8), requestingUserID: "u"))
        let rt2 = TokenSaverPromotionCanaryRuntime(
            boundUserID: "u",
            bindingDigest: "b",
            originalStore: try makeOriginalStore(at: dir, user: "u", binding: "b")
        )
        XCTAssertEqual(rt2.viewOriginal(handle: "h1", requestingUserID: "u"), Data("durable-orig".utf8))
        let other = TokenSaverPromotionCanaryRuntime(
            boundUserID: "other",
            bindingDigest: "b",
            originalStore: try makeOriginalStore(at: dir, user: "other", binding: "b")
        )
        XCTAssertNil(other.viewOriginal(handle: "h1", requestingUserID: "other"))
    }
}
