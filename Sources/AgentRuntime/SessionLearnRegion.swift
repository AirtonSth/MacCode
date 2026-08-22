import Foundation

/// headroom's "learn from failed sessions" idea, ported native (the deterministic
/// half). On a failed or expensive run, a short imperative correction is appended to a
/// marker-bounded region at the END of the managed instructions file, so future runs
/// avoid repeating a dead-end. The region is FIFO-capped and append-only at the bottom,
/// which keeps the large upper instruction prefix byte-stable (so the provider's prompt
/// cache for those instructions is never disturbed — a cache-cold write).
///
/// This type owns the deterministic plumbing — the WHEN (pre-filter) and the WHERE/HOW
/// (region management, FIFO cap, dedup). Generating the rule TEXT from a transcript is a
/// separate background MLX pass (gated; requires the local model) that calls `append`.
public struct SessionLearnRegion {
    public static let beginMarker = "<!-- distill session-learn: begin -->"
    public static let endMarker = "<!-- distill session-learn: end -->"

    public let fileURL: URL
    public let maxRules: Int
    private let fileManager: FileManager

    public init(fileURL: URL, maxRules: Int = 20, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.maxRules = max(1, maxRules)
        self.fileManager = fileManager
    }

    /// Deterministic pre-filter: only mine runs that failed or were expensive. Cheap,
    /// pure, runs BEFORE any model pass so we never spend inference on routine runs.
    public static func shouldMine(runFailed: Bool, inputTokens: Int, expensiveTokenThreshold: Int = 50_000) -> Bool {
        runFailed || inputTokens >= expensiveTokenThreshold
    }

    /// Append one correction rule. Idempotent on identical text (dedup), FIFO-capped to
    /// `maxRules` (oldest evicted), region kept at the file's end with everything above
    /// it byte-stable.
    public func append(_ rule: String) throws {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let oneLine = trimmed.replacingOccurrences(of: "\n", with: " ")

        var existing = currentRules(in: readFile())
        if existing.contains(oneLine) { return } // dedup
        existing.append(oneLine)
        if existing.count > maxRules {
            existing.removeFirst(existing.count - maxRules) // FIFO: drop oldest
        }
        try writeRegion(rules: existing)
    }

    /// Rules currently in the managed region, oldest first.
    public func rules() throws -> [String] {
        currentRules(in: readFile())
    }

    /// Remove the managed region entirely (Token Saver disabled), leaving the rest of
    /// the file intact.
    public func clear() throws {
        let text = readFile()
        guard let stripped = removingRegion(from: text) else { return }
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if fileManager.fileExists(atPath: fileURL.path) { try fileManager.removeItem(at: fileURL) }
        } else {
            try Data(stripped.utf8).write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - region plumbing

    private func readFile() -> String {
        ((try? Data(contentsOf: fileURL, options: .mappedIfSafe)).flatMap { String(data: $0, encoding: .utf8) }) ?? ""
    }

    private func currentRules(in text: String) -> [String] {
        guard let region = regionBody(in: text) else { return [] }
        return region
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("- ") else { return nil }
                return String(l.dropFirst(2))
            }
    }

    private func regionBody(in text: String) -> String? {
        guard let start = text.range(of: Self.beginMarker),
              let end = text.range(of: Self.endMarker),
              start.upperBound <= end.lowerBound else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }

    private func removingRegion(from text: String) -> String? {
        guard let start = text.range(of: Self.beginMarker),
              let end = text.range(of: Self.endMarker),
              start.lowerBound <= end.upperBound else {
            return nil
        }
        var result = text
        result.removeSubrange(start.lowerBound..<end.upperBound)
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : result
    }

    private func writeRegion(rules: [String]) throws {
        let body = ([Self.beginMarker]
            + rules.map { "- \($0)" }
            + [Self.endMarker]).joined(separator: "\n")

        let base = removingRegion(from: readFile()) ?? readFile()
        let prefix = base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : base.trimmingTrailingNewlines() + "\n\n"
        let next = prefix + body + "\n"
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(next.utf8).write(to: fileURL, options: .atomic)
    }
}

private extension String {
    func trimmingTrailingNewlines() -> String {
        var s = self
        while s.hasSuffix("\n") || s.hasSuffix(" ") { s.removeLast() }
        return s
    }
}
