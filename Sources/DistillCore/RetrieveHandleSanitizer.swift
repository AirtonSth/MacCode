import Foundation

/// Strips unresolved CCR handle markers (`[[rc:<hex>]]`) from text before it is shown
/// to a human or persisted as a final message. The marker is meaningful to the agent
/// (it can `distill retrieve <hex>`), but a leaked marker in user-facing text is noise.
/// Pure and deterministic.
public enum RetrieveHandleSanitizer {
    private static let pattern = #"\[\[rc:[0-9a-fA-F]+\]\]"#

    /// Remove all `[[rc:...]]` markers, collapsing any whitespace they leave behind.
    public static func strip(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        // Tidy the residue: trailing spaces before newlines and 3+ blank lines.
        return stripped
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if the text still carries an unresolved handle marker.
    public static func containsHandle(_ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
