import Foundation

/// Deterministic compaction for unified-diff payloads (headroom's diff idea).
/// Keeps every structural and changed line — `diff --git`, `index`, `---`/`+++`,
/// `@@` hunk headers, and all `+`/`-` lines — and shrinks only long runs of
/// *unchanged context* into a marker.
///
/// Dropping context is **element-dropping (lossy)**: the original cannot be
/// reconstructed from the windowed text alone, so this is reversible ONLY when
/// the caller has first stored the original in the CCR store and embedded its
/// handle. It is therefore OFF by default and enabled only on the store-backed
/// path (see P1-T6 / RouterOptions). The lossless crushers (JSON/log) are the
/// default-on transforms.
public enum DiffCrusher {
    /// Compacts unchanged-context runs longer than `2*context` to `context` lines
    /// at each edge plus a `… N unchanged lines …` marker. Returns nil when the
    /// input is not a diff or nothing was compacted (never inflate, fail-open).
    public static func window(_ input: String, context: Int = 3) -> String? {
        guard looksLikeDiff(input) else { return nil }
        let lines = input.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var didCompact = false
        var i = 0
        while i < lines.count {
            if isContext(lines[i]) {
                var j = i + 1
                while j < lines.count && isContext(lines[j]) { j += 1 }
                let run = j - i
                if run > context * 2 + 1 {
                    for k in i..<(i + context) { out.append(lines[k]) }
                    let omitted = run - context * 2
                    out.append("… \(omitted) unchanged lines …")
                    for k in (j - context)..<j { out.append(lines[k]) }
                    didCompact = true
                } else {
                    for k in i..<j { out.append(lines[k]) }
                }
                i = j
            } else {
                out.append(lines[i])
                i += 1
            }
        }
        guard didCompact else { return nil }
        let text = out.joined(separator: "\n")
        return text.count < input.count ? text : nil
    }

    /// A context line is unchanged content: blank, or starting with a single space
    /// (unified-diff context). Change lines (`+`/`-`) and headers are preserved.
    private static func isContext(_ line: String) -> Bool {
        if line.isEmpty { return true }
        guard let first = line.first else { return true }
        return first == " "
    }

    /// True when `text` carries unified-diff structure.
    public static func looksLikeDiff(_ text: String) -> Bool {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(40) {
            if line.hasPrefix("diff --git ") || line.hasPrefix("@@ ") ||
               line.hasPrefix("@@") || (line.hasPrefix("--- ") ) || line.hasPrefix("+++ ") {
                return true
            }
        }
        return false
    }
}
