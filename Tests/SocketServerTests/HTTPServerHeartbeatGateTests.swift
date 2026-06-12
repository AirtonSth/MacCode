import XCTest
@testable import SocketServer

final class HTTPServerHeartbeatGateTests: XCTestCase {
    // Threshold: heartbeat allowed only when queued < max/2.
    // WHY: prevents heartbeat frames accumulating on a backed-up slow client,
    // which would make queue pressure worse and delay real events further.

    func test_below_half_allows_heartbeat() {
        // queued=0, max=1024*1024 -> well below half -> send
        XCTAssertTrue(DirectHTTPServer.shouldSendHeartbeat(queued: 0, max: 1_048_576))
    }

    func test_exactly_half_blocks_heartbeat() {
        // queued==max/2 -> NOT below half -> skip
        XCTAssertFalse(DirectHTTPServer.shouldSendHeartbeat(queued: 512, max: 1_024))
    }

    func test_above_half_blocks_heartbeat() {
        // queued > max/2 -> backed up -> skip
        XCTAssertFalse(DirectHTTPServer.shouldSendHeartbeat(queued: 600, max: 1_024))
    }

    func test_just_below_half_allows_heartbeat() {
        // queued=511, max=1024, threshold=512 -> 511 < 512 -> send
        XCTAssertTrue(DirectHTTPServer.shouldSendHeartbeat(queued: 511, max: 1_024))
    }

    func test_full_queue_blocks_heartbeat() {
        XCTAssertFalse(DirectHTTPServer.shouldSendHeartbeat(queued: 1_048_576, max: 1_048_576))
    }
}
