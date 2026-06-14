import Foundation

/// Strips unresolved CCR handle markers (`[[rc:<hex>]]`) from final user-facing text.
public enum RetrieveHandleSanitizer {
    private static let pattern = #"\[\[rc:[0-9a-fA-F]+\]\]"#

    public static func strip(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return stripped
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func containsHandle(_ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
