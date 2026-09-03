import XCTest
@testable import AppShell
@testable import Persistence

/// SEC-001 — `pairing.create` must not persist the six-digit pairing code
/// (or the bearer redeem will mint) in `audit_log.detail`.
///
/// WHY: `LocalAuthAdapter.createPairingCode()` used to audit `detail: p.code`.
/// The code stays valid for ten minutes, and Settings renders audit detail, so
/// a screen-share, log export, or DB copy leaked a live pairing secret.
/// The row must still exist (action, actor, timestamp) with result `created`
/// and an opaque correlation id only.
@MainActor
final class PairingAuditRedactionTests: XCTestCase {

    private func makeAuth() throws -> (LocalAuthAdapter, DeviceTrustRepository) {
        let dir = NSTemporaryDirectory() + "RC2PairingAuditRedact-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: dir).run()
        let repo = DeviceTrustRepository(db: db)
        return (LocalAuthAdapter(repo: repo), repo)
    }

    private func pairingCreateEntries(in repo: DeviceTrustRepository) throws -> [AuditLogEntry] {
        try repo.listAuditLog(limit: 100).filter { $0.action == "pairing.create" }
    }

    // MARK: - Sentinel: minted code never appears in pairing.create detail

    /// WHY: if `detail` still holds the live six-digit code, anyone who can
    /// read Settings → audit log or copy `audit_log` can redeem the device
    /// for the remaining TTL. The returned code (whatever `createPairingCode`
    /// minted, including a value such as `123456`) must not appear, and the
    /// detail must not contain any standalone six-digit token.
    func test_createPairingCode_auditDetail_doesNotContainPairingCodeOrSixDigitToken() throws {
        let (auth, repo) = try makeAuth()
        let code = try XCTUnwrap(auth.createPairingCode(),
                                 "createPairingCode must succeed on a fresh DB")
        XCTAssertEqual(code.count, 6, "pairing codes are six digits; a different shape would hide a leak from the six-digit sentinel")
        XCTAssertTrue(code.allSatisfy(\.isNumber),
                      "pairing codes are numeric; a non-digit code would evade \\b\\d{6}\\b")

        let entries = try pairingCreateEntries(in: repo)
        XCTAssertFalse(entries.isEmpty,
                       "createPairingCode must still write a pairing.create audit row — redaction is not omission")

        let sixDigitWord = try NSRegularExpression(pattern: #"\b\d{6}\b"#)
        for entry in entries {
            let detail = try XCTUnwrap(entry.detail,
                                       "pairing.create detail must exist (result + opaque id), not be nil-as-redaction")
            XCTAssertFalse(detail.contains(code),
                           "pairing.create detail must not contain the minted code \(code); leaked detail=\(detail)")
            let nsRange = NSRange(detail.startIndex..<detail.endIndex, in: detail)
            XCTAssertEqual(
                sixDigitWord.numberOfMatches(in: detail, range: nsRange),
                0,
                "pairing.create detail must not contain a standalone six-digit token; leaked detail=\(detail)"
            )
        }
    }

    // MARK: - Positive contract: result + opaque correlation id

    /// WHY: operators still need to see that a code was minted and to correlate
    /// the event. Result `created` plus a UUID (not the code, not a bearer)
    /// keeps the trail without storing the secret. Timestamp and action live
    /// on the row itself.
    func test_createPairingCode_auditDetail_isCreatedResultAndOpaqueUUID() throws {
        let (auth, repo) = try makeAuth()
        _ = try XCTUnwrap(auth.createPairingCode())

        let entries = try pairingCreateEntries(in: repo)
        XCTAssertEqual(entries.count, 1, "one createPairingCode call must write exactly one pairing.create row")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.actor, "system")
        XCTAssertEqual(entry.action, "pairing.create")
        XCTAssertEqual(entry.ts.timeIntervalSinceNow, 0, accuracy: 5,
                       "pairing.create must stamp a current timestamp on the audit row")

        let detail = try XCTUnwrap(entry.detail, "pairing.create detail must not be nil — result and correlation id belong there")
        XCTAssertTrue(detail.hasPrefix("created corr="),
                      "detail must start with result 'created' and an opaque corr= id; got \(detail)")
        let correlationId = String(detail.dropFirst("created corr=".count))
        XCTAssertNotNil(UUID(uuidString: correlationId),
                        "correlation id must be a UUID, not the pairing code or a bearer; got \(correlationId)")
        XCTAssertEqual(detail, "created corr=\(correlationId)")
    }

    /// WHY: a constant detail (or hashing the six-digit code — a 10^6 space)
    /// would either collapse events or remain brute-forceable. Distinct random
    /// UUIDs keep two mints distinguishable without encoding the secret.
    func test_createPairingCode_auditCorrelationIds_areUniquePerMint() throws {
        let (auth, repo) = try makeAuth()
        let firstCode = try XCTUnwrap(auth.createPairingCode())
        let secondCode = try XCTUnwrap(auth.createPairingCode())

        let entries = try pairingCreateEntries(in: repo)
        XCTAssertEqual(entries.count, 2)
        let details = try entries.map { try XCTUnwrap($0.detail) }
        XCTAssertEqual(Set(details).count, 2,
                       "each pairing.create row must have its own opaque correlation id")
        for code in [firstCode, secondCode] {
            for detail in details {
                XCTAssertFalse(detail.contains(code),
                               "neither mint's code (\(code)) may appear in any pairing.create detail (\(detail))")
            }
        }
    }

    /// WHY: redeem mints a bearer token. That secret must not land in the
    /// pairing.create row (already written) or in any other audit detail —
    /// Settings would display it the same way it used to display the code.
    func test_redeemPairingCode_auditDetails_doNotContainCodeOrBearer() throws {
        let (auth, repo) = try makeAuth()
        let code = try XCTUnwrap(auth.createPairingCode())
        let redeemed = try XCTUnwrap(auth.redeemPairingCode(code, deviceName: "iPhone-redact"),
                                     "redeemPairingCode must succeed for a freshly minted code")

        let entries = try repo.listAuditLog(limit: 100)
        XCTAssertTrue(entries.contains { $0.action == "pairing.create" })
        XCTAssertTrue(entries.contains { $0.action == "pairing.redeem" })
        for entry in entries {
            let detail = entry.detail ?? ""
            XCTAssertFalse(detail.contains(code),
                           "\(entry.action) detail must not contain the pairing code; leaked detail=\(detail)")
            XCTAssertFalse(detail.contains(redeemed.token),
                           "\(entry.action) detail must not contain the redeem bearer; leaked detail=\(detail)")
        }
    }

    /// WHY: the helper is the only formatter `createPairingCode` uses. If it
    /// ever interpolated a six-digit string, the integration sentinels would
    /// still catch a live mint, but this pins the shape independently of DB
    /// state so a formatter regression fails without opening a database.
    func test_pairingCreateAuditDetail_shape_isCreatedCorrUUID() {
        let detail = LocalAuthAdapter.pairingCreateAuditDetail()
        XCTAssertTrue(detail.hasPrefix("created corr="))
        let correlationId = String(detail.dropFirst("created corr=".count))
        XCTAssertNotNil(UUID(uuidString: correlationId))
        XCTAssertNil(detail.range(of: #"\d{6}"#, options: .regularExpression),
                     "formatter output must not contain six consecutive digits: \(detail)")
        let again = LocalAuthAdapter.pairingCreateAuditDetail()
        XCTAssertNotEqual(detail, again, "each call must mint a new correlation id")
    }
}
