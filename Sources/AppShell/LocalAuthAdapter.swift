import Foundation
import Persistence
import SocketServer

public final class LocalAuthAdapter: DirectAuthProvider {
    let repo: DeviceTrustRepository
    public init(repo: DeviceTrustRepository) { self.repo = repo }

    public func verify(token: String) -> Bool {
        ((try? repo.verify(token: token)) ?? nil) != nil
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
