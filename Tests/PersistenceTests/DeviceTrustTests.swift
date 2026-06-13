import XCTest
@testable import Persistence

final class DeviceTrustTests: XCTestCase {
    func test_pairAndRedeem_yieldsToken_thatVerifies() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = DeviceTrustRepository(db: db)
        let code = try repo.createPairingCode(ttlSeconds: 60)
        let result = try repo.redeemPairingCode(code.code, deviceName: "phone")
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.0.displayName, "phone")
        let verified = try XCTUnwrap(try repo.verify(token: unwrapped.token))
        XCTAssertEqual(verified.id, unwrapped.0.id)
    }

    func test_expiredPairingCode_failsRedeem() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = DeviceTrustRepository(db: db)
        let code = try repo.createPairingCode(ttlSeconds: -10)
        let result = try repo.redeemPairingCode(code.code, deviceName: "x")
        XCTAssertNil(result)
    }

    func test_revokedDevice_failsVerify() throws {
        let tmp = NSTemporaryDirectory() + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        let repo = DeviceTrustRepository(db: db)
        let code = try repo.createPairingCode()
        let result = try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "x"))
        try repo.revoke(id: result.0.id)
        XCTAssertNil(try repo.verify(token: result.token))
    }

    private func freshRepo() throws -> DeviceTrustRepository {
        let tmp = NSTemporaryDirectory() + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return DeviceTrustRepository(db: db)
    }

    func test_requestApprove_mintsTokenThatVerifies() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "iPhone")
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.status, "pending")

        let approved = try XCTUnwrap(try repo.approvePairingRequest(id: req.id))
        XCTAssertEqual(approved.0.displayName, "iPhone")
        let verified = try XCTUnwrap(try repo.verify(token: approved.token))
        XCTAssertEqual(verified.id, approved.0.id)
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.status, "approved")

        // Approving twice must not mint a second device (single-use).
        XCTAssertNil(try repo.approvePairingRequest(id: req.id))
    }

    func test_requestDeny_blocksApproval() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "x")
        try repo.denyPairingRequest(id: req.id)
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.status, "denied")
        XCTAssertNil(try repo.approvePairingRequest(id: req.id))
    }

    func test_expiredRequest_cannotBeApproved() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "x", ttlSeconds: -10)
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.effectiveStatus, "expired")
        XCTAssertNil(try repo.approvePairingRequest(id: req.id))
    }

    /// WHY: "Always Allow" is meaningful only when the pre-token request carries
    /// a stable client_device_id. Approval must persist that id with the trusted
    /// device so a future tokenless pairing request from the same phone can be
    /// auto-approved without a private-account login.
    func test_approveAlwaysAllow_persistsClientDeviceIDAndAllowFlag() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "iPhone", clientDeviceID: "ios-client-1")

        let approved = try XCTUnwrap(try repo.approvePairingRequest(id: req.id, alwaysAllowPairing: true))

        XCTAssertEqual(approved.0.clientDeviceID, "ios-client-1")
        XCTAssertTrue(approved.0.alwaysAllowPairing,
                      "approving with Always Allow must persist the opt-in flag; otherwise future repeated pairing still prompts")
        let listed = try XCTUnwrap(try repo.list().first)
        XCTAssertEqual(listed.clientDeviceID, "ios-client-1")
        XCTAssertTrue(listed.alwaysAllowPairing)
    }

    /// WHY: if a device is explicitly trusted permanently, the auth adapter uses
    /// this lookup to decide whether a repeated tokenless request can be approved.
    /// Revoked rows must not qualify or a revoked phone could regain access.
    func test_alwaysAllowedPairingDevice_ignoresRevokedRows() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "iPhone", clientDeviceID: "ios-client-2")
        let approved = try XCTUnwrap(try repo.approvePairingRequest(id: req.id, alwaysAllowPairing: true))
        XCTAssertNotNil(try repo.alwaysAllowedPairingDevice(clientDeviceID: "ios-client-2"))

        try repo.revoke(id: approved.0.id)

        XCTAssertNil(try repo.alwaysAllowedPairingDevice(clientDeviceID: "ios-client-2"),
                     "revoking a trusted device must also remove its permanent auto-approve authority")
    }

    /// WHY: Settings needs a reversible control. Turning Always Allow off must
    /// immediately stop the lookup that auto-approves future pairing requests.
    func test_setAlwaysAllowPairing_canDisableAndEnableForKnownClientDevice() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "iPhone", clientDeviceID: "ios-client-3")
        let approved = try XCTUnwrap(try repo.approvePairingRequest(id: req.id, alwaysAllowPairing: true))

        try repo.setAlwaysAllowPairing(id: approved.0.id, enabled: false)
        XCTAssertNil(try repo.alwaysAllowedPairingDevice(clientDeviceID: "ios-client-3"))

        try repo.setAlwaysAllowPairing(id: approved.0.id, enabled: true)
        XCTAssertNotNil(try repo.alwaysAllowedPairingDevice(clientDeviceID: "ios-client-3"))
    }

    /// WHY: cancelling a pending request must report success and make the
    /// status terminal ('cancelled'), so a later /v1/pair/status returns the
    /// terminal state and the device stops polling. This is the backing
    /// invariant for POST /v1/pair/cancel.
    func test_cancelPendingRequest_makesStatusTerminal() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "iPhone")
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.status, "pending")

        XCTAssertTrue(try repo.cancelPairingRequest(id: req.id))
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.status, "cancelled")
    }

    /// WHY: cancel must be single-shot and must never resurrect a decided
    /// request. An unknown id, or a request already approved, must return
    /// false so the HTTP layer answers 404 instead of a false "cancelled".
    func test_cancelUnknownOrDecidedRequest_returnsFalse() throws {
        let repo = try freshRepo()
        XCTAssertFalse(try repo.cancelPairingRequest(id: "no-such-id"))

        let req = try repo.createPairingRequest(deviceName: "x")
        _ = try XCTUnwrap(try repo.approvePairingRequest(id: req.id))
        // Already approved -> cancel is a no-op and must not flip it back.
        XCTAssertFalse(try repo.cancelPairingRequest(id: req.id))
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.status, "approved")
    }

    /// WHY: an expired pending request is effectively gone; cancelling it
    /// must return false (404 at the wire) rather than transitioning a
    /// stale row, mirroring approve's expired guard.
    func test_cancelExpiredRequest_returnsFalse() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "x", ttlSeconds: -10)
        XCTAssertFalse(try repo.cancelPairingRequest(id: req.id))
    }
}
