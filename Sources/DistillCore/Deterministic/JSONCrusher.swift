import Foundation

/// Deterministic, lossless structural compression for JSON payloads (headroom's
/// SmartCrusher, ported native). `.minify` re-serializes parsed JSON with all
/// insignificant whitespace removed; the result is *semantically identical* to
/// the input — a re-parse is deep-equal — so it needs no reversible handle.
/// Pretty-printed tool output (2-space indent, newlines) shrinks substantially
/// with zero information loss. This runs on the CPU with no model and no I/O.
public enum JSONCrusher {
    /// Returns a minified rendering of `input` when (a) it parses as a JSON
    /// object/array and (b) the minified form is strictly smaller. Returns nil
    /// otherwise so the caller falls through unchanged (never inflate).
    ///
    /// `.sortedKeys` makes the output deterministic regardless of the parser's
    /// hash-ordered dictionary iteration; `.withoutEscapingSlashes` avoids
    /// inflating "/" into "\/". Both options are semantics-preserving, so two
    /// payloads with identical structure always crush to identical bytes — which
    /// is exactly what cross-turn dedup (P4) and the prompt cache reward.
    public static func minify(_ input: String) -> String? {
        guard let data = input.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        // Only top-level array/dict are valid for re-serialization; fragments
        // (bare scalars) are not worth crushing and would throw.
        guard object is [Any] || object is [String: Any] else { return nil }
        guard let out = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let text = String(data: out, encoding: .utf8),
              text.count < input.count else {
            return nil
        }
        return text
    }

    /// True when `text` parses as a top-level JSON object or array. Cheap structural
    /// probe used by the router's classifier; tolerant of leading/trailing whitespace.
    public static func looksLikeJSON(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "{" || first == "[" else { return false }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return false
        }
        return object is [Any] || object is [String: Any]
    }
}
