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
}
