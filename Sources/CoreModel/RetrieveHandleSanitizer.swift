import Foundation

/// Strips unresolved CCR handle markers from final user-facing text.
public enum RetrieveHandleSanitizer {
    private static let uuid = #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#

    // PERF: compile once — strip/contains run on final assistant text and distill
    // gates; range(of:options:.regularExpression) recompiled every call.
    private static let handleRegex = try! NSRegularExpression(
        pattern: #"\[\[rc:(?:[0-9a-fA-F]+|rcv1\."# + uuid + #"\."# + uuid + uuid + #")\]\]"#
    )
    private static let trailingSpacesBeforeNewlineRegex = try! NSRegularExpression(
        pattern: #"[ \t]+\n"#
    )
    private static let multiNewlineCollapseRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#
    )

    public static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = handleRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
        return tidyWhitespace(stripped)
    }

    public static func containsHandle(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return handleRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text
        for (regex, template) in [
            (trailingSpacesBeforeNewlineRegex, "\n"),
            (multiNewlineCollapseRegex, "\n\n")
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
