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

    // PERF: compile once. `compact` scores every line of multi-KB tool dumps and
    // previously recompiled 2–4 patterns per line via `String.range(of:options:
    // .regularExpression)`. Same patterns as before; match via cached NSRegularExpression.
    private static let fileLineRegex = try! NSRegularExpression(
        pattern: #"[\w./~-]+\.[A-Za-z0-9]+:\d+"#
    )
    private static let pathRegex = try! NSRegularExpression(
        pattern: #"(^|\s)(/|\./|~/)[\w./-]+"#
    )
    private static let pythonFrameRegex = try! NSRegularExpression(
        pattern: #"File "[^"]+", line \d+"#
    )
    private static let jsFrameRegex = try! NSRegularExpression(
        pattern: #"^\s*at .+\(.+:\d+(?::\d+)?\)"#
    )

    /// Keep at most `maxKeep` of the highest-scoring lines (original order preserved),
    /// always keeping the last `keepLast`. Returns the original unchanged when it is
    /// already within budget (never inflate).
    public static func compact(_ text: String, maxKeep: Int = 40, keepLast: Int = 8) -> Result {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > maxKeep else { return Result(compacted: text, droppedLines: 0) }

        let lastStart = max(0, lines.count - keepLast)
        // Indices to keep: floor lines (error/fatal/file:line) and the last-N tail are
        // kept UNCONDITIONALLY (I6.2) — they are exempt from the maxKeep budget so a
        // burst of error lines can never push a real error out. Everything else competes
        // for the remaining budget by score.
        var keep = Set<Int>()
        var scored: [(index: Int, score: Int)] = []
        for (i, line) in lines.enumerated() {
            if i >= lastStart || isFloorLine(line) { keep.insert(i) }
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
        if isFloorLine(line) { s += 10 }
        if lower.contains("warn") { s += 4 }
        if matches(fileLineRegex, in: line) { s += 8 } // file:line
        if matches(pathRegex, in: line) { s += 3 }     // a path
        if index < 3 { s += 2 } // a little weight to the head (command echo / first lines)
        return s
    }

    /// A line that must never be silently dropped (I6.2): error/exception/fatal/panic/
    /// traceback/fail lines and any `file:line` reference, including Python (`File "x",
    /// line N`) and JS (`at fn (file:line)`) stack frames (I6.3).
    static func isFloorLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("exception") || lower.contains("fatal")
            || lower.contains("panic") || lower.contains("traceback") || lower.contains(" fail")
            || lower.hasPrefix("fail") {
            return true
        }
        // file.ext:line  |  Python: File "...", line N  |  JS: at ... (file:line)
        if matches(fileLineRegex, in: line) { return true }
        if matches(pythonFrameRegex, in: line) { return true }
        if matches(jsFrameRegex, in: line) { return true }
        return false
    }

    private static func matches(_ regex: NSRegularExpression, in line: String) -> Bool {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }
}
