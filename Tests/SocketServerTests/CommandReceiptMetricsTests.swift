import XCTest
import Persistence
@testable import SocketServer

final class CommandReceiptMetricsTests: XCTestCase {
    func test_snapshotAggregatesReceiptOutcomesAndLatencyWithoutRequestIdentity() {
        let metrics = CommandReceiptMetrics()

        metrics.recordClaim(.claimed, latencyMilliseconds: 1.5)
        metrics.recordClaim(.inProgress, latencyMilliseconds: 2)
        metrics.recordClaim(.committed(resultJSON: "true"), latencyMilliseconds: 3)
        metrics.recordClaim(.unknown, latencyMilliseconds: 4)
        metrics.recordClaimFailure(latencyMilliseconds: 5)
        metrics.recordUnknownOutcome()
        metrics.recordFinalization(success: true, latencyMilliseconds: 6)
        metrics.recordFinalization(success: false, latencyMilliseconds: 7)

        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.claimsTotal, 5)
        XCTAssertEqual(snapshot.newClaimsTotal, 1)
        XCTAssertEqual(snapshot.claimFailuresTotal, 1)
        XCTAssertEqual(snapshot.duplicatesInProgressTotal, 1)
        XCTAssertEqual(snapshot.duplicatesCommittedTotal, 1)
        XCTAssertEqual(snapshot.duplicatesUnknownTotal, 1)
        XCTAssertEqual(snapshot.unknownOutcomesTotal, 1)
        XCTAssertEqual(snapshot.finalizationSuccessesTotal, 1)
        XCTAssertEqual(snapshot.finalizationFailuresTotal, 1)
        XCTAssertEqual(snapshot.claimLatency.count, 5)
        XCTAssertEqual(snapshot.claimLatency.totalMilliseconds, 15.5, accuracy: 0.001)
        XCTAssertEqual(snapshot.claimLatency.maxMilliseconds, 5, accuracy: 0.001)
        XCTAssertEqual(snapshot.finalizationLatency.count, 2)
        XCTAssertEqual(snapshot.finalizationLatency.totalMilliseconds, 13, accuracy: 0.001)
        XCTAssertEqual(snapshot.finalizationLatency.maxMilliseconds, 7, accuracy: 0.001)
    }
}
