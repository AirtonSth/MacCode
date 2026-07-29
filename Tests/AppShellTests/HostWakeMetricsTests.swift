import XCTest
@testable import AppShell

final class HostWakeMetricsTests: XCTestCase {
    func testFunnelCounters() {
        let m = HostWakeMetrics()
        m.increment(.outboxCoalesced)
        m.increment(.silentAttempt)
        m.increment(.silent429)
        m.increment(.silentSent)
        m.increment(.silentFailed)
        m.increment(.wakeNotSent)
        XCTAssertEqual(m.count(.outboxCoalesced), 1)
        XCTAssertEqual(m.count(.silentAttempt), 1)
        XCTAssertEqual(m.count(.silent429), 1)
        XCTAssertEqual(m.count(.silentSent), 1)
        XCTAssertEqual(m.count(.silentFailed), 1)
        XCTAssertEqual(m.count(.wakeNotSent), 1)
        let snap = m.snapshot()
        XCTAssertEqual(snap["silent_sent"], 1)
        XCTAssertEqual(snap["wake_not_sent"], 1)
    }

    func testWakeNotSentIsDistinctFromSilentFailed() {
        // WHY: unsubscribed / no push target used to return with no counter, so
        // "host pushed nothing" looked identical to success. wake_not_sent must
        // not inflate silent_failed (which means the HTTPS path threw).
        let m = HostWakeMetrics()
        m.increment(.wakeNotSent)
        m.increment(.wakeNotSent)
        XCTAssertEqual(m.count(.wakeNotSent), 2)
        XCTAssertEqual(m.count(.silentFailed), 0)
        XCTAssertEqual(m.count(.silentSent), 0)
        XCTAssertEqual(m.count(.silentAttempt), 0)
        XCTAssertTrue(HostWakeMetricKey.allCases.contains(.wakeNotSent))
        XCTAssertEqual(HostWakeMetricKey.wakeNotSent.rawValue, "wake_not_sent")
    }

    func testResetClearsWakeNotSent() {
        let m = HostWakeMetrics()
        m.increment(.wakeNotSent)
        m.reset()
        XCTAssertEqual(m.count(.wakeNotSent), 0)
        XCTAssertNil(m.snapshot()["wake_not_sent"])
    }
}
