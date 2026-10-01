import XCTest
import Darwin
@testable import SocketServer

final class AcceptRetryBackoffTests: XCTestCase {
    func test_persistentAcceptFailureBacksOff_becauseEMFILEMustNotSpinACoreForever() {
        // WHY: accept() fails instantly while the process is out of descriptors;
        // retrying immediately burned a full core until the app was restarted.
        var backoff = AcceptRetryBackoff()
        let delays = (0..<10).map { _ in backoff.delay(afterErrno: EMFILE) }
        XCTAssertEqual(delays.first ?? nil, 10_000)
        XCTAssertEqual(delays[1], 20_000)
        XCTAssertEqual(delays.last ?? nil, 1_000_000, "backoff caps at one second")
        let totalSeconds = delays.compactMap { $0 }.reduce(0) { $0 + Double($1) } / 1_000_000
        XCTAssertGreaterThan(totalSeconds, 2, "ten consecutive failures must spend seconds asleep, not microseconds")
        XCTAssertEqual(backoff.delay(afterErrno: ENFILE), 1_000_000)

        backoff.reset()
        XCTAssertEqual(backoff.delay(afterErrno: ENOBUFS), 10_000, "a successful accept resets the backoff")
    }

    func test_transientAcceptErrorsRetryImmediately_becauseAbortedClientsAreNormal() {
        var backoff = AcceptRetryBackoff()
        XCTAssertNil(backoff.delay(afterErrno: EINTR))
        XCTAssertNil(backoff.delay(afterErrno: ECONNABORTED))
        XCTAssertNil(backoff.delay(afterErrno: EAGAIN))
        XCTAssertEqual(backoff.delay(afterErrno: EMFILE), 10_000, "transient errors do not advance the backoff")
    }
}
