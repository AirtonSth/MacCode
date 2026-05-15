import Foundation
import CryptoKit

public struct DeviceTrust: Codable, Sendable, Equatable {
    public let id: String
    public var displayName: String
    public var tokenHash: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var revokedAt: Date?
    public var capabilities: String

    public init(id: String, displayName: String, tokenHash: String, createdAt: Date = Date(), lastSeenAt: Date? = nil, revokedAt: Date? = nil, capabilities: String = "*") {
        self.id = id; self.displayName = displayName; self.tokenHash = tokenHash
        self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.revokedAt = revokedAt
        self.capabilities = capabilities
    }
}

public struct PairingCode: Codable, Sendable, Equatable {
    public let code: String
    public let createdAt: Date
    public let expiresAt: Date
    public var redeemedAt: Date?
    public var redeemedDeviceID: String?
}

public final class DeviceTrustRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    private let iso = ISO8601DateFormatter()

    public static func hash(_ token: String) -> String {
        let d = SHA256.hash(data: Data(token.utf8))
        return d.map { String(format: "%02x", $0) }.joined()
    }

    public static func generateToken() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    public func createPairingCode(ttlSeconds: TimeInterval = 600) throws -> PairingCode {
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let now = Date()
        let exp = now.addingTimeInterval(ttlSeconds)
        let st = try db.prepare("""
            INSERT INTO pairing_codes(code, created_at, expires_at) VALUES(?, ?, ?);
        """)
        try st.bind(1, code)
        try st.bind(2, iso.string(from: now))
        try st.bind(3, iso.string(from: exp))
        _ = try st.step()
        return PairingCode(code: code, createdAt: now, expiresAt: exp, redeemedAt: nil, redeemedDeviceID: nil)
    }

    public func redeemPairingCode(_ code: String, deviceName: String) throws -> (DeviceTrust, token: String)? {
        let st = try db.prepare("SELECT expires_at, redeemed_at FROM pairing_codes WHERE code = ?;")
        try st.bind(1, code)
        guard try st.step() else { return nil }
        let expS = st.columnText(0) ?? ""
        let redeemed = st.columnText(1)
        guard let exp = iso.date(from: expS), exp > Date(), redeemed == nil else { return nil }

        let deviceId = UUID().uuidString
        let token = DeviceTrustRepository.generateToken()
        let hash = DeviceTrustRepository.hash(token)
        let now = Date()
        let now_s = iso.string(from: now)

        let ins = try db.prepare("""
            INSERT INTO device_trust(id, display_name, token_hash, created_at, capabilities)
            VALUES(?, ?, ?, ?, '*');
        """)
        try ins.bind(1, deviceId); try ins.bind(2, deviceName)
        try ins.bind(3, hash); try ins.bind(4, now_s)
        _ = try ins.step()

        let upd = try db.prepare("UPDATE pairing_codes SET redeemed_at = ?, redeemed_device_id = ? WHERE code = ?;")
        try upd.bind(1, now_s); try upd.bind(2, deviceId); try upd.bind(3, code)
        _ = try upd.step()

        let trust = DeviceTrust(id: deviceId, displayName: deviceName, tokenHash: hash, createdAt: now)
        return (trust, token: token)
    }

    public func verify(token: String) throws -> DeviceTrust? {
        let hash = DeviceTrustRepository.hash(token)
        let st = try db.prepare("SELECT id, display_name, created_at, last_seen_at, revoked_at, capabilities FROM device_trust WHERE token_hash = ? AND revoked_at IS NULL;")
        try st.bind(1, hash)
        if try st.step() {
            let id = st.columnText(0) ?? ""
            let name = st.columnText(1) ?? ""
            let createdAt = iso.date(from: st.columnText(2) ?? "") ?? Date()
            let lastSeen = (st.columnText(3)).flatMap { iso.date(from: $0) }
            let revoked = (st.columnText(4)).flatMap { iso.date(from: $0) }
            let caps = st.columnText(5) ?? "*"
            // Touch last_seen_at
            let touch = try db.prepare("UPDATE device_trust SET last_seen_at = ? WHERE id = ?;")
            try touch.bind(1, iso.string(from: Date())); try touch.bind(2, id)
            _ = try touch.step()
            return DeviceTrust(id: id, displayName: name, tokenHash: hash, createdAt: createdAt, lastSeenAt: lastSeen, revokedAt: revoked, capabilities: caps)
        }
        return nil
    }

    public func list() throws -> [DeviceTrust] {
        let st = try db.prepare("SELECT id, display_name, token_hash, created_at, last_seen_at, revoked_at, capabilities FROM device_trust ORDER BY created_at DESC;")
        var out: [DeviceTrust] = []
        while try st.step() {
            out.append(DeviceTrust(
                id: st.columnText(0) ?? "",
                displayName: st.columnText(1) ?? "",
                tokenHash: st.columnText(2) ?? "",
                createdAt: iso.date(from: st.columnText(3) ?? "") ?? Date(),
                lastSeenAt: (st.columnText(4)).flatMap { iso.date(from: $0) },
                revokedAt: (st.columnText(5)).flatMap { iso.date(from: $0) },
                capabilities: st.columnText(6) ?? "*"
            ))
        }
        return out
    }

    public func revoke(id: String) throws {
        let st = try db.prepare("UPDATE device_trust SET revoked_at = ? WHERE id = ?;")
        try st.bind(1, iso.string(from: Date())); try st.bind(2, id)
        _ = try st.step()
    }

    public func audit(actor: String?, action: String, detail: String?) throws {
        let st = try db.prepare("INSERT INTO audit_log(ts, actor, action, detail) VALUES(?, ?, ?, ?);")
        try st.bind(1, iso.string(from: Date()))
        try st.bind(2, actor)
        try st.bind(3, action)
        try st.bind(4, detail)
        _ = try st.step()
    }
}
