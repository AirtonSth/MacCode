import Foundation

/// Opt-in `git.diff` bounded response (v1) for cellular-safe wire windows.
///
/// WHY: iOS already requests `response_version` / `max_bytes` / `max_lines`. Without
/// host support the Dispatcher returned the full patch as a bare string, so a weak
/// link still paid for the entire diff. Legacy callers omit `response_version` and
/// must keep receiving that bare string.
///
/// Line semantics match the iOS decoder: empty string = 0 lines; otherwise Swift
/// `split(separator: "\n", omittingEmptySubsequences: false)`.
public enum GitDiffBoundedResponse: Sendable {
    public static let version = 1
    public static let maxBytesCeiling = 1_048_576
    public static let maxLinesCeiling = 10_000

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

    /// Line count matching the iOS decoder.
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
    /// WHY fail closed before `router.gitDiff`: invalid caps must not pay for an
    /// expensive full-patch generation only to reject the response afterward.
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

    /// Prefix of `text` at most both caps. One Character walk; no per-line String map.
    ///
    /// `truncated` is true exactly when any original text was omitted. A byte cap
    /// may clip mid-line so `truncated` can be true while the returned line count
    /// still equals `total_lines`.
    public static func bound(text: String, maxBytes: Int, maxLines: Int) -> Window {
        guard !text.isEmpty else {
            return Window(text: "", truncated: false, totalLines: 0)
        }

        var end = text.startIndex
        var bytes = 0
        var newlinesInPrefix = 0
        var totalNewlines = 0
        var prefixDone = false
        var i = text.unicodeScalars.startIndex

        while i < text.unicodeScalars.endIndex {
            let scalar = text.unicodeScalars[i]
            let next = text.unicodeScalars.index(after: i)
            let isNewline = scalar.value == 0x0A
            if isNewline { totalNewlines += 1 }

            if !prefixDone {
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
                    prefixDone = true
                } else {
                    bytes += cost
                    if isNewline { newlinesInPrefix += 1 }
                    end = next
                }
            }
            i = next
        }

        let totalLines = 1 + totalNewlines
        if end == text.endIndex {
            return Window(text: text, truncated: false, totalLines: totalLines)
        }
        return Window(text: String(text[..<end]), truncated: true, totalLines: totalLines)
    }
}
