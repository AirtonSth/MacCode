import CryptoKit
import Foundation
import Persistence
import SocketServer

/// What the Mac modal needs to render one pairing prompt.
public struct PairingPrompt: Sendable {
    public let requestId: String
    public let code: String
    public let deviceName: String
    /// Stable client-provided ID used only for explicit "always allow" pairing.
    public let clientDeviceID: String?
    /// When the pairing request was created on the server (used for countdown).
    public let createdAt: Date
    /// When the pairing request expires (createdAt + TTL).
    public let expiresAt: Date
    /// Source IP of the device that initiated the request, if known.
    public let sourceIP: String?

    public init(requestId: String, code: String, deviceName: String, clientDeviceID: String? = nil,
                createdAt: Date = Date(), expiresAt: Date = Date().addingTimeInterval(300),
                sourceIP: String? = nil) {
        self.requestId = requestId
        self.code = code
        self.deviceName = deviceName
        self.clientDeviceID = clientDeviceID
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.sourceIP = sourceIP
    }
}

public final class LocalAuthAdapter: DirectAuthProvider {
    let repo: DeviceTrustRepository
    private let privateAccountStore: PrivateAccountSessionStore?
    private let privateAccountAPI: PrivateAccountAPI

    public init(repo: DeviceTrustRepository,
                privateAccountStore: PrivateAccountSessionStore? = nil,
                privateAccountAPI: PrivateAccountAPI = URLSessionPrivateAccountAPI()) {
        self.repo = repo
        self.privateAccountStore = privateAccountStore
        self.privateAccountAPI = privateAccountAPI
    }

    /// Set by AppDelegate. Invoked (off the main thread) when a device
    /// asks to pair; the closure hops to main and shows the modal.
    public var onPairingRequest: (@Sendable (PairingPrompt) -> Void)?

    /// Set by AppDelegate. Invoked (off the main thread) with the request id
    /// when a device cancels its own outstanding request; the closure hops
    /// to main and dismisses the approve/deny modal if it is showing that id.
    public var onPairingCancelled: (@Sendable (String) -> Void)?

    /// requestId → freshly minted plaintext token, held in RAM only and
    /// delivered to the device exactly once (never persisted — mirrors
    /// the redeem path's no-plaintext-at-rest invariant).
    ///
    /// Each entry carries an `issuedAt` timestamp so that entries whose
    /// device stopped polling (e.g. user cancelled before the token was
    /// retrieved) are lazily swept on the next `pairingRequestStatus` call.
    private let pendingLock = NSLock()
    private var pendingTokens: [String: (deviceId: String, token: String, issuedAt: Date)] = [:]

    /// How long a pending (unpolled) approved-token is retained in RAM.
    /// Matches the pairing-request TTL so a device that polls right up to
    /// expiry can still retrieve its token.
    static let pendingTokenTTL: TimeInterval = 300   // 5 min

    // MARK: - Pure helpers (testable, no side effects)

    /// Returns `true` when a pending token that was issued at `issuedAt`
    /// should no longer be delivered because more than `ttl` seconds have
    /// elapsed since issuance.
    ///
    /// Pure helper — no state. `nonisolated static` so tests can call it
    /// directly without constructing a `LocalAuthAdapter`.
    nonisolated static func isPendingTokenExpired(
        issuedAt: Date, now: Date, ttl: TimeInterval
    ) -> Bool {
        now.timeIntervalSince(issuedAt) > ttl
    }

    /// Returns a copy of `tokens` with all entries whose `issuedAt` is older
    /// than `ttl` removed.  Pure helper — callers are responsible for writing
    /// the result back under the lock.
    nonisolated static func sweepExpiredPendingTokens(
        _ tokens: [String: (deviceId: String, token: String, issuedAt: Date)],
        now: Date,
        ttl: TimeInterval
    ) -> [String: (deviceId: String, token: String, issuedAt: Date)] {
        tokens.filter { !isPendingTokenExpired(issuedAt: $0.value.issuedAt, now: now, ttl: ttl) }
    }

    public func verify(token: String) -> Bool {
        ((try? repo.verify(token: token)) ?? nil) != nil
    }

    /// Stable durable owner for Attachment Upload v2 (and similar bindings).
    ///
    /// The trusted device row is the security principal. `clientDeviceID` is
    /// client-supplied display/pairing metadata and must never merge two trust
    /// rows into one upload owner. Only an opaque SHA-256 fingerprint is
    /// returned — never the bearer or raw row id.
    public func authorizedOwnerFingerprint(token: String) -> String? {
        guard let trust = (try? repo.verify(token: token)) ?? nil else { return nil }
        return Self.opaqueAuthorizedOwnerFingerprint(
            stableIdentity: "device:\(trust.id)"
        )
    }

    public func isAuthorizedOwnerFingerprintActive(
        _ fingerprint: String
    ) -> Bool {
        guard fingerprint.utf8.count == 64 else { return false }
        return ((try? repo.list()) ?? []).contains { trust in
            trust.revokedAt == nil
                && Self.opaqueAuthorizedOwnerFingerprint(
                    stableIdentity: "device:\(trust.id)"
                ) == fingerprint
        }
    }

