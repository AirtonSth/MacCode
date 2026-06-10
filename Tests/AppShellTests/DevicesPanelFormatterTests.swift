import XCTest
import Persistence
@testable import AppShell

/// Tests for the pure Devices-panel view-model helpers:
/// DeviceRowFormatter and AuditLogRowFormatter.
///
/// All tests are value-type pure: no AppContext, no DB, no MainActor.
/// Tests encode business rules, not just current output (Rule 8).
final class DevicesPanelFormatterTests: XCTestCase {

    // MARK: - Shared fixtures

    private let iso: ISO8601DateFormatter = ISO8601DateFormatter()
    private let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// A fixed "now" so relative-time assertions are deterministic.
    private let now = Date(timeIntervalSince1970: 1_749_470_400) // 2025-06-09T12:00:00Z

    private func makeDevice(
        id: String = "abc12345-0000-0000-0000-000000000000",
        name: String = "Sam's iPhone",
        createdAt: Date? = nil,
        lastSeenAt: Date? = nil,
        revokedAt: Date? = nil
    ) -> DeviceTrust {
        DeviceTrust(
            id: id,
            displayName: name,
            tokenHash: "fakehash",
            createdAt: createdAt ?? Date(timeIntervalSince1970: 1_749_384_000),
            lastSeenAt: lastSeenAt,
            revokedAt: revokedAt
        )
    }

    // MARK: - DeviceRowFormatter.title

    /// Title must show the display name followed by the first 8 chars of the id
    /// in parentheses so users can identify devices that share a name (e.g. two
    /// iPhones named "iPhone") by their distinct id prefix.
    func test_title_containsNameAndIdPrefix() {
        let d = makeDevice(id: "abc12345-0000-0000-0000-000000000000", name: "Sam's iPhone")
        let title = DeviceRowFormatter.title(d)
        XCTAssertTrue(title.contains("Sam's iPhone"),
                      "title must include the display name so the user recognises their device")
        XCTAssertTrue(title.contains("abc12345"),
                      "title must include the 8-char id prefix to distinguish same-named devices")
    }

    /// A device whose name is empty must still produce a non-empty title rather
    /// than just the id prefix with no label — guards against blank display names
    /// from old firmware that sends an empty string.
    func test_title_emptyName_stillIncludesIdPrefix() {
        let d = makeDevice(id: "zzz99999-0000-0000-0000-000000000000", name: "")
        let title = DeviceRowFormatter.title(d)
        XCTAssertTrue(title.contains("zzz99999"),
                      "title must expose the id prefix even when display name is empty")
    }

    // MARK: - DeviceRowFormatter.subtitle

    /// Subtitle for a device that has never connected after pairing must contain
    /// the paired date and NOT the \"seen\" segment, so the user knows the device
    /// paired but never used.
    func test_subtitle_noLastSeen_omitsSeenSegment() {
        let pairedAt = Date(timeIntervalSince1970: 1_749_384_000)
        let d = makeDevice(createdAt: pairedAt, lastSeenAt: nil, revokedAt: nil)
        let sub = DeviceRowFormatter.subtitle(d, isoFormatter: iso, relativeFormatter: relative, now: now)
        XCTAssertTrue(sub.contains("paired"),
                      "subtitle must include 'paired' prefix so the date is contextually clear")
        XCTAssertFalse(sub.contains("seen"),
                       "subtitle must omit the 'seen' segment when lastSeenAt is nil")
    }

    /// Subtitle for a device that has connected must contain a relative \"seen\"
    /// string so the user can tell at a glance how recently the device was active.
    func test_subtitle_withLastSeen_includesSeenSegment() {
        let pairedAt = Date(timeIntervalSince1970: 1_749_384_000)
        let seenAt = now.addingTimeInterval(-3600) // 1 hour ago
        let d = makeDevice(createdAt: pairedAt, lastSeenAt: seenAt, revokedAt: nil)
        let sub = DeviceRowFormatter.subtitle(d, isoFormatter: iso, relativeFormatter: relative, now: now)
        XCTAssertTrue(sub.contains("seen"),
                      "subtitle must include 'seen' when lastSeenAt is set so users know the device is active")
    }

    /// A revoked device must have \"revoked\" in its subtitle so the badge state
    /// is also encoded in the text (screen-reader accessibility + copy-paste).
    func test_subtitle_revokedDevice_containsRevokedLabel() {
        let d = makeDevice(revokedAt: now.addingTimeInterval(-60))
        let sub = DeviceRowFormatter.subtitle(d, isoFormatter: iso, relativeFormatter: relative, now: now)
        XCTAssertTrue(sub.contains("revoked"),
                      "subtitle must include 'revoked' so the device state is readable without the pill UI")
    }

    // MARK: - DeviceRowFormatter.isRevoked

    /// A device with revokedAt nil must not be flagged as revoked — guards
    /// against accidentally hiding the Revoke button for active devices.
    func test_isRevoked_activeDevice_returnsFalse() {
        let d = makeDevice(revokedAt: nil)
        XCTAssertFalse(DeviceRowFormatter.isRevoked(d),
                       "isRevoked must return false for an active (non-revoked) device")
    }

