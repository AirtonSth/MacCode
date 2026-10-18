import XCTest
@testable import Persistence

/// A device's relay key authorizes end-to-end relay streams, so it must exist only
/// for non-revoked devices and disappear the moment the device is revoked.
final class RelayKeysTests: XCTestCase {
    private func make() throws -> (SQLiteDB, DeviceTrustRepository) {
        let path = NSTemporaryDirectory() + UUID().uuidString
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: path).run()
        return (db, DeviceTrustRepository(db: db))
    }

    private func pairDevice(_ repo: DeviceTrustRepository) throws -> String {
        let code = try repo.createPairingCode()
        return try XCTUnwrap(try repo.redeemPairingCode(code.code, deviceName: "phone")).0.id
    }

    func testMigrationAddsRelayColumnAtV98() throws {
        let (db, _) = try make()
        XCTAssertEqual(Schema.relayKeysSchemaVersion, 98)
        XCTAssertEqual(Schema.steps.last?.version, Schema.currentVersion)
        let columns = try db.performSync { database -> [String] in
            let st = try database.prepare("PRAGMA table_info(device_trust);")
            defer { st.reset() }
            var names: [String] = []
            while try st.step() { names.append(st.columnText(1) ?? "") }
            return names
        }
        XCTAssertTrue(columns.contains("relay_public_key"))
    }

    func testKeyResolvesToItsDeviceAndRevokeClearsIt() throws {
        let (_, repo) = try make()
        let id = try pairDevice(repo)
        let key = Data(repeating: 9, count: 32)
        XCTAssertNil(try repo.deviceIdForRelayKey(key))
        try repo.setRelayPublicKey(deviceId: id, key: key)
        XCTAssertEqual(try repo.deviceIdForRelayKey(key), id)
        try repo.revoke(id: id)
        XCTAssertNil(try repo.deviceIdForRelayKey(key), "a revoked device must not keep relay access")
        try repo.setRelayPublicKey(deviceId: id, key: key)
        XCTAssertNil(try repo.deviceIdForRelayKey(key), "a revoked device cannot be given a new key")
    }

    func testOnlyTheOwningDeviceMatches() throws {
        let (_, repo) = try make()
        let a = try pairDevice(repo), b = try pairDevice(repo)
        let ka = Data(repeating: 1, count: 32), kb = Data(repeating: 2, count: 32)
        try repo.setRelayPublicKey(deviceId: a, key: ka)
        try repo.setRelayPublicKey(deviceId: b, key: kb)
        XCTAssertEqual(try repo.deviceIdForRelayKey(ka), a)
        XCTAssertEqual(try repo.deviceIdForRelayKey(kb), b)
        try repo.revoke(id: a)
        XCTAssertEqual(try repo.deviceIdForRelayKey(kb), b)
    }
}
