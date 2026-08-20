import Foundation

/// Strips local-model thinking traces so they never enter paid context.
public enum LibrarianThinkStrip {
    public static func strip(_ text: String) -> String? {
        if hasUnclosed(text, open: "<think>", close: "</think>") { return nil }
        if hasUnclosed(text, open: "<thinking>", close: "</thinking>") { return nil }
        var out = text
        out = stripTagged(out, open: "<think>", close: "</think>")
        out = stripTagged(out, open: "<thinking>", close: "</thinking>")
        out = stripJSONKey(out, key: "reasoning_content")
        out = stripJSONKey(out, key: "reasoning")
        if out.localizedCaseInsensitiveContains("<think>") || out.contains("reasoning_content") {
            return nil
        }
        return out
    }

    private static func hasUnclosed(_ text: String, open: String, close: String) -> Bool {
        text.localizedCaseInsensitiveContains(open) && !text.localizedCaseInsensitiveContains(close)
    }

    public static func paidFacingText(_ text: String) -> String? {
        strip(text)
    }

    private static func stripTagged(_ text: String, open: String, close: String) -> String {
        var result = text
        while let start = result.range(of: open, options: .caseInsensitive) {
            if let end = result.range(of: close, options: .caseInsensitive, range: start.lowerBound..<result.endIndex) {
                result.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                result.removeSubrange(start.lowerBound...)
                break
            }
        }
        return result
    }

    private static func stripJSONKey(_ text: String, key: String) -> String {
        guard let data = text.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return text
        }
        if object[key] != nil {
            object.removeValue(forKey: key)
            if let out = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
               let s = String(data: out, encoding: .utf8) {
                return s
            }
        }
        return text
    }
}
