import Foundation

public protocol RemoteCodeRPCContract {
    associatedtype Params: Codable & Sendable
    associatedtype Result: Codable & Sendable
    static var method: String { get }
}

public struct RemoteCodeError: Codable, Equatable, Sendable, Error {
    public enum Kind: Equatable, Sendable {
        case parseError
        case invalidRequest
        case methodNotFound
        case invalidParams
        case internalError
        case missingRequestID
        case botControlPlaneOff
        case botNotFound
        case botLimit
        case reservedCapability
        case crossTarget
        case idempotencyConflict
        case unknown(Int)
    }

    public let code: Int
    public let message: String
    public let data: RemoteCodeJSONValue?

    public init(code: Int, message: String, data: RemoteCodeJSONValue?) {
        self.code = code
        self.message = message
        self.data = data
    }

    public var kind: Kind {
        switch code {
        case -32700: return .parseError
        case -32600: return .invalidRequest
        case -32601: return .methodNotFound
        case -32602: return .invalidParams
        case -32603: return .internalError
        case -32097: return .missingRequestID
        case -32081: return .botControlPlaneOff
        case -32044: return .botNotFound
        case -32082: return .botLimit
        case -32083: return .reservedCapability
        case -32084: return .crossTarget
        case -32086: return .idempotencyConflict
        default: return .unknown(code)
        }
    }
}
