import Foundation

/// I7.5 / I7.6 / I2.9 / I10.8: safety + budget helpers for the command-output and
/// subtype-routing paths. Pure, unit-testable.
public enum CommandOutputSafety {
    // PERF: compile once. omitted-region / failing-line scans ran on every head/tail
    // lossy decision and recompiled via String.range(options: .regularExpression).
    private static let omittedErrorRegex = try! NSRegularExpression(
        pattern: #"\b(error|panic|exception|traceback|fatal|fail|failed|failure)\b|✕|✗"#,
        options: [.caseInsensitive]
    )
    fileprivate static let failingLineRegex = try! NSRegularExpression(
        pattern: #"\b(fail|failed|✕)\b"#,
        options: [.caseInsensitive]
    )

    /// I7.5: before accepting a head/tail summary that omits a region, scan the omitted
    /// region for failure markers — any hit refuses the summary (fall through to MLX).
    public static func omittedRegionHasError(_ omitted: String) -> Bool {
        let range = NSRange(omitted.startIndex..<omitted.endIndex, in: omitted)
        return omittedErrorRegex.firstMatch(in: omitted, options: [], range: range) != nil
    }

    /// I7.6: the intent classifier may only go default-on when its semantic parity vs the
    /// MLX lane clears ≥98% on samples FROM THE EXPANSION REGION (classifier fires where
    /// the keyword matcher does not). Agreement with the keyword path alone is insufficient.
    public static func intentParityMeetsGate(
        expansionRegionAgreements: Int,
        expansionRegionSamples: Int,
        threshold: Double = 0.98
    ) -> Bool {
        guard expansionRegionSamples >= 500 else { return false } // need ≥500 expansion samples
        return Double(expansionRegionAgreements) / Double(expansionRegionSamples) >= threshold
    }
}

/// I6.4: the maxOutputCharacters cut from 4000→2000 is a SEPARATE, gated change, and
/// truncation must never split a list mid-item nor drop a failing-test line. This helper
/// truncates at a line boundary and always keeps lines that name a failing test.
public enum CommandOutputCharGate {
    public static func limit(gatedToTwoThousand: Bool) -> Int { gatedToTwoThousand ? 2000 : 4000 }

    /// Truncate to <= limit characters at a LINE boundary, but always keep failing-test
    /// lines verbatim (appended after the head) plus an explicit elision marker.
    public static func truncate(_ text: String, limit: Int) -> String {
        // PERF: under-limit short-circuit via O(1) utf8.count (chars ≤ bytes).
        // Over budget, only then walk graphemes for the Character-oriented budget.
        let limit = max(0, limit)
        if text.utf8.count <= limit { return text }
        if text.count <= limit { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let failing = lines.filter { line in
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return CommandOutputSafety.failingLineRegex.firstMatch(in: line, options: [], range: range) != nil
        }
        var kept: [String] = []
        var used = 0
        for line in lines {
            if used + line.count + 1 > limit { break }
            kept.append(line); used += line.count + 1
        }
        // Ensure every failing-test line survives even if it was past the cut.
        // PERF: single pass with a kept-index (was kept.contains per failing
        // line plus a filter/contains elided count: O(F×K + K×N) on truncation).
        var keptIndex: Set<String> = Set(kept)
        for f in failing where !keptIndex.contains(f) { kept.append(f); keptIndex.insert(f) }
        let elided = lines.count - kept.count
        if elided > 0 { kept.append("… \(elided) lines elided (retrieve original) …") }
        return kept.joined(separator: "\n")
    }
}

/// I2.9: latency budgets. The deterministic-only sync path must answer fast; the MLX lane
/// sits behind a short interactive deadline with prewarm; everything fails open.
public enum DistillLatencyBudget {
    public static let deterministicSyncP95Millis = 300
    public static let mlxInteractiveDeadlineMillis = 1_000

    public static func withinDeterministicBudget(p95Millis: Int) -> Bool {
        p95Millis <= deterministicSyncP95Millis
    }
    public static func mlxDeadlineExceeded(elapsedMillis: Int) -> Bool {
        elapsedMillis > mlxInteractiveDeadlineMillis
    }
}

/// I10.8: classify HEAD and TAIL windows (failures cluster in the tail), not just the
/// first seq-512 window. Composite payloads (build+test+traces) that exceed both windows
/// fall below confidence → current path. Pure windowing.
public enum SubtypeWindowing {
    public static func headTailWindows(_ text: String, windowChars: Int = 2048) -> (head: String, tail: String) {
        // PERF: O(1) utf8 under-window short-circuit (chars ≤ bytes).
        let budget = max(0, windowChars) * 2
        if text.utf8.count <= budget { return (text, text) }
        if text.count <= budget { return (text, text) }
        let head = String(text.prefix(windowChars))
        let tail = String(text.suffix(windowChars))
        return (head, tail)
    }

    /// A composite payload (multiple distinct content kinds across head/tail) is below
    /// confidence and must use the current path, not a single-label subtype route.
    public static func isComposite(headKind: String?, tailKind: String?) -> Bool {
        guard let h = headKind, let t = tailKind else { return true }
        return h != t
    }
}
