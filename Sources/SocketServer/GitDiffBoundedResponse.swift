import Foundation

/// Opt-in bounded diff response (v1) for cellular-safe wire windows.
///
/// Shared by `git.diff` and `agent.checkpoint.diff` so both endpoints use exactly
/// one UTF-8/LF-safe clipping implementation. iOS requests `response_version` /
/// `max_bytes` / `max_lines` (planned checkpoint window: 128 KiB / 500 lines).
/// Without host support the Dispatcher returned the full patch as a bare string,
/// so a weak link still paid for the entire diff (and can hit the outer 8 MiB
/// HTTP compatibility ceiling). Legacy callers omit `response_version` and must
/// keep receiving that bare string byte-for-byte — even if `max_bytes` /
/// `max_lines` happen to be present.
///
/// Line semantics match the iOS decoder: empty string = 0 lines; otherwise Swift
/// `split(separator: "\n", omittingEmptySubsequences: false)`. Literal LF only:
/// CRLF contains an LF delimiter; lone CR does not.
public enum GitDiffBoundedResponse: Sendable {
    public static let version = 1
    public static let maxBytesCeiling = 1_048_576
    public static let maxLinesCeiling = 10_000
    /// Planned iOS `agent.checkpoint.diff` request window.
    public static let checkpointDefaultMaxBytes = 128 * 1024
    public static let checkpointDefaultMaxLines = 500

    public struct Window: Sendable, Equatable {
        public let text: String
        public let truncated: Bool
        public let totalLines: Int

        public init(text: String, truncated: Bool, totalLines: Int) {
            self.text = text
            self.truncated = truncated
            self.totalLines = totalLines
        }

        public var json: JSONValue {
            .object([
                "version": .number(Double(GitDiffBoundedResponse.version)),
                "text": .string(text),
                "truncated": .bool(truncated),
                "total_lines": .number(Double(totalLines)),
            ])
        }
    }

    /// Line count matching the iOS decoder (LF delimiters only).
    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var count = 1
        for byte in text.utf8 where byte == UInt8(ascii: "\n") {
            count += 1
        }
        return count
    }

    /// Parse opt-in wire caps. Returns `nil` when `response_version` is absent (legacy).
    /// Throws `invalidParams` when the key is present but the triple is not a valid v1 request.
    ///
    /// WHY fail closed before `router.gitDiff` / `router.agentCheckpointDiff`: invalid
    /// caps must not pay for an expensive full-patch generation only to reject the
    /// response afterward.
    public static func parseOptInCaps(_ params: [String: JSONValue]) throws -> (maxBytes: Int, maxLines: Int)? {
        guard params["response_version"] != nil else { return nil }
        guard let responseVersion = params["response_version"]?.intValue,
              responseVersion == version,
              let maxBytes = params["max_bytes"]?.intValue,
              (1...maxBytesCeiling).contains(maxBytes),
              let maxLines = params["max_lines"]?.intValue,
              (1...maxLinesCeiling).contains(maxLines) else {
            throw JSONRPCError.invalidParams
        }
        return (maxBytes, maxLines)
    }

    /// Prefix of `text` at most both caps. No per-line String map.
    ///
    /// `truncated` is true exactly when any original text was omitted. A byte cap
    /// may clip mid-line so `truncated` can be true while the returned line count
    /// still equals `total_lines`. Never splits a UTF-8 scalar.
    ///
    /// PERF: under-budget patches take one UTF-8 LF scan (`lineCount`) and return
    /// the original string — no unicodeScalars walk and no copy. Over-budget paths
    /// walk unicodeScalars only until the admitted head, then finish `total_lines`
    /// with the same O(n) UTF-8 LF scan instead of scanning the tail as scalars.
    public static func bound(text: String, maxBytes: Int, maxLines: Int) -> Window {
        guard !text.isEmpty else {
            return Window(text: "", truncated: false, totalLines: 0)
        }

        // Fast path: whole body fits the byte budget. A single UTF-8 LF scan
        // decides identity vs line-only truncation (common for under-window
        // checkpoint diffs on a weak link).
        if text.utf8.count <= maxBytes {
            let totalLines = lineCount(text)
            if totalLines <= maxLines {
                return Window(text: text, truncated: false, totalLines: totalLines)
            }
            // Byte budget ok; still need a line-bounded prefix (below).
        }

        var end = text.startIndex
        var bytes = 0
        var newlinesInPrefix = 0
        var i = text.unicodeScalars.startIndex

        while i < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[i]
            let next = text.unicodeScalars.index(after: i)
            let isNewline = scalar.value == 0x0A

            // Unicode-scalar indices are valid String indices. Counting the
            // scalar's encoded width avoids both grapheme-cluster surprises
            // (Swift treats CRLF as one Character) and intermediate strings.
            let cost: Int
            switch scalar.value {
            case ...0x7F: cost = 1
            case ...0x7FF: cost = 2
            case ...0xFFFF: cost = 3
            default: cost = 4
            }
            // Non-empty prefix line count = 1 + newline count (matches iOS split).
            let projectedLines = 1 + newlinesInPrefix + (isNewline ? 1 : 0)
            if bytes + cost > maxBytes || projectedLines > maxLines {
                // Prefix complete — do not walk the tail as unicodeScalars.
                break
            }
            bytes += cost
            if isNewline { newlinesInPrefix += 1 }
            end = next
            i = next
        }

        // UTF-8 LF scan of the full body (same contract as lineCount / iOS).
        let totalLines = lineCount(text)
        if end == text.endIndex {
            return Window(text: text, truncated: false, totalLines: totalLines)
        }
        return Window(text: String(text[..<end]), truncated: true, totalLines: totalLines)
    }
}
