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
        XCTAssertEqual(m.count(.outboxCoalesced), 1)
        XCTAssertEqual(m.count(.silentAttempt), 1)
        XCTAssertEqual(m.count(.silent429), 1)
        XCTAssertEqual(m.count(.silentSent), 1)
        XCTAssertEqual(m.count(.silentFailed), 1)
        let snap = m.snapshot()
        XCTAssertEqual(snap["silent_sent"], 1)
    }
}
