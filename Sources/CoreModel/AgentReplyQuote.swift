import Foundation

/// A reply to one Bot message. The quote travels inside the user's message
/// text as its first line, so the Bot reads which message is answered, the
/// transcript keeps it across restarts, and iOS renders the same text:
///
///     > Replying to: “Opened 2 new slow-query tasks today: Studio #…”
///
///     <what the user typed>
///
/// iOS parses and composes the identical format (Mac↔iOS parity).
public enum AgentReplyQuote {
    static let prefix = "> Replying to: “"
    static let suffix = "”"
    /// Longest excerpt kept in the quote line (then "…").
    public static let maxExcerptCharacters = 140

    /// One plain line of `message` (Markdown removed, clipped) for the quote.
    public static func excerpt(of message: String) -> String {
        MarkdownPlainText.firstLine(strippingQuote(message), maxCharacters: maxExcerptCharacters)
    }

    /// The message to send: the quote line, a blank line, then the user's text.
    public static func compose(excerpt: String, text: String) -> String {
        let line = excerpt.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return text }
        return "\(prefix)\(line)\(suffix)\n\n\(text)"
    }

    /// The quote and the user's own text when `text` starts with a reply quote.
    public static func parse(_ text: String) -> (excerpt: String, body: String)? {
        guard text.hasPrefix(prefix) else { return nil }
        let firstLineEnd = text.firstIndex(of: "\n") ?? text.endIndex
        let line = text[text.index(text.startIndex, offsetBy: prefix.count)..<firstLineEnd]
        guard line.hasSuffix(suffix) else { return nil }
        let excerpt = String(line.dropLast(suffix.count))
        let body = text[firstLineEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !excerpt.isEmpty, !body.isEmpty else { return nil }
        return (excerpt, body)
    }

    /// `text` without its reply quote (previews, copy).
    public static func strippingQuote(_ text: String) -> String {
        parse(text)?.body ?? text
    }
}
