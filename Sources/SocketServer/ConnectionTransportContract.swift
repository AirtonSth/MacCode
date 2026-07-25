import Foundation

public struct ConnectionDomainRevisions: Codable, Equatable, Sendable {
    public let shell: Int64
    public let surfaces: Int64
    public let agentThreads: Int64
    public let browser: Int64
    public let files: Int64

    public init(shell: Int64, surfaces: Int64, agentThreads: Int64, browser: Int64, files: Int64) {
        self.shell = shell
        self.surfaces = surfaces
        self.agentThreads = agentThreads
        self.browser = browser
        self.files = files
    }

    public static let zero = ConnectionDomainRevisions(
        shell: 0, surfaces: 0, agentThreads: 0, browser: 0, files: 0
    )

    var jsonValue: JSONValue {
        .object([
            "shell": .number(Double(shell)),
            "surfaces": .number(Double(surfaces)),
            "agentThreads": .number(Double(agentThreads)),
            "browser": .number(Double(browser)),
            "files": .number(Double(files)),
        ])
    }

    /// Domains whose host revision is strictly ahead of `known` (Wave 4 incremental).
    public func domainsChanged(since known: ConnectionDomainRevisions) -> Set<String> {
        var out = Set<String>()
        if shell > known.shell { out.insert("shell") }
        if surfaces > known.surfaces { out.insert("surfaces") }
        if agentThreads > known.agentThreads { out.insert("agentThreads") }
        if browser > known.browser { out.insert("browser") }
        if files > known.files { out.insert("files") }
        return out
    }

    public static func parse(_ any: Any?) -> ConnectionDomainRevisions? {
        guard let object = any as? [String: Any] else { return nil }
        func rev(_ key: String) -> Int64? {
            guard let number = object[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number) else { return nil }
            return Int64(truncating: number)
        }
        guard let shell = rev("shell"),
              let surfaces = rev("surfaces"),
              let agentThreads = rev("agentThreads"),
              let browser = rev("browser"),
              let files = rev("files") else { return nil }
        return ConnectionDomainRevisions(
            shell: shell,
            surfaces: surfaces,
            agentThreads: agentThreads,
            browser: browser,
            files: files
        )
    }
}

public struct ConnectionSnapshotWorkspaceItems: Equatable, Sendable {
    public let workspaceId: String
    public let items: [JSONValue]

    public init(workspaceId: String, items: [JSONValue]) {
        self.workspaceId = workspaceId
        self.items = items
    }

    var jsonValue: JSONValue {
        .object(["workspaceId": .string(workspaceId), "items": .array(items)])
    }
}

public struct ConnectionSnapshotSurfaceState: Equatable, Sendable {
    public let workspaceId: String
    public let surfaceId: String
    public let state: JSONValue

    public init(workspaceId: String, surfaceId: String, state: JSONValue) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.state = state
    }

    var jsonValue: JSONValue {
        .object([
            "workspaceId": .string(workspaceId),
            "surfaceId": .string(surfaceId),
            "state": state,
        ])
    }
}

public struct ConnectionSnapshotReadState: Equatable, Sendable {
    public let selectedWorkspaceId: String?
    public let workspaces: [JSONValue]
    public let surfaces: [ConnectionSnapshotWorkspaceItems]
    public let agentThreads: [ConnectionSnapshotWorkspaceItems]
    public let browserStates: [ConnectionSnapshotSurfaceState]
    public let filesStates: [ConnectionSnapshotSurfaceState]

    public init(
        selectedWorkspaceId: String?,
        workspaces: [JSONValue],
        surfaces: [ConnectionSnapshotWorkspaceItems],
        agentThreads: [ConnectionSnapshotWorkspaceItems],
        browserStates: [ConnectionSnapshotSurfaceState],
        filesStates: [ConnectionSnapshotSurfaceState]
    ) {
        self.selectedWorkspaceId = selectedWorkspaceId
        self.workspaces = workspaces
        self.surfaces = surfaces
        self.agentThreads = agentThreads
        self.browserStates = browserStates
        self.filesStates = filesStates
    }

