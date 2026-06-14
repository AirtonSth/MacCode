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
    public typealias NearDuplicateNominator = @Sendable (_ first: String, _ second: String) -> Bool

    public struct Result: Sendable, Equatable {
        public let output: String
        public let dedupedBlocks: Int
        public let nearDedupedBlocks: Int
    }

    /// Collapse 2nd+ exact duplicates of blocks (paragraphs split on blank lines) that are
    /// at least `minBlockChars` long. Returns the input unchanged when nothing dedupes.
    public static func dedupe(
        _ text: String,
        minBlockChars: Int = 400,
        originalHandleMarker: String? = nil,
        nearDuplicateNominator: NearDuplicateNominator? = nil
    ) -> Result {
        let blocks = text.components(separatedBy: "\n\n")
        guard blocks.count > 1 else { return Result(output: text, dedupedBlocks: 0, nearDedupedBlocks: 0) }

        var firstSeenOrdinal: [String: Int] = [:]
        var seenBlocks: [(ordinal: Int, text: String)] = []
        var ordinal = 0
        var out: [String] = []
        out.reserveCapacity(blocks.count)
        var deduped = 0
        var nearDeduped = 0

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
            } else if let near = firstNearDuplicate(
                of: key,
                in: seenBlocks,
                originalHandleMarker: originalHandleMarker,
                nearDuplicateNominator: nearDuplicateNominator
            ) {
                out.append(near.pointer)
                nearDeduped += 1
            } else {
                ordinal += 1
                firstSeenOrdinal[key] = ordinal
                seenBlocks.append((ordinal: ordinal, text: key))
                out.append(block)
            }
        }

        guard deduped > 0 || nearDeduped > 0 else {
            return Result(output: text, dedupedBlocks: 0, nearDedupedBlocks: 0)
        }
        let joined = out.joined(separator: "\n\n")
        // Never inflate (the pointer is far shorter than a >=400-char block, so this holds).
        return joined.count < text.count
            ? Result(output: joined, dedupedBlocks: deduped, nearDedupedBlocks: nearDeduped)
            : Result(output: text, dedupedBlocks: 0, nearDedupedBlocks: 0)
    }

    private static func firstNearDuplicate(
        of block: String,
        in seenBlocks: [(ordinal: Int, text: String)],
        originalHandleMarker: String?,
        nearDuplicateNominator: NearDuplicateNominator?
    ) -> (pointer: String, ordinal: Int)? {
        for seen in seenBlocks {
            let nominated = nearDuplicateNominator?(seen.text, block) ?? false
            guard nominated || normalizeVolatile(seen.text) == normalizeVolatile(block) else { continue }
            if let pointer = nearDuplicatePointer(
                original: seen.text,
                duplicate: block,
                ordinal: seen.ordinal,
                originalHandleMarker: originalHandleMarker
            ) {
                return (pointer, seen.ordinal)
            }
        }
        return nil
    }

    private static func nearDuplicatePointer(
        original: String,
        duplicate: String,
        ordinal: Int,
        originalHandleMarker: String?
    ) -> String? {
        let originalLines = original.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let duplicateLines = duplicate.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard originalLines.count == duplicateLines.count else { return nil }

        var diffs: [String] = []
        for index in originalLines.indices {
            let old = originalLines[index]
            let new = duplicateLines[index]
            guard old != new else { continue }
            guard normalizeVolatile(old) == normalizeVolatile(new) else { return nil }
            diffs.append("line \(index + 1): \(quoted(old)) -> \(quoted(new))")
        }
        guard !diffs.isEmpty else { return nil }

        var pointer = "⟪same as block #\(ordinal) above except: \(diffs.joined(separator: "; "))⟫"
        if let originalHandleMarker {
            pointer += " \(originalHandleMarker)"
        }
        return pointer
    }

    private static func normalizeVolatile(_ text: String) -> String {
        var normalized = text
        let replacements: [(String, String)] = [
            (#"\b\d{4}-\d{2}-\d{2}[T ][0-9:.+-Zz]+\b"#, "<timestamp>"),
            (#"\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b"#, "<time>"),
            (#"\bpid\s*[=: ]\s*\d+\b"#, "<pid>"),
            (#"\b0x[0-9a-fA-F]{12,16}\b"#, "<aslr>")
        ]
        for (pattern, replacement) in replacements {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return normalized
    }

    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
