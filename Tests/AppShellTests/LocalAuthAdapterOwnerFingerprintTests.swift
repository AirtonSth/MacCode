import CryptoKit
import XCTest
@testable import AppShell
@testable import Persistence
@testable import SocketServer

/// Pins LocalAuthAdapter's authorized-owner fingerprint to the trusted row,
/// never to client-supplied pairing metadata.
@MainActor
final class LocalAuthAdapterOwnerFingerprintTests: XCTestCase {

    private func makeAuth() throws -> (LocalAuthAdapter, DeviceTrustRepository, String) {
        let dir = NSTemporaryDirectory() + "RC2LocalAuthOwnerFP-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let repo = DeviceTrustRepository(db: ctx.db)
        let auth = LocalAuthAdapter(repo: repo)
        return (auth, repo, dir)
    }

    /// WHY: without a clientDeviceID the durable owner must still be stable for
    /// the trusted device row, and must never echo raw ids or bearer material.
    func test_authorizedOwnerFingerprint_usesDeviceRowIdWhenNoClientDeviceID() throws {
        let (auth, repo, dir) = try makeAuth()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        auth.onPairingRequest = { _ in }

        let req = try repo.createPairingRequest(deviceName: "iPhone-no-client-id")
        let approved = try XCTUnwrap(try repo.approvePairingRequest(id: req.id))
        let token = approved.token
        let deviceId = approved.0.id

        let fingerprint = try XCTUnwrap(auth.authorizedOwnerFingerprint(token: token))
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertTrue(fingerprint.allSatisfy(\.isHexDigit))
        XCTAssertEqual(
            fingerprint,
            LocalAuthAdapter.opaqueAuthorizedOwnerFingerprint(
                stableIdentity: "device:\(deviceId)"
            )
        )
        XCTAssertNotEqual(fingerprint, token)
        XCTAssertFalse(fingerprint.contains(deviceId))
        XCTAssertEqual(
            auth.authorizedOwnerFingerprint(token: token),
            fingerprint,
            "same authorized device must keep a stable fingerprint"
        )
        XCTAssertNil(
            auth.authorizedOwnerFingerprint(token: "not-a-real-token"),
            "invalid tokens must not produce an owner fingerprint"
        )
        // Default token-derived path would change with bearer; stable path must not
        // equal a raw connectionOwnerFingerprint of the bearer when identity is used.
        XCTAssertNotEqual(
            fingerprint,
            DirectHTTPServer.connectionOwnerFingerprint(token: token)
        )
    }

    /// WHY: two devices can claim the same clientDeviceID. Separate trust rows
    /// must remain separate upload owners even when that untrusted string is
    /// byte-identical.
    func test_authorizedOwnerFingerprint_doesNotMergeRowsWithSameClientDeviceID() throws {
        let (auth, repo, dir) = try makeAuth()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        auth.onPairingRequest = { _ in }

        let clientDeviceID = "ios-client-\(UUID().uuidString)"

        let firstReq = try repo.createPairingRequest(
            deviceName: "iPhone-A",
            clientDeviceID: clientDeviceID
        )
        let first = try XCTUnwrap(try repo.approvePairingRequest(id: firstReq.id))
        let firstFP = try XCTUnwrap(auth.authorizedOwnerFingerprint(token: first.token))

        // Second approved pair for the same client device: new row id + new token.
        let secondReq = try repo.createPairingRequest(
            deviceName: "iPhone-A",
            clientDeviceID: clientDeviceID
        )
        let second = try XCTUnwrap(try repo.approvePairingRequest(id: secondReq.id))
        XCTAssertNotEqual(first.0.id, second.0.id, "re-pair mints a new device row")
        XCTAssertNotEqual(first.token, second.token, "re-pair mints a new bearer")
        XCTAssertEqual(first.0.clientDeviceID, clientDeviceID)
        XCTAssertEqual(second.0.clientDeviceID, clientDeviceID)

        let secondFP = try XCTUnwrap(auth.authorizedOwnerFingerprint(token: second.token))
        XCTAssertNotEqual(
            firstFP,
            secondFP,
            "client-supplied identity must not merge separate trusted rows"
        )
        XCTAssertEqual(
            firstFP,
            LocalAuthAdapter.opaqueAuthorizedOwnerFingerprint(
                stableIdentity: "device:\(first.0.id)"
            )
        )
        XCTAssertFalse(firstFP.contains(clientDeviceID))
        XCTAssertEqual(
            secondFP,
            LocalAuthAdapter.opaqueAuthorizedOwnerFingerprint(
                stableIdentity: "device:\(second.0.id)"
            ),
            "each approved row is its own security principal"
        )

        // A different client device stays isolated even with a valid token.
        let otherReq = try repo.createPairingRequest(
            deviceName: "iPhone-B",
            clientDeviceID: "ios-client-other-\(UUID().uuidString)"
        )
        let other = try XCTUnwrap(try repo.approvePairingRequest(id: otherReq.id))
        let otherFP = try XCTUnwrap(auth.authorizedOwnerFingerprint(token: other.token))
        XCTAssertNotEqual(firstFP, otherFP)
    }
}