    func jsonValue(domainRevisions: ConnectionDomainRevisions) -> JSONValue {
        jsonValue(domainRevisions: domainRevisions, includeDomains: nil)
    }

    /// Wave 4: when `includeDomains` is non-nil, only those domains are emitted
    /// (plus `domainRevisions` / `partial` / `includedDomains` metadata).
    /// `nil` means full snapshot (backward compatible exact key set).
    func jsonValue(
        domainRevisions: ConnectionDomainRevisions,
        includeDomains: Set<String>?
    ) -> JSONValue {
        let all: Set<String> = ["shell", "surfaces", "agentThreads", "browser", "files"]
        let include = includeDomains ?? all
        let partial = includeDomains != nil && include != all

        if !partial {
            return .object([
                "selectedWorkspaceId": selectedWorkspaceId.map(JSONValue.string) ?? .null,
                "workspaces": .array(workspaces),
                "surfaces": .array(surfaces.map(\.jsonValue)),
                "agentThreads": .array(agentThreads.map(\.jsonValue)),
                "browserStates": .array(browserStates.map(\.jsonValue)),
                "filesStates": .array(filesStates.map(\.jsonValue)),
                "domainRevisions": domainRevisions.jsonValue,
            ])
        }

        var object: [String: JSONValue] = [
            "partial": .bool(true),
            "includedDomains": .array(include.sorted().map(JSONValue.string)),
            "domainRevisions": domainRevisions.jsonValue,
        ]
        if include.contains("shell") {
            object["selectedWorkspaceId"] = selectedWorkspaceId.map(JSONValue.string) ?? .null
            object["workspaces"] = .array(workspaces)
        }
        if include.contains("surfaces") {
            object["surfaces"] = .array(surfaces.map(\.jsonValue))
        }
        if include.contains("agentThreads") {
            object["agentThreads"] = .array(agentThreads.map(\.jsonValue))
        }
        if include.contains("browser") {
            object["browserStates"] = .array(browserStates.map(\.jsonValue))
        }
        if include.contains("files") {
            object["filesStates"] = .array(filesStates.map(\.jsonValue))
        }
        return .object(object)
    }
}

