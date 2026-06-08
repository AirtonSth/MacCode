import Foundation

/// Deterministic line-importance scorer for compacting bulky tool output (headroom's
/// IntelligentContext idea). Load-bearing lines — errors/warnings, `file:line` refs,
/// cited paths, and the last-N lines — are kept verbatim; low-signal bulk (the middle)
/// is elided into a `… N lines elided …` marker. The elided bulk is recoverable when
/// this runs store-backed (CCR), so the compaction is safe (N5). Pure, no I/O.
public enum DistillImportanceScorer {
    public struct Result: Sendable, Equatable {
        public let compacted: String
        public let droppedLines: Int
    }

    /// Keep at most `maxKeep` of the highest-scoring lines (original order preserved),
    /// always keeping the last `keepLast`. Returns the original unchanged when it is
    /// already within budget (never inflate).
    public static func compact(_ text: String, maxKeep: Int = 40, keepLast: Int = 8) -> Result {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > maxKeep else { return Result(compacted: text, droppedLines: 0) }

        let lastStart = max(0, lines.count - keepLast)
        // Indices to keep: high score OR within the last-N tail.
        var keep = Set<Int>()
        var scored: [(index: Int, score: Int)] = []
        for (i, line) in lines.enumerated() {
            if i >= lastStart { keep.insert(i) }
            scored.append((i, score(line, index: i, total: lines.count)))
        }
        // Fill remaining budget with the top-scoring non-tail lines.
        let budget = max(0, maxKeep - keep.count)
        let topByScore = scored
            .filter { !keep.contains($0.index) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .prefix(budget)
            .map(\.index)
        keep.formUnion(topByScore)

        var out: [String] = []
        var dropped = 0
        var run = 0
        for i in lines.indices {
            if keep.contains(i) {
                if run > 0 { out.append("… \(run) lines elided …"); dropped += run; run = 0 }
                out.append(lines[i])
            } else {
                run += 1
            }
        }
        if run > 0 { out.append("… \(run) lines elided …"); dropped += run }
        return Result(compacted: out.joined(separator: "\n"), droppedLines: dropped)
    }

    private static func score(_ line: String, index: Int, total: Int) -> Int {
        let lower = line.lowercased()
        var s = 0
        if lower.contains("error") || lower.contains("exception") || lower.contains("fatal")
            || lower.contains("panic") || lower.contains("traceback") || lower.contains(" fail") {
            s += 10
        }
        if lower.contains("warn") { s += 4 }
        if line.range(of: #"[\w./~-]+\.[A-Za-z0-9]+:\d+"#, options: .regularExpression) != nil { s += 8 } // file:line
        if line.range(of: #"(^|\s)(/|\./|~/)[\w./-]+"#, options: .regularExpression) != nil { s += 3 }     // a path
        if index < 3 { s += 2 } // a little weight to the head (command echo / first lines)
        return s
    }
}