    /// A device with a non-nil revokedAt must be flagged as revoked — the UI
    /// shows a pill and hides the Revoke button for these rows.
    func test_isRevoked_revokedDevice_returnsTrue() {
        let d = makeDevice(revokedAt: now)
        XCTAssertTrue(DeviceRowFormatter.isRevoked(d),
                      "isRevoked must return true so the UI renders the revoked pill instead of the Revoke button")
    }

    // MARK: - Revoked-row filter (pure array logic)

    /// Filtering a mixed list to only revoked rows must yield exactly the
    /// revoked devices. This mirrors the business rule that \"Delete Revoked\"
    /// must not touch active devices.
    func test_revokedFilter_onlyReturnsRevokedRows() {
        let active = makeDevice(id: "aaaa1111-0000-0000-0000-000000000000", name: "Active", revokedAt: nil)
        let revoked = makeDevice(id: "bbbb2222-0000-0000-0000-000000000000", name: "Revoked", revokedAt: now)
        let devices = [active, revoked]
        let result = devices.filter { DeviceRowFormatter.isRevoked($0) }
        XCTAssertEqual(result.count, 1,
                       "filter must return exactly one revoked device from a list of one active + one revoked")
        XCTAssertEqual(result.first?.id, "bbbb2222-0000-0000-0000-000000000000",
                       "filter must return the revoked device, not the active one")
    }

    /// An all-active list must produce an empty revoked subset so \"Delete Revoked\"
    /// is hidden and no device is erroneously deleted.
    func test_revokedFilter_allActiveDevices_returnsEmpty() {
        let devices = [
            makeDevice(id: "aa-0", name: "A", revokedAt: nil),
            makeDevice(id: "bb-0", name: "B", revokedAt: nil),
        ]
        let result = devices.filter { DeviceRowFormatter.isRevoked($0) }
        XCTAssertTrue(result.isEmpty,
                      "filter must return empty when all devices are active — no rows should be deleteable")
    }

    // MARK: - AuditLogRowFormatter.line

    private func makeEntry(
        id: Int64 = 1,
        ts: Date? = nil,
        actor: String? = "device",
        action: String = "pairing.redeem",
        detail: String? = "MyPhone"
    ) -> AuditLogEntry {
        AuditLogEntry(
            id: id,
            ts: ts ?? now,
            actor: actor,
            action: action,
            detail: detail
        )
    }

    /// Audit line must contain the ISO timestamp so users see when each event
    /// occurred — a log without timestamps is useless for security review.
    func test_auditLine_containsTimestamp() {
        let entry = makeEntry(ts: now)
        let line = AuditLogRowFormatter.line(entry, isoFormatter: iso)
        let expected = iso.string(from: now)
        XCTAssertTrue(line.contains(expected),
                      "audit log line must contain the ISO timestamp for traceability")
    }

    /// Audit line must contain the action so users can identify what happened
    /// (e.g. \"pairing.revoke\" vs \"pairing.redeem\").
    func test_auditLine_containsAction() {
        let entry = makeEntry(action: "device.revoke")
        let line = AuditLogRowFormatter.line(entry, isoFormatter: iso)
        XCTAssertTrue(line.contains("device.revoke"),
                      "audit log line must contain the action so users can read what happened")
    }

    /// When actor is present it must appear in the line so users know which
    /// actor (device id / \"system\" / \"user\") triggered the event.
    func test_auditLine_withActor_containsActor() {
        let entry = makeEntry(actor: "system")
        let line = AuditLogRowFormatter.line(entry, isoFormatter: iso)
        XCTAssertTrue(line.contains("system"),
                      "audit log line must include the actor so the security trail is attributable")
    }

    /// When actor is nil (e.g. an anonymous event) the line must still be valid
    /// and must NOT produce literal \"nil\" or \"Optional(...)\" output.
    func test_auditLine_nilActor_doesNotLeakOptionalString() {
        let entry = makeEntry(actor: nil)
        let line = AuditLogRowFormatter.line(entry, isoFormatter: iso)
        XCTAssertFalse(line.contains("nil"),
                       "audit log line must not print literal 'nil' when actor is absent")
        XCTAssertFalse(line.contains("Optional"),
                       "audit log line must not print 'Optional(...)' when actor is absent")
    }

    /// When detail is nil the line must still be valid and not contain
    /// \"nil\"/\"Optional\".
    func test_auditLine_nilDetail_doesNotLeakOptionalString() {
        let entry = makeEntry(detail: nil)
        let line = AuditLogRowFormatter.line(entry, isoFormatter: iso)
        XCTAssertFalse(line.contains("nil"),
                       "audit log line must not print literal 'nil' when detail is absent")
    }

    /// A fully-populated entry (actor + detail) must contain all four fields
    /// so no information is silently dropped.
    func test_auditLine_allFieldsPresent_allFieldsInLine() {
        let entry = makeEntry(ts: now, actor: "acc123", action: "pairing.approve", detail: "SamPhone")
        let line = AuditLogRowFormatter.line(entry, isoFormatter: iso)
        XCTAssertTrue(line.contains(iso.string(from: now)), "timestamp missing")
        XCTAssertTrue(line.contains("acc123"), "actor missing")
        XCTAssertTrue(line.contains("pairing.approve"), "action missing")
        XCTAssertTrue(line.contains("SamPhone"), "detail missing")
    }
}
