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
