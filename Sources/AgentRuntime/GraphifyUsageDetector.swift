import Foundation

/// One detected Graphify CLI invocation inside a tool payload.
public struct GraphifyInvocation: Sendable, Equatable {
    public let subcommand: String  // query | path | explain
    public init(subcommand: String) {
        self.subcommand = subcommand
    }
}

/// Pure detector: finds real `graphify query|path|explain` invocations in tool
/// summary/body text. Counts only when a pipeline/segment **starts** with
/// `graphify` (or a path ending in `/graphify`) followed by an allowed subcommand.
///
/// WHY: Token Saver must never credit Graphify for preference-on alone, host
/// indexing, `graphify update`, or prose mentions.
public enum GraphifyUsageDetector {
    public static let allowedSubcommands: Set<String> = ["query", "path", "explain"]
    public static let maxMatchesPerToolCall = 5

    /// Tool names whose **output size** is a credible exploration sample for
    /// Phase-2 counterfactual (median bare-agent file read size).
    public static let explorationToolNames: Set<String> = [
        "read", "grep", "glob", "search", "find"
    ]

    /// Detect Graphify CLI uses in a tool item's summary and body.
    public static func detect(summary: String?, body: String?) -> [GraphifyInvocation] {
        var found: [GraphifyInvocation] = []
        var seen = Set<String>()
        for source in [summary, body].compactMap({ $0 }) {
            for inv in detect(in: source) {
                if seen.insert(inv.subcommand).inserted {
                    found.append(inv)
                }
                if found.count >= maxMatchesPerToolCall { return found }
            }
        }
        return found
    }

    /// True when the tool summary looks like a file-exploration tool we can
    /// use as a bare-agent baseline sample (Read/Grep/Glob family).
    public static func isExplorationTool(summary: String?) -> Bool {
        guard let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return false }
        let name = raw.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "/" }).last.map(String.init)?.lowercased() ?? raw.lowercased()
        return explorationToolNames.contains(name)
    }

    /// Extract a shell `command` string from Claude-style tool input JSON body
    /// (`{"command":"…"}`) when present; otherwise return the body as-is.
    public static func commandText(fromBody body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return body
        }
        if let command = obj["command"] as? String { return command }
        // Some providers nest under "input"
        if let input = obj["input"] as? [String: Any], let command = input["command"] as? String {
            return command
        }
        return body
    }

    /// Approximate tokens from UTF-8 char count (TokenEstimator family ~4 chars/token).
    public static func tokensFromUTF8Count(_ utf8Count: Int, charsPerToken: Double = 4.0) -> Int {
        guard utf8Count > 0, charsPerToken > 0 else { return 0 }
        return max(0, Int((Double(utf8Count) / charsPerToken).rounded()))
    }

    /// True when tool output is a **high-confidence** shell failure (no savings credit).
    ///
    /// Prefer under-count over false deletes: legit Graphify/code output often
    /// contains "error:", "fatal:", "not found" in snippets. Only treat as failed
    /// when the shell clearly could not run graphify.
    public static func looksLikeFailure(output: String?) -> Bool {
        guard let o = output?.lowercased(), !o.isEmpty else { return false }
        let head = String(o.prefix(400))
        let needles = [
            "command not found",
            "not found in path",
            "no such file or directory",
            "executable file not found",
            "is not recognized as an internal or external command",
            "permission denied: graphify",
            "graphify: command not found",
            "graphifyy: command not found",
        ]
        return needles.contains { head.contains($0) || o.contains($0) }
    }

    // MARK: - Internals

    static func detect(in text: String) -> [GraphifyInvocation] {
        let command = commandText(fromBody: text)
        // Split on common shell separators so `cd x && graphify query` still matches.
        let segments = command
            .components(separatedBy: CharacterSet(charactersIn: "\n;|&"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var out: [GraphifyInvocation] = []
        for segment in segments {
            if let sub = matchSegment(segment) {
                out.append(GraphifyInvocation(subcommand: sub))
                if out.count >= maxMatchesPerToolCall { break }
            }
        }
        return out
    }

    // PERF: compile once — matchSegment runs on every shell segment of tool
    // payloads when Graphify usage is detected; env strip recompiled in a loop
    // and the graphify subcommand pattern recompiled per segment.
    private static let quotedEnvAssignmentRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_]*="[^"]*"\s+"#
    )
    private static let bareEnvAssignmentRegex = try! NSRegularExpression(
        pattern: #"^[A-Za-z_][A-Za-z0-9_]*=\S+\s+"#
    )
    private static let graphifySubcommandRegex = try! NSRegularExpression(
        pattern: #"^(?:/usr/bin/env\s+)?(?:\S+/)?graphify(?:y)?\s+(query|path|explain)(?:\s|$)"#,
        options: [.caseInsensitive]
    )

    /// Segment must start with optional env/path then graphify + allowed subcommand.
    static func matchSegment(_ segment: String) -> String? {
        // Strip leading env assignments: FOO=bar graphify query …
        var s = segment
        while let prefix = leadingEnvAssignmentPrefix(in: s) {
            s = String(s[prefix...])
        }
        // Optional path prefix: /usr/bin/env, absolute path, ./graphify
        // Capture the token after graphify.
        let ns = s as NSString
        guard let match = graphifySubcommandRegex.firstMatch(
            in: s,
            options: [],
            range: NSRange(location: 0, length: ns.length)
        ),
              match.numberOfRanges >= 2,
              let r = Range(match.range(at: 1), in: s) else {
            return nil
        }
        let sub = String(s[r]).lowercased()
        return allowedSubcommands.contains(sub) ? sub : nil
    }

    /// End index of a leading `KEY=value ` env assignment, if present.
    private static func leadingEnvAssignmentPrefix(in text: String) -> String.Index? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for regex in [quotedEnvAssignmentRegex, bareEnvAssignmentRegex] {
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  match.range.location == 0,
                  let end = Range(match.range, in: text)?.upperBound else {
                continue
            }
            return end
        }
        return nil
    }
}
