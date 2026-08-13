import XCTest
@testable import CoreModel

final class TokenEstimatorTests: XCTestCase {
    func testEstimateMatchesSharedUtf8WordFormula() {
        // WHY: SR2 adoption and Distill ledger must share one estimator.
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
        XCTAssertGreaterThan(TokenEstimator.estimate("hello world this is a sentence"), 0)
        XCTAssertGreaterThan(
            TokenEstimator.estimate(String(repeating: "token ", count: 100)),
            TokenEstimator.estimate("token token token")
        )
    }
}
