import XCTest
@testable import AgentRuntime

final class DistillAccountRouteFailureTests: XCTestCase {
    // WHY: Distill reports "every account for this model is used up" as
    // "Authentication required". Tagging it auth sends people to Sign in,
    // which cannot fix a spent quota; it must read as a quota/route problem.
    func test_noAccountRoute_isNotClassifiedAsAuth() {
        for text in [
            "Distill ACP RPC error: Authentication required: No available account route for this session",
            "Distill ACP RPC error: Authentication required: Saved account route is unavailable",
        ] {
            let failure = DistillACPFailureTaxonomy.normalize(diagnostic: text, context: .start)
            XCTAssertEqual(failure.category, .rateLimited, text)
            XCTAssertFalse(failure.message.contains(DistillACPFailureTaxonomy.authRequiredMarker), failure.message)
            XCTAssertTrue(failure.message.contains("Choose Auto or another model"), failure.message)
        }
    }

    func test_realAuthFailure_staysAuth() {
        let failure = DistillACPFailureTaxonomy.normalize(
            diagnostic: "Distill ACP RPC error: Authentication required: token expired", context: .start)
        XCTAssertEqual(failure.category, .authRequired)
    }
}
