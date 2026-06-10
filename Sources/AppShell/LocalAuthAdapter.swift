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

    /// requestId → freshly minted plaintext token, held in RAM only and
    /// delivered to the device exactly once (never persisted — mirrors
    /// the redeem path's no-plaintext-at-rest invariant).
    private let pendingLock = NSLock()
    private var pendingTokens: [String: (deviceId: String, token: String)] = [:]

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
        guard let privateAccountAccessToken,
              let localSession = privateAccountStore?.load(),
              localSession.user.subscribed else { return false }

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
        pendingLock.lock(); pendingTokens[requestId] = (trust.id, token); pendingLock.unlock()
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
            pendingLock.lock()
            let pending = pendingTokens.removeValue(forKey: requestId)
            pendingLock.unlock()
            return ("approved", r.deviceID ?? pending?.deviceId, pending?.token)
        }
        return (r.effectiveStatus, nil, nil)
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

private final class LockedAccountVerificationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
