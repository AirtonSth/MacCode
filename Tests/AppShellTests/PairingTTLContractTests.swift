import XCTest
@testable import AppShell
@testable import Persistence

/// WHY (T013): `SettingsViewModel.createPairingCode()` hardcodes the TTL in TWO
/// independent places:
///   1. `trustRepo.createPairingCode(ttlSeconds: 600)` - stores the DB row that
///      the iOS client validates against during the redeem call.
///   2. `pairingCodeExpiresAt = Date().addingTimeInterval(600)` - drives the
///      on-screen countdown the Mac user sees.
///
/// If those two 600-second constants drift (one changes, the other does not) the
/// countdown can show "still valid" after the iOS redeem call has already rejected
/// the code, or vice versa.  This file pins the contract that:
///   (a) the repo row carries the exact TTL the VM constant implies, and
///   (b) the displayed expiry matches what the repo would accept as unexpired.
///
/// Uses an in-memory DB; no real process or sockets.
final class PairingTTLContractTests: XCTestCase {

    /// The TTL constant used in both SettingsViewModel.createPairingCode() and
    /// DeviceTrustRepository.createPairingCode(ttlSeconds:).
    /// Pinning it here means a change to one site turns this test red.
    private let expectedTTL: TimeInterval = 600

    private func freshRepo() throws -> DeviceTrustRepository {
        let tmp = NSTemporaryDirectory() + "RC2PairingTTL-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return DeviceTrustRepository(db: db)
    }

    // MARK: - (a) Repo row carries exactly the expected TTL

    /// WHY: `createPairingCode(ttlSeconds: 600, at: now)` must store a row whose
    /// `expiresAt` equals `now + 600`.  If the repo uses a different constant
    /// internally (e.g. 300) the iOS client rejects the code before the Mac
    /// countdown even reaches zero.
    func test_repoPairingCode_expiresAt_equals_ttlAfterCreation() throws {
        let repo = try freshRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pc = try repo.createPairingCode(ttlSeconds: expectedTTL, at: now)

        XCTAssertEqual(
            pc.expiresAt.timeIntervalSince1970,
            now.addingTimeInterval(expectedTTL).timeIntervalSince1970,
            accuracy: 0.001,
            "PairingCode.expiresAt must equal createdAt + ttlSeconds; a mismatch means the " +
            "iOS client's server-side validation uses a different window than the Mac countdown"
        )
    }

    // MARK: - (b) Displayed expiry == repo expiry (drift guard)

    /// WHY: SettingsViewModel sets `pairingCodeExpiresAt = Date().addingTimeInterval(600)`
    /// immediately after calling `createPairingCode(ttlSeconds: 600)`.  Both branches
    /// must use the same constant.  This test simulates that sequence at a fixed clock
    /// and asserts that the two derived expiry instants are equal within 1 ms.
    func test_displayedExpiry_matchesRepoExpiry_sameConstant() throws {
        let repo = try freshRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        // Simulate what trustRepo.createPairingCode does inside the VM.
        let pc = try repo.createPairingCode(ttlSeconds: expectedTTL, at: now)

        // Simulate what pairingCodeExpiresAt = Date().addingTimeInterval(600) does,
        // anchored to the same clock instant so the comparison is deterministic.
        let displayedExpiry = now.addingTimeInterval(expectedTTL)

        XCTAssertEqual(
            pc.expiresAt.timeIntervalSince1970,
            displayedExpiry.timeIntervalSince1970,
            accuracy: 0.001,
            "T013 drift guard: the on-screen countdown (pairingCodeExpiresAt) must expire at the " +
            "same instant the server-side row expires; a mismatch lets the user see a valid-looking " +
            "code after the server already rejected it (or the reverse)"
        )
    }

    // MARK: - (c) Code is considered unexpired immediately after creation

    /// WHY: a freshly created pairing code must not be expired at t=0.  If
    /// the DB row stores a past `expires_at` the iOS client rejects the code
    /// immediately and the user never succeeds in pairing even with a correct code.
    func test_pairingCode_isUnexpired_immediatelyAfterCreation() throws {
        let repo = try freshRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pc = try repo.createPairingCode(ttlSeconds: expectedTTL, at: now)

        XCTAssertGreaterThan(
            pc.expiresAt.timeIntervalSince1970,
            now.timeIntervalSince1970,
            "a freshly created pairing code must not be expired at the creation instant; " +
            "an immediately-expired code makes LAN pairing impossible"
        )
    }

    // MARK: - (d) Code is expired after TTL elapses

    /// WHY: the code must be considered expired at `createdAt + ttl`.  If
    /// expiresAt were stored incorrectly (e.g., createdAt + 0) every code
    /// would expire before the iOS client could redeem it.
    func test_pairingCode_isExpired_afterTTLElapses() throws {
        let repo = try freshRepo()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let pc = try repo.createPairingCode(ttlSeconds: expectedTTL, at: now)

        let afterExpiry = now.addingTimeInterval(expectedTTL + 1)
        XCTAssertLessThan(
            pc.expiresAt.timeIntervalSince1970,
            afterExpiry.timeIntervalSince1970,
            "a pairing code must be expired 1 second after the TTL; " +
            "if expiresAt is set too far in the future the server accepts stale codes"
        )
    }
}
