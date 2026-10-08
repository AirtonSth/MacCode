import XCTest
@testable import AppShell
@testable import Persistence
@testable import SocketServer

/// A trust lookup that fails on storage is not the same answer as an unknown
/// bearer. The HTTP gates turn "unknown" into 401, which the phone latches as
/// "pair again" and stops reconnecting, so the adapter must let a caller tell
/// the two apart.
@MainActor
final class LocalAuthAdapterLookupFailureTests: XCTestCase {

    /// A bare database, not `AppContext`: its background writers could consume
    /// the injected result code before the lookup does.
    private func makeAuth() throws -> (LocalAuthAdapter, DeviceTrustRepository, SQLiteDB) {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        let repo = DeviceTrustRepository(db: db)
        return (LocalAuthAdapter(repo: repo), repo, db)
    }

    /// WHY: only a throw may mean "retry"; nil must stay reserved for a bearer
    /// the Mac really does not trust. A failed lookup must also not be
    /// remembered as "unknown", and the non-throwing entry point keeps
    /// rejecting on a storage error (a bearer is never accepted unverified).
    func test_resolveRPCPrincipal_throwsOnStorageError_andReturnsNilOnlyForAnUnknownBearer() throws {
        let (auth, repo, db) = try makeAuth()
        let request = try repo.createPairingRequest(deviceName: "phone")
        let approved = try XCTUnwrap(try repo.approvePairingRequest(id: request.id))

        db.injectedResultCodesForTesting = [10] // SQLITE_IOERR
        XCTAssertThrowsError(try auth.resolveRPCPrincipal(token: approved.token),
                             "a storage error is not an unknown bearer")
        XCTAssertTrue(db.injectedResultCodesForTesting.isEmpty, "the lookup hit the injected failure")

        db.injectedResultCodesForTesting = [10] // SQLITE_IOERR
        XCTAssertNil(auth.authorizedRPCPrincipal(token: approved.token),
                     "the non-throwing lookup still rejects when storage fails")
        XCTAssertTrue(db.injectedResultCodesForTesting.isEmpty, "the lookup hit the injected failure")

        XCTAssertNil(try auth.resolveRPCPrincipal(token: "not-a-token"),
                     "an unknown bearer is nil, not an error")
        let principal = try XCTUnwrap(try auth.resolveRPCPrincipal(token: approved.token),
                                      "the failed lookups were not remembered as unknown")
        XCTAssertEqual(
            principal.ownerFingerprint,
            LocalAuthAdapter.opaqueAuthorizedOwnerFingerprint(
                stableIdentity: "token:\(approved.0.tokenHash)"
            )
        )
        XCTAssertEqual(principal.grantedCapabilities, approved.0.capabilities)
        repo.drainLastSeenWritesForTesting()
    }
}
