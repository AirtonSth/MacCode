import CryptoKit
import XCTest
@testable import AppShell
@testable import Persistence
@testable import SocketServer

/// Pins LocalAuthAdapter's authorized-owner fingerprint to the verified bearer,
/// never to Mac identity or client-supplied pairing metadata.
@MainActor
final class LocalAuthAdapterOwnerFingerprintTests: XCTestCase {

    private func makeAuth() throws -> (LocalAuthAdapter, DeviceTrustRepository, String) {
        let dir = NSTemporaryDirectory() + "RC2LocalAuthOwnerFP-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let repo = DeviceTrustRepository(db: ctx.db)
        let auth = LocalAuthAdapter(repo: repo)
        return (auth, repo, dir)
    }

    /// WHY: HTTP authorization must depend only on the bearer while preserving
    /// a revocation-checkable, non-secret durable fingerprint.
    func test_authorizedOwnerFingerprint_usesTokenHashWithoutMacIdentity() throws {
        let (auth, repo, dir) = try makeAuth()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        auth.onPairingRequest = { _ in }

        let req = try repo.createPairingRequest(deviceName: "iPhone-no-client-id")
        let approved = try XCTUnwrap(try repo.approvePairingRequest(id: req.id))
        let token = approved.token
        let tokenHash = approved.0.tokenHash

        let fingerprint = try XCTUnwrap(auth.authorizedOwnerFingerprint(token: token))
        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertTrue(fingerprint.allSatisfy(\.isHexDigit))
        XCTAssertEqual(
            fingerprint,
            LocalAuthAdapter.opaqueAuthorizedOwnerFingerprint(
                stableIdentity: "token:\(tokenHash)"
            )
        )
        XCTAssertNotEqual(fingerprint, token)
        XCTAssertFalse(fingerprint.contains(approved.0.id))
        XCTAssertEqual(
            auth.authorizedOwnerFingerprint(token: token),
            fingerprint,
            "same authorized device must keep a stable fingerprint"
        )
        XCTAssertNil(
            auth.authorizedOwnerFingerprint(token: "not-a-real-token"),
            "invalid tokens must not produce an owner fingerprint"
        )
        // The upload fingerprint is domain-separated from general connection
        // ownership even though both derive only from the verified bearer.
        XCTAssertNotEqual(
            fingerprint,
            DirectHTTPServer.connectionOwnerFingerprint(token: token)
        )
    }

    /// WHY: separate bearer tokens must remain separate upload owners even when
    /// client-supplied pairing metadata is byte-identical.
    func test_authorizedOwnerFingerprint_doesNotMergeTokensWithSameClientDeviceID() throws {
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
                stableIdentity: "token:\(first.0.tokenHash)"
            )
        )
        XCTAssertFalse(firstFP.contains(clientDeviceID))
        XCTAssertEqual(
            secondFP,
            LocalAuthAdapter.opaqueAuthorizedOwnerFingerprint(
                stableIdentity: "token:\(second.0.tokenHash)"
            ),
            "each verified bearer is its own security principal"
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
