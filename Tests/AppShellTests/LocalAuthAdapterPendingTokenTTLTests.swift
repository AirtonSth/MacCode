import XCTest
@testable import AppShell
@testable import Persistence

/// Tests for the pending-token TTL expiry helpers introduced in the PERF fix.
///
/// WHY these tests matter:
///   Before this fix, `pendingTokens` entries accumulated unboundedly — a device
///   that approved pairing then crashed (or stopped polling) left a plaintext
///   token in RAM forever.  The fix adds TTL-based lazy eviction driven by two
///   pure helpers (`isPendingTokenExpired` and `sweepExpiredPendingTokens`) and
///   a real-path integration through `pairingRequestStatus`.
///
/// Coverage:
///   T-TTL-01  isPendingTokenExpired: past-TTL token is expired
///   T-TTL-02  isPendingTokenExpired: fresh token is NOT expired
///   T-TTL-03  isPendingTokenExpired: token exactly at TTL boundary is NOT expired
///             (boundary is exclusive: >ttl, not >=ttl)
///   T-TTL-04  sweepExpiredPendingTokens: removes only expired entries, keeps fresh ones
///   T-TTL-05  sweepExpiredPendingTokens: empty input -> empty output (no crash)
///   T-TTL-06  Integration — pairingRequestStatus delivers nil token when the
///             entry's issuedAt is past TTL (device stopped polling; entry leaked)
///   T-TTL-07  Integration — pairingRequestStatus still delivers token when
///             entry is fresh (normal happy path not broken by TTL check)
///   T-TTL-08  sweepExpiredPendingTokens: all-expired input -> empty output
///
/// No @MainActor needed — pure helpers have no actor requirement; integration
/// tests use DeviceTrustRepository directly (non-actor).
@MainActor
final class LocalAuthAdapterPendingTokenTTLTests: XCTestCase {

    // MARK: - Helpers

    private static let ttl: TimeInterval = 300   // mirrors LocalAuthAdapter.pendingTokenTTL

    private func makeEntry(issuedAt: Date) -> (deviceId: String, token: String, issuedAt: Date) {
        ("dev-\(UUID().uuidString)", "tok-\(UUID().uuidString)", issuedAt)
    }

    private func makeAuth() throws -> LocalAuthAdapter {
        let dir = NSTemporaryDirectory() + "RC2TTL-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        return LocalAuthAdapter(repo: DeviceTrustRepository(db: ctx.db))
    }

    // MARK: - T-TTL-01

    /// WHY: a token issued > TTL seconds ago must be treated as expired so it
    /// is not delivered to a device that resumes polling after abandoning the
    /// flow. Delivering a stale in-RAM token long after the pairing UI was
    /// dismissed would be a silent auth bypass.
    func test_isPendingTokenExpired_pastTTL_isTrue() {
        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let now      = issuedAt.addingTimeInterval(Self.ttl + 1)   // 1 s past TTL
        XCTAssertTrue(
            LocalAuthAdapter.isPendingTokenExpired(issuedAt: issuedAt, now: now, ttl: Self.ttl),
            "Token issued more than TTL seconds ago must be reported as expired"
        )
    }

    // MARK: - T-TTL-02

    /// WHY: a token issued BEFORE the TTL window must NOT be expired; evicting
    /// fresh tokens would break normal pairing where the device polls within
    /// seconds of approval.
    func test_isPendingTokenExpired_freshToken_isFalse() {
        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let now      = issuedAt.addingTimeInterval(Self.ttl - 1)   // 1 s before TTL
        XCTAssertFalse(
            LocalAuthAdapter.isPendingTokenExpired(issuedAt: issuedAt, now: now, ttl: Self.ttl),
            "Token issued less than TTL seconds ago must NOT be reported as expired"
        )
    }

    // MARK: - T-TTL-03

    /// WHY: the boundary is > (strictly greater), not >=. A token issued exactly
    /// TTL seconds ago is on the boundary and must still be deliverable so that
    /// devices with perfectly timed polls are not wrongly rejected.
    func test_isPendingTokenExpired_exactBoundary_isFalse() {
        let issuedAt = Date(timeIntervalSince1970: 1_000_000)
        let now      = issuedAt.addingTimeInterval(Self.ttl)   // exactly at TTL
        XCTAssertFalse(
            LocalAuthAdapter.isPendingTokenExpired(issuedAt: issuedAt, now: now, ttl: Self.ttl),
            "Token at exactly TTL seconds must NOT be expired (boundary is exclusive)"
        )
    }

    // MARK: - T-TTL-04

