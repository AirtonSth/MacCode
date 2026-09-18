import XCTest
@testable import AppShell

/// WHY: The non-blocking pairing sheet must show the user an accurate live
/// countdown driven by the 300-second TTL. If `remainingSecs` or `expired`
/// compute incorrectly the sheet could show "300s left" after expiry (risk:
/// user approves a request the server will reject) or auto-dismiss too early
/// (risk: user never gets to approve a valid request). These tests pin the
/// pure time math without touching AppKit or any timer.
final class PairingCountdownTests: XCTestCase {

    // Stable epoch for all cases
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func test_pairingCodeTimelineSchedule_stopsAfterExpiredInitialRender() {
        // WHY: once Settings already says Expired, another 60 one-second
        // invalidations cannot change its label, color, or button state.
        let now = epoch.addingTimeInterval(601)
        let entries = PairingCodeTimelineSchedule(expiresAt: epoch.addingTimeInterval(600))
            .entries(from: now, mode: .normal)
        let renderedDates = Array(entries.prefix(61))

        XCTAssertEqual(renderedDates, [now])
        XCTAssertEqual(renderedDates.dropFirst().count, 0)
    }

    func test_pairingCodeTimelineSchedule_keepsCadenceAndExpiryLabel() {
        // WHY: before expiry the visible countdown must still advance every
        // second and render the exact terminal Expired state at the boundary.
        let expiresAt = epoch.addingTimeInterval(60)
        let entries = PairingCodeTimelineSchedule(expiresAt: expiresAt)
            .entries(from: epoch, mode: .normal)
        let renderedDates = Array(entries.prefix(62))

        XCTAssertEqual(renderedDates.count, 61)
        XCTAssertEqual(renderedDates.first, epoch)
        XCTAssertEqual(renderedDates.last, expiresAt)
        XCTAssertTrue(zip(renderedDates, renderedDates.dropFirst()).allSatisfy {
            $1.timeIntervalSince($0) == 1
        })
        XCTAssertEqual(
            PairingCodeCountdownPresentation(expiresAt: expiresAt, now: epoch).label,
            "Expires in 1:00"
        )
        XCTAssertEqual(
            PairingCodeCountdownPresentation(expiresAt: expiresAt, now: expiresAt).label,
            "Expired"
        )
    }

    func test_pairingCodeCountdownPresentation_preservesRoundingAndState() {
        let expiresAt = epoch.addingTimeInterval(60)
        let live = PairingCodeCountdownPresentation(
            expiresAt: expiresAt,
            now: epoch.addingTimeInterval(0.2)
        )
        XCTAssertEqual(live.remaining, 60,
                       "the existing rounded-up countdown must not lose a second")
        XCTAssertFalse(live.expired)
        XCTAssertEqual(live.label, "Expires in 1:00")

        let expired = PairingCodeCountdownPresentation(
            expiresAt: expiresAt,
            now: expiresAt.addingTimeInterval(20)
        )
        XCTAssertEqual(expired.remaining, 0)
        XCTAssertTrue(expired.expired)
        XCTAssertEqual(expired.label, "Expired")
    }

    func test_pairingQR_disappearsWithTheCode() {
        // WHY: the QR is a scannable shortcut for the same pairing URL. Showing it
        // past expiry invites the user to scan a code the server already rejects,
        // so the view must drop it at the exact instant the code greys out.
        let expiresAt = epoch.addingTimeInterval(60)
        let payload = "remotecode://pair?code=ABC"
        let live = PairingCodeCountdownPresentation(
            expiresAt: expiresAt,
            now: expiresAt.addingTimeInterval(-0.2)
        )
        XCTAssertFalse(live.expired)
        XCTAssertEqual(live.livePairingQRPayload(payload), payload,
                       "a live code must keep its QR")
        XCTAssertNil(live.livePairingQRPayload(nil),
                     "no payload means no QR")

        XCTAssertNil(
            PairingCodeCountdownPresentation(expiresAt: expiresAt, now: expiresAt)
                .livePairingQRPayload(payload),
            "the QR must be gone at the exact expiry instant"
        )
        XCTAssertNil(
            PairingCodeCountdownPresentation(expiresAt: expiresAt, now: expiresAt.addingTimeInterval(120))
                .livePairingQRPayload(payload),
            "the QR must stay gone after expiry"
        )
    }