@MainActor
public protocol ConnectionSnapshotRouting: AnyObject {
    func readConnectionSnapshotState() throws -> ConnectionSnapshotReadState
}

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
    /// Progress-idle budget for snapshot transfer (ms). Independent of heartbeat (C-03).
    let snapshotTimeoutMs: Int64
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
                "snapshotTimeoutMs",
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
        if type == "snapshot", !hasStrictSnapshotRevisionFields(object) {
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
                "heartbeatTimeoutMs", "snapshotTimeoutMs",
                "currentSequence", "oldestReplaySequence",
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

    private static func hasStrictSnapshotRevisionFields(_ object: [String: Any]) -> Bool {
        guard let state = object["state"] as? [String: Any],
              let revisions = state["domainRevisions"] as? [String: Any],
              Set(revisions.keys) == ["shell", "surfaces", "agentThreads", "browser", "files"] else {
            return false
        }
        return revisions.values.allSatisfy(isStrictInteger)
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
        // C-06: welcome may advertise Wi-Fi (10s/30s) or cellular (25s/90s) profiles.
        // C-03: snapshotTimeoutMs is an independent progress-idle transfer budget.
        guard frame.serverTimeEpochMs >= 0,
              (1...25_000).contains(frame.heartbeatIntervalMs),
              frame.heartbeatTimeoutMs > frame.heartbeatIntervalMs,
              frame.heartbeatTimeoutMs <= 90_000,
              (5_000...60_000).contains(frame.snapshotTimeoutMs),
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
              frame.snapshotMethod == "sync.snapshot" else {
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
              frame.stateVersion == 3,
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
        guard case .object(let state) = value else { return false }
        // Wave 4 partial snapshots: subset of domains + metadata.
        if case .bool(true)? = state["partial"] {
            return isValidPartialSnapshotState(state)
        }
        guard Set(state.keys) == [
                  "selectedWorkspaceId", "workspaces", "surfaces", "agentThreads",
                  "browserStates", "filesStates", "domainRevisions",
              ] else {
            return false
        }
        switch state["selectedWorkspaceId"] {
        case .null?: break
        case .string(let value)?: guard isNonEmpty(value) else { return false }
        default: return false
        }
        for key in ["workspaces", "surfaces", "agentThreads", "browserStates", "filesStates"] {
            guard case .array? = state[key] else { return false }
        }
        guard case .array(let workspaceValues)? = state["workspaces"] else { return false }
        let workspaceIDs = workspaceValues.compactMap { item -> String? in
            guard case .object(let object) = item else { return nil }
            return object["id"]?.stringValue
        }
        guard workspaceIDs.count == workspaceValues.count,
              Set(workspaceIDs).count == workspaceIDs.count,
              workspaceIDs.allSatisfy(isNonEmpty) else {
            return false
        }
        let workspaceSet = Set(workspaceIDs)
        if case .string(let selected)? = state["selectedWorkspaceId"],
           !workspaceSet.contains(selected) {
            return false
        }

        var surfaceReferences: [String: (workspaceID: String, type: String)] = [:]
        guard validateSurfaceItems(
            state["surfaces"],
            workspaceIDs: workspaceSet,
            references: &surfaceReferences
        ) else { return false }
        var threadIDs = Set<String>()
        guard validateWorkspaceItems(
            state["agentThreads"],
            workspaceIDs: workspaceSet,
            itemIDs: &threadIDs
        ) else { return false }
        var surfaceStateIDs = Set<String>()
        guard validateSurfaceStates(
            state["browserStates"],
            expectedType: "browser",
            surfaceReferences: surfaceReferences,
            stateIDs: &surfaceStateIDs
        ), validateSurfaceStates(
            state["filesStates"],
            expectedType: "files",
            surfaceReferences: surfaceReferences,
            stateIDs: &surfaceStateIDs
        ) else { return false }

        guard case .object(let revisions)? = state["domainRevisions"],
              Set(revisions.keys) == ["shell", "surfaces", "agentThreads", "browser", "files"] else {
            return false
        }
        return revisions.values.allSatisfy { value in
            guard case .number(let revision) = value else { return false }
            return revision.isFinite && revision >= 0 && revision.rounded(.towardZero) == revision
        }
    }

    /// Wave 4 partial: requires domainRevisions + includedDomains + only those domain keys.
    private static func isValidPartialSnapshotState(_ state: [String: JSONValue]) -> Bool {
        guard case .object(let revisions)? = state["domainRevisions"],
              Set(revisions.keys) == ["shell", "surfaces", "agentThreads", "browser", "files"],
              revisions.values.allSatisfy({ value in
                  guard case .number(let revision) = value else { return false }
                  return revision.isFinite && revision >= 0 && revision.rounded(.towardZero) == revision
              }),
              case .array(let includedRaw)? = state["includedDomains"] else {
            return false
        }
        let allowed = Set(["shell", "surfaces", "agentThreads", "browser", "files"])
        var included = Set<String>()
        for value in includedRaw {
            guard case .string(let name) = value, allowed.contains(name) else { return false }
            guard included.insert(name).inserted else { return false }
        }
        // Required metadata keys only + domain payloads that are included.
        var expected: Set<String> = ["partial", "includedDomains", "domainRevisions"]
        if included.contains("shell") {
            expected.formUnion(["selectedWorkspaceId", "workspaces"])
        }
        if included.contains("surfaces") { expected.insert("surfaces") }
        if included.contains("agentThreads") { expected.insert("agentThreads") }
        if included.contains("browser") { expected.insert("browserStates") }
        if included.contains("files") { expected.insert("filesStates") }
        guard Set(state.keys) == expected else { return false }
        // Lightweight presence checks (full structural validation still runs on
        // full snapshots; partials are merged client-side into a prior baseline).
        if included.contains("shell") {
            guard state["selectedWorkspaceId"] == .null
                    || state["selectedWorkspaceId"]?.stringValue != nil,
                  case .array? = state["workspaces"] else { return false }
        }
        if included.contains("surfaces"), state["surfaces"]?.arrayValue == nil { return false }
        if included.contains("agentThreads"), state["agentThreads"]?.arrayValue == nil { return false }
        if included.contains("browser"), state["browserStates"]?.arrayValue == nil { return false }
        if included.contains("files"), state["filesStates"]?.arrayValue == nil { return false }
        return true
    }

    private static func validateWorkspaceItems(
        _ value: JSONValue?,
        workspaceIDs: Set<String>,
        itemIDs: inout Set<String>
    ) -> Bool {
        guard case .array(let groups)? = value else { return false }
        var groupedWorkspaceIDs = Set<String>()
        for group in groups {
            guard case .object(let object) = group,
                  Set(object.keys) == ["workspaceId", "items"],
                  let workspaceID = object["workspaceId"]?.stringValue,
                  workspaceIDs.contains(workspaceID),
                  groupedWorkspaceIDs.insert(workspaceID).inserted,
                  case .array(let items)? = object["items"] else {
                return false
            }
            for item in items {
                guard case .object(let itemObject) = item,
                      let itemID = itemObject["id"]?.stringValue,
                      let itemWorkspaceID = itemObject["workspaceId"]?.stringValue,
                      isNonEmpty(itemID),
                      isNonEmpty(itemWorkspaceID),
                      itemWorkspaceID == workspaceID,
                      itemIDs.insert(itemID).inserted else {
                    return false
                }
            }
        }
        return true
    }

    private static func validateSurfaceItems(
        _ value: JSONValue?,
        workspaceIDs: Set<String>,
        references: inout [String: (workspaceID: String, type: String)]
    ) -> Bool {
        guard case .array(let groups)? = value else { return false }
        var groupedWorkspaceIDs = Set<String>()
        for group in groups {
            guard case .object(let object) = group,
                  Set(object.keys) == ["workspaceId", "items"],
                  let workspaceID = object["workspaceId"]?.stringValue,
                  workspaceIDs.contains(workspaceID),
                  groupedWorkspaceIDs.insert(workspaceID).inserted,
                  case .array(let items)? = object["items"] else {
                return false
            }
            for item in items {
                guard case .object(let itemObject) = item,
                      let itemID = itemObject["id"]?.stringValue,
                      let type = itemObject["type"]?.stringValue,
                      isNonEmpty(itemID),
                      isNonEmpty(type),
                      references[itemID] == nil else {
                    return false
                }
                references[itemID] = (workspaceID, type)
            }
        }
        return true
    }

    private static func validateSurfaceStates(
        _ value: JSONValue?,
        expectedType: String,
        surfaceReferences: [String: (workspaceID: String, type: String)],
        stateIDs: inout Set<String>
    ) -> Bool {
        guard case .array(let values)? = value else { return false }
        var typedStateIDs = Set<String>()
        for value in values {
            guard case .object(let object) = value,
                  Set(object.keys) == ["workspaceId", "surfaceId", "state"],
                  let workspaceID = object["workspaceId"]?.stringValue,
                  let surfaceID = object["surfaceId"]?.stringValue,
                  let reference = surfaceReferences[surfaceID],
                  reference.workspaceID == workspaceID,
                  reference.type == expectedType,
                  typedStateIDs.insert(surfaceID).inserted,
                  stateIDs.insert(surfaceID).inserted,
                  case .object? = object["state"] else {
                return false
            }
        }
        let expectedIDs = Set(surfaceReferences.compactMap { id, reference in
            reference.type == expectedType ? id : nil
        })
        return typedStateIDs == expectedIDs
    }
}
