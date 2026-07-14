import Foundation

enum ConnectionProtocolFailure: Error, Equatable, CustomStringConvertible {
    case frameTooLarge
    case malformedJSON
    case unsupportedVersion
    case unknownType
    case unknownFields
    case invalidFrame

    var description: String {
        switch self {
        case .frameTooLarge: return "frame_too_large"
        case .malformedJSON: return "malformed_json"
        case .unsupportedVersion: return "unsupported_version"
        case .unknownType: return "unknown_type"
        case .unknownFields: return "unknown_fields"
        case .invalidFrame: return "invalid_frame"
        }
    }
}

struct ConnectionWelcomeFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let serverTimeEpochMs: Int64
    let heartbeatIntervalMs: Int64
    let heartbeatTimeoutMs: Int64
    let currentSequence: Int64
    let oldestReplaySequence: Int64
    let capabilities: [String]
}

struct ConnectionHeartbeatFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let sentAtEpochMs: Int64
    let lastReceivedSequence: Int64
    let nonce: String
}

struct ConnectionClosingFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let code: Int
    let reason: String
    let retryable: Bool
    let retryAfterMs: Int64?

    enum CodingKeys: String, CodingKey {
        case protocolVersion, type, connectionId, hostId, bootEpoch
        case code, reason, retryable, retryAfterMs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(type, forKey: .type)
        try container.encode(connectionId, forKey: .connectionId)
        try container.encode(hostId, forKey: .hostId)
        try container.encode(bootEpoch, forKey: .bootEpoch)
        try container.encode(code, forKey: .code)
        try container.encode(reason, forKey: .reason)
        try container.encode(retryable, forKey: .retryable)
        if let retryAfterMs {
            try container.encode(retryAfterMs, forKey: .retryAfterMs)
        } else {
            try container.encodeNil(forKey: .retryAfterMs)
        }
    }
}

struct ConnectionErrorFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let code: String
    let message: String
    let retryable: Bool
    let requestId: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion, type, connectionId, hostId, bootEpoch
        case code, message, retryable, requestId
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(type, forKey: .type)
        try container.encode(connectionId, forKey: .connectionId)
        try container.encode(hostId, forKey: .hostId)
        try container.encode(bootEpoch, forKey: .bootEpoch)
        try container.encode(code, forKey: .code)
        try container.encode(message, forKey: .message)
        try container.encode(retryable, forKey: .retryable)
        if let requestId {
            try container.encode(requestId, forKey: .requestId)
        } else {
            try container.encodeNil(forKey: .requestId)
        }
    }
}

struct ConnectionEventFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let sequence: Int64
    let eventId: String
    let occurredAtEpochMs: Int64
    let kind: String
    let payload: JSONValue
}

struct ConnectionBaselineRequiredFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let reason: String
    let requestedAfterSequence: Int64
    let currentSequence: Int64
    let snapshotMethod: String
}

struct ConnectionSnapshotFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let sequence: Int64
    let snapshotId: String
    let generatedAtEpochMs: Int64
    let stateVersion: Int
    let state: JSONValue
}

enum ConnectionTransportFrame: Equatable, Sendable {
    static let protocolVersion = 3
    static let maximumEncodedBytes = 1_048_576
    private static let dottedNameExpression = try! NSRegularExpression(
        pattern: #"[a-z][a-z0-9]*(?:\.[a-z0-9_]+)+"#
    )

