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
    public var clientDeviceID: String?
    public var alwaysAllowPairing: Bool

    public init(id: String, displayName: String, tokenHash: String, createdAt: Date = Date(), lastSeenAt: Date? = nil, revokedAt: Date? = nil, capabilities: String = "*", clientDeviceID: String? = nil, alwaysAllowPairing: Bool = false) {
        self.id = id; self.displayName = displayName; self.tokenHash = tokenHash
        self.createdAt = createdAt; self.lastSeenAt = lastSeenAt; self.revokedAt = revokedAt
        self.capabilities = capabilities
        self.clientDeviceID = clientDeviceID
        self.alwaysAllowPairing = alwaysAllowPairing
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
    public var clientDeviceID: String?

    public var isExpired: Bool { status == "pending" && expiresAt <= Date() }
    /// Status as the wire reports it (pending collapses to expired once TTL passes).
    public var effectiveStatus: String { isExpired ? "expired" : status }

    public init(id: String, code: String, deviceName: String, createdAt: Date, expiresAt: Date, status: String, deviceID: String? = nil, decidedAt: Date? = nil, clientDeviceID: String? = nil) {
        self.id = id
        self.code = code
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.status = status
        self.deviceID = deviceID
        self.decidedAt = decidedAt
        self.clientDeviceID = clientDeviceID
    }
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
    /// Reserved slots bound to their pairing request id, so a slot is
    /// released exactly once when the request reaches a terminal state
    /// (approved/denied/expired/cancelled) no matter how many times the
    /// device polls, and reclaimed by expiry when the device disappears
    /// mid-pair without ever polling a terminal status.
    private var boundRequests: [String: (peer: String, expiresAt: Date)] = [:]

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
    /// Expired bindings are pruned first so abandoned requests (device died
    /// mid-pair, never polled a terminal status) cannot exhaust the cap.
    public func reserveOutstanding(peer: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredBindingsLocked(now: now)
        var st = peers[peer] ?? State()
        guard st.outstanding < maxOutstandingPerPeer else { return false }
        st.outstanding += 1
        peers[peer] = st
        return true
    }

    /// Bind a reserved slot to its pairing request id once the request row
    /// exists. From then on the slot is released by `releaseOutstanding(requestId:)`
    /// or by expiry pruning — never by the count-based peer release.
    public func bindOutstanding(requestId: String, peer: String, expiresAt: Date) {
        lock.lock(); defer { lock.unlock() }
        // Re-binding the same id (request reuse) frees the overwritten
        // binding's slot so the per-peer count stays exact.
        if let previous = boundRequests.removeValue(forKey: requestId) {
            releaseSlotLocked(peer: previous.peer)
        }
        boundRequests[requestId] = (peer, expiresAt)
    }

    /// Idempotent release by request id: only the first call for a given id
    /// frees the slot; repeated terminal-status polls no-op.
    public func releaseOutstanding(requestId: String) {
        lock.lock(); defer { lock.unlock() }
        guard let bound = boundRequests.removeValue(forKey: requestId) else { return }
        releaseSlotLocked(peer: bound.peer)
    }

    /// Release one reserved-but-unbound slot (create-request failed before a
    /// request id existed). Clamped at 0.
    public func releaseOutstanding(peer: String) {
        lock.lock(); defer { lock.unlock() }
        releaseSlotLocked(peer: peer)
    }

    private func releaseSlotLocked(peer: String) {
        guard var st = peers[peer] else { return }
        st.outstanding = max(0, st.outstanding - 1)
        peers[peer] = st
    }

    private func pruneExpiredBindingsLocked(now: Date) {
        for (id, bound) in boundRequests where bound.expiresAt <= now {
            boundRequests.removeValue(forKey: id)
            releaseSlotLocked(peer: bound.peer)
        }
    }
}

