import XCTest
@testable import DistillCore

/// Item 218: explicit transport budget for the optimizer client. Oversized
/// requests fail open byte-exact before transport; they are never truncated.
final class DistillTransportBudgetTests: XCTestCase {

    // WHY: the budget exists so a slow/hung optimizer never blocks the agent's
    // shell for ~a minute. If this constant drifts out of [5,10]s the whole
    // point (fail fast, fall back to raw) is defeated.
    func testRequestTimeoutIsInFiveToTenSecondBand() {
        let t = DistillServiceClient.requestTimeoutSeconds
        XCTAssertGreaterThanOrEqual(t, 5, "timeout must be >= 5s per item 218 budget")
        XCTAssertLessThanOrEqual(t, 10, "timeout must be <= 10s so shell never hangs ~a minute")
    }

    // WHY: the local sidecar and client share one explicit maximum. The
    // end-to-end oversized tests prove cap+1 returns the complete original and
    // performs zero transport/store/marker work.
    func testInputBudgetIsExactlyThirtyTwoMiB() {
        XCTAssertEqual(DistillServiceClient.stdinByteCap, 32 * 1_024 * 1_024)
    }
}
