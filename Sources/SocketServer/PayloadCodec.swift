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
    public static let gzip = PayloadCodec(wireName: "gzip")
    public static let lzfse = PayloadCodec(wireName: "rc-lzfse")
    public static let acceptEncodingHeader = "\(gzip.wireName), \(lzfse.wireName)"

    public init(wireName: String) {
        self.wireName = wireName
    }

    public func encode(_ data: Data) throws -> Data {
        switch wireName {
        case Self.identity.wireName:
            return data
        case Self.gzip.wireName:
            return try Self.encodeGzip(data)
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
        case Self.gzip.wireName:
            decoded = try Self.decodeGzip(data)
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
        if normalized == gzip.wireName { return .gzip }
        if normalized == identity.wireName { return .identity }
        throw PayloadCodecError.unsupported(wireName)
    }

    public static func preferredResponseCodec(acceptEncoding: String?) -> PayloadCodec? {
        let accepted = acceptEncoding?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? []
        if accepted.contains(gzip.wireName) { return .gzip }
        if accepted.contains(lzfse.wireName) { return .lzfse }
        return nil
    }

    private static func encodeGzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(deflated)
        appendLittleEndian(UInt32(crc32(data)), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: UInt64(data.count)), to: &out)
        return out
    }

    private static func decodeGzip(_ data: Data) throws -> Data {
        guard data.count >= 18,
              data[0] == 0x1f,
              data[1] == 0x8b,
              data[2] == 0x08 else {
            throw PayloadCodecError.invalidData
        }
        let flags = data[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= data.count else { throw PayloadCodecError.invalidData }
            let xlen = Int(data[index]) | (Int(data[index + 1]) << 8)
            index += 2 + xlen
        }
        if flags & 0x08 != 0 {
            while index < data.count, data[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x10 != 0 {
            while index < data.count, data[index] != 0 { index += 1 }
            index += 1
        }
        if flags & 0x02 != 0 { index += 2 }
        guard index <= data.count - 8 else { throw PayloadCodecError.invalidData }
        do {
            let body = Data(data[index..<(data.count - 8)])
            return try (body as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw PayloadCodecError.invalidData
        }
    }

    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 24) & 0xff))
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            var current = crc ^ UInt32(byte)
            for _ in 0..<8 {
                current = (current & 1) == 1 ? (0xedb8_8320 ^ (current >> 1)) : (current >> 1)
            }
            crc = current
        }
        return crc ^ 0xffff_ffff
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
