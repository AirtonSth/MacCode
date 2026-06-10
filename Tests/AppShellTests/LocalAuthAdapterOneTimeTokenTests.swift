import XCTest
@testable import AppShell
@testable import Persistence

/// Tests for LocalAuthAdapter one-time-token paths T016-T018.
///
/// Coverage:
///   T016  -  denyPairingRequest sets status to "denied"; a subsequent
///           pairingRequestStatus returns "denied" with no token
///   T017  -  double-poll: pairingRequestStatus can be called twice after
///           approvePairingRequest; the token is returned on the FIRST poll
///           and is nil on the second (one-time delivery invariant)
///   T018-guard  -  an expired/unknown requestId returns nil from pairingRequestStatus
///
/// WHY: The one-time-token contract is security-critical.  A second caller
/// polling after the first must NOT receive the device token; if it did a
/// race-window attacker could steal an already-redeemed token.
/// AppIdentityNotificationTests line 175 covers auto-approve only; these
/// tests pin the deny path and the one-time-delivery invariant.
@MainActor
final class LocalAuthAdapterOneTimeTokenTests: XCTestCase {

    private func makeAuth() throws -> (LocalAuthAdapter, String) {
        let dir = NSTemporaryDirectory() + "RC2LocalAuthOTT-\(UUID().uuidString)"
        let ctx = try AppContext(channel: .debug, appSupportOverride: dir)
        let auth = LocalAuthAdapter(repo: DeviceTrustRepository(db: ctx.db))
        return (auth, dir)
    }

    // MARK: - T016: deny path

    /// WHY: When the Mac user presses "Deny", the pairing request must move to
    /// "denied" so a subsequent device poll (pairingRequestStatus) gets back
    /// "denied" with no token. If deny silently no-ops, the request stays
    /// "pending" forever and the device poll loop never terminates cleanly.
    func test_denyPairingRequest_status_becomesdDenied_noToken() throws {
        let (auth, _) = try makeAuth()
        var promptedPrompt: PairingPrompt?
        auth.onPairingRequest = { promptedPrompt = $0 }

        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-T016") else {
            return XCTFail("createPairingRequest must succeed on a fresh DB")
        }
        XCTAssertNotNil(promptedPrompt,
                        "Without a private account session, createPairingRequest must call onPairingRequest so the Mac user can approve or deny")

        auth.denyPairingRequest(reqId)

        guard let result = auth.pairingRequestStatus(requestId: reqId) else {
            return XCTFail("pairingRequestStatus must return a row even after deny  -  the device must receive 'denied', not nil (which it cannot distinguish from a network timeout)")
        }

        XCTAssertEqual(result.status, "denied",
                       "After denyPairingRequest the status must be 'denied' so the device stops polling and shows 'Pairing was denied'")
        XCTAssertNil(result.token,
                     "A denied request must never yield a token  -  yielding one would allow the device to pair despite the user's explicit rejection")
    }

    // MARK: - T017: one-time token delivery (double-poll)

    /// WHY: the pending-token map (`pendingTokens`) in LocalAuthAdapter uses
    /// `removeValue(forKey:)` so the token is consumed on first retrieval.
    /// If `removeValue` were replaced by a plain subscript read, the second
    /// caller would also receive the token, breaking the one-time contract.
    /// This test encodes that invariant mechanically.
    func test_approvePairingRequest_tokenDeliveredOnce_nilOnSecondPoll() throws {
        let (auth, _) = try makeAuth()
        auth.onPairingRequest = { _ in }   // suppress the modal in tests

        guard let (reqId, _) = auth.createPairingRequest(deviceName: "iPhone-T017") else {
            return XCTFail("createPairingRequest must succeed")
        }

        // Approve from the Mac modal side.
        auth.approvePairingRequest(reqId)

        // First poll  -  must return "approved" with a non-nil token.
        guard let first = auth.pairingRequestStatus(requestId: reqId) else {
            return XCTFail("pairingRequestStatus must return a result after approval")
        }
        XCTAssertEqual(first.status, "approved",
                       "Status must be 'approved' after approvePairingRequest  -  the device must see this to proceed")
        XCTAssertNotNil(first.token,
                        "First poll after approval must yield the one-time token so the device can authenticate future RPC calls")

        // Second poll  -  must return "approved" (status is persisted) but token must be nil.
        guard let second = auth.pairingRequestStatus(requestId: reqId) else {
            return XCTFail("pairingRequestStatus must still return a row on second poll; returning nil would leave the device in limbo")
        }
        XCTAssertEqual(second.status, "approved",
                       "Status remains 'approved' on subsequent polls  -  the device may retry once and must not see 'pending'")
        XCTAssertNil(second.token,
                     "Token must be nil on second poll  -  the one-time-delivery invariant prevents a race-window attacker from stealing an already-redeemed token")
    }

    // MARK: - T018-guard: unknown requestId returns nil

    /// WHY: pairingRequestStatus must return nil for a requestId that was never
    /// created, so callers can distinguish "pending" from "not found" without
    /// special-casing. Returning a synthetic "denied" row for unknown IDs would
    /// allow an attacker to probe whether a given UUID was ever issued.
    func test_pairingRequestStatus_unknownId_returnsNil() throws {
        let (auth, _) = try makeAuth()
        let result = auth.pairingRequestStatus(requestId: UUID().uuidString)
        XCTAssertNil(result,
                     "pairingRequestStatus must return nil for an unknown requestId  -  " +
                     "returning any row would expose whether a given UUID was ever issued")
    }
}
