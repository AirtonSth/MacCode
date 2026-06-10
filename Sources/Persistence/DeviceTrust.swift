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

/// A device-initiated pairing request the Mac user must approve or deny
/// in a modal. `status` ∈ pending|approved|denied; `expired` is derived
/// from `expiresAt`, never stored, so a stale pending request can never
/// be approved after the fact.
public struct PairingRequest: Codable, Sendable, Equatable {
    public let id: String
    public let code: String
    public let deviceName: String
    public let createdAt: Date
    public let expiresAt: Date
    public var status: String
    public var deviceID: String?
    public var decidedAt: Date?

    public var isExpired: Bool { status == "pending" && expiresAt <= Date() }
    /// Status as the wire reports it (pending collapses to expired once TTL passes).
    public var effectiveStatus: String { isExpired ? "expired" : status }
}

/// Decision returned by `PairingThrottle.check`.
public enum PairingThrottleDecision: Sendable, Equatable {
    case allowed
    /// Peer is locked out; `retryAfter` seconds remain until the next attempt.
    case denied(retryAfter: TimeInterval)
}

/// Thread-safe brute-force defense for the LAN pairing surface.
///
/// A 6-digit pairing code (10^6 space) with a 10-minute TTL is trivially
/// brute-forceable over LAN if the redeem/request endpoints accept unlimited
/// attempts. This component throttles by *peer* (source IP): each failed
/// attempt grows an exponential backoff lockout, a success resets the peer,
/// and the number of simultaneously-outstanding pairing requests per peer is
/// capped so a single peer cannot flood the approve/deny queue.
///
/// Pure & deterministic given an injected `now`, so the backoff schedule is
/// directly testable without sleeping. All mutating ops take the internal
/// lock so it is safe to share across the server's per-connection threads.
public final class PairingThrottle: @unchecked Sendable {
    /// Failures before lockout begins. Below this, attempts are free so a
    /// legitimate mistyped code is never punished with a wait.
    public let freeAttempts: Int
    /// Backoff base after the free attempts are exhausted (seconds). Doubles
    /// per excess failure: base, 2·base, 4·base … capped at `maxBackoff`.
    public let baseBackoff: TimeInterval
    /// Upper bound on a single lockout window (seconds).
    public let maxBackoff: TimeInterval
    /// Max pairing requests a single peer may have outstanding at once.
    public let maxOutstandingPerPeer: Int

    private struct State {
        var failures: Int = 0
        var lockedUntil: Date?
        var outstanding: Int = 0
    }

    private let lock = NSLock()
    private var peers: [String: State] = [:]

    public init(freeAttempts: Int = 3,
                baseBackoff: TimeInterval = 2,
                maxBackoff: TimeInterval = 300,
                maxOutstandingPerPeer: Int = 5) {
        self.freeAttempts = freeAttempts
        self.baseBackoff = baseBackoff
        self.maxBackoff = maxBackoff
        self.maxOutstandingPerPeer = maxOutstandingPerPeer
    }

    /// Whether `peer` may attempt a redeem right now. Read-only: it never
    /// mutates the failure count (call `recordFailure`/`recordSuccess` for
    /// that) so a denied peer is not penalized merely for being checked.
    public func check(peer: String, now: Date = Date()) -> PairingThrottleDecision {
        lock.lock(); defer { lock.unlock() }
        guard let until = peers[peer]?.lockedUntil, until > now else { return .allowed }
        return .denied(retryAfter: until.timeIntervalSince(now))
    }

    /// Record a failed attempt and arm/extend the lockout. Returns the new
    /// decision (always `.denied` once past the free attempts).
    @discardableResult
    public func recordFailure(peer: String, now: Date = Date()) -> PairingThrottleDecision {
        lock.lock(); defer { lock.unlock() }
        var st = peers[peer] ?? State()
        st.failures += 1
        let excess = st.failures - freeAttempts
        if excess > 0 {
            // base · 2^(excess-1), capped.
            let raw = baseBackoff * pow(2, Double(excess - 1))
            let window = min(raw, maxBackoff)
            st.lockedUntil = now.addingTimeInterval(window)
            peers[peer] = st
            return .denied(retryAfter: window)
        }
        peers[peer] = st
        return .allowed
    }

