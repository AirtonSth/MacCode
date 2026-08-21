import Foundation

/// Host-generated proof that a Distill invocation replaced tool/output bytes.
public enum DistillAppliedReceipt {
    private static let trailingMarkerRegex = try! NSRegularExpression(
        pattern: #"(?:\A|\r?\n)\[\[rcd:v1\.[A-Za-z0-9_-]{22}\]\](?:\r?\n)?\z"#
    )
    private static let trailingSpacesBeforeNewlineRegex = try! NSRegularExpression(
        pattern: #"[ \t]+\n"#
    )
    private static let multiNewlineCollapseRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#
    )

    /// Returns an exact `[[rcd:v1.<token>]]` marker with 128 random bits encoded
    /// as 22 unpadded base64url characters.
    public static func makeMarker() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "[[rcd:v1.\(token)]]"
    }

    /// Recognizes only an exact marker occupying the complete trailing line.
    public static func containsMarker(_ text: String) -> Bool {
        match(in: text) != nil
    }

    /// Removes a valid trailing receipt before text reaches the user. Invalid or
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
