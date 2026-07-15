import XCTest
@testable import Persistence

/// Brute-force defense for the LAN pairing surface. A 6-digit code over LAN
/// is brute-forceable in seconds without throttling; these tests pin the
/// backoff *schedule*, the success-reset, and the outstanding-request cap so
/// the protection cannot silently regress to "unlimited attempts".
final class PairingThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // WHY: the first few mistypes by a legitimate user must NOT incur a wait,
    // or normal pairing becomes painful. Below freeAttempts => still allowed.
    func test_freeAttempts_areNotLockedOut() {
        let th = PairingThrottle(freeAttempts: 3, baseBackoff: 2, maxBackoff: 300)
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .allowed)
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .allowed)
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .allowed)
        XCTAssertEqual(th.check(peer: "a", now: t0), .allowed,
                       "within the free-attempt budget the peer must stay allowed")
    }

    // WHY: this is the actual brute-force brake. Each failure past the budget
    // must DOUBLE the lockout window; if the doubling regresses to a constant,
    // an attacker regains a high steady attempt rate. Assert the exact schedule.
    func test_lockout_growsExponentially_perExcessFailure() {
        let th = PairingThrottle(freeAttempts: 3, baseBackoff: 2, maxBackoff: 1000)
        _ = th.recordFailure(peer: "a", now: t0)   // 1 (free)
        _ = th.recordFailure(peer: "a", now: t0)   // 2 (free)
        _ = th.recordFailure(peer: "a", now: t0)   // 3 (free)
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .denied(retryAfter: 2))   // excess 1 -> 2·2^0
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .denied(retryAfter: 4))   // excess 2 -> 2·2^1
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .denied(retryAfter: 8))   // excess 3 -> 2·2^2
    }

    // WHY: an unbounded backoff would eventually overflow / lock a peer out
    // effectively forever. The window must clamp at maxBackoff.
    func test_lockout_clampsAtMaxBackoff() {
        let th = PairingThrottle(freeAttempts: 0, baseBackoff: 2, maxBackoff: 5)
        _ = th.recordFailure(peer: "a", now: t0)   // 2
        _ = th.recordFailure(peer: "a", now: t0)   // 4
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .denied(retryAfter: 5),
                       "8 would exceed maxBackoff=5, so it must clamp")
    }

    // WHY: while locked, check() must DENY and report remaining time so the
    // endpoint can return it; once the window passes, the peer is allowed again.
    func test_check_deniesDuringWindow_thenAllowsAfter() {
        let th = PairingThrottle(freeAttempts: 0, baseBackoff: 10, maxBackoff: 1000)
        _ = th.recordFailure(peer: "a", now: t0)   // locked for 10s
        if case .denied(let r) = th.check(peer: "a", now: t0.addingTimeInterval(3)) {
            XCTAssertEqual(r, 7, accuracy: 0.001, "must report remaining lockout seconds")
        } else { XCTFail("expected denied mid-window") }
        XCTAssertEqual(th.check(peer: "a", now: t0.addingTimeInterval(10)), .allowed,
                       "after the window elapses the peer may attempt again")
    }

    // WHY: a device that finally pairs successfully must not be stuck behind a
    // prior backoff. Success resets that peer's penalty to zero.
    func test_success_resetsLockout() {
        let th = PairingThrottle(freeAttempts: 0, baseBackoff: 10, maxBackoff: 1000)
        _ = th.recordFailure(peer: "a", now: t0)
        XCTAssertNotEqual(th.check(peer: "a", now: t0), .allowed)
        th.recordSuccess(peer: "a")
        XCTAssertEqual(th.check(peer: "a", now: t0), .allowed,
                       "a successful pairing must clear the peer's lockout")
        // And the next failure starts the schedule over from the beginning.
        XCTAssertEqual(th.recordFailure(peer: "a", now: t0), .denied(retryAfter: 10))
    }

    // WHY: lockout is per-peer; one attacker IP must not lock out a different,
    // legitimate device behind a different IP.
    func test_lockout_isPerPeer() {
        let th = PairingThrottle(freeAttempts: 0, baseBackoff: 10, maxBackoff: 1000)
        _ = th.recordFailure(peer: "attacker", now: t0)
        XCTAssertNotEqual(th.check(peer: "attacker", now: t0), .allowed)
        XCTAssertEqual(th.check(peer: "victim", now: t0), .allowed,
                       "one peer's lockout must not bleed onto another peer")
    }

    // WHY: a single peer must not be able to flood the approve/deny queue with
    // unbounded outstanding pairing_requests. The cap bounds concurrent reqs;
    // releasing a slot frees capacity again.
    func test_outstandingRequests_cappedPerPeer() {
        let th = PairingThrottle(maxOutstandingPerPeer: 2)
        XCTAssertTrue(th.reserveOutstanding(peer: "a"))
        XCTAssertTrue(th.reserveOutstanding(peer: "a"))
        XCTAssertFalse(th.reserveOutstanding(peer: "a"),
                       "third outstanding request from the same peer must be refused")
        th.releaseOutstanding(peer: "a")
        XCTAssertTrue(th.reserveOutstanding(peer: "a"),
                      "releasing a slot must restore capacity")
    }

    // WHY: the outstanding cap is per-peer too; one peer at its cap must not
    // block a different peer from creating its own request.
    func test_outstandingCap_isPerPeer() {
        let th = PairingThrottle(maxOutstandingPerPeer: 1)
        XCTAssertTrue(th.reserveOutstanding(peer: "a"))
        XCTAssertFalse(th.reserveOutstanding(peer: "a"))
        XCTAssertTrue(th.reserveOutstanding(peer: "b"),
                      "a separate peer must get its own outstanding budget")
    }

    // WHY: the normal pairing lifecycle is reserve → bind → terminal status.
    // If a completed pairing did not free its slot, a phone re-pairing a few
    // times (the "Not authorized → re-pair" recovery loop) would hit the cap
    // and get 429 until the Mac app restarts — pairing must stay repeatable.
    func test_completedPairings_doNotExhaustCap() {
        let th = PairingThrottle(maxOutstandingPerPeer: 2)
        for i in 0..<5 {
            XCTAssertTrue(th.reserveOutstanding(peer: "phone", now: t0),
                          "pairing #\(i + 1) must not be blocked by earlier completed pairings")
            th.bindOutstanding(requestId: "req-\(i)", peer: "phone", expiresAt: t0.addingTimeInterval(300))
            th.releaseOutstanding(requestId: "req-\(i)")   // terminal status observed
        }
    }

    // WHY: the device polls /v1/pair/status repeatedly after the request is
    // decided. Only the FIRST terminal observation may free the slot —
    // repeated releases for the same request id must not free slots that
    // belong to the peer's other outstanding requests (cap bypass).
    func test_releaseByRequestId_isIdempotent() {
        let th = PairingThrottle(maxOutstandingPerPeer: 2)
        XCTAssertTrue(th.reserveOutstanding(peer: "a", now: t0))
        th.bindOutstanding(requestId: "r1", peer: "a", expiresAt: t0.addingTimeInterval(300))
        XCTAssertTrue(th.reserveOutstanding(peer: "a", now: t0))
        th.bindOutstanding(requestId: "r2", peer: "a", expiresAt: t0.addingTimeInterval(300))

        th.releaseOutstanding(requestId: "r1")
        th.releaseOutstanding(requestId: "r1")   // repeated terminal poll
        th.releaseOutstanding(requestId: "r1")

        XCTAssertTrue(th.reserveOutstanding(peer: "a", now: t0),
                      "exactly one slot was freed, so exactly one reserve must succeed")
        XCTAssertFalse(th.reserveOutstanding(peer: "a", now: t0),
                       "repeated releases of the same request id must not free r2's slot")
    }

    // WHY: a phone that dies mid-pair never polls a terminal status and never
    // cancels. Its slot must come back on its own once the request's TTL
    // passes, or abandoned requests permanently shrink the peer's budget.
    func test_abandonedBinding_isReclaimedAfterExpiry() {
        let th = PairingThrottle(maxOutstandingPerPeer: 1)
        XCTAssertTrue(th.reserveOutstanding(peer: "a", now: t0))
        th.bindOutstanding(requestId: "r1", peer: "a", expiresAt: t0.addingTimeInterval(300))

        XCTAssertFalse(th.reserveOutstanding(peer: "a", now: t0.addingTimeInterval(299)),
                       "before the TTL the slot is still held")
        XCTAssertTrue(th.reserveOutstanding(peer: "a", now: t0.addingTimeInterval(300)),
                      "after the TTL the abandoned slot must be reclaimed")
    }
}
