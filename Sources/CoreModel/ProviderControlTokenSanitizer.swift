import Foundation

/// Strips leaked model special/control tokens from assistant-facing text.
///
/// WHY: providers occasionally emit tokenizer control markers into the visible
/// stream (observed Grok ACP `agent_message_chunk`: literal `<|eos|>` as the
/// final body). Those must never reach the transcript, Work log answer bubble,
/// or persisted `agent_messages` content. Pattern is provider-agnostic so the
/// shared final-text choke point can defend Claude/Codex/Grok uniformly.
public enum ProviderControlTokenSanitizer {
    /// `<|name|>` interior limited to identifier-like chars (eos, endoftext,
    /// im_end, eot_id, …). Rejects newlines / bare `<|` so ordinary prose is safe.
    // PERF: compile once — strip runs on every streaming chunk and final message.
    private static let controlTokenRegex = try! NSRegularExpression(
        pattern: #"<\|[A-Za-z0-9_.\-]{1,64}\|>"#
    )
    private static let trailingSpacesBeforeNewlineRegex = try! NSRegularExpression(
        pattern: #"[ \t]+\n"#
    )
    private static let multiNewlineCollapseRegex = try! NSRegularExpression(
        pattern: #"\n{3,}"#
    )

    public static func containsControlToken(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return controlTokenRegex.firstMatch(in: text, options: [], range: range) != nil
    }

    /// Final-text strip: remove control tokens and tidy trailing whitespace.
    public static func strip(_ text: String) -> String {
        let stripped = stripPreservingWhitespace(text)
        guard stripped != text || containsControlToken(text) else { return text }
        return tidyWhitespace(stripped)
    }

    /// Streaming-delta strip: remove control tokens **without** trimming so
    /// inter-chunk spaces (`"Hello"` + `" world"`) stay intact.
    public static func stripPreservingWhitespace(_ text: String) -> String {
        guard containsControlToken(text) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return controlTokenRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: ""
        )
    }

    /// Strip for streaming deltas: drop a chunk that is only control tokens so
    /// the UI never flashes `<|eos|>`, while preserving real partial words and
    /// leading/trailing spaces on mixed chunks.
    public static func stripStreamingChunk(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let stripped = stripPreservingWhitespace(text)
        // Whole chunk was control-token debris (e.g. "<|eos|>" alone).
        if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           containsControlToken(text) {
            return ""
        }
        return stripped
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
