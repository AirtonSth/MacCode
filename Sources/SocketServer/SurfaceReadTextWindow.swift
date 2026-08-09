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
    ///
    /// PERF: O(1) UTF-8 jump to `total - maxBytes`, then a short boundary walk and
    /// optional newline scan on the admitted tail only. The prior Character walk
    /// paid O(window) grapheme steps and a temporary `String` per step on every
    /// `surface.read_text` — the iOS terminal mirror's hottest read.
    public static func tail(of text: String, maxBytes: Int?) -> Window {
        guard let maxBytes, maxBytes > 0 else {
            return Window(text: text, truncatedHead: false)
        }
        // O(1) on native Swift strings: under-budget never pays a walk.
        guard text.utf8.count > maxBytes else {
            return Window(text: text, truncatedHead: false)
        }

        var copy = text
        let total = copy.utf8.count
        // Longest suffix ≤ maxBytes that starts on a Character boundary.
        // Mid-scalar candidates advance forward so the window stays under budget.
        var start = total - maxBytes
        while start < total {
            let byteIndex = copy.utf8.index(copy.utf8.startIndex, offsetBy: start)
            if !isUTF8Continuation(copy.utf8[byteIndex]) {
                break
            }
            start += 1
        }
        // A scalar boundary can still be inside an extended grapheme cluster
        // (for example, between the scalars in "é" or a family emoji). The
        // previous Character walk excluded that whole cluster when it did not
        // fit, so preserve that contract while retaining the O(1) byte jump.
        var characterStart = copy.utf8.index(
            copy.utf8.startIndex,
            offsetBy: start,
            limitedBy: copy.utf8.endIndex
        ) ?? copy.utf8.endIndex
        while characterStart < copy.utf8.endIndex,
              characterStart.samePosition(in: copy) == nil {
            copy.utf8.formIndex(after: &characterStart)
        }
        start = copy.utf8.distance(from: copy.utf8.startIndex, to: characterStart)

        var windowed = ""
        copy.withUTF8 { buffer in
            // Prefer a line boundary inside the window so the first retained line
            // is whole. Only when a newline exists and dropping to it still leaves
            // content — otherwise keep the raw byte window (live partial lines).
            if start < total {
                var lineStart = start
                var i = start
                while i < total {
                    if buffer[i] == UInt8(ascii: "\n") {
                        let after = i + 1
                        if after < total {
                            lineStart = after
                        }
                        break
                    }
                    i += 1
                }
                start = lineStart
            }
            windowed = String(decoding: buffer[start..<total], as: UTF8.self)
        }
        return Window(text: windowed, truncatedHead: true)
    }

    /// UTF-8 continuation byte (10xxxxxx) — not a valid scalar start.
    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (byte & 0xC0) == 0x80
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
