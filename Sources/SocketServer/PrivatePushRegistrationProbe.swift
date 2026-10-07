import Foundation
import RemoteCodeTreaty

/// What a `private.push_token.update` would persist when it only re-sends an
/// alert (or legacy single-target) APNs/FCM token. iOS sends one on most
/// reconnects; when the host already holds exactly this state the dispatcher
/// answers before the durable receipt claim instead of writing a receipt, the
/// same settings rows and a `private.push_token.updated` event again.
///
/// Live Activity registrations (push-to-start, activity-update, and any target
/// that opts into `live_activity_v2`) are never probed: they also hand the token
/// to the Live Activity coordinator, whose backend registration must not be
/// skipped.
public struct PrivatePushRegistrationProbe: Equatable, Sendable {
    public let pushToken: String
    public let pushTokenType: String
    public let liveActivityToken: String?
    public let deviceID: String?
    /// Typed alert record identity; nil for the legacy single-target request.
    public let alert: Alert?
    /// Bot attention binding the request would (re)write.
    public let profileBinding: ProfileBinding?
    public let registrationRevision: Int?

    public struct Alert: Equatable, Sendable {
        public let environment: String
        public let serverID: String
        public let contractVersion: Int
        public let capabilities: [String]?
    }

    public struct ProfileBinding: Equatable, Sendable {
        public let profileID: String
        public let hostID: String
        public let deviceID: String
    }

    /// Returns nil whenever the request is not a plain alert/legacy token
    /// re-send, or is shaped so that the full path might reject it. Those go
    /// through the normal claim → execute → finalize path unchanged.
    static func make(from params: [String: JSONValue]) -> PrivatePushRegistrationProbe? {
        guard let pushToken = params["push_token"]?.stringValue, !pushToken.isEmpty,
              let pushTokenType = params["push_token_type"]?.stringValue,
              pushTokenType == "apns" || pushTokenType == "fcm" else { return nil }
        for key in ["boot_epoch", "activity_generation", "activity_id", "activity_session_id"]
        where params[key] != nil {
            return nil
        }
        func optionalString(_ key: String) -> String?? {
            guard let value = params[key] else { return .some(nil) }
            guard let string = value.stringValue else { return nil }
            return .some(string)
        }
        guard let liveActivityToken = optionalString("live_activity_token"),
              let deviceID = optionalString("device_id"),
              let profileID = optionalString("profile_id") else { return nil }

        var registrationRevision: Int?
        if params["registration_revision"] != nil {
            guard let revision = params["registration_revision"]?.intValue, revision >= 0 else { return nil }
            registrationRevision = revision
        }
        let hasTypedMetadata = params["token_purpose"] != nil || params["environment"] != nil ||
            params["server_id"] != nil || params["contract_version"] != nil ||
            params["capabilities"] != nil || params["registration_revision"] != nil
        var alert: Alert?
        if hasTypedMetadata {
            guard params["token_purpose"]?.stringValue == "alert",
                  let environment = params["environment"]?.stringValue,
                  environment == "sandbox" || environment == "production",
                  let deviceID, !deviceID.isEmpty,
                  let serverID = params["server_id"]?.stringValue, !serverID.isEmpty else { return nil }
            var contractVersion = 1
            if params["contract_version"] != nil {
                guard let version = params["contract_version"]?.intValue, version >= 1 else { return nil }
                contractVersion = version
            }
            var capabilities: [String]?
            if let raw = params["capabilities"] {
                guard let values = raw.arrayValue else { return nil }
                let strings = values.compactMap(\.stringValue)
                guard strings.count == values.count else { return nil }
                capabilities = strings
            }
            // Any live_activity_v2 alert goes through the coordinator (or is
            // rejected when the contract version is too low): full path only.
            if capabilities?.contains("live_activity_v2") == true { return nil }
            alert = Alert(
                environment: environment,
                serverID: serverID,
                contractVersion: contractVersion,
                capabilities: capabilities
            )
        }
        var profileBinding: ProfileBinding?
        if let profileID {
            let trimmedProfile = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedProfile.isEmpty,
                  let hostID = params["authenticated_host_id"]?.stringValue,
                  !hostID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let deviceID,
                  !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            profileBinding = ProfileBinding(profileID: profileID, hostID: hostID, deviceID: deviceID)
        }
        return PrivatePushRegistrationProbe(
            pushToken: pushToken,
            pushTokenType: pushTokenType,
            liveActivityToken: liveActivityToken,
            deviceID: deviceID,
            alert: alert,
            profileBinding: profileBinding,
            registrationRevision: registrationRevision
        )
    }

    /// The exact result the full path returns for this request.
    var result: JSONValue {
        var result: [String: JSONValue] = [
            "ok": .bool(true),
            "push_token_type": .string(pushTokenType)
        ]
        if let registrationRevision {
            result["registration_revision"] = .number(Double(registrationRevision))
        }
        if let profileBinding {
            result["profile_id"] = .string(profileBinding.profileID)
            result["host_id"] = .string(profileBinding.hostID)
            result["device_id"] = .string(profileBinding.deviceID)
        }
        return .object(result)
    }
}