/// A single row from the audit_log table. Immutable value type; never persists
/// back to the DB. Used by the Devices Settings panel to render the audit trail.
public struct AuditLogEntry: Sendable, Equatable {
    public let id: Int64
    public let ts: Date
    public let actor: String?
    public let action: String
    public let detail: String?

    public init(id: Int64, ts: Date, actor: String?, action: String, detail: String?) {
        self.id = id; self.ts = ts; self.actor = actor
        self.action = action; self.detail = detail
    }
}

public final class DeviceTrustRepository {
    let db: SQLiteDB
    public init(db: SQLiteDB) { self.db = db }

    private let iso = LockedISO8601Formatter(ISO8601DateFormatter())

    // MARK: - Principal cache (request auth)

    /// How long a verified token stays valid in memory without re-reading
    /// device_trust. In-process trust changes (revoke, pair, delete, always-allow)
    /// invalidate immediately through `trustGeneration`; the TTL only bounds how
    /// long a change made by another process can go unseen.
    public static let principalCacheTTL: TimeInterval = 60
    static let principalCacheCapacity = 64

    /// Process-wide device_trust mutation counter. Every repository instance on
    /// any connection bumps it after a trust write commits, so a revoke issued
    /// from Settings (its own repository) invalidates the HTTP auth cache too.
    private static let trustGenerationLock = NSLock()
    nonisolated(unsafe) private static var trustGenerationValue: UInt64 = 0
    public static var trustGeneration: UInt64 {
        trustGenerationLock.lock()
        defer { trustGenerationLock.unlock() }
        return trustGenerationValue
    }

    /// Call only after the trust write has committed: a lookup that read the old
    /// row captured the old generation before its SELECT, so its entry can never
    /// match the bumped value.
    static func bumpTrustGeneration() {
        trustGenerationLock.lock()
        trustGenerationValue &+= 1
        trustGenerationLock.unlock()
    }

    private struct CachedPrincipal {
        let trust: DeviceTrust
        let generation: UInt64
        let cachedAt: Date
        /// Latest last_seen_at written or scheduled for this device.
        var lastSeenAt: Date?
    }

    private let principalCacheLock = NSLock()
    private var principalCache: [String: CachedPrincipal] = [:]
    private var principalCacheHits = 0
    private var principalCacheMisses = 0
    /// last_seen_at is telemetry: it is written after the request has been
    /// authorized, on its own queue, at most once per `threshold` per device.
    private let lastSeenQueue = DispatchQueue(
        label: "io.remotecode.device-trust.last-seen",
        qos: .utility
    )

    public var principalCacheHitCountForTesting: Int {
        principalCacheLock.lock()
        defer { principalCacheLock.unlock() }
        return principalCacheHits
    }

    public var principalCacheMissCountForTesting: Int {
        principalCacheLock.lock()
        defer { principalCacheLock.unlock() }
        return principalCacheMisses
    }

    /// Blocks until every scheduled last_seen_at write has run.
    public func drainLastSeenWritesForTesting() {
        lastSeenQueue.sync {}
    }