    /// Hash a stable authorized identity into an opaque 64-char hex fingerprint.
    /// Pure helper so tests can assert the mapping without logging raw ids.
    nonisolated static func opaqueAuthorizedOwnerFingerprint(stableIdentity: String) -> String {
        let material = Data("rc2.authorized-owner.v1:\(stableIdentity)".utf8)
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func createPairingRequest(deviceName: String) -> (requestId: String, code: String)? {
        createPairingRequest(deviceName: deviceName, privateAccountAccessToken: nil)
    }

    public func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)? {
        createPairingRequest(deviceName: deviceName, clientDeviceID: nil, privateAccountAccessToken: privateAccountAccessToken)
    }

    public func createPairingRequest(deviceName: String, clientDeviceID: String?, privateAccountAccessToken: String?) -> (requestId: String, code: String)? {
        let normalizedClientDeviceID = clientDeviceID
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard let req = try? repo.createPairingRequest(deviceName: deviceName, clientDeviceID: normalizedClientDeviceID) else { return nil }
        auditLoud(actor: "device", action: "pairing.request", detail: deviceName)
        if canAutoApprovePairing(privateAccountAccessToken: privateAccountAccessToken) {
            approvePairingRequest(req.id)
            auditLoud(actor: "account", action: "pairing.auto_approve", detail: deviceName)
            return (req.id, req.code)
        }
        if canAlwaysAllowPairing(clientDeviceID: normalizedClientDeviceID) {
            approvePairingRequest(req.id, alwaysAllowPairing: true)
            auditLoud(actor: "device", action: "pairing.always_allow_auto_approve", detail: deviceName)
            return (req.id, req.code)
        }
        onPairingRequest?(PairingPrompt(requestId: req.id, code: req.code, deviceName: deviceName,
                                         clientDeviceID: normalizedClientDeviceID,
                                         createdAt: req.createdAt, expiresAt: req.expiresAt))
        return (req.id, req.code)
    }

    private func canAlwaysAllowPairing(clientDeviceID: String?) -> Bool {
        guard let clientDeviceID else { return false }
        return ((try? repo.alwaysAllowedPairingDevice(clientDeviceID: clientDeviceID)) ?? nil) != nil
    }

    private func canAutoApprovePairing(privateAccountAccessToken: String?) -> Bool {
        // The non-blocking early return below is main-thread safe (no token / no
        // subscription => no remote check). Only the blocking tail must be guarded.
        guard let privateAccountAccessToken,
              let localSession = privateAccountStore?.load(),
              localSession.user.subscribed else { return false }

        // SAFETY: from here the function blocks the calling thread
        // (DispatchSemaphore.wait) for up to 8 seconds. It MUST NOT run on the main
        // actor -- doing so would deadlock the run loop. Today callers are HTTP
        // listener threads (safe); if a future refactor routes the blocking path
        // here from the main actor, this precondition surfaces the bug at call-site.
        precondition(!Thread.isMainThread,
                     "canAutoApprovePairing must not block the main thread -- it waits up to 8 s")

        let sema = DispatchSemaphore(value: 0)
        let box = LockedAccountVerificationBox()
        let api = privateAccountAPI
        Task.detached {
            let remoteUser = try? await api.currentUser(accessToken: privateAccountAccessToken)
            box.value = remoteUser?.subscribed == true
                && remoteUser?.id == localSession.user.id
                && remoteUser?.email.lowercased() == localSession.user.email.lowercased()
            sema.signal()
        }
        if sema.wait(timeout: .now() + 8) == .timedOut { return false }
        return box.value
    }

    /// Called from the Mac modal's Approve button.
    public func approvePairingRequest(_ requestId: String, alwaysAllowPairing: Bool = false) {
        guard let (trust, token) = try? repo.approvePairingRequest(id: requestId, alwaysAllowPairing: alwaysAllowPairing) else { return }
        pendingLock.lock()
        pendingTokens[requestId] = (trust.id, token, Date())
        pendingLock.unlock()
        auditLoud(actor: trust.id, action: alwaysAllowPairing ? "pairing.approve_always_allow" : "pairing.approve", detail: trust.displayName)
    }

    /// Called from the Mac modal's Deny button.
    public func denyPairingRequest(_ requestId: String) {
        try? repo.denyPairingRequest(id: requestId)
        auditLoud(actor: "user", action: "pairing.deny", detail: requestId)
    }