    /// WHY: the sweep must be selective — only expired entries are removed;
    /// fresh entries survive unchanged. A sweep that discards all entries
    /// (or discards none) would silently break TTL guarantees.
    func test_sweepExpiredPendingTokens_removesExpiredKeepsFresh() {
        let t0      = Date(timeIntervalSince1970: 2_000_000)
        let now     = t0.addingTimeInterval(Self.ttl + 60)   // 60 s past TTL

        let expiredEntry = makeEntry(issuedAt: t0)                                // issued at t0 -> expired
        let freshEntry   = makeEntry(issuedAt: now.addingTimeInterval(-10))       // issued 10 s ago -> fresh

        let tokens: [String: (deviceId: String, token: String, issuedAt: Date)] = [
            "expired-req": expiredEntry,
            "fresh-req":   freshEntry
        ]

        let result = LocalAuthAdapter.sweepExpiredPendingTokens(tokens, now: now, ttl: Self.ttl)

        XCTAssertNil(result["expired-req"],
                     "sweepExpiredPendingTokens must remove entries whose issuedAt is past TTL")
        XCTAssertNotNil(result["fresh-req"],
                        "sweepExpiredPendingTokens must retain entries whose issuedAt is within TTL")
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - T-TTL-05

    /// WHY: empty input is a common steady-state; the sweep must not crash or
    /// return anything unexpected.
    func test_sweepExpiredPendingTokens_emptyInput_returnsEmpty() {
        let result = LocalAuthAdapter.sweepExpiredPendingTokens([:], now: Date(), ttl: Self.ttl)
        XCTAssertTrue(result.isEmpty,
                      "sweepExpiredPendingTokens on empty input must return empty output")
    }

    // MARK: - T-TTL-08

    /// WHY: all-expired map must become empty after sweep. Validates the filter
    /// direction (keep-if-not-expired, not keep-if-expired).
    func test_sweepExpiredPendingTokens_allExpired_returnsEmpty() {
        let t0  = Date(timeIntervalSince1970: 3_000_000)
        let now = t0.addingTimeInterval(Self.ttl + 1)

        let tokens: [String: (deviceId: String, token: String, issuedAt: Date)] = [
            "r1": makeEntry(issuedAt: t0),
            "r2": makeEntry(issuedAt: t0.addingTimeInterval(-60)),
            "r3": makeEntry(issuedAt: t0.addingTimeInterval(-120))
        ]

        let result = LocalAuthAdapter.sweepExpiredPendingTokens(tokens, now: now, ttl: Self.ttl)
        XCTAssertTrue(result.isEmpty,
                      "sweepExpiredPendingTokens must remove all entries when all are expired")
    }

    // MARK: - T-TTL-06 (integration)

    /// WHY: if a device stops polling after approval, the in-RAM token would
    /// leak indefinitely (pre-fix). This test simulates the leak by back-dating
    /// the issuedAt via a test-only hook path, then confirms that
    /// pairingRequestStatus withholds the token once TTL has elapsed.
    /// If the TTL check were absent, `liveToken` would be non-nil and a device
    /// resuming after >TTL could still authenticate — a silent auth bypass.
    func test_pairingRequestStatus_pastTTL_tokenIsNil() throws {
        let auth = try makeAuth()
        auth.onPairingRequest = { _ in }

        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-TTL-06") else {
            return XCTFail("createPairingRequest must succeed on a fresh DB")
        }
        auth.approvePairingRequest(reqId)

        // Reach into the pendingTokens dictionary and back-date the issuedAt by
        // more than TTL so the lazy sweep inside pairingRequestStatus will treat
        // the entry as expired.
        auth.testBackdatePendingToken(requestId: reqId, by: LocalAuthAdapter.pendingTokenTTL + 1)

        guard let result = auth.pairingRequestStatus(requestId: reqId) else {
            return XCTFail("pairingRequestStatus must return a row even when token is expired")
        }
        XCTAssertEqual(result.status, "approved",
                       "Status must remain 'approved' even when the pending token has expired")
        XCTAssertNil(result.token,
                     "Token must be nil when the pending entry is older than TTL — the device must re-pair")
    }

    // MARK: - T-TTL-07 (integration)

    /// WHY: normal pairing (device polls within seconds) must not be broken by
    /// the TTL check. A fresh entry must still deliver the token.
    func test_pairingRequestStatus_freshToken_tokenDelivered() throws {
        let auth = try makeAuth()
        auth.onPairingRequest = { _ in }

        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-TTL-07") else {
            return XCTFail("createPairingRequest must succeed on a fresh DB")
        }
        auth.approvePairingRequest(reqId)

        guard let result = auth.pairingRequestStatus(requestId: reqId) else {
            return XCTFail("pairingRequestStatus must return a result after approval")
        }
        XCTAssertEqual(result.status, "approved")
        XCTAssertNotNil(result.token,
                        "Fresh pending token must be delivered on first poll (TTL not yet elapsed)")
    }
}

// testBackdatePendingToken is defined in LocalAuthAdapter.swift under #if DEBUG.