    /// Request-path verify. A token verified within `principalCacheTTL` and
    /// before any later trust write returns from memory with zero SQLite work.
    /// A miss runs one SELECT. Revoked or unknown tokens are never cached.
    /// last_seen_at keeps the `verify` debounce (`threshold`) but is written
    /// off the caller's thread, so a held write lock never delays the request.
    public func verifyCached(
        token: String,
        threshold: TimeInterval = 60,
        now: Date = Date()
    ) throws -> DeviceTrust? {
        let hash = DeviceTrustRepository.hash(token)
        let generation = Self.trustGeneration
        principalCacheLock.lock()
        if var entry = principalCache[hash] {
            let age = now.timeIntervalSince(entry.cachedAt)
            if entry.generation == generation, age >= 0, age < Self.principalCacheTTL {
                principalCacheHits += 1
                let touch = Self.shouldUpdateLastSeen(prev: entry.lastSeenAt, now: now, threshold: threshold)
                if touch {
                    entry.lastSeenAt = now
                    principalCache[hash] = entry
                }
                principalCacheLock.unlock()
                if touch { scheduleLastSeenWrite(id: entry.trust.id, at: now) }
                return entry.trust
            }
            principalCache[hash] = nil
        }
        principalCacheMisses += 1
        principalCacheLock.unlock()

        guard let trust = try lookupActiveTrust(tokenHash: hash) else { return nil }
        let touch = Self.shouldUpdateLastSeen(prev: trust.lastSeenAt, now: now, threshold: threshold)
        principalCacheLock.lock()
        if principalCache.count >= Self.principalCacheCapacity {
            principalCache = principalCache.filter {
                $0.value.generation == generation
                    && now.timeIntervalSince($0.value.cachedAt) < Self.principalCacheTTL
            }
            if principalCache.count >= Self.principalCacheCapacity { principalCache.removeAll() }
        }
        principalCache[hash] = CachedPrincipal(
            trust: trust,
            generation: generation,
            cachedAt: now,
            lastSeenAt: touch ? now : trust.lastSeenAt
        )
        principalCacheLock.unlock()
        if touch { scheduleLastSeenWrite(id: trust.id, at: now) }
        return trust
    }

    private func lookupActiveTrust(tokenHash hash: String) throws -> DeviceTrust? {
        let st = try db.prepare(
            "SELECT id, display_name, created_at, last_seen_at, revoked_at, capabilities, client_device_id, always_allow_pairing FROM device_trust WHERE token_hash = ? AND revoked_at IS NULL;"
        )
        // Reset so this connection does not keep a WAL read snapshot after a
        // single-row lookup.
        defer { st.reset() }
        try st.bind(1, hash)
        guard try st.step() else { return nil }
        return DeviceTrust(
            id: st.columnText(0) ?? "",
            displayName: st.columnText(1) ?? "",
            tokenHash: hash,
            createdAt: iso.date(from: st.columnText(2) ?? "") ?? Date(),
            lastSeenAt: (st.columnText(3)).flatMap { iso.date(from: $0) },
            revokedAt: (st.columnText(4)).flatMap { iso.date(from: $0) },
            capabilities: st.columnText(5) ?? "*",
            clientDeviceID: st.columnText(6),
            alwaysAllowPairing: st.columnInt64(7) != 0
        )
    }

    private func scheduleLastSeenWrite(id: String, at now: Date) {
        let stamp = iso.string(from: now)
        lastSeenQueue.async { [db] in
            // Best-effort telemetry, same as the synchronous verify path: the
            // request was already authorized, so a locked or read-only DB must
            // never de-authorize the device.
            do {
                let touch = try db.prepare("UPDATE device_trust SET last_seen_at = ? WHERE id = ?;")
                try touch.bind(1, stamp); try touch.bind(2, id)
                _ = try touch.step()
            } catch {}
        }
    }

    /// Pure predicate: returns `true` when the stored `last_seen_at` is old
    /// enough that a new write is warranted, avoiding a WAL write on every
    /// authenticated request when the stored value is already fresh.
    ///
    /// - `prev`: the last stored last_seen_at (nil = never seen -> always write)
    /// - `now`: the current wall-clock time used for the comparison
    /// - `threshold`: minimum elapsed seconds before a new write is issued
    ///
    /// Returns `false` when `prev` is within the threshold window (skip write).
    /// Returns `true` when `prev` is nil or older than the threshold (do write).
    public nonisolated static func shouldUpdateLastSeen(
        prev: Date?,
        now: Date,
        threshold: TimeInterval
    ) -> Bool {
        guard let prev = prev else { return true }
        return now.timeIntervalSince(prev) > threshold
    }

    /// PERF: nibble table instead of per-byte `String(format:)` so every token
    /// verify/store hash avoids 32 formatter calls while keeping the same
    /// CryptoKit lowercase hex contract for durable `token_hash` matching.
    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    public static func hash(_ token: String) -> String {
        hexDigest(SHA256.hash(data: Data(token.utf8)))
    }

