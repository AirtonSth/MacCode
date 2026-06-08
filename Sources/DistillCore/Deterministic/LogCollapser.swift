import Foundation

/// Deterministic, *reversible* run-length collapse of repeated log lines
/// (headroom's log-dedup idea, ported native). Consecutive identical lines —
/// the dominant waste in retry loops, progress spam, and stack repeats — are
/// folded into one line plus a count marker. `expand(collapse(x)) == x` exactly,
/// so this is lossless: it carries no information loss and needs no CCR handle.
public enum LogCollapser {
    /// Sentinel chosen to be vanishingly unlikely in real log text. A run marker
    /// is a whole line of the exact form `⟦×N⟧`.
    static let markerPrefix = "⟦×"
    static let markerSuffix = "⟧"

    /// Collapses runs of `>= minRun` consecutive identical lines. Returns nil when
    /// nothing collapsed or the result is not smaller (never inflate, fail-open).
    public static func collapse(_ input: String, minRun: Int = 3) -> String? {
        let lines = input.components(separatedBy: "\n")
        guard lines.count >= minRun else { return nil }
        var out: [String] = []
        out.reserveCapacity(lines.count)
        var i = 0
        var didCollapse = false
        while i < lines.count {
            var j = i + 1
            while j < lines.count && lines[j] == lines[i] { j += 1 }
            let run = j - i
            // Never collapse a line that itself looks like our marker — keeps the
            // transform unambiguous and the round-trip exact.
            if run >= minRun && parseMarker(lines[i]) == nil {
                out.append(lines[i])
                out.append("\(markerPrefix)\(run)\(markerSuffix)")
                didCollapse = true
            } else {
                for k in i..<j { out.append(lines[k]) }
            }
            i = j
        }
        guard didCollapse else { return nil }
        let text = out.joined(separator: "\n")
        return text.count < input.count ? text : nil
    }

    /// Inverse of `collapse`. A marker line `⟦×N⟧` means the immediately preceding
    /// line occurs N times total (so N-1 additional copies are emitted).
    public static func expand(_ input: String) -> String {
        let lines = input.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            if let count = parseMarker(line), let last = out.last, count >= 1 {
                for _ in 1..<count { out.append(last) }
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Returns the run count if `line` is exactly a `⟦×N⟧` marker, else nil.
    static func parseMarker(_ line: String) -> Int? {
        guard line.hasPrefix(markerPrefix), line.hasSuffix(markerSuffix) else { return nil }
        let inner = line.dropFirst(markerPrefix.count).dropLast(markerSuffix.count)
        guard !inner.isEmpty, inner.allSatisfy(\.isNumber) else { return nil }
        return Int(inner)
    }

    /// True when `text` reads like a multi-line log (enough lines, and at least
    /// one repeated run or a recognizable level/timestamp token). Heuristic only.
    public static func looksLikeLog(_ text: String) -> Bool {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 4 else { return false }
        var seen = Set<Substring>()
        for line in lines.prefix(400) {
            if !seen.insert(line).inserted { return true } // a repeat appeared
            let lower = line.lowercased()
            if lower.contains(" info ") || lower.contains(" debug ") ||
               lower.contains(" warn") || lower.contains(" error") ||
               lower.contains("[info]") || lower.contains("[error]") {
                return true
            }
        }
        return false
    }
}
