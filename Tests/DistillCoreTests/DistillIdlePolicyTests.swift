import XCTest
@testable import DistillCore

/// plan-final W2: idleTimeout is consumed by a real decision path.
final class DistillIdlePolicyTests: XCTestCase {
    func test_decide_activeRequests_stayAlive() {
        let d = DistillIdlePolicy.decide(
            now: Date(timeIntervalSince1970: 1000),
            lastRequestAt: Date(timeIntervalSince1970: 0),
            idleTimeout: 10,
            activeRequestCount: 1
        )
        XCTAssertEqual(d, .stayAlive)
    }

    func test_decide_idlePastTimeout_exitClean() {
        let d = DistillIdlePolicy.decide(
            now: Date(timeIntervalSince1970: 100),
            lastRequestAt: Date(timeIntervalSince1970: 0),
            idleTimeout: 30,
            activeRequestCount: 0
        )
        XCTAssertEqual(d, .exitCleanIdle)
    }

    func test_decide_withinTimeout_stayAlive() {
        let d = DistillIdlePolicy.decide(
            now: Date(timeIntervalSince1970: 20),
            lastRequestAt: Date(timeIntervalSince1970: 0),
            idleTimeout: 30,
            activeRequestCount: 0
        )
        XCTAssertEqual(d, .stayAlive)
    }

    func test_tracker_noteRequest_resetsIdleClock() {
        let tracker = DistillIdleTracker(idleTimeout: 30, startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            tracker.decision(now: Date(timeIntervalSince1970: 40), activeRequestCount: 0),
            .exitCleanIdle
        )
        tracker.noteRequest(at: Date(timeIntervalSince1970: 35))
        XCTAssertEqual(
            tracker.decision(now: Date(timeIntervalSince1970: 40), activeRequestCount: 0),
            .stayAlive
        )
    }
}