    public static func generateToken() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    private static func sixDigitCode() -> String {
        // PERF: manual zero-pad avoids String(format:) ICU per pairing code.
        let v = Int.random(in: 0..<1_000_000)
        let s = String(v)
        return String(repeating: "0", count: 6 - s.count) + s
    }

    public func createPairingCode(ttlSeconds: TimeInterval = 600, at now: Date = Date()) throws -> PairingCode {
        let code = Self.sixDigitCode()
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

    public func redeemPairingCode(_ code: String, deviceName: String, now: Date = Date()) throws -> (DeviceTrust, token: String)? {
        let deviceId = UUID().uuidString
        let token = DeviceTrustRepository.generateToken()
        let hash = DeviceTrustRepository.hash(token)
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
            Self.bumpTrustGeneration()
            return (trust, token: token)
        } catch is PairingConflict {
            return nil
        }
    }

    // MARK: device-initiated request → user approves/denies in a modal

    /// Create a pending request. The 6-digit code is shown on BOTH the
    /// Mac modal and the device so the user can visually confirm they
    /// match before approving (anti-MITM, like Bluetooth pairing).
    public func createPairingRequest(deviceName: String, clientDeviceID: String? = nil, ttlSeconds: TimeInterval = 300, at now: Date = Date()) throws -> PairingRequest {
        let id = UUID().uuidString
        let code = Self.sixDigitCode()
        let exp = now.addingTimeInterval(ttlSeconds)
        let st = try db.prepare("""
            INSERT INTO pairing_requests(id, code, device_name, created_at, expires_at, status, client_device_id)
            VALUES(?, ?, ?, ?, ?, 'pending', ?);
        """)
        try st.bind(1, id); try st.bind(2, code); try st.bind(3, deviceName)
        try st.bind(4, iso.string(from: now)); try st.bind(5, iso.string(from: exp))
        try st.bind(6, clientDeviceID)
        _ = try st.step()
        return PairingRequest(id: id, code: code, deviceName: deviceName,
                              createdAt: now, expiresAt: exp, status: "pending",
                              clientDeviceID: clientDeviceID)
    }

    public func pairingRequest(id: String) throws -> PairingRequest? {
        let st = try db.prepare("""
            SELECT code, device_name, created_at, expires_at, status, device_id, decided_at, client_device_id
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
            decidedAt: (st.columnText(6)).flatMap { iso.date(from: $0) },
            clientDeviceID: st.columnText(7)
        )
    }

    /// Approve a pending, non-expired request: mint a device token and
    /// persist trust (hash only). Returns the plaintext token exactly
    /// once to the caller — it is never written to the DB.
    public func approvePairingRequest(id: String, alwaysAllowPairing: Bool = false) throws -> (DeviceTrust, token: String)? {
        guard let req = try pairingRequest(id: id), req.status == "pending", !req.isExpired else { return nil }
        let deviceId = UUID().uuidString
        let token = DeviceTrustRepository.generateToken()
        let hash = DeviceTrustRepository.hash(token)
        let now = Date()
        let now_s = iso.string(from: now)
        let persistedClientDeviceID = req.clientDeviceID.flatMap { $0.isEmpty ? nil : $0 }
        let persistedAlwaysAllow = alwaysAllowPairing && persistedClientDeviceID != nil

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
                    INSERT INTO device_trust(id, display_name, token_hash, created_at, capabilities, client_device_id, always_allow_pairing)
                    VALUES(?, ?, ?, ?, '*', ?, ?);
                """)
                try ins.bind(1, deviceId); try ins.bind(2, req.deviceName)
                try ins.bind(3, hash); try ins.bind(4, now_s)
                try ins.bind(5, persistedClientDeviceID)
                try ins.bind(6, persistedAlwaysAllow)
                _ = try ins.step()

                return DeviceTrust(
                    id: deviceId,
                    displayName: req.deviceName,
                    tokenHash: hash,
                    createdAt: now,
                    clientDeviceID: persistedClientDeviceID,
                    alwaysAllowPairing: persistedAlwaysAllow
                )
            }
            Self.bumpTrustGeneration()
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

