import Foundation

/// The correctness gate for any LOSSY compression (N5). Before adopting a lossy
/// output (an MLX prose pass, a log level-filter), we pin the load-bearing literals
/// in the original — `file:line` refs, UUIDs, hex hashes, long numbers, diff change
/// lines — and verify every one of them survives. If any pinned literal is dropped,
/// the lossy output is REJECTED and the original is used instead. This is what lets
/// lossy compression be turned on without silently corrupting an exact value the
/// agent depends on.
public enum LiteralPreservation {
    private static let patterns: [String] = [
        #"[\w./~-]+\.[A-Za-z0-9]+:\d+"#,                                  // file.ext:line
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, // UUID
        #"\b[0-9a-f]{12,}\b"#,                                            // hex hash / sha (>=12)
        #"\b\d{4,}\b"#,                                                   // long numbers (ids, counts, codes)
    ]

    /// Distinct load-bearing literals found in `text`.
    public static func pinnedLiterals(in text: String) -> Set<String> {
        var found = Set<String>()
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range, in: text) {
                    found.insert(String(text[r]))
                }
            }
        }
        // Diff change lines (the actual edit) must survive verbatim.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if (line.hasPrefix("+") || line.hasPrefix("-")) && !line.hasPrefix("+++") && !line.hasPrefix("---") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.count > 1 { found.insert(String(trimmed)) }
            }
        }
        return found
    }

    /// True when every literal pinned in `original` is still present (as a substring)
    /// in `compressed`.
    public static func preservesLiterals(original: String, compressed: String) -> Bool {
        pinnedLiterals(in: original).allSatisfy { compressed.contains($0) }
    }

    /// The N5 guard: adopt `compressed` only if it preserves every pinned literal;
    /// otherwise reject it and return `original`. `droppedLiteral` reports the first
    /// missing literal (for telemetry / motivating a retrieve).
    public static func guarded(original: String, compressed: String) -> (output: String, droppedLiteral: String?) {
        for literal in pinnedLiterals(in: original) where !compressed.contains(literal) {
            return (original, literal)
        }
        return (compressed, nil)
    }
}