    case welcome(ConnectionWelcomeFrame)
    case heartbeat(ConnectionHeartbeatFrame)
    case closing(ConnectionClosingFrame)
    case error(ConnectionErrorFrame)
    case event(ConnectionEventFrame)
    case baselineRequired(ConnectionBaselineRequiredFrame)
    case snapshot(ConnectionSnapshotFrame)

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        let data: Data
        switch self {
        case .welcome(let frame): try Self.validate(frame); data = try encoder.encode(frame)
        case .heartbeat(let frame): try Self.validate(frame); data = try encoder.encode(frame)
        case .closing(let frame): try Self.validate(frame); data = try encoder.encode(frame)
        case .error(let frame): try Self.validate(frame); data = try encoder.encode(frame)
        case .event(let frame): try Self.validate(frame); data = try encoder.encode(frame)
        case .baselineRequired(let frame): try Self.validate(frame); data = try encoder.encode(frame)
        case .snapshot(let frame): try Self.validate(frame); data = try encoder.encode(frame)
        }
        guard data.count <= Self.maximumEncodedBytes else {
            throw ConnectionProtocolFailure.frameTooLarge
        }
        return data
    }

    static func decodeStrict(_ data: Data) throws -> ConnectionTransportFrame {
        guard data.count <= maximumEncodedBytes else {
            throw ConnectionProtocolFailure.frameTooLarge
        }
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ConnectionProtocolFailure.malformedJSON
        }
        guard let object = value as? [String: Any] else {
            throw ConnectionProtocolFailure.invalidFrame
        }
        guard let version = object["protocolVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(protocolVersion) else {
            throw ConnectionProtocolFailure.unsupportedVersion
        }
        guard let type = object["type"] as? String else {
            throw ConnectionProtocolFailure.invalidFrame
        }

        let allowedKeys: Set<String>
        switch type {
        case "welcome":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "serverTimeEpochMs", "heartbeatIntervalMs", "heartbeatTimeoutMs",
                "currentSequence", "oldestReplaySequence", "capabilities",
            ]
        case "heartbeat":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "sentAtEpochMs", "lastReceivedSequence", "nonce",
            ]
        case "closing":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "code", "reason", "retryable", "retryAfterMs",
            ]
        case "error":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "code", "message", "retryable", "requestId",
            ]
        case "event":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "sequence", "eventId", "occurredAtEpochMs", "kind", "payload",
            ]
        case "baselineRequired":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "reason", "requestedAfterSequence", "currentSequence", "snapshotMethod",
            ]
        case "snapshot":
            allowedKeys = [
                "protocolVersion", "type", "connectionId", "hostId", "bootEpoch",
                "sequence", "snapshotId", "generatedAtEpochMs", "stateVersion", "state",
            ]
        default:
            throw ConnectionProtocolFailure.unknownType
        }
        guard Set(object.keys) == allowedKeys else {
            throw ConnectionProtocolFailure.unknownFields
        }
        guard hasStrictIntegerFields(object, type: type) else {
            throw ConnectionProtocolFailure.invalidFrame
        }

        let decoder = JSONDecoder()
        do {
            switch type {
            case "welcome":
                let frame = try decoder.decode(ConnectionWelcomeFrame.self, from: data)
                try validate(frame)
                return .welcome(frame)
            case "heartbeat":
                let frame = try decoder.decode(ConnectionHeartbeatFrame.self, from: data)
                try validate(frame)
                return .heartbeat(frame)
            case "closing":
                let frame = try decoder.decode(ConnectionClosingFrame.self, from: data)
                try validate(frame)
                return .closing(frame)
            case "error":
                let frame = try decoder.decode(ConnectionErrorFrame.self, from: data)
                try validate(frame)
                return .error(frame)
            case "event":
                let frame = try decoder.decode(ConnectionEventFrame.self, from: data)
                try validate(frame)
                return .event(frame)
            case "baselineRequired":
                let frame = try decoder.decode(ConnectionBaselineRequiredFrame.self, from: data)
                try validate(frame)
                return .baselineRequired(frame)
            case "snapshot":
                let frame = try decoder.decode(ConnectionSnapshotFrame.self, from: data)
                try validate(frame)
                return .snapshot(frame)
            default: throw ConnectionProtocolFailure.unknownType
            }
        } catch let failure as ConnectionProtocolFailure {
            throw failure
        } catch {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validateCommon(
        protocolVersion: Int,
        type: String,
        expectedType: String,
        connectionId: String,
        hostId: String,
        bootEpoch: UInt64
    ) throws {
        guard protocolVersion == self.protocolVersion,
              type == expectedType,
              isNonEmpty(connectionId),
              isNonEmpty(hostId) else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func hasStrictIntegerFields(_ object: [String: Any], type: String) -> Bool {
        let requiredKeys: [String]
        switch type {
        case "welcome":
            requiredKeys = [
                "bootEpoch", "serverTimeEpochMs", "heartbeatIntervalMs",
                "heartbeatTimeoutMs", "currentSequence", "oldestReplaySequence",
            ]
        case "heartbeat":
            requiredKeys = ["bootEpoch", "sentAtEpochMs", "lastReceivedSequence"]
        case "closing":
            requiredKeys = ["bootEpoch", "code"]
        case "error":
            requiredKeys = ["bootEpoch"]
        case "event":
            requiredKeys = ["bootEpoch", "sequence", "occurredAtEpochMs"]
        case "baselineRequired":
            requiredKeys = ["bootEpoch", "requestedAfterSequence", "currentSequence"]
        case "snapshot":
            requiredKeys = ["bootEpoch", "sequence", "generatedAtEpochMs", "stateVersion"]
        default:
            return false
        }
        guard requiredKeys.allSatisfy({ isStrictInteger(object[$0]) }) else { return false }
        if type == "closing", !(object["retryAfterMs"] is NSNull) {
            return isStrictInteger(object["retryAfterMs"])
        }
        return true
    }

    private static func isStrictInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return false
        }
        return !CFNumberIsFloatType(number)
    }

    private static func validate(_ frame: ConnectionWelcomeFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "welcome",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.serverTimeEpochMs >= 0,
              frame.heartbeatIntervalMs > 0,
              frame.heartbeatTimeoutMs > frame.heartbeatIntervalMs,
              frame.currentSequence >= 0,
              frame.oldestReplaySequence >= 0,
              frame.oldestReplaySequence <= frame.currentSequence,
              !frame.capabilities.isEmpty,
              Set(frame.capabilities).count == frame.capabilities.count else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionHeartbeatFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "heartbeat",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.sentAtEpochMs >= 0,
              frame.lastReceivedSequence >= 0,
              isNonEmpty(frame.nonce) else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionClosingFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "closing",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        let reservedCodes: Set<Int> = [1004, 1005, 1006, 1015]
        guard (1000...4999).contains(frame.code),
              !reservedCodes.contains(frame.code),
              isNonEmpty(frame.reason),
              frame.retryAfterMs.map({ $0 >= 0 }) ?? true else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionErrorFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "error",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard isNonEmpty(frame.code),
              isNonEmpty(frame.message),
              frame.requestId.map(isNonEmpty) ?? true else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionEventFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "event",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.sequence > 0,
              isNonEmpty(frame.eventId),
              frame.occurredAtEpochMs >= 0,
              isDotted(frame.kind),
              case .object = frame.payload else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionBaselineRequiredFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "baselineRequired",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        let allowedReasons: Set<String> = [
            "eventGap", "hostReset", "replayTruncated", "snapshotRejected",
        ]
        guard allowedReasons.contains(frame.reason),
              frame.requestedAfterSequence >= 0,
              frame.currentSequence >= frame.requestedAfterSequence,
              frame.snapshotMethod == "mirror.snapshot" else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func validate(_ frame: ConnectionSnapshotFrame) throws {
        try validateCommon(
            protocolVersion: frame.protocolVersion,
            type: frame.type,
            expectedType: "snapshot",
            connectionId: frame.connectionId,
            hostId: frame.hostId,
            bootEpoch: frame.bootEpoch
        )
        guard frame.sequence >= 0,
              isNonEmpty(frame.snapshotId),
              frame.generatedAtEpochMs >= 0,
              frame.stateVersion >= 1,
              isValidSnapshotState(frame.state) else {
            throw ConnectionProtocolFailure.invalidFrame
        }
    }

    private static func isNonEmpty(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isDotted(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return dottedNameExpression.firstMatch(in: value, range: range)?.range == range
    }

    private static func isValidSnapshotState(_ value: JSONValue) -> Bool {
        guard case .object(let state) = value,
              Set(state.keys) == [
                  "selectedWorkspaceId", "workspaces", "surfaces", "agentThreads",
              ] else {
            return false
        }
        switch state["selectedWorkspaceId"] {
        case .null?: break
        case .string(let value)?: guard isNonEmpty(value) else { return false }
        default: return false
        }
        for key in ["workspaces", "surfaces", "agentThreads"] {
            guard case .array? = state[key] else { return false }
        }
        return true
    }
}