    /// Device-initiated cancel: move a still-pending request to a terminal
    /// 'cancelled' state so a later `pairingRequest` reports it as such and
    /// it no longer shows as outstanding. Returns true only when an
    /// existing, still-pending request was actually transitioned; an
    /// unknown id, or one already approved/denied/expired, returns false so
    /// the HTTP layer can answer 404. Additive: does not touch redeem or
    /// status semantics, and the guarded UPDATE (status = 'pending') cannot
    /// race past an in-flight approve/deny.
    @discardableResult
    public func cancelPairingRequest(id: String) throws -> Bool {
        guard let req = try pairingRequest(id: id), req.status == "pending", !req.isExpired else { return false }
        let st = try db.prepare("""
            UPDATE pairing_requests SET status = 'cancelled', decided_at = ? WHERE id = ? AND status = 'pending';
        """)
        try st.bind(1, iso.string(from: Date())); try st.bind(2, id)
        _ = try st.step()
        // Confirm we won the pending->cancelled transition (a concurrent
        // approve/deny may have moved it first). Only report success when
        // the row now reads 'cancelled'.
        return try pairingRequest(id: id)?.status == "cancelled"
    }

    /// Verify `token` and conditionally update `last_seen_at`.
    ///
    /// The update is debounced: it is skipped when the stored `last_seen_at`
    /// is within `threshold` seconds of `now`, avoiding a WAL write on every
    /// authenticated HTTP request when the value is already fresh.
    ///
    /// Default `threshold` of 60 s means at most one write per minute per
    /// device under sustained traffic, versus one write per request before.
    public func verify(
        token: String,
        threshold: TimeInterval = 60,
        now: Date = Date()
    ) throws -> DeviceTrust? {
        let hash = DeviceTrustRepository.hash(token)
        let st = try db.prepare(
            "SELECT id, display_name, created_at, last_seen_at, revoked_at, capabilities, client_device_id, always_allow_pairing FROM device_trust WHERE token_hash = ? AND revoked_at IS NULL;"
        )
        try st.bind(1, hash)
        guard try st.step() else { return nil }
        let id        = st.columnText(0) ?? ""
        let name      = st.columnText(1) ?? ""
        let createdAt = iso.date(from: st.columnText(2) ?? "") ?? Date()
        let lastSeen  = (st.columnText(3)).flatMap { iso.date(from: $0) }
        let revoked   = (st.columnText(4)).flatMap { iso.date(from: $0) }
        let caps      = st.columnText(5) ?? "*"
        let clientDeviceID = st.columnText(6)
        let alwaysAllowPairing = st.columnInt64(7) != 0
        if DeviceTrustRepository.shouldUpdateLastSeen(prev: lastSeen, now: now, threshold: threshold) {
            // Best-effort telemetry: the token already matched above, so a
            // failed last_seen write (locked/read-only DB) must never
            // de-authorize a valid device.
            do {
                let touch = try db.prepare("UPDATE device_trust SET last_seen_at = ? WHERE id = ?;")
                try touch.bind(1, iso.string(from: now)); try touch.bind(2, id)
                _ = try touch.step()
            } catch {}
        }
        return DeviceTrust(id: id, displayName: name, tokenHash: hash,
                           createdAt: createdAt, lastSeenAt: lastSeen,
                           revokedAt: revoked, capabilities: caps,
                           clientDeviceID: clientDeviceID,
                           alwaysAllowPairing: alwaysAllowPairing)
    }

