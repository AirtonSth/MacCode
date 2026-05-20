import Foundation

public struct JSONRPCRequest: Codable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: [String: JSONValue]?
}

public struct JSONRPCResponse: Codable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: JSONRPCID?, result: JSONValue?) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }
    public init(id: JSONRPCID?, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }
}

public struct JSONRPCError: Codable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }

    public static let parseError = JSONRPCError(code: -32700, message: "Parse error")
    public static let invalidRequest = JSONRPCError(code: -32600, message: "Invalid Request")
    public static let methodNotFound = JSONRPCError(code: -32601, message: "Method not found")
    public static let invalidParams = JSONRPCError(code: -32602, message: "Invalid params")
    public static let internalError = JSONRPCError(code: -32603, message: "Internal error")
    public static func notSupported(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32004, message: "Method not supported in V1", data: .string(method))
    }
}

public enum JSONRPCID: Codable, Hashable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let n = try? c.decode(Int.self) { self = .number(n); return }
        throw DecodingError.typeMismatch(JSONRPCID.self, .init(codingPath: decoder.codingPath, debugDescription: "id must be string or number"))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        }
    }
}

public indirect enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.typeMismatch(JSONValue.self, .init(codingPath: decoder.codingPath, debugDescription: "unknown json"))
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
    public var intValue: Int? { if case .number(let n) = self { return Int(n) } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
}

public extension JSONValue {
    static func obj(_ pairs: [String: JSONValue]) -> JSONValue { .object(pairs) }
    static func from(_ any: Any?) -> JSONValue {
        guard let any, !(any is NSNull) else { return .null }
        if let s = any as? String { return .string(s) }
        // JSONSerialization bridges both `true` and `1` to NSNumber, and
        // `1 as? Bool` succeeds — so an integer count like `additions: 1`
        // would wrongly encode as `true`. CFBoolean is the only reliable
        // bool discriminator; everything else NSNumber is a real number.
        if let n = any as? NSNumber {
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .number(Double(i)) }
        if let d = any as? Double { return .number(d) }
        if let arr = any as? [Any] { return .array(arr.map { JSONValue.from($0) }) }
        if let dict = any as? [String: Any] {
            var out: [String: JSONValue] = [:]
            for (k, v) in dict { out[k] = JSONValue.from(v) }
            return .object(out)
        }
        return .null
    }
}