    /// Clear all penalty + lockout for `peer` after a successful pairing so a
    /// device that finally pairs is not stuck behind a prior backoff. Keeps
    /// any outstanding-request reservations intact.
    public func recordSuccess(peer: String) {
        lock.lock(); defer { lock.unlock() }
        guard var st = peers[peer] else { return }
        st.failures = 0
        st.lockedUntil = nil
        peers[peer] = st
    }

    /// Reserve one outstanding-request slot for `peer`. Returns false (and
    /// reserves nothing) when the peer is already at `maxOutstandingPerPeer`.
    public func reserveOutstanding(peer: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var st = peers[peer] ?? State()
        guard st.outstanding < maxOutstandingPerPeer else { return false }
        st.outstanding += 1
        peers[peer] = st
        return true
    }

    /// Release one previously-reserved outstanding-request slot (clamped at 0).
    public func releaseOutstanding(peer: String) {
        lock.lock(); defer { lock.unlock() }
        guard var st = peers[peer] else { return }
        st.outstanding = max(0, st.outstanding - 1)
        peers[peer] = st
    }
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

    /// Internal sentinel: a guard inside a pairing transaction lost the
    /// single-use race (code already redeemed / request no longer pending /
    /// expired). Thrown to force the surrounding `db.transaction` to ROLLBACK,
    /// then translated back to a `nil` return so the public contract is
    /// unchanged. Never escapes this type.
    private struct PairingConflict: Error {}

    public func redeemPairingCode(_ code: String, deviceName: String) throws -> (DeviceTrust, token: String)? {
        let deviceId = UUID().uuidString
        let token = DeviceTrustRepository.generateToken()
        let hash = DeviceTrustRepository.hash(token)
        let now = Date()
        let now_s = iso.string(from: now)

        do {
            let trust: DeviceTrust = try db.transaction {
                // Atomic single-use gate: claim the code FIRST with a guarded
                // UPDATE. Under BEGIN IMMEDIATE writers are serialized, so a
                // second concurrent redeem of the same code sees redeemed_at
                // already set (or expiry passed) and matches zero rows. We do
                // NOT trust sqlite3_changes here (no accessor); instead we
                // read the claimant back and confirm it is *this* device.
                let upd = try db.prepare("""
                    UPDATE pairing_codes
                    SET redeemed_at = ?, redeemed_device_id = ?
                    WHERE code = ? AND redeemed_at IS NULL AND expires_at > ?;
                """)
                try upd.bind(1, now_s); try upd.bind(2, deviceId)
                try upd.bind(3, code); try upd.bind(4, now_s)
                _ = try upd.step()

                let chk = try db.prepare("SELECT redeemed_device_id FROM pairing_codes WHERE code = ?;")
                try chk.bind(1, code)
                guard try chk.step(), chk.columnText(0) == deviceId else {
                    // No such code, already redeemed by someone else, or expired.
                    throw PairingConflict()
                }

                let ins = try db.prepare("""
                    INSERT INTO device_trust(id, display_name, token_hash, created_at, capabilities)
                    VALUES(?, ?, ?, ?, '*');
                """)
                try ins.bind(1, deviceId); try ins.bind(2, deviceName)
                try ins.bind(3, hash); try ins.bind(4, now_s)
                _ = try ins.step()

                return DeviceTrust(id: deviceId, displayName: deviceName, tokenHash: hash, createdAt: now)
            }
            return (trust, token: token)
        } catch is PairingConflict {
            return nil
        }
    }

    // MARK: device-initiated request → user approves/denies in a modal

