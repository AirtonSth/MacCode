import CryptoKit
import Foundation

/// Host-generated proof that a Distill invocation replaced tool/output bytes.
public enum DistillAppliedReceipt {
    private static let trailingMarkerRegex = try! NSRegularExpression(
        pattern: #"(?:\A|\r?\n)\[\[rcd:(?:v1\.[A-Za-z0-9_-]{22}|v2\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43})\]\](?:\r?\n)?\z"#
    )
    private static let trailingSpacesBeforeNewlineRegex = try! NSRegularExpression(
        pattern: #"[ \t]+\n"#
    )
    private static let multiNewlineCollapseRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#
    )
    private static let v2Prefix = Data("[[rcd:v2.".utf8)
    private static let canonicalDomain = Data("io.remotecode.distill-applied-receipt".utf8)
    private static let canonicalVersion = Data("v2".utf8)
    private static let nonceByteCount = 16
    private static let macByteCount = 32
    private static let nonceEncodedCount = 22
    private static let macEncodedCount = 43

    /// The exact v2 marker length. Coordinators may retain only this bounded ASCII
    /// tail plus a possible CRLF; receipt parsing itself never decodes preceding UTF-8.
    public static let maximumV2MarkerByteCount = 77

    public struct ParsedV2Marker: Sendable, Equatable {
        public let nonce: Data
        public let mac: Data
        /// Byte offsets relative to the supplied tail. The preceding line feed is
        /// intentionally outside this range and remains part of the signed payload.
        public let markerByteRange: Range<Int>
        /// Zero, one (LF), or two (CRLF) bytes after the closing brackets.
        public let terminalSuffixByteCount: Int

        public var markerByteCount: Int { markerByteRange.count }
    }

    /// Returns an exact `[[rcd:v1.<token>]]` marker with 128 random bits encoded
    /// as 22 unpadded base64url characters.
    public static func makeMarker() -> String {
        let token = base64URL(randomData(count: nonceByteCount))
        return "[[rcd:v1.\(token)]]"
    }

    /// Generates the independent 256-bit secret persisted in the owner-only CLI
    /// state file for one Token Saver On lifecycle.
    public static func generateReceiptKey() -> Data {
        randomData(count: macByteCount)
    }

    public static func encodeReceiptKey(_ key: Data) -> String? {
        guard key.count == macByteCount else { return nil }
        return key.base64EncodedString()
    }

    /// Legacy state files omit the key and malformed keys remain usable only for
    /// sidecar admission, never for authenticated receipt production.
    public static func decodeReceiptKey(_ encoded: String?) -> Data? {
        guard let encoded,
              let decoded = Data(base64Encoded: encoded),
              decoded.count == macByteCount else {
            return nil
        }
        return decoded
    }

    /// Makes a v2 receipt over an already-hashed exact provider-visible prefix.
    /// Returns nil rather than weakening authentication when any bound input is invalid.
    public static func makeV2Marker(
        rootRunID: String,
        payloadByteCount: Int,
        payloadSHA256: Data,
        key: Data,
        nonce: Data? = nil
    ) -> String? {
        let nonce = nonce ?? randomData(count: nonceByteCount)
        guard let material = canonicalMaterial(
            rootRunID: rootRunID,
            payloadByteCount: payloadByteCount,
            payloadSHA256: payloadSHA256,
            nonce: nonce
        ), key.count == macByteCount else {
            return nil
        }
        let mac = Data(HMAC<SHA256>.authenticationCode(
            for: material,
            using: SymmetricKey(data: key)
        ))
        return "[[rcd:v2.\(base64URL(nonce)).\(base64URL(mac))]]"
    }

    /// Convenience for producers that still hold the exact prefix bytes.
    public static func makeV2Marker(
        rootRunID: String,
        payload: Data,
        key: Data,
        nonce: Data? = nil
    ) -> String? {
        makeV2Marker(
            rootRunID: rootRunID,
            payloadByteCount: payload.count,
            payloadSHA256: Data(SHA256.hash(data: payload)),
            key: key,
            nonce: nonce
        )
    }

    /// Parses only the exact terminal ASCII v2 marker. `tail` may begin inside a
    /// multi-byte UTF-8 scalar because no String conversion is performed.
    public static func parseTrailingV2Marker(in tail: Data) -> ParsedV2Marker? {
        let bytes = [UInt8](tail)
        var terminalEnd = bytes.count
        var suffixByteCount = 0
        if terminalEnd > 0, bytes[terminalEnd - 1] == 0x0a {
            terminalEnd -= 1
            suffixByteCount = 1
            if terminalEnd > 0, bytes[terminalEnd - 1] == 0x0d {
                terminalEnd -= 1
                suffixByteCount = 2
            }
        }
        guard terminalEnd >= maximumV2MarkerByteCount else { return nil }
        let markerStart = terminalEnd - maximumV2MarkerByteCount
        guard markerStart == 0 || bytes[markerStart - 1] == 0x0a else { return nil }
        let marker = Array(bytes[markerStart..<terminalEnd])
        guard marker.count == maximumV2MarkerByteCount,
              marker.starts(with: v2Prefix),
              marker[31] == 0x2e,
              marker[75] == 0x5d,
              marker[76] == 0x5d else {
            return nil
        }
        let nonceText = marker[9..<31]
        let macText = marker[32..<75]
        guard nonceText.count == nonceEncodedCount,
              macText.count == macEncodedCount,
              nonceText.allSatisfy(isBase64URLByte),
              macText.allSatisfy(isBase64URLByte),
              let nonce = decodeBase64URL(nonceText), nonce.count == nonceByteCount,
              let mac = decodeBase64URL(macText), mac.count == macByteCount else {
            return nil
        }
        return ParsedV2Marker(
            nonce: nonce,
            mac: mac,
            markerByteRange: markerStart..<terminalEnd,
            terminalSuffixByteCount: suffixByteCount
        )
    }

    /// Verifies a parsed marker without retaining the payload. The caller may feed
    /// an incremental SHA-256 digest plus its exact byte count.
    public static func verify(
        _ marker: ParsedV2Marker,
        rootRunID: String,
        payloadByteCount: Int,
        payloadSHA256: Data,
        key: Data
    ) -> Bool {
        guard key.count == macByteCount,
              let material = canonicalMaterial(
                  rootRunID: rootRunID,
                  payloadByteCount: payloadByteCount,
                  payloadSHA256: payloadSHA256,
                  nonce: marker.nonce
              ) else {
            return false
        }
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: material,
            using: SymmetricKey(data: key)
        ))
        return constantTimeEqual(expected, marker.mac)
    }

    /// Recognizes only an exact marker occupying the complete trailing line.
    public static func containsMarker(_ text: String) -> Bool {
        match(in: text) != nil
    }

    /// Removes a valid trailing receipt before text reaches the user. Invalid or
    /// merely marker-shaped text is preserved byte-for-byte.
    public static func strip(_ text: String) -> String {
        guard let match = match(in: text) else { return text }
        let stripped = trailingMarkerRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: match,
            withTemplate: ""
        )
        return tidyWhitespace(stripped)
    }

    private static func match(in text: String) -> NSRange? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return trailingMarkerRegex.firstMatch(in: text, options: [], range: range)?.range
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text
        for (regex, template) in [
            (trailingSpacesBeforeNewlineRegex, "\n"),
            (multiNewlineCollapseRegex, "\n\n"),
        ] {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalMaterial(
        rootRunID: String,
        payloadByteCount: Int,
        payloadSHA256: Data,
        nonce: Data
    ) -> Data? {
        guard !rootRunID.isEmpty,
              payloadByteCount >= 0,
              payloadSHA256.count == macByteCount,
              nonce.count == nonceByteCount else {
            return nil
        }
        var result = Data()
        for field in [
            canonicalDomain,
            canonicalVersion,
            Data(rootRunID.utf8),
            Data(String(payloadByteCount).utf8),
            payloadSHA256,
            nonce,
        ] {
            var count = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL<C: Collection>(_ bytes: C) -> Data? where C.Element == UInt8 {
        var text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (0x41...0x5a).contains(byte)
            || (0x61...0x7a).contains(byte)
            || (0x30...0x39).contains(byte)
            || byte == 0x2d
            || byte == 0x5f
    }

    /// Both MACs have a public fixed length. The byte loop has no data-dependent
    /// early exit, avoiding a prefix timing oracle.
    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
