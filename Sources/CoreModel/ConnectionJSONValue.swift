import Foundation

/// JSON wire values for the provider-independent connections boundary.
public indirect enum ConnectionJSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ConnectionJSONValue])
    case object([String: ConnectionJSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([ConnectionJSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: ConnectionJSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(ConnectionJSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "unknown json"))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    // `Int(_: Double)` traps on non-finite or out-of-range values; `Int(exactly:)`
    // returns nil instead (also rejecting fractional numbers on integer fields),
    // so a hostile/oversized JSON number can never abort the host process.
    public var intValue: Int? { if case .number(let n) = self { return Int(exactly: n) } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [ConnectionJSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: ConnectionJSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}
