import XCTest
@testable import Persistence

/// PERF: last_seen debounce + retention pruning for audit_log / pairing_codes / pairing_requests.
///
/// WHY these tests matter:
///   (a) Without debounce, every authenticated HTTP request issues a WAL write
///       (UPDATE last_seen_at). At high request rates this keeps WAL frames from
///       being checkpointed and wastes I/O. The debounce gate must let writes
///       through only when the stored value is genuinely stale.
///   (b) audit_log / pairing_codes / pairing_requests have no retention policy,
///       so they grow without bound. A device that produces many audited requests
///       or a user who creates many pairing codes will accumulate rows forever.
///       The prune method must enforce both an age cutoff and a row cap.

final class DeviceTrustRetentionTests: XCTestCase {

    // MARK: - shouldUpdateLastSeen pure helper

    // WHY: within the threshold window the caller should skip the UPDATE so
    // rapid back-to-back HTTP requests do not each produce a WAL write.
    func test_shouldUpdateLastSeen_withinThreshold_returnsFalse() {
        let prev = Date(timeIntervalSince1970: 1_000_000)
        let now  = prev.addingTimeInterval(30)   // 30 s elapsed, threshold = 60 s
        XCTAssertFalse(
            DeviceTrustRepository.shouldUpdateLastSeen(prev: prev, now: now, threshold: 60),
            "last_seen UPDATE must be skipped when prev is within the debounce threshold"
        )
    }

    // WHY: once the threshold has elapsed the write is appropriate so the
    // stored last_seen drifts by at most threshold seconds, not arbitrarily.
    func test_shouldUpdateLastSeen_pastThreshold_returnsTrue() {
        let prev = Date(timeIntervalSince1970: 1_000_000)
        let now  = prev.addingTimeInterval(61)   // 61 s elapsed, threshold = 60 s
        XCTAssertTrue(
            DeviceTrustRepository.shouldUpdateLastSeen(prev: prev, now: now, threshold: 60),
            "last_seen UPDATE must be issued when prev is older than the debounce threshold"
        )
    }