    public func pairingRequestStatus(requestId: String) -> (status: String, deviceId: String?, token: String?)? {
        guard let r = try? repo.pairingRequest(id: requestId) else { return nil }
        if r.effectiveStatus == "approved" {
            let now = Date()
            pendingLock.lock()
            // Lazily sweep TTL-expired entries on every approved-status poll.
            pendingTokens = LocalAuthAdapter.sweepExpiredPendingTokens(
                pendingTokens, now: now, ttl: LocalAuthAdapter.pendingTokenTTL
            )
            // Read WITHOUT consuming: the HTTP response carrying the token can
            // be lost after this call (Wi-Fi→cellular handoff mid-write), and a
            // consumed token would strand the approved device on "Approved, but
            // no token was returned" forever. Redelivery is bounded by the TTL
            // sweep above and by cancel; one-shot delivery added no security on
            // this plaintext-LAN transport — the token itself travels in the
            // first response, and a request_id holder could always have won the
            // first-poll race.
            let pending = pendingTokens[requestId]
            pendingLock.unlock()
            // Deliver the token only when it has not already expired.
            let liveToken: String? = pending.flatMap { entry in
                LocalAuthAdapter.isPendingTokenExpired(
                    issuedAt: entry.issuedAt, now: now, ttl: LocalAuthAdapter.pendingTokenTTL
                ) ? nil : entry.token
            }
            return ("approved", r.deviceID ?? pending?.deviceId, liveToken)
        }
        return (r.effectiveStatus, nil, nil)
    }

    /// Device-initiated cancel of an outstanding request. Moves the pending
    /// request to a terminal state in the store (so a later status poll
    /// returns "cancelled") and drops any RAM-held pending token for it.
    /// Returns true only when a still-pending request was transitioned.
    public func cancelPairingRequest(requestId: String) -> Bool {
        let cancelled = (try? repo.cancelPairingRequest(id: requestId)) ?? false
        guard cancelled else { return false }
        // Defensive: if a token was minted in a race before cancel landed,
        // never deliver it. Pending tokens are RAM-only and one-shot.
        pendingLock.lock()
        pendingTokens.removeValue(forKey: requestId)
        pendingLock.unlock()
        auditLoud(actor: "device", action: "pairing.cancel", detail: requestId)
        onPairingCancelled?(requestId)
        return true
    }

    public func createPairingCode() -> String? {
        guard let p = try? repo.createPairingCode() else { return nil }
        auditLoud(actor: "system", action: "pairing.create", detail: p.code)
        return p.code
    }

    public func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? {
        do {
            guard let p = try repo.redeemPairingCode(code, deviceName: deviceName) else { return nil }
            auditLoud(actor: p.0.id, action: "pairing.redeem", detail: deviceName)
            return (p.0.id, p.token)
        } catch {
            return nil
        }
    }

    public func listDevices() -> [[String: Any]] {
        let list = (try? repo.list()) ?? []
        return list.map { d in
            var dict: [String: Any] = [
                "id": d.id,
                "display_name": d.displayName,
                "created_at": ISO8601DateFormatter().string(from: d.createdAt),
                "capabilities": d.capabilities,
                "revoked": d.revokedAt != nil,
                "always_allow_pairing": d.alwaysAllowPairing
            ]
            if let ls = d.lastSeenAt { dict["last_seen_at"] = ISO8601DateFormatter().string(from: ls) }
            if let clientDeviceID = d.clientDeviceID { dict["client_device_id"] = clientDeviceID }
            return dict
        }
    }

    public func revokeDevice(_ id: String) {
        try? repo.revoke(id: id)
        auditLoud(actor: "system", action: "device.revoke", detail: id)
        // Material wake taxonomy classifies device.revoke as criticalAlert, but
        // without an EventBus publisher a revoked/kicked device never surfaces
        // to MaterialWakeCoordinator (or remote subscribers). Match AppContext
        // publish shape: kind + object payload with the device id.
        // Necessary-but-not-yet-sufficient: no consumer currently turns a
        // criticalAlert-class EventBus event into an actual delivered alert, so
        // this event is correctly classified but inert until that consumer exists.
        EventBus.shared.publish(
            kind: "device.revoke",
            payload: .object([
                "device_id": .string(id),
            ])
        )
    }

    // MARK: - Internal audit helper

    /// Write an audit row. In DEBUG builds throws loudly on failure so regressions
    /// are caught immediately; in release builds falls back to the original silent
    /// `try?` so a transient DB error never crashes a production user's session.
    ///
    /// WHY: `try? repo.audit(...)` silently swallows errors. A broken audit path
    /// (schema regression, corrupt table) is a compliance gap that is invisible
    /// until a post-incident review. A DEBUG assertion turns it into an immediate
    /// test failure.
    private func auditLoud(actor: String, action: String, detail: String?) {
        #if DEBUG
        do {
            try repo.audit(actor: actor, action: action, detail: detail)
        } catch {
            assertionFailure("audit_log write failed in DEBUG build — action=\(action) error=\(error). " +
                             "A silent audit failure is a compliance/regression risk; fix the underlying error.")
        }
        #else
        try? repo.audit(actor: actor, action: action, detail: detail)
        #endif
    }
}

#if DEBUG
extension LocalAuthAdapter {
    /// Back-dates the `issuedAt` of a pending-token entry by `seconds`.
    /// Only available in DEBUG builds for TTL-expiry unit tests; must not
    /// ship in production.
    func testBackdatePendingToken(requestId: String, by seconds: TimeInterval) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard let entry = pendingTokens[requestId] else { return }
        pendingTokens[requestId] = (
            entry.deviceId,
            entry.token,
            entry.issuedAt.addingTimeInterval(-seconds)
        )
    }
}
#endif

private final class LockedAccountVerificationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
