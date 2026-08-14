import Foundation

/// The correctness gate for any LOSSY compression (N5). Before adopting a lossy
/// output (an MLX prose pass, a log level-filter), we pin the load-bearing literals
/// in the original — `file:line` refs, UUIDs, hex hashes, long numbers, diff change
/// lines — and verify every one of them survives. If any pinned literal is dropped,
/// the lossy output is REJECTED and the original is used instead. This is what lets
/// lossy compression be turned on without silently corrupting an exact value the
/// agent depends on.
public enum LiteralPreservation {
    // PERF: compile once. `pinnedLiterals` runs on every lossy adoption gate
    // (semantic prose, prose pruning, wire encoding, faithfulness stacks). Rebuilding
    // 13 NSRegularExpressions per scan dominated multi-KB pin checks.
    private static let regexes: [NSRegularExpression] = [
        #"[\w./~-]+\.[A-Za-z0-9]+:\d+"#,                                  // file.ext:line (also covers JS `at fn (a.js:1:2)`)
        #"File "[^"\n]+", line \d+"#,                                      // Python traceback frame
        #"/(?:[A-Za-z0-9._~+-]+/)+[A-Za-z0-9._~+-]+"#,                     // absolute path (I8.5: load-bearing, anti-hallucination)
        #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#, // UUID
        #"\b[0-9a-f]{7,11}\b"#,                                             // short git SHA
        #"\b[0-9a-f]{12,}\b"#,                                            // hex hash / sha (>=12)
        #"\b\d{4,}\b"#,                                                   // long numbers (ids, counts, codes)
        #"`[^`\n]{1,120}`"#,                                               // quoted identifiers / commands
        #"\bv?\d+\.\d+(?:\.\d+){0,2}(?:[-+][A-Za-z0-9.-]+)?\b"#,          // versions
        #"\b(?:exit(?:\s+code)?|code|port)\s*[:=]?\s*\d{1,5}\b"#,         // small but load-bearing codes/ports
        #"\b[A-Z]{1,2}\d{3,5}\b"#,                                        // compiler/lint codes (I10.6): TS2345, E501, E0382
        #"\[\[rc:[0-9a-fA-F]+\]\]"#,                                      // recoverable content marker
        #"</?[A-Za-z][A-Za-z0-9:_-]*(?:\s+[^<>]*?)?>"#,                   // XML/HTML-style tags
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// PERF: one compile for the per-line error/panic/fatal/exception probe
    /// that previously recompiled via `String.range(of:options: .regularExpression)`.
    private static let errorLineRegex = try! NSRegularExpression(
        pattern: #"\b(error|panic|fatal|exception)\b"#,
        options: [.caseInsensitive]
    )

    /// Distinct load-bearing literals found in `text`.
    public static func pinnedLiterals(in text: String) -> Set<String> {
        var found = Set<String>()
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in regexes {
            for match in regex.matches(in: text, range: fullRange) {
                if let r = Range(match.range, in: text) {
                    found.insert(String(text[r]))
                }
            }
        }
        // Diff change lines (the actual edit) must survive verbatim.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if (line.hasPrefix("+") || line.hasPrefix("-")) && !line.hasPrefix("+++") && !line.hasPrefix("---") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.utf8.count > 1 { found.insert(String(trimmed)) }
            }
            let lineString = String(line)
            let lineRange = NSRange(lineString.startIndex..<lineString.endIndex, in: lineString)
            if errorLineRegex.firstMatch(in: lineString, range: lineRange) != nil {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.utf8.count > 1 { found.insert(String(trimmed)) }
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
