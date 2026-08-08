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
    ///
    /// PERF: size floor and never-inflate checks used `String.count` (O(n) grapheme
    /// walk) per substantial block and again on the joined result. `utf8.count` is
    /// O(1); for ASCII-heavy agent prompts (the common case) it matches Character
    /// length exactly, and it stays consistent with Token Saver's byte-oriented
    /// savings gates elsewhere.
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
        let textBytes = text.utf8.count
        let minBlockBytes = max(0, minBlockChars)

        for block in blocks {
            let key = block.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only dedupe substantial blocks; tiny/blank blocks pass through verbatim.
            guard key.utf8.count >= minBlockBytes else {
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
        // Never inflate (the pointer is far shorter than a >=400-byte block, so this holds).
        return joined.utf8.count < textBytes
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

    // PERF: compile once. Near-dup compares call `normalizeVolatile` per candidate
    // pair (and per line pair), and `String.replacingOccurrences(options: .regularExpression)`
    // recompiled all four patterns on every call.
    private static let volatileReplacements: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}[T ][0-9:.+-Zz]+\b"#, options: [.caseInsensitive]), "<timestamp>"),
        (try! NSRegularExpression(pattern: #"\b\d{2}:\d{2}:\d{2}(?:\.\d+)?\b"#, options: [.caseInsensitive]), "<time>"),
        (try! NSRegularExpression(pattern: #"\bpid\s*[=: ]\s*\d+\b"#, options: [.caseInsensitive]), "<pid>"),
        (try! NSRegularExpression(pattern: #"\b0x[0-9a-fA-F]{12,16}\b"#, options: [.caseInsensitive]), "<aslr>")
    ]

    private static func normalizeVolatile(_ text: String) -> String {
        var normalized = text
        for (regex, replacement) in volatileReplacements {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            normalized = regex.stringByReplacingMatches(
                in: normalized,
                options: [],
                range: range,
                withTemplate: replacement
            )
        }
        return normalized
    }

    private static func quoted(_ text: String) -> String {
        "\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