    public func list() throws -> [DeviceTrust] {
        let st = try db.prepare("SELECT id, display_name, token_hash, created_at, last_seen_at, revoked_at, capabilities, client_device_id, always_allow_pairing FROM device_trust ORDER BY created_at DESC;")
        var out: [DeviceTrust] = []
        while try st.step() {
            out.append(DeviceTrust(
                id: st.columnText(0) ?? "",
                displayName: st.columnText(1) ?? "",
                tokenHash: st.columnText(2) ?? "",
                createdAt: iso.date(from: st.columnText(3) ?? "") ?? Date(),
                lastSeenAt: (st.columnText(4)).flatMap { iso.date(from: $0) },
                revokedAt: (st.columnText(5)).flatMap { iso.date(from: $0) },
                capabilities: st.columnText(6) ?? "*",
                clientDeviceID: st.columnText(7),
                alwaysAllowPairing: st.columnInt64(8) != 0
            ))
        }
        return out
    }

    public func alwaysAllowedPairingDevice(clientDeviceID: String) throws -> DeviceTrust? {
        let normalized = clientDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let st = try db.prepare("""
            SELECT id, display_name, token_hash, created_at, last_seen_at, revoked_at, capabilities, client_device_id, always_allow_pairing
            FROM device_trust
            WHERE client_device_id = ? AND always_allow_pairing = 1 AND revoked_at IS NULL
            ORDER BY COALESCE(last_seen_at, created_at) DESC, created_at DESC
            LIMIT 1;
        """)
        try st.bind(1, normalized)
        guard try st.step() else { return nil }
        return DeviceTrust(
            id: st.columnText(0) ?? "",
            displayName: st.columnText(1) ?? "",
            tokenHash: st.columnText(2) ?? "",
            createdAt: iso.date(from: st.columnText(3) ?? "") ?? Date(),
            lastSeenAt: (st.columnText(4)).flatMap { iso.date(from: $0) },
            revokedAt: (st.columnText(5)).flatMap { iso.date(from: $0) },
            capabilities: st.columnText(6) ?? "*",
            clientDeviceID: st.columnText(7),
            alwaysAllowPairing: st.columnInt64(8) != 0
        )
    }

    public func setAlwaysAllowPairing(id: String, enabled: Bool) throws {
        let st = try db.prepare("""
            UPDATE device_trust
            SET always_allow_pairing = ?
            WHERE id = ? AND revoked_at IS NULL AND client_device_id IS NOT NULL;
        """)
        try st.bind(1, enabled)
        try st.bind(2, id)
        _ = try st.step()
        Self.bumpTrustGeneration()
    }

    public func revoke(id: String) throws {
        let st = try db.prepare("UPDATE device_trust SET revoked_at = ?, relay_public_key = NULL WHERE id = ?;")
        try st.bind(1, iso.string(from: Date())); try st.bind(2, id)
        _ = try st.step()
        Self.bumpTrustGeneration()
    }

    /// Stores (or clears) the relay key of a non-revoked device.
    public func setRelayPublicKey(deviceId: String, key: Data?) throws {
        let st = try db.prepare("UPDATE device_trust SET relay_public_key = ? WHERE id = ? AND revoked_at IS NULL;")
        try st.bind(1, key); try st.bind(2, deviceId)
        _ = try st.step()
    }

    /// Device id owning this relay key; revoked devices never match.
    public func deviceIdForRelayKey(_ key: Data) throws -> String? {
        let st = try db.prepare("SELECT id FROM device_trust WHERE relay_public_key = ? AND revoked_at IS NULL LIMIT 1;")
        defer { st.reset() }
        try st.bind(1, key)
        guard try st.step() else { return nil }
        return st.columnText(0)
    }

    /// Delete all device_trust rows that have been revoked (revoked_at IS NOT NULL).
    /// Keeps active devices intact. Called from the Devices Settings panel.
    public func deleteRevoked() throws {
        let st = try db.prepare("DELETE FROM device_trust WHERE revoked_at IS NOT NULL;")
        _ = try st.step()
        Self.bumpTrustGeneration()
    }

