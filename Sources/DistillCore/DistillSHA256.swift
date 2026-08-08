import CryptoKit
import Foundation

/// Shared SHA-256 lowercase hex for Distill / Token Saver fingerprints.
///
/// WHY a single helper: skip-set keys, cross-turn dedup, result-cache keys, and
/// embedding cache keys all hash multi-KB/MB tool outputs. Per-site
/// `Data(utf8)` + `String(format: "%02x")` paid a full-body copy and 32
/// formatter calls per digest. Contiguous UTF-8 hashing + nibble hex keeps
/// CryptoKit-identical digests with less work on the store-before-loss path.
enum DistillSHA256 {
    static func hex(_ text: String) -> String {
        var hasher = SHA256()
        var copy = text
        copy.withUTF8 { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hex(hasher.finalize())
    }

    static func hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(alphabet[Int(byte >> 4)])
            out.append(alphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    private static let alphabet: [UInt8] = Array("0123456789abcdef".utf8)
}
