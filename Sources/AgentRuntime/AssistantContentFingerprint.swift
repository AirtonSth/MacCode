import Foundation

/// Fixed-size equality key for last-persisted assistant-text dedup.
///
/// WHY: coordinator and surface maps previously stored the full final-answer
/// `String` (up to 32 KiB, or unbounded on the surface) solely to compare
/// equality on the next turnCompleted/finished pair. Only equality is needed,
/// so retain `utf8Count` + a stable 64-bit FNV-1a of NFC-normalized UTF-8
/// (~16 B). NFC matches Swift `String` canonical equivalence (e.g. composed vs
/// decomposed `é`) so dedup cannot miss equal logical finals.
public struct AssistantContentFingerprint: Equatable, Hashable, Sendable {
    public let utf8Count: Int
    public let digest: UInt64

    public init(utf8Count: Int, digest: UInt64) {
        self.utf8Count = utf8Count
        self.digest = digest
    }

    /// Approximate stored size of one fingerprint value (two machine words).
    public static let storedByteSize = MemoryLayout<Int>.size + MemoryLayout<UInt64>.size

    public static func of(_ text: String) -> AssistantContentFingerprint {
        // NFC so Swift-equal strings (canonical equivalence) share one digest.
        let normalized = text.precomposedStringWithCanonicalMapping
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        var count = 0
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
            count += 1
        }
        return AssistantContentFingerprint(utf8Count: count, digest: hash)
    }
}
