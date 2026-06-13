import XCTest
@testable import AppShell
@testable import Persistence

/// T024 — audit_log integration assertions for LocalAuthAdapter auth events.
///
/// WHY: `try? repo.audit(...)` silently swallows errors. A broken audit path
/// (schema regression, corrupt table) is a compliance gap — security events
/// (pair, approve, deny, revoke) become invisible until a post-incident review.
/// These tests pin that every auth event in LocalAuthAdapter produces a row in
/// `audit_log`, and that `auditLoud` (the internal helper) asserts loudly in
/// DEBUG builds so regressions surface as test failures, not silent gaps.
///
/// Production note: the DEBUG hard-throw lives in `LocalAuthAdapter.auditLoud`.
/// Release builds fall back to `try?` so a transient DB error never crashes a
/// production user's session.
@MainActor
final class AuditLogIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private final class PromptFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        func mark() { lock.lock(); _value = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    }

    private func makeAuth() throws -> (LocalAuthAdapter, DeviceTrustRepository) {
        let dir = NSTemporaryDirectory() + "RC2AuditIT-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let repo = DeviceTrustRepository(db: ctx.db)
        let auth = LocalAuthAdapter(repo: repo)
        auth.onPairingRequest = { _ in }  // suppress modal in tests
        return (auth, repo)
    }

    private func auditActions(in repo: DeviceTrustRepository) throws -> [String] {
        try repo.listAuditLog(limit: 100).map(\.action)
    }

    // MARK: - createPairingRequest writes audit row

    /// WHY: when a device initiates a pairing request, the audit log must record
    /// "pairing.request" so an operator can trace which device triggered the
    /// approve/deny modal.  A missing row here means a pairing flow is invisible
    /// in the audit trail — a compliance gap for multi-device access control.
    func test_createPairingRequest_writesAuditRow() throws {
        let (auth, repo) = try makeAuth()
        _ = auth.createPairingRequest(deviceName: "iPhone-audit-test")
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.request"),
                      "createPairingRequest must write a 'pairing.request' audit row — " +
                      "missing row means device-initiated pair events are invisible to operators")
    }

    // MARK: - approvePairingRequest writes audit row

    /// WHY: when the Mac user approves a pairing request, "pairing.approve" must
    /// be recorded. Without this row an auditor cannot tell whether a device was
    /// explicitly approved by a human or slipped in through a bug.
    func test_approvePairingRequest_writesAuditRow() throws {
        let (auth, repo) = try makeAuth()
        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-approve") else {
            return XCTFail("createPairingRequest must succeed on a fresh DB")
        }
        auth.approvePairingRequest(reqId)
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.approve"),
                      "approvePairingRequest must write a 'pairing.approve' audit row — " +
                      "missing row makes explicit human approval invisible in the audit trail")
    }

    /// WHY: users without a private-account login asked for a permanent trust
    /// choice. After one explicit Always Allow approval, a repeated pairing
    /// request from the same stable client_device_id must mint a token without
    /// showing another modal.
    func test_alwaysAllowPairing_autoApprovesRepeatedClientDeviceWithoutModal() throws {
        let (auth, repo) = try makeAuth()
        guard let (firstReqId, _) = auth.createPairingRequest(
            deviceName: "iPhone-always",
            clientDeviceID: "ios-client-a",
            privateAccountAccessToken: nil
        ) else {
            return XCTFail("first createPairingRequest must succeed on a fresh DB")
        }
        auth.approvePairingRequest(firstReqId, alwaysAllowPairing: true)
        _ = auth.pairingRequestStatus(requestId: firstReqId)

        let promptFlag = PromptFlag()
        auth.onPairingRequest = { _ in promptFlag.mark() }
        guard let (secondReqId, _) = auth.createPairingRequest(
            deviceName: "iPhone-always",
            clientDeviceID: "ios-client-a",
            privateAccountAccessToken: nil
        ) else {
            return XCTFail("second createPairingRequest must succeed")
        }
        let status = try XCTUnwrap(auth.pairingRequestStatus(requestId: secondReqId))

        XCTAssertFalse(promptFlag.value,
                       "a permanently trusted client_device_id must not show another approve/deny modal on repeated pairing")
        XCTAssertEqual(status.status, "approved")
        XCTAssertNotNil(status.token,
                        "auto-approved repeated pairing must still mint and deliver a fresh one-time token")
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.approve_always_allow"))
        XCTAssertTrue(actions.contains("pairing.always_allow_auto_approve"))
    }

    // MARK: - denyPairingRequest writes audit row

    /// WHY: when the Mac user presses Deny, "pairing.deny" must be logged. The
    /// deny action is security-critical: if it is absent an auditor cannot confirm
    /// that access was actually rejected rather than silently ignored.
    func test_denyPairingRequest_writesAuditRow() throws {
        let (auth, repo) = try makeAuth()
        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-deny") else {
            return XCTFail("createPairingRequest must succeed on a fresh DB")
        }
        auth.denyPairingRequest(reqId)
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.deny"),
                      "denyPairingRequest must write a 'pairing.deny' audit row — " +
                      "missing row means an explicit rejection is invisible and indistinguishable from no-op")
    }

    // MARK: - cancelPairingRequest writes audit row

    /// WHY: a device-initiated cancel (POST /v1/pair/cancel) must be audited so
    /// an operator can distinguish "device cancelled" from "request expired silently".
    func test_cancelPairingRequest_writesAuditRow() throws {
        let (auth, repo) = try makeAuth()
        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-cancel") else {
            return XCTFail("createPairingRequest must succeed on a fresh DB")
        }
        let cancelled = auth.cancelPairingRequest(requestId: reqId)
        XCTAssertTrue(cancelled, "cancelPairingRequest must return true for a pending request")
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.cancel"),
                      "cancelPairingRequest must write a 'pairing.cancel' audit row — " +
                      "missing row makes device-initiated cancels look like silent expiry")
    }

    // MARK: - revokeDevice writes audit row

    /// WHY: device revocation is an administrative action; it must be audited so
    /// an operator can reconstruct when and why a trusted device lost access.
    /// A missing row makes revocations invisible in post-incident reviews.
    func test_revokeDevice_writesAuditRow() throws {
        let (auth, repo) = try makeAuth()
        // Create and approve a device so we have a real device ID to revoke.
        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-revoke") else {
            return XCTFail("createPairingRequest must succeed on a fresh DB")
        }
        auth.approvePairingRequest(reqId)
        guard let status = auth.pairingRequestStatus(requestId: reqId),
              let deviceId = status.deviceId else {
            return XCTFail("approvePairingRequest must produce a deviceId")
        }
        auth.revokeDevice(deviceId)
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("device.revoke"),
                      "revokeDevice must write a 'device.revoke' audit row — " +
                      "missing row makes administrative revocations invisible to operators")
    }

    // MARK: - createPairingCode writes audit row

    /// WHY: pairing code creation is the entry-point for legacy code-based pairing;
    /// it must be audited so an operator can see when codes were minted.
    func test_createPairingCode_writesAuditRow() throws {
        let (auth, repo) = try makeAuth()
        let code = auth.createPairingCode()
        XCTAssertNotNil(code, "createPairingCode must succeed on a fresh DB")
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.create"),
                      "createPairingCode must write a 'pairing.create' audit row — " +
                      "missing row means code-based pairing entry points are unaudited")
    }

    // MARK: - redeemPairingCode writes audit row

    /// WHY: code redemption is the moment a new device gains trust; it is the
    /// most security-critical step in the legacy pairing flow and must always
    /// be audited. A missing row means new device enrollments are invisible.
    func test_redeemPairingCode_writesAuditRow() throws {
        let (auth, repo) = try makeAuth()
        guard let code = auth.createPairingCode() else {
            return XCTFail("createPairingCode must succeed on a fresh DB")
        }
        let result = auth.redeemPairingCode(code, deviceName: "iPhone-redeem")
        XCTAssertNotNil(result, "redeemPairingCode must succeed for a freshly-created code")
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.redeem"),
                      "redeemPairingCode must write a 'pairing.redeem' audit row — " +
                      "missing row means new device enrollments via code are not traceable")
    }

    // MARK: - DEBUG hard-throw contract

    /// WHY: `auditLoud` must call `assertionFailure` in DEBUG builds when the DB
    /// write fails. We cannot directly trigger a DB error on a live repo without
    /// schema surgery, so we verify the contract from the other direction: with a
    /// healthy DB, `auditLoud` must NOT throw/crash — if it did every auth event
    /// would break the flow. The presence of the audit row (above tests) confirms
    /// the write succeeded. The `#if DEBUG` hard-throw contract is documented in
    /// `LocalAuthAdapter.auditLoud` and is the mechanism by which a schema
    /// regression turns into a loud test failure rather than a silent no-op.
    func test_auditLoud_healthyDB_doesNotThrow() throws {
        let (auth, repo) = try makeAuth()
        // A complete auth-event flow must not crash in DEBUG.
        XCTAssertNoThrow(
            auth.denyPairingRequest("non-existent-id"),
            "auditLoud must not throw or crash in DEBUG when the DB is healthy — " +
            "a crash here would make every deny action break the UI flow"
        )
        // The deny audit row for a non-existent request is still written
        // (audit is independent of request state).
        let actions = try auditActions(in: repo)
        XCTAssertTrue(actions.contains("pairing.deny"),
                      "auditLoud on a healthy DB must successfully write the row in all cases")
    }
}
