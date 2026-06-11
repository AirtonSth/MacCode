import Foundation
import Persistence
import SocketServer

/// What the Mac modal needs to render one pairing prompt.
public struct PairingPrompt: Sendable {
    public let requestId: String
    public let code: String
    public let deviceName: String
    /// When the pairing request was created on the server (used for countdown).
    public let createdAt: Date
    /// When the pairing request expires (createdAt + TTL).
    public let expiresAt: Date
    /// Source IP of the device that initiated the request, if known.
    public let sourceIP: String?

    public init(requestId: String, code: String, deviceName: String,
                createdAt: Date = Date(), expiresAt: Date = Date().addingTimeInterval(300),
                sourceIP: String? = nil) {
        self.requestId = requestId
        self.code = code
        self.deviceName = deviceName
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

    public func createPairingRequest(deviceName: String) -> (requestId: String, code: String)? {
        createPairingRequest(deviceName: deviceName, privateAccountAccessToken: nil)
    }

    public func createPairingRequest(deviceName: String, privateAccountAccessToken: String?) -> (requestId: String, code: String)? {
        guard let req = try? repo.createPairingRequest(deviceName: deviceName) else { return nil }
        try? repo.audit(actor: "device", action: "pairing.request", detail: deviceName)
        if canAutoApprovePairing(privateAccountAccessToken: privateAccountAccessToken) {
            approvePairingRequest(req.id)
            try? repo.audit(actor: "account", action: "pairing.auto_approve", detail: deviceName)
            return (req.id, req.code)
        }
        onPairingRequest?(PairingPrompt(requestId: req.id, code: req.code, deviceName: deviceName,
                                         createdAt: req.createdAt, expiresAt: req.expiresAt))
        return (req.id, req.code)
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
    public func approvePairingRequest(_ requestId: String) {
        guard let (trust, token) = try? repo.approvePairingRequest(id: requestId) else { return }
        pendingLock.lock()
        pendingTokens[requestId] = (trust.id, token, Date())
        pendingLock.unlock()
        try? repo.audit(actor: trust.id, action: "pairing.approve", detail: trust.displayName)
    }

    /// Called from the Mac modal's Deny button.
    public func denyPairingRequest(_ requestId: String) {
        try? repo.denyPairingRequest(id: requestId)
        try? repo.audit(actor: "user", action: "pairing.deny", detail: requestId)
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
            let pending = pendingTokens.removeValue(forKey: requestId)
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
        try? repo.audit(actor: "device", action: "pairing.cancel", detail: requestId)
        onPairingCancelled?(requestId)
        return true
    }

    public func createPairingCode() -> String? {
        guard let p = try? repo.createPairingCode() else { return nil }
        try? repo.audit(actor: "system", action: "pairing.create", detail: p.code)
        return p.code
    }

    public func redeemPairingCode(_ code: String, deviceName: String) -> (deviceId: String, token: String)? {
        do {
            guard let p = try repo.redeemPairingCode(code, deviceName: deviceName) else { return nil }
            try? repo.audit(actor: p.0.id, action: "pairing.redeem", detail: deviceName)
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
                "revoked": d.revokedAt != nil
            ]
            if let ls = d.lastSeenAt { dict["last_seen_at"] = ISO8601DateFormatter().string(from: ls) }
            return dict
        }
    }

    public func revokeDevice(_ id: String) {
        try? repo.revoke(id: id)
        try? repo.audit(actor: "system", action: "device.revoke", detail: id)
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