    public func audit(actor: String?, action: String, detail: String?, at now: Date = Date()) throws {
        let st = try db.prepare("INSERT INTO audit_log(ts, actor, action, detail) VALUES(?, ?, ?, ?);")
        try st.bind(1, iso.string(from: now))
        try st.bind(2, actor)
        try st.bind(3, action)
        try st.bind(4, detail)
        _ = try st.step()
    }

    /// Fetch the most recent audit log entries, newest first. Does not touch
    /// the device_trust schema; reads only the audit_log table.
    public func listAuditLog(limit: Int = 50) throws -> [AuditLogEntry] {
        let st = try db.prepare(
            "SELECT id, ts, actor, action, detail FROM audit_log ORDER BY id DESC LIMIT ?;"
        )
        try st.bind(1, limit)
        var out: [AuditLogEntry] = []
        while try st.step() {
            out.append(AuditLogEntry(
                id: st.columnInt64(0),
                ts: iso.date(from: st.columnText(1) ?? "") ?? Date(timeIntervalSince1970: 0),
                actor: st.columnText(2),
                action: st.columnText(3) ?? "",
                detail: st.columnText(4)
            ))
        }
        return out
    }

    /// Audit `detail` payloads for specific actions, newest first.
    ///
    /// Readers that only need `detail` (orchestration receipts / ledger) used to
    /// call `listAuditLog` and discard every timestamp — yet each row still paid
    /// an `NSISO8601DateFormatter` parse, and the action filter ran in Swift
    /// after unrelated rows had already been loaded. Under a MainActor refresh
    /// that made the cost scale with the entire audit log (measured ~1.3s of the
    /// ~2.0s Subagents refresh). Filter in SQL and skip date decoding entirely.
    public func listAuditLogDetails(actions: [String], limit: Int) throws -> [String] {
        try listAuditLogDetails(actions: actions, detailContains: nil, limit: limit)
    }