    func test_microbenchPairingCodeTimelineSchedule_eliminatesExpiredInvalidations() {
        let warmups = 2
        let samples = 7
        let expiresAt = epoch.addingTimeInterval(600)
        let expiredNow = expiresAt.addingTimeInterval(1)
        var optimizedSamples: [Int] = []

        for iteration in 0..<(warmups + samples) {
            let entries = PairingCodeTimelineSchedule(expiresAt: expiresAt)
                .entries(from: expiredNow, mode: .normal)
            let optimizedInvalidations = Array(entries.prefix(61)).dropFirst().count
            if iteration >= warmups {
                XCTAssertEqual(optimizedInvalidations, 0)
                optimizedSamples.append(optimizedInvalidations)
            }
        }

        XCTAssertEqual(optimizedSamples, Array(repeating: 0, count: samples))
        print("PERF expired_pairing_clock warmup=2 n=7 baseline_invalidations=60 optimized_invalidations=0 reduction_pct=100 live_invalidations=60")
    }

    // MARK: remainingSecs

    func test_remainingSecs_atCreation_equalsFullTTL() {
        let secs = PairingCountdown.remainingSecs(createdAt: epoch, ttl: 300, now: epoch)
        XCTAssertEqual(secs, 300.0, accuracy: 0.001,
            "at t=0 the full TTL must remain so the sheet opens with the correct countdown")
    }

    func test_remainingSecs_midWindow_decreasesByElapsed() {
        let secs = PairingCountdown.remainingSecs(createdAt: epoch, ttl: 300, now: epoch.addingTimeInterval(100))
        XCTAssertEqual(secs, 200.0, accuracy: 0.001,
            "100s after creation exactly 200s must remain; a wrong value would desync the on-screen timer from server TTL")
    }

    func test_remainingSecs_atExactExpiry_isZero() {
        let secs = PairingCountdown.remainingSecs(createdAt: epoch, ttl: 300, now: epoch.addingTimeInterval(300))
        XCTAssertEqual(secs, 0.0, accuracy: 0.001,
            "at the exact TTL boundary remaining time is 0; the sheet must auto-dismiss at this instant")
    }

    func test_remainingSecs_pastExpiry_clampedToZero() {
        let secs = PairingCountdown.remainingSecs(createdAt: epoch, ttl: 300, now: epoch.addingTimeInterval(400))
        XCTAssertEqual(secs, 0.0, accuracy: 0.001,
            "beyond TTL remaining time must clamp to 0 (never negative) so the sheet never shows a nonsensical countdown")
    }

    func test_remainingSecs_shortTTL_respectsTTLParam() {
        // Ensures the helper uses the injected ttl, not a hardcoded 300.
        let secs = PairingCountdown.remainingSecs(createdAt: epoch, ttl: 60, now: epoch.addingTimeInterval(20))
        XCTAssertEqual(secs, 40.0, accuracy: 0.001,
            "the helper must use the caller-supplied TTL, not a hardcoded constant, or non-standard pairing codes break")
    }

    // MARK: expired

    func test_expired_beforeExpiry_isFalse() {
        let result = PairingCountdown.expired(createdAt: epoch, ttl: 300, now: epoch.addingTimeInterval(299))
        XCTAssertFalse(result,
            "one second before TTL the request is still valid; dismissing early would prevent a legitimate pairing")
    }

    func test_expired_atExactBoundary_isTrue() {
        let result = PairingCountdown.expired(createdAt: epoch, ttl: 300, now: epoch.addingTimeInterval(300))
        XCTAssertTrue(result,
            "at the exact expiry instant the request is expired; the sheet must dismiss and deny must fire")
    }

    func test_expired_pastExpiry_isTrue() {
        let result = PairingCountdown.expired(createdAt: epoch, ttl: 300, now: epoch.addingTimeInterval(400))
        XCTAssertTrue(result,
            "well past TTL the request is expired; the helper must not allow approval of stale requests")
    }

    func test_expired_justCreated_isFalse() {
        let result = PairingCountdown.expired(createdAt: epoch, ttl: 300, now: epoch)
        XCTAssertFalse(result,
            "a freshly-created request is valid; the sheet must open rather than immediately closing")
    }
}
