import Foundation

/// Strip-only helper for `[[rcd:…]]` markers that Token Saver (removed) left
/// at the end of tool output in older threads, so they never render raw.
public enum DistillAppliedReceipt {
    private static let trailingMarkerRegex = try! NSRegularExpression(
        pattern: #"(?:\A|\r?\n)\[\[rcd:(?:v1\.[A-Za-z0-9_-]{22}|v2\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43})\]\](?:\r?\n)?\z"#
    )
    private static let trailingSpacesBeforeNewlineRegex = try! NSRegularExpression(
        pattern: #"[ \t]+\n"#
    )
    private static let multiNewlineCollapseRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#
    )

    /// Removes a valid trailing marker before text reaches the user. Invalid or
    /// merely marker-shaped text is preserved byte-for-byte.
    public static func strip(_ text: String) -> String {
        guard let match = match(in: text) else { return text }
        let stripped = trailingMarkerRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: match,
            withTemplate: ""
        )
        return tidyWhitespace(stripped)
    }

    private static func match(in text: String) -> NSRange? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return trailingMarkerRegex.firstMatch(in: text, options: [], range: range)?.range
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text
        for (regex, template) in [
            (trailingSpacesBeforeNewlineRegex, "\n"),
            (multiNewlineCollapseRegex, "\n\n"),
        ] {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: template
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
