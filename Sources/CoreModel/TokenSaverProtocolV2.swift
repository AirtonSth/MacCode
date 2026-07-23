import Foundation

/// Fase 1 protocol/grants/hook reservation (task-07).
/// Policy types for AF_UNIX identity, grants, deadline raw, and reserved `hook` subcommand.
public enum TokenSaverProtocolV2 {
    public static let schemaVersion = 2
    public static let taskID = "task-07"
    public static let reservedHookSubcommand = "hook"

    public enum Grant: String, Sendable, CaseIterable, Equatable {
        case distill
        case outcomeAck = "outcome_ack"
        case retrieve
        case search
        case stats
        case admin
    }

    public enum DecodeResult: Sendable, Equatable {
        case ok
        case rawMissingField(String)
        case rawUnknownEnum(String)
        case rawTimeout
        case rawSidecarDown
    }

    public struct PeerIdentity: Sendable, Equatable {
        public let uid: uid_t
        public let expectedUID: uid_t
        public let dirMode: mode_t
        public let socketMode: mode_t

        public init(uid: uid_t, expectedUID: uid_t, dirMode: mode_t, socketMode: mode_t) {
            self.uid = uid
            self.expectedUID = expectedUID
            self.dirMode = dirMode
            self.socketMode = socketMode
        }

        public var isAuthorized: Bool {
            uid == expectedUID && dirMode == 0o700 && socketMode == 0o600
        }
    }

    public struct WireMessage: Sendable, Equatable {
        public let protocolVersion: Int
        public let capabilitySet: Set<String>
        public let generation: UInt64
        public let operationDigest: String
        public let bindingDigestHex: String
        public let handle: String?

        public init(
            protocolVersion: Int,
            capabilitySet: Set<String>,
            generation: UInt64,
            operationDigest: String,
            bindingDigestHex: String,
            handle: String?
        ) {
            self.protocolVersion = protocolVersion
            self.capabilitySet = capabilitySet
            self.generation = generation
            self.operationDigest = operationDigest
            self.bindingDigestHex = bindingDigestHex
            self.handle = handle
        }
    }

    /// `hook` is reserved and must never fall through to generic compression.
    public static func routeCLISubcommand(_ name: String) -> String {
        if name == reservedHookSubcommand { return "hook_handler" }
        return "generic_or_other"
    }

    public static func isHookFallthroughToGenericCompression(subcommand: String, routedTo: String) -> Bool {
        subcommand == reservedHookSubcommand && routedTo != "hook_handler"
    }

    public static func decodeRequired(
        version: Int?,
        capabilities: Set<String>?,
        generation: UInt64?,
        knownCapabilityEnums: Set<String>
    ) -> DecodeResult {
        guard let version else { return .rawMissingField("protocol_version") }
        guard version == schemaVersion else { return .rawUnknownEnum("protocol_version") }
        guard let capabilities else { return .rawMissingField("capability_set") }
        guard let generation else { return .rawMissingField("generation") }
        _ = generation
        if let unknown = capabilities.first(where: { !knownCapabilityEnums.contains($0) }) {
            return .rawUnknownEnum(unknown)
        }
        return .ok
    }

    public static func grantAllows(_ grant: Grant, requested: Grant) -> Bool {
        grant == requested
    }

    public static func containsSecretLeak(argv: [String], env: [String: String]) -> Bool {
        let secretMarkers = ["BOOTSTRAP_TOKEN", "SIDECAR_SECRET", "TOKEN_SAVER_KEY"]
        for arg in argv where secretMarkers.contains(where: { arg.contains($0) || arg.count > 64 && arg.contains("=") }) {
            // Heuristic: explicit secret key names in argv are leaks.
            if secretMarkers.contains(where: { arg.contains($0) }) { return true }
        }
        for key in env.keys where secretMarkers.contains(key) {
            return true
        }
        return false
    }

    public struct DeadlineState: Sendable, Equatable {
        public let expired: Bool
        public let cleanupPerformed: Bool
        public let mutatedAfterExpiry: Bool

        public init(expired: Bool, cleanupPerformed: Bool, mutatedAfterExpiry: Bool) {
            self.expired = expired
            self.cleanupPerformed = cleanupPerformed
            self.mutatedAfterExpiry = mutatedAfterExpiry
        }

        public var isSafeRaw: Bool {
            !expired || (cleanupPerformed && !mutatedAfterExpiry)
        }
    }
}
