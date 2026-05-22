import Foundation

public enum PayloadCodecError: Error, Equatable {
    case invalidData
    case sizeMismatch(expected: Int, actual: Int)
    case unsupported(String)
}

public struct PayloadCodec: Sendable, Equatable {
    public let wireName: String
    private static let wsEnvelopeMagic = Data("RC2WS1".utf8)

    public static let identity = PayloadCodec(wireName: "identity")
    public static let lzfse = PayloadCodec(wireName: "rc-lzfse")
    public static let acceptEncodingHeader = lzfse.wireName

    public init(wireName: String) {
        self.wireName = wireName
    }

    public func encode(_ data: Data) throws -> Data {
        switch wireName {
        case Self.identity.wireName:
            return data
        case Self.lzfse.wireName:
            return try (data as NSData).compressed(using: .lzfse) as Data
        default:
            throw PayloadCodecError.unsupported(wireName)
        }
    }

    public func decode(_ data: Data, expectedSize: Int?) throws -> Data {
        let decoded: Data
        switch wireName {
        case Self.identity.wireName:
            decoded = data
        case Self.lzfse.wireName:
            do {
                decoded = try (data as NSData).decompressed(using: .lzfse) as Data
            } catch {
                throw PayloadCodecError.invalidData
            }
        default:
            throw PayloadCodecError.unsupported(wireName)
        }
        if let expectedSize, decoded.count != expectedSize {
            throw PayloadCodecError.sizeMismatch(expected: expectedSize, actual: decoded.count)
        }
        return decoded
    }

    public static func codec(for wireName: String) throws -> PayloadCodec {
        let normalized = wireName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == lzfse.wireName { return .lzfse }
        if normalized == identity.wireName { return .identity }
        throw PayloadCodecError.unsupported(wireName)
    }

    public static func encodeWebSocketEnvelope(_ payload: Data, codec: PayloadCodec = .lzfse) throws -> Data {
        let encoded = try codec.encode(payload)
        let codecData = Data(codec.wireName.utf8)
        guard codecData.count <= UInt8.max else { throw PayloadCodecError.unsupported(codec.wireName) }
        var out = wsEnvelopeMagic
        out.append(UInt8(codecData.count))
        out.append(codecData)
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { out.append(contentsOf: $0) }
        out.append(encoded)
        return out
    }

    public static func decodeWebSocketEnvelope(_ data: Data) throws -> Data {
        guard data.starts(with: wsEnvelopeMagic) else { throw PayloadCodecError.invalidData }
        var index = wsEnvelopeMagic.count
        guard data.indices.contains(index) else { throw PayloadCodecError.invalidData }
        let codecLength = Int(data[index])
        index += 1
        guard data.count >= index + codecLength + 4 else { throw PayloadCodecError.invalidData }
        let codecName = String(decoding: data[index..<index + codecLength], as: UTF8.self)
        index += codecLength
        let lengthBytes = data[index..<index + 4]
        let expected = lengthBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        index += 4
        return try codec(for: codecName).decode(Data(data[index...]), expectedSize: Int(expected))
    }
}
