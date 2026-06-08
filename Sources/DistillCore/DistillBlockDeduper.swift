import Foundation

/// Sound cross-occurrence dedup for a single outbound prompt (P4, redesigned).
///
/// The plan's original "replace repeats with an opaque [[rc:hash]] ref" is unsafe — the
/// PROVIDER MODEL receives the argv and cannot resolve an opaque ref. This variant is
/// NON-LOSSY and model-readable instead: the FIRST occurrence of a large block stays
/// inline, and later EXACT duplicates are replaced with a human/model-readable pointer
/// ("⟪identical to block #N above⟫"). The model still has the full content (once) plus an
/// explicit pointer it understands, so no information is lost — only the redundant copy's
/// tokens are saved. Deterministic, pure, order-preserving.
public enum DistillBlockDeduper {
    public struct Result: Sendable, Equatable {
        public let output: String
        public let dedupedBlocks: Int
    }

    /// Collapse 2nd+ exact duplicates of blocks (paragraphs split on blank lines) that are
    /// at least `minBlockChars` long. Returns the input unchanged when nothing dedupes.
    public static func dedupe(_ text: String, minBlockChars: Int = 400) -> Result {
        let blocks = text.components(separatedBy: "\n\n")
        guard blocks.count > 1 else { return Result(output: text, dedupedBlocks: 0) }

        var firstSeenOrdinal: [String: Int] = [:]
        var ordinal = 0
        var out: [String] = []
        out.reserveCapacity(blocks.count)
        var deduped = 0

        for block in blocks {
            let key = block.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only dedupe substantial blocks; tiny/blank blocks pass through verbatim.
            guard key.count >= minBlockChars else {
                out.append(block)
                continue
            }
            if let firstOrdinal = firstSeenOrdinal[key] {
                out.append("⟪identical to block #\(firstOrdinal) above⟫")
                deduped += 1
            } else {
                ordinal += 1
                firstSeenOrdinal[key] = ordinal
                out.append(block)
            }
        }

        guard deduped > 0 else { return Result(output: text, dedupedBlocks: 0) }
        let joined = out.joined(separator: "\n\n")
        // Never inflate (the pointer is far shorter than a >=400-char block, so this holds).
        return joined.count < text.count
            ? Result(output: joined, dedupedBlocks: deduped)
            : Result(output: text, dedupedBlocks: 0)
    }
}
