import Foundation
import Compression

public enum PayloadCodecError: Error, Equatable {
    case invalidData
    case outputTooLarge(maximum: Int)
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

    public func decode(
        _ data: Data,
        expectedSize: Int?,
        maximumSize: Int? = nil
    ) throws -> Data {
        if let maximumSize, let expectedSize, expectedSize > maximumSize {
            throw PayloadCodecError.outputTooLarge(maximum: maximumSize)
        }
        let decoded: Data
        switch wireName {
        case Self.identity.wireName:
            decoded = data
        case Self.gzip.wireName:
            decoded = try Self.decodeGzip(data, maximumSize: maximumSize)
        case Self.lzfse.wireName:
            decoded = try Self.decodeCompressed(
                data,
                algorithm: COMPRESSION_LZFSE,
                maximumSize: maximumSize
            )
        default:
            throw PayloadCodecError.unsupported(wireName)
        }
        if let maximumSize, decoded.count > maximumSize {
            throw PayloadCodecError.outputTooLarge(maximum: maximumSize)
        }
        if let expectedSize, decoded.count != expectedSize {
            throw PayloadCodecError.sizeMismatch(expected: expectedSize, actual: decoded.count)
        }
        return decoded
    }

    public static func codec(for wireName: String) throws -> PayloadCodec {
        let trimmed = wireName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(lzfse.wireName) == .orderedSame { return .lzfse }
        if trimmed.caseInsensitiveCompare(gzip.wireName) == .orderedSame { return .gzip }
        if trimmed.caseInsensitiveCompare(identity.wireName) == .orderedSame { return .identity }
        throw PayloadCodecError.unsupported(wireName)
    }

    /// Single response codec selector (C-23).
    ///
    /// Policy: **prefer better compression ratio for client bandwidth** (gzip
    /// before lzfse). The host is rarely CPU-bound on encode relative to a
    /// 3G uplink; smaller bodies win. Returns nil when the client advertises
    /// no supported encoding.
    public static func preferredResponseCodec(acceptEncoding: String?) -> PayloadCodec? {
        // PERF: short-circuit scan avoids the map array + two contains passes
        // per JSON response; gzip-first policy unchanged.
        guard let acceptEncoding else { return nil }
        var sawLZFSE = false
        for token in acceptEncoding.split(separator: ",") {
            let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == gzip.wireName { return .gzip }
            if normalized == lzfse.wireName { sawLZFSE = true }
        }
        return sawLZFSE ? .lzfse : nil
    }

    /// Size-gated variant of `preferredResponseCodec` (C-23 — one policy).
    /// Returns nil when `payloadSize < threshold` or no accepted encoding matches.
    /// Prefers gzip (ratio) over lzfse so 3G clients are not stuck with a
    /// larger body from a CPU-first selector.
    public static func selectResponseCodec(
        payloadSize: Int,
        acceptEncoding: String?,
        threshold: Int = 128
    ) -> PayloadCodec? {
        guard payloadSize >= threshold else { return nil }
        return preferredResponseCodec(acceptEncoding: acceptEncoding)
    }

    private static func encodeGzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        out.append(deflated)
        appendLittleEndian(UInt32(crc32(data)), to: &out)
        appendLittleEndian(UInt32(truncatingIfNeeded: UInt64(data.count)), to: &out)
        return out
    }

    private static func decodeGzip(_ data: Data, maximumSize: Int?) throws -> Data {
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
        let body = Data(data[index..<(data.count - 8)])
        return try decodeCompressed(
            body,
            algorithm: COMPRESSION_ZLIB,
            maximumSize: maximumSize
        )
    }

    private static func decodeCompressed(
        _ data: Data,
        algorithm: compression_algorithm,
        maximumSize: Int?
    ) throws -> Data {
        let chunkSize = 64 * 1024
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { outputBuffer.deallocate() }

        var stream = compression_stream(
            dst_ptr: outputBuffer,
            dst_size: chunkSize,
            src_ptr: UnsafePointer(outputBuffer),
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) != COMPRESSION_STATUS_ERROR else {
            throw PayloadCodecError.invalidData
        }
        defer { compression_stream_destroy(&stream) }

        return try data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw PayloadCodecError.invalidData
            }
            stream.src_ptr = source
            stream.src_size = data.count
            var output = Data()

            while true {
                stream.dst_ptr = outputBuffer
                stream.dst_size = chunkSize
                let sourceSizeBefore = stream.src_size
                let status = compression_stream_process(
                    &stream,
                    Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                )
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    if let maximumSize,
                       (produced > maximumSize || output.count > maximumSize - produced) {
                        throw PayloadCodecError.outputTooLarge(maximum: maximumSize)
                    }
                    output.append(outputBuffer, count: produced)
                }

                switch status {
                case COMPRESSION_STATUS_END:
                    return output
                case COMPRESSION_STATUS_OK:
                    guard produced > 0 || stream.src_size < sourceSizeBefore else {
                        throw PayloadCodecError.invalidData
                    }
                default:
                    throw PayloadCodecError.invalidData
                }
            }
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
