import XCTest
@testable import CoreModel

final class TokenSaverPromotionCanaryTests: XCTestCase {
    func test_defaultOffAndUI() {
        XCTAssertFalse(TokenSaverPromotionCanary.defaultEnabled)
        let rt = TokenSaverPromotionCanaryRuntime()
        XCTAssertFalse(rt.uiMayShowConfirmedSavingsCopy(hasDeliveringConfirmedLane: true))
        let r = TokenSaverPromotionCanaryRuntime.PresentationReceipt(
            bindingDigest: "b", measuredTokens: 10, estimatedTokens: 99, confirmed: false, originalHandle: nil
        )
        XCTAssertEqual(rt.confirmedTotal(receipt: r), 0)
        XCTAssertEqual(rt.confirmedTotal(receipt: .init(bindingDigest: "b", measuredTokens: 10, estimatedTokens: 99, confirmed: true, originalHandle: nil)), 10)
    }

    func test_canaryWatermarkNotTime() {
        let rt = TokenSaverPromotionCanaryRuntime()
        rt.live = true
        XCTAssertEqual(rt.advanceCanary(elapsedHours: 1000), .one)
        rt.recordOutcomes(10)
        XCTAssertEqual(rt.advanceCanary(elapsedHours: 0), .five)
        rt.recordOutcomes(40)
        XCTAssertEqual(rt.advanceCanary(elapsedHours: 0), .twentyFive)
        rt.recordOutcomes(150)
        XCTAssertEqual(rt.advanceCanary(elapsedHours: 0), .complete)
    }

    func test_attributionHoldAndRevoke() {
        let rt = TokenSaverPromotionCanaryRuntime()
        rt.live = true
        rt.recordOutcomes(10)
        rt.setAttribution(0.5)
        XCTAssertEqual(rt.advanceCanary(elapsedHours: 0), .one) // hold
        rt.setAttribution(0.99)
        XCTAssertEqual(rt.advanceCanary(elapsedHours: 0), .five)
        rt.revokeCanary()
        XCTAssertEqual(rt.currentStep(), .one)
    }

    func test_promotionGatesAndOriginalView() {
        let rt = TokenSaverPromotionCanaryRuntime()
        rt.live = true
        XCTAssertFalse(rt.mayPromote(bindingDigest: "b"))
        rt.setCoverageComplete(true)
        rt.setPresentationParityOK(true)
        rt.setModelBOMComplete(true)
        rt.setSemanticConsent(true)
        rt.recordOutcomes(300)
        _ = rt.advanceCanary(elapsedHours: 0)
        XCTAssertTrue(rt.mayPromote(bindingDigest: "b"))
        XCTAssertTrue(rt.storeOriginal(handle: "h1", bytes: Data("orig".utf8)))
        XCTAssertEqual(rt.viewOriginal(handle: "h1"), Data("orig".utf8))
        XCTAssertFalse(rt.storeOriginal(handle: "h1", bytes: Data("x".utf8)))
    }
}