    /// Create a pending request. The 6-digit code is shown on BOTH the
    /// Mac modal and the device so the user can visually confirm they
    /// match before approving (anti-MITM, like Bluetooth pairing).
    public func createPairingRequest(deviceName: String, ttlSeconds: TimeInterval = 300) throws -> PairingRequest {
        let id = UUID().uuidString
        let code = String(format: "%06d", Int.random(in: 0..<1_000_000))
        let now = Date()
        let exp = now.addingTimeInterval(ttlSeconds)
        let st = try db.prepare("""
            INSERT INTO pairing_requests(id, code, device_name, created_at, expires_at, status)
            VALUES(?, ?, ?, ?, ?, 'pending');
        """)
        try st.bind(1, id); try st.bind(2, code); try st.bind(3, deviceName)
        try st.bind(4, iso.string(from: now)); try st.bind(5, iso.string(from: exp))
        _ = try st.step()
        return PairingRequest(id: id, code: code, deviceName: deviceName,
                              createdAt: now, expiresAt: exp, status: "pending")
    }

    public func pairingRequest(id: String) throws -> PairingRequest? {
        let st = try db.prepare("""
            SELECT code, device_name, created_at, expires_at, status, device_id, decided_at
            FROM pairing_requests WHERE id = ?;
        """)
        try st.bind(1, id)
        guard try st.step() else { return nil }
        return PairingRequest(
            id: id,
            code: st.columnText(0) ?? "",
            deviceName: st.columnText(1) ?? "",
            createdAt: iso.date(from: st.columnText(2) ?? "") ?? Date(),
            expiresAt: iso.date(from: st.columnText(3) ?? "") ?? Date(),
            status: st.columnText(4) ?? "pending",
            deviceID: st.columnText(5),
            decidedAt: (st.columnText(6)).flatMap { iso.date(from: $0) }
        )
    }

    /// Approve a pending, non-expired request: mint a device token and
    /// persist trust (hash only). Returns the plaintext token exactly
    /// once to the caller — it is never written to the DB.
    public func approvePairingRequest(id: String) throws -> (DeviceTrust, token: String)? {
        guard let req = try pairingRequest(id: id), req.status == "pending", !req.isExpired else { return nil }
        let deviceId = UUID().uuidString
        let token = DeviceTrustRepository.generateToken()
        let hash = DeviceTrustRepository.hash(token)
        let now = Date()
        let now_s = iso.string(from: now)

        do {
            let trust: DeviceTrust = try db.transaction {
                // Atomic single-use gate: claim the request FIRST with a guarded
                // UPDATE (status must still be 'pending'). BEGIN IMMEDIATE
                // serializes writers, so a concurrent approve/deny that already
                // moved the request out of 'pending' wins and this UPDATE matches
                // zero rows. We confirm by reading the claimant's device_id back
                // (only the winner sees its own deviceId), so approve is
                // idempotent and can never mint a second device.
                let upd = try db.prepare("""
                    UPDATE pairing_requests
                    SET status = 'approved', device_id = ?, decided_at = ?
                    WHERE id = ? AND status = 'pending';
                """)
                try upd.bind(1, deviceId); try upd.bind(2, now_s); try upd.bind(3, id)
                _ = try upd.step()

                let chk = try db.prepare("SELECT device_id FROM pairing_requests WHERE id = ?;")
                try chk.bind(1, id)
                guard try chk.step(), chk.columnText(0) == deviceId else {
                    throw PairingConflict()
                }

                let ins = try db.prepare("""
                    INSERT INTO device_trust(id, display_name, token_hash, created_at, capabilities)
                    VALUES(?, ?, ?, ?, '*');
                """)
                try ins.bind(1, deviceId); try ins.bind(2, req.deviceName)
                try ins.bind(3, hash); try ins.bind(4, now_s)
                _ = try ins.step()

                return DeviceTrust(id: deviceId, displayName: req.deviceName, tokenHash: hash, createdAt: now)
            }
            return (trust, token: token)
        } catch is PairingConflict {
            return nil
        }
    }

    public func denyPairingRequest(id: String) throws {
        let st = try db.prepare("""
            UPDATE pairing_requests SET status = 'denied', decided_at = ? WHERE id = ? AND status = 'pending';
        """)
        try st.bind(1, iso.string(from: Date())); try st.bind(2, id)
        _ = try st.step()
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
