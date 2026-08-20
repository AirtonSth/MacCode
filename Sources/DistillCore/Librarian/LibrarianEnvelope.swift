import Foundation

public enum LibrarianStatus: String, Sendable, Equatable, Codable {
    case ok
    case lowConfidence = "low_confidence"
    case unavailable
    case refused
    case skippedNetNegative = "skipped_net_negative"
}

public struct LibrarianEvidence: Sendable, Equatable, Codable {
    public let handle: String
    public let span: String

    public init(handle: String, span: String) {
        self.handle = handle
        self.span = span
    }
}

public struct LibrarianFallback: Sendable, Equatable, Codable {
    public let recommended: String
    public let handle: String?
    public let question: String?

    public init(recommended: String, handle: String? = nil, question: String? = nil) {
        self.recommended = recommended
        self.handle = handle
        self.question = question
    }
}

/// MCP JSON envelope for local-LLM librarian results.
public struct LibrarianEnvelope: Sendable, Equatable, Codable {
    public var status: LibrarianStatus
    public var confidence: Double
    public var op: String
    public var answer: AnyCodableJSON
    public var evidence: [LibrarianEvidence]
    public var whyUncertain: String
    public var fallback: LibrarianFallback
    public var modelID: String?

    public init(
        status: LibrarianStatus,
        confidence: Double,
        op: String,
        answer: AnyCodableJSON = .object([:]),
        evidence: [LibrarianEvidence] = [],
        whyUncertain: String = "",
        fallback: LibrarianFallback,
        modelID: String? = nil
    ) {
        self.status = status
        self.confidence = min(1, max(0, confidence))
        self.op = op
        self.answer = answer
        self.evidence = evidence
        self.whyUncertain = whyUncertain
        self.fallback = fallback
        self.modelID = modelID
    }

    public enum CodingKeys: String, CodingKey {
        case status, confidence, op, answer, evidence
        case whyUncertain = "why_uncertain"
        case fallback
        case modelID = "model_id"
    }

    public func jsonString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return #"{"status":"unavailable","confidence":0,"op":"\#(op)","answer":{},"evidence":[],"why_uncertain":"encode_failed","fallback":{"recommended":"retrieve"}}"#
        }
        return text
    }

    public static func refused(op: String, reason: String, handle: String? = nil) -> LibrarianEnvelope {
        LibrarianEnvelope(
            status: .refused,
            confidence: 0,
            op: op,
            answer: .object(["reason": .string(reason)]),
            whyUncertain: reason,
            fallback: LibrarianFallback(recommended: "ignore_local", handle: handle)
        )
    }

    public static func unavailable(op: String, reason: String, handle: String? = nil) -> LibrarianEnvelope {
        LibrarianEnvelope(
            status: .unavailable,
            confidence: 0,
            op: op,
            answer: .object(["reason": .string(reason)]),
            whyUncertain: reason,
            fallback: LibrarianFallback(recommended: "retrieve", handle: handle)
        )
    }

    public static func skipped(op: String, reason: String) -> LibrarianEnvelope {
        LibrarianEnvelope(
            status: .skippedNetNegative,
            confidence: 0,
            op: op,
            answer: .object(["reason": .string(reason)]),
            whyUncertain: reason,
            fallback: LibrarianFallback(recommended: "ignore_local")
        )
    }
}

/// Minimal JSON value for envelope answers without extra packages.
public enum AnyCodableJSON: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodableJSON])
    case object([String: AnyCodableJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([AnyCodableJSON].self) { self = .array(v); return }
        if let v = try? container.decode([String: AnyCodableJSON].self) { self = .object(v); return }
        self = .null
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}
