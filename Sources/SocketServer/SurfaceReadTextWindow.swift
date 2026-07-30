import Foundation

/// Optional byte window for `surface.read_text`.
///
/// WHY: `surface.read_text` is the iOS terminal mirror's hottest read. It returns
/// the authoritative transcript — and for terminal surfaces it returns it *twice*,
/// as `text` plus a full `ansi_text` copy including scrollback. It had no size
/// parameter, so on a ~200 kbps cellular link every refresh paid for the entire
/// transcript even though the client caps what it displays anyway. Its sibling
/// `surface.read_history` has always accepted `max_bytes`; this brings the same
/// bounded-read discipline to `read_text`.
///
/// Semantics, mirroring `read_history`:
/// - Absent / non-positive `max_bytes` ⇒ no windowing at all (byte-for-byte the
///   previous response). Older clients are therefore unaffected.
/// - The window keeps the **tail**, because a terminal viewport shows the newest
///   output. Dropping the tail would be useless to the caller.
/// - The cut lands on a newline boundary when one exists inside the window, so a
///   client never has to render a half line, and never on a partial UTF-8
///   scalar.
/// - When anything was dropped the response says so (`text_truncated_head`).
///   Silently returning a prefix of the transcript as if it were the whole thing
///   would be fake freshness.
public enum SurfaceReadTextWindow: Sendable {
    /// Response key set when the transcript was windowed.
    public static let truncatedHeadKey = "text_truncated_head"
    /// Response key carrying the byte budget the window was built for.
    public static let appliedMaxBytesKey = "text_max_bytes"

    /// Result of windowing one transcript field.
    public struct Window: Sendable, Equatable {
        public let text: String
        public let truncatedHead: Bool

        public init(text: String, truncatedHead: Bool) {
            self.text = text
            self.truncatedHead = truncatedHead
        }
    }

    /// Tail window of `text` no larger than `maxBytes` UTF-8 bytes.
    ///
    /// Returns the input unchanged when `maxBytes` is nil, non-positive, or already
    /// large enough to hold the whole transcript.
    public static func tail(of text: String, maxBytes: Int?) -> Window {
        guard let maxBytes, maxBytes > 0 else {
            return Window(text: text, truncatedHead: false)
        }
        let utf8 = text.utf8
        guard utf8.count > maxBytes else {
            return Window(text: text, truncatedHead: false)
        }

        // Walk back from the end by scalar so the cut never splits a UTF-8
        // sequence or a grapheme's leading scalar.
        var startIndex = text.endIndex
        var budget = maxBytes
        while startIndex > text.startIndex {
            let previous = text.index(before: startIndex)
            let cost = String(text[previous]).utf8.count
            if cost > budget { break }
            budget -= cost
            startIndex = previous
        }

        var windowed = text[startIndex...]
        // Prefer a line boundary inside the window so the first retained line is
        // whole. Only do this when a newline exists and dropping to it still
        // leaves content — otherwise keep the raw byte window.
        if let newline = windowed.firstIndex(of: "\n") {
            let afterNewline = windowed.index(after: newline)
            if afterNewline < windowed.endIndex {
                windowed = windowed[afterNewline...]
            }
        }
        return Window(text: String(windowed), truncatedHead: true)
    }

    /// Positive byte budget from request params, or nil when unbounded.
    ///
    /// Non-positive and absent both mean "no window" so a client cannot ask for an
    /// empty transcript by sending `max_bytes: 0`.
    public static func requestedMaxBytes(_ raw: Int?) -> Int? {
        guard let raw, raw > 0 else { return nil }
        return raw
    }

    /// Apply the window to a `surface.read_text` metadata response.
    ///
    /// Windows both transcript carriers (`text` and `ansi_text`) with the same
    /// budget, since a client that asked for a bounded read must not receive an
    /// unbounded ANSI copy alongside a bounded plain one. Every other field is
    /// passed through untouched.
    public static func applied(
        to fields: [String: JSONValue],
        maxBytes: Int?
    ) -> [String: JSONValue] {
        guard let maxBytes = requestedMaxBytes(maxBytes) else { return fields }
        var next = fields
        var truncated = false

        if let text = fields["text"]?.stringValue {
            let window = tail(of: text, maxBytes: maxBytes)
            next["text"] = .string(window.text)
            truncated = truncated || window.truncatedHead
        }
        if let ansi = fields["ansi_text"]?.stringValue {
            let window = tail(of: ansi, maxBytes: maxBytes)
            next["ansi_text"] = .string(window.text)
            truncated = truncated || window.truncatedHead
        }

        next[appliedMaxBytesKey] = .number(Double(maxBytes))
        next[truncatedHeadKey] = .bool(truncated)
        return next
    }
}
