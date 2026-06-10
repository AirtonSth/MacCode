import XCTest
@testable import Persistence

/// P2 - Atomic, single-use pairing operations.
///
/// WHY these tests matter: `redeemPairingCode` and `approvePairingRequest`
/// each mint a device-trust token. If the check->insert->update sequence is
/// not atomic, two racing redeems of the SAME 6-digit code (or two racing
/// approvals of the same request) can BOTH pass the "not yet redeemed" check
/// before either commits, minting two trusted devices from a single-use
/// secret. That is a real privilege-escalation hole over LAN pairing. These
/// tests pin the contract that a code/request is claimable EXACTLY ONCE even
/// under concurrent callers, and that a repeat call is a no-op (returns nil,
/// mints nothing). They are deterministic: no sleeps, no wall-clock expiry.
final class PairingAtomicityTests: XCTestCase {

    private func freshRepo() throws -> DeviceTrustRepository {
        let tmp = NSTemporaryDirectory() + UUID().uuidString
        addTeardownBlock { try? FileManager.default.removeItem(atPath: tmp) }
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: tmp).run()
        return DeviceTrustRepository(db: db)
    }

    // MARK: redeem

    /// Serial double-redeem: the second redeem of an already-claimed code must
    /// fail (nil) and must NOT create a second device_trust row.
    func test_redeem_secondAttempt_failsAndMintsNoSecondDevice() throws {
        let repo = try freshRepo()
        let code = try repo.createPairingCode(ttlSeconds: 60)

        let first = try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "phone"))
        let second = try repo.redeemPairingCode(code.code, deviceName: "phone")

        XCTAssertNil(second, "a single-use code must not redeem twice")
        // Exactly one device exists, and it is the one the first redeem minted.
        let devices = try repo.list()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, first.0.id)
    }

    /// Concurrent double-redeem: many threads race to redeem ONE code. Exactly
    /// one must succeed; all others must see nil. Proves the claim is atomic,
    /// not merely guarded by a pre-read that both racers can pass.
    func test_redeem_concurrent_succeedsExactlyOnce() throws {
        let repo = try freshRepo()
        let code = try repo.createPairingCode(ttlSeconds: 60)

        let successes = SuccessCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "redeem.race", attributes: .concurrent)
        let start = DispatchSemaphore(value: 0)

        let racers = 8
        for i in 0..<racers {
            group.enter()
            queue.async {
                start.wait()
                if let r = try? repo.redeemPairingCode(code.code, deviceName: "dev-\(i)") {
                    if r != nil { successes.increment() }
                }
                group.leave()
            }
        }
        // Release all racers at once to maximize overlap.
        for _ in 0..<racers { start.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "race did not finish")

        XCTAssertEqual(successes.value, 1, "exactly one concurrent redeem must win")
        XCTAssertEqual(try repo.list().count, 1, "only one device may be minted")
    }

    // MARK: approve

    /// Idempotent approve: approving the same request twice mints one device.
    func test_approve_secondAttempt_isNoOp() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "iPhone")

        let first = try XCTUnwrap(try repo.approvePairingRequest(id: req.id))
        let second = try repo.approvePairingRequest(id: req.id)

        XCTAssertNil(second, "approve must be idempotent")
        let devices = try repo.list()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, first.0.id)
    }

    /// Concurrent approve: many threads race to approve ONE request. Exactly
    /// one wins; the request ends 'approved' bound to the winner's device.
    func test_approve_concurrent_succeedsExactlyOnce() throws {
        let repo = try freshRepo()
        let req = try repo.createPairingRequest(deviceName: "iPhone")

        let successes = SuccessCounter()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "approve.race", attributes: .concurrent)
        let start = DispatchSemaphore(value: 0)

        let racers = 8
        for _ in 0..<racers {
            group.enter()
            queue.async {
                start.wait()
                if let r = try? repo.approvePairingRequest(id: req.id), r != nil {
                    successes.increment()
                }
                group.leave()
            }
        }
        for _ in 0..<racers { start.signal() }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "race did not finish")

        XCTAssertEqual(successes.value, 1, "exactly one concurrent approve must win")
        XCTAssertEqual(try repo.list().count, 1, "only one device may be minted")
        XCTAssertEqual(try repo.pairingRequest(id: req.id)?.status, "approved")
    }
}

/// Tiny lock-guarded counter so concurrent racers can tally successes without
/// a data race in the test harness itself.
private final class SuccessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