    // WHY: nil prev (device never seen) must always write — the first touch
    // must always be recorded, regardless of threshold.
    func test_shouldUpdateLastSeen_nilPrev_alwaysReturnsTrue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(
            DeviceTrustRepository.shouldUpdateLastSeen(prev: nil, now: now, threshold: 60),
            "nil prev (never seen) must always trigger a last_seen write"
        )
    }

    // WHY: exact-threshold boundary — elapsed == threshold is not strictly greater,
    // so the write should still be skipped (debounce is >=, not >).
    func test_shouldUpdateLastSeen_exactlyAtThreshold_returnsFalse() {
        let prev = Date(timeIntervalSince1970: 1_000_000)
        let now  = prev.addingTimeInterval(60)   // exactly at threshold
        XCTAssertFalse(
            DeviceTrustRepository.shouldUpdateLastSeen(prev: prev, now: now, threshold: 60),
            "elapsed == threshold is within the window; the write must still be skipped"
        )
    }

    // MARK: - verify() debounce integration

    // WHY: calling verify() many times within the threshold window must not
    // update last_seen_at in the DB each time — only the first call (nil prev)
    // and the call after the threshold elapses should write.
    func test_verify_doesNotUpdateLastSeen_withinThreshold() throws {
        let repo = try freshRepo()
        let t0   = Date(timeIntervalSince1970: 1_000_000)
        let iso  = ISO8601DateFormatter()
        let code = try repo.createPairingCode(ttlSeconds: 60, at: t0)
        let (device, token) = try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "phone"))

        // First verify at t0 — prev is nil, so last_seen is written.
        _ = try XCTUnwrap(try repo.verify(token: token, threshold: 60, now: t0))

        // Read what was stored after the first verify (should be t0).
        let db = repo.db
        let readSt = try db.prepare("SELECT last_seen_at FROM device_trust WHERE id = ?;")
        try readSt.bind(1, device.id)
        _ = try readSt.step()
        let afterFirst = try XCTUnwrap(iso.date(from: readSt.columnText(0) ?? ""))
        XCTAssertEqual(afterFirst.timeIntervalSince1970, t0.timeIntervalSince1970,
                       accuracy: 1.0, "first verify (nil prev) must write last_seen = t0")

        // Second verify 30 s later (within 60 s threshold) — must NOT overwrite.
        let t1 = t0.addingTimeInterval(30)
        _ = try XCTUnwrap(try repo.verify(token: token, threshold: 60, now: t1))

        // Confirm the DB row still holds t0, not t1.
        let readSt2 = try db.prepare("SELECT last_seen_at FROM device_trust WHERE id = ?;")
        try readSt2.bind(1, device.id)
        _ = try readSt2.step()
        let afterSecond = try XCTUnwrap(iso.date(from: readSt2.columnText(0) ?? ""))
        XCTAssertEqual(afterSecond.timeIntervalSince1970, t0.timeIntervalSince1970,
                       accuracy: 1.0,
                       "verify() within the debounce threshold must not write a new last_seen_at to the DB")
    }

    // MARK: - pruneDeviceTrustTables retention

    private func freshRepo() throws -> DeviceTrustRepository {
        let tmp = NSTemporaryDirectory() + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return DeviceTrustRepository(db: db)
    }

    // WHY: audit_log rows older than the age cutoff must be pruned so
    // the table cannot grow indefinitely over a long-lived server session.
    func test_pruneAuditLog_removesOldRows_keepsRecent() throws {
        let repo = try freshRepo()
        let now  = Date(timeIntervalSince1970: 2_000_000)
        let old  = now.addingTimeInterval(-8 * 86_400)   // 8 days ago
        let age  = TimeInterval(7 * 86_400)              // 7-day cutoff

        // Insert 2 old rows directly via audit()
        try repo.audit(actor: nil, action: "login", detail: nil, at: old)
        try repo.audit(actor: nil, action: "login", detail: nil, at: old)
        // Insert 1 recent row
        try repo.audit(actor: nil, action: "login", detail: nil, at: now)

        let removed = try repo.pruneDeviceTrustTables(
            auditMaxAge: age,
            auditMaxRows: 1000,
            pairingMaxAge: 0,   // don't touch pairing tables in this test
            now: now
        )

        let remaining = try repo.listAuditLog(limit: 100)
        XCTAssertEqual(remaining.count, 1,
                       "2 old audit_log rows must be pruned, leaving only the recent row")
        XCTAssertGreaterThanOrEqual(removed, 2,
                                    "pruneDeviceTrustTables must report >= 2 removed rows")
    }

    // WHY: the row cap applies independently of age — if rows exceed the cap
    // even within the age window the oldest must be trimmed so the table stays bounded.
    func test_pruneAuditLog_rowCap_removesOldestWhenOverCap() throws {
        let repo = try freshRepo()
        let now  = Date(timeIntervalSince1970: 2_000_000)
        let age  = TimeInterval(30 * 86_400)  // 30-day age window (all rows are recent)

        // Insert 5 rows, all recent
        for i in 0..<5 {
            let ts = now.addingTimeInterval(-TimeInterval(i * 60))  // 0, 1, 2, 3, 4 min ago
            try repo.audit(actor: nil, action: "ev\(i)", detail: nil, at: ts)
        }

        _ = try repo.pruneDeviceTrustTables(
            auditMaxAge: age,
            auditMaxRows: 3,    // cap at 3
            pairingMaxAge: 0,
            now: now
        )

        let remaining = try repo.listAuditLog(limit: 100)
        XCTAssertEqual(remaining.count, 3,
                       "row cap must trim audit_log to at most 3 rows, keeping the newest")
    }

    // WHY: pairing_codes older than the age cutoff (whether redeemed, expired,
    // or never used) must be pruned so the table cannot grow without bound.
    func test_prunePairingCodes_removesExpiredOldRows() throws {
        let repo = try freshRepo()
        let now  = Date(timeIntervalSince1970: 2_000_000)
        let age  = TimeInterval(2 * 86_400)   // 2-day cutoff

        // Create an old code (expires_at in the distant past)
        _ = try repo.createPairingCode(ttlSeconds: -3 * 86_400 - 1, at: now.addingTimeInterval(-3 * 86_400))
        // Create a recent code (created just now)
        let recent = try repo.createPairingCode(ttlSeconds: 600, at: now)

        _ = try repo.pruneDeviceTrustTables(
            auditMaxAge: 0,
            auditMaxRows: 1000,
            pairingMaxAge: age,
            now: now
        )

        // The old code must be gone; the recent code must survive.
        // Verify via the raw DB since there is no public "listPairingCodes".
        let st = try repo.db.prepare("SELECT code FROM pairing_codes;")
        var codes: [String] = []
        while try st.step() { codes.append(st.columnText(0) ?? "") }
        XCTAssertEqual(codes, [recent.code],
                       "only the recent pairing code must remain; old code must be pruned, recent code must survive")
    }

    // WHY: decided pairing_requests (approved/denied) older than the age
    // cutoff must be pruned. Pending requests must never be pruned (they are
    // still actionable).
    func test_prunePairingRequests_removesOldDecided_keepsPending() throws {
        let repo = try freshRepo()
        let now  = Date(timeIntervalSince1970: 2_000_000)
        let age  = TimeInterval(2 * 86_400)   // 2-day cutoff
        let iso  = ISO8601DateFormatter()
        let oldCreatedAt = iso.string(from: now.addingTimeInterval(-3 * 86_400))
        let oldExpiresAt = iso.string(from: now.addingTimeInterval(-3 * 86_400 + 300))
        let db = repo.db

        // Insert an old approved pairing_request directly (bypasses wall-clock
        // expiry check in approvePairingRequest which would block a past-TTL approve).
        let approvedId = UUID().uuidString
        let insApproved = try db.prepare("""
            INSERT INTO pairing_requests(id, code, device_name, created_at, expires_at, status)
            VALUES(?, '000001', 'old-device', ?, ?, 'approved');
        """)
        try insApproved.bind(1, approvedId)
        try insApproved.bind(2, oldCreatedAt)
        try insApproved.bind(3, oldExpiresAt)
        _ = try insApproved.step()

        // Insert an old denied pairing_request directly.
        let deniedId = UUID().uuidString
        let insDenied = try db.prepare("""
            INSERT INTO pairing_requests(id, code, device_name, created_at, expires_at, status)
            VALUES(?, '000002', 'denied-device', ?, ?, 'denied');
        """)
        try insDenied.bind(1, deniedId)
        try insDenied.bind(2, oldCreatedAt)
        try insDenied.bind(3, oldExpiresAt)
        _ = try insDenied.step()

        // Pending request created at `now` — must survive.
        let pending = try repo.createPairingRequest(deviceName: "pending-device", ttlSeconds: 300, at: now)

        _ = try repo.pruneDeviceTrustTables(
            auditMaxAge: 0,
            auditMaxRows: 1000,
            pairingMaxAge: age,
            now: now
        )

        let st = try db.prepare("SELECT id, status FROM pairing_requests;")
        var rows: [(String, String)] = []
        while try st.step() {
            rows.append((st.columnText(0) ?? "", st.columnText(1) ?? ""))
        }
        let ids = rows.map(\.0)
        let statuses = Dictionary(uniqueKeysWithValues: rows)
        XCTAssertTrue(ids.contains(pending.id),
                      "pending pairing_request must never be pruned by retention")
        XCTAssertFalse(ids.contains(approvedId),
                       "old approved pairing_request must be pruned")
        XCTAssertFalse(ids.contains(deniedId),
                       "old denied pairing_request must be pruned")
        XCTAssertEqual(statuses[pending.id], "pending",
                       "surviving pending request must retain pending status")
    }

    // WHY: running prune on empty tables must not throw. The cadence job fires
    // unconditionally; it must be safe when all tables are empty.
    func test_pruneDeviceTrustTables_emptyTablesIsNoop() throws {
        let repo = try freshRepo()
        let now  = Date(timeIntervalSince1970: 1_000_000)
        let removed = try repo.pruneDeviceTrustTables(
            auditMaxAge: TimeInterval(7 * 86_400),
            auditMaxRows: 500,
            pairingMaxAge: TimeInterval(2 * 86_400),
            now: now
        )
        XCTAssertEqual(removed, 0,
                       "pruneDeviceTrustTables on empty tables must be a no-op (removed=0)")
    }
}
