import Foundation

/// P3 our-storage compaction, done SAFELY. Shrinks the large tool-output string(s) inside
/// a persisted stream-event payload while keeping the JSON structurally identical — same
/// keys, same nesting, only an oversized string value replaced by head + `[[rc:HASH]]`
/// marker + tail. The original is stored (CCR) via `store`, so it is recoverable, and the
/// payload still decodes to the same event on replay (the decoder just sees a shorter
/// string). Fail-safe: returns the input unchanged if it is small, unparseable, or nothing
/// qualifies. This NEVER alters structural fields — only long free-text values.
public enum ReversiblePayloadCompactor {
    /// Compact string values longer than `thresholdChars`. `store` persists an original and
    /// returns its handle, or nil if it could not store (in which case that value is left
    /// verbatim — never compact without a recovery handle, N5).
    public static func compact(_ payloadJSON: String, thresholdChars: Int = 16_000, store: (String) -> String?) -> String {
        guard payloadJSON.count > thresholdChars else { return payloadJSON } // cheap skip for the common case
        guard let data = payloadJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              object is [String: Any] || object is [Any] else {
            return payloadJSON
        }
        var changed = false
        let transformed = transform(object, thresholdChars: thresholdChars, store: store, changed: &changed)
        guard changed,
              let out = try? JSONSerialization.data(withJSONObject: transformed, options: [.sortedKeys]),
              let text = String(data: out, encoding: .utf8) else {
            return payloadJSON
        }
        return text
    }

    private static func transform(_ value: Any, thresholdChars: Int, store: (String) -> String?, changed: inout Bool) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            out.reserveCapacity(dict.count)
            for (key, inner) in dict {
                out[key] = transform(inner, thresholdChars: thresholdChars, store: store, changed: &changed)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { transform($0, thresholdChars: thresholdChars, store: store, changed: &changed) }
        }
        if let string = value as? String, string.count > thresholdChars {
            guard let handle = store(string), !handle.isEmpty else { return value } // no handle => leave verbatim (N5)
            let head = String(string.prefix(400))
            let tail = String(string.suffix(200))
            let dropped = string.count - head.count - tail.count
            changed = true
            return "\(head)\n…[[rc:\(handle)]] \(dropped) chars elided (retrieve to expand)…\n\(tail)"
        }
        return value
    }
}