    /// Like `listAuditLogDetails(actions:limit:)` with an optional SQL `detail LIKE`
    /// prefilter. The needle is a cheap index-free prefilter only — callers must
    /// still enforce exact membership after decoding (false positives can match).
    public func listAuditLogDetails(
        actions: [String],
        detailContains needle: String?,
        limit: Int
    ) throws -> [String] {
        guard !actions.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: actions.count).joined(separator: ",")
        let filter = needle == nil ? "" : " AND detail LIKE ?"
        let st = try db.prepare(
            "SELECT detail FROM audit_log WHERE action IN (\(placeholders))\(filter) ORDER BY id DESC LIMIT ?;"
        )
        var bindIndex: Int32 = 1
        for action in actions {
            try st.bind(bindIndex, action)
            bindIndex += 1
        }
        if let needle {
            try st.bind(bindIndex, "%\(needle)%")
            bindIndex += 1
        }
        try st.bind(bindIndex, limit)
        var out: [String] = []
        while try st.step() {
            if let detail = st.columnText(0) { out.append(detail) }
        }
        return out
    }

    /// Cheap `(count, max id)` signature over the audit rows of the given
    /// actions. Served by `idx_audit_log_action_id` (schema v82) so hot polls
    /// (e.g. the 2s orchestration receipt poll, perf X-01) can skip re-decoding
    /// receipt JSON while no process appended or pruned rows. Returns nil when
    /// no row matches (callers treat nil as "uncacheable" the same way).
    public func auditLogSignature(actions: [String]) throws -> (count: Int, maxID: Int64)? {
        guard !actions.isEmpty else { return nil }
        let placeholders = Array(repeating: "?", count: actions.count).joined(separator: ",")
        let st = try db.prepare(
            "SELECT COUNT(*), MAX(id) FROM audit_log WHERE action IN (\(placeholders));"
        )
        for (index, action) in actions.enumerated() {
            try st.bind(Int32(index + 1), action)
        }
        defer { st.reset() }
        guard try st.step() else { return nil }
        let count = Int(st.columnInt64(0))
        let maxID = st.columnInt64(1)
        guard count > 0, maxID > 0 else { return nil }
        return (count, maxID)
    }

    /// Prune unbounded device-trust tables so they cannot grow without limit
    /// over long-lived server sessions.
    ///
    /// - `auditMaxAge`: remove audit_log rows whose `ts` is older than this
    ///   interval before `now`. Pass 0 to skip age-based audit pruning.
    /// - `auditMaxRows`: after age-pruning, trim the oldest rows until at most
    ///   `auditMaxRows` remain.  Pass `Int.max` to skip row-cap pruning.
    /// - `pairingMaxAge`: remove pairing_codes and decided (approved/denied)
    ///   pairing_requests whose `created_at` is older than this interval before
    ///   `now`. Pending requests are never pruned. Pass 0 to skip.
    /// - `now`: wall-clock reference injected for deterministic testing.
    ///
    /// Returns the total number of rows deleted across all three tables.
    @discardableResult
    public func pruneDeviceTrustTables(
        auditMaxAge: TimeInterval,
        auditMaxRows: Int,
        pairingMaxAge: TimeInterval,
        now: Date = Date()
    ) throws -> Int {
        var removed = 0

        // --- audit_log: age cutoff ---
        if auditMaxAge > 0 {
            let cutoff = now.addingTimeInterval(-auditMaxAge)
            let cutoffStr = iso.string(from: cutoff)
            removed += try countThenDelete(
                count: "SELECT COUNT(*) FROM audit_log WHERE ts < ?;",
                delete: "DELETE FROM audit_log WHERE ts < ?;",
                binding: cutoffStr
            )
        }

        // --- audit_log: row cap ---
        if auditMaxRows < Int.max {
            // Count current rows; only run the cap DELETE if over limit.
            let cnt = try db.prepare("SELECT COUNT(*) FROM audit_log;")
            _ = try cnt.step()
            let total = Int(cnt.columnInt64(0))
            if total > auditMaxRows {
                // Keep the newest auditMaxRows rows by timestamp; delete the rest.
                // Sort by ts DESC (ISO-8601 sorts lexicographically correctly for UTC)
                // to find the boundary id, then delete rows older than that boundary.
                let cap = try db.prepare("""
                    DELETE FROM audit_log WHERE id NOT IN (
                        SELECT id FROM audit_log ORDER BY ts DESC, id DESC LIMIT ?
                    );
                """)
                try cap.bind(1, Int64(auditMaxRows))
                _ = try cap.step()
                removed += (total - auditMaxRows)
            }
        }

        // --- pairing_codes: age cutoff ---
        if pairingMaxAge > 0 {
            let cutoff = now.addingTimeInterval(-pairingMaxAge)
            let cutoffStr = iso.string(from: cutoff)
            removed += try countThenDelete(
                count: "SELECT COUNT(*) FROM pairing_codes WHERE created_at < ?;",
                delete: "DELETE FROM pairing_codes WHERE created_at < ?;",
                binding: cutoffStr
            )
        }

        // --- pairing_requests: age cutoff, decided rows only ---
        if pairingMaxAge > 0 {
            let cutoff = now.addingTimeInterval(-pairingMaxAge)
            let cutoffStr = iso.string(from: cutoff)
            removed += try countThenDelete(
                count: "SELECT COUNT(*) FROM pairing_requests WHERE created_at < ? AND status != 'pending';",
                delete: "DELETE FROM pairing_requests WHERE created_at < ? AND status != 'pending';",
                binding: cutoffStr
            )
        }

        return removed
    }

    /// Run a COUNT then DELETE for a single-binding SQL pair, returning the count.
    private func countThenDelete(count countSQL: String, delete deleteSQL: String, binding: String) throws -> Int {
        let cnt = try db.prepare(countSQL)
        try cnt.bind(1, binding)
        _ = try cnt.step()
        let n = Int(cnt.columnInt64(0))
        if n > 0 {
            let del = try db.prepare(deleteSQL)
            try del.bind(1, binding)
            _ = try del.step()
        }
        return n
    }
}
