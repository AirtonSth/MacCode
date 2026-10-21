import Foundation

/// Identity and state of a Titio notice message, written by the host as a
/// fenced block after the choices block:
///
///     ```notice
///     {"key":"run.R1.completed","kind":"runCompleted","source":{"workspace":"api"},"state":"open"}
///     ```
///
/// iOS parses the same block with the same rules. Unknown `kind` and `state`
/// strings still parse, so a newer host never breaks an older client.
public struct TitioNoticeBlock: Equatable, Sendable {
    public let key: String
    public let kind: String
    /// Provenance labels (`workspace`, `bot`, `conversation`), non-empty values only.
    public let source: [String: String]
    /// `open` until the host rewrites it to the resolution's status value.
    public let state: String

    public var isOpen: Bool { state == "open" }

    public init(key: String, kind: String, source: [String: String], state: String) {
        self.key = key
        self.kind = kind
        self.source = source
        self.state = state
    }

    public struct Parsed: Equatable, Sendable {
        /// The message as the chat shows it.
        public let text: String
        public let block: TitioNoticeBlock?
    }

    /// Splits a message into its visible text and its notice block.
    /// - A valid block is removed and becomes the block.
    /// - An unclosed block (still streaming) is hidden; no block yet.
    /// - A closed but invalid block stays as written, so nothing is lost.
    public static func parse(_ message: String) -> Parsed {
        // PERF: transcript rows parse on every paint; most messages have no block.
        guard message.range(of: "```notice", options: .caseInsensitive) != nil else {
            return Parsed(text: message, block: nil)
        }
        let lines = message.components(separatedBy: "\n")
        guard let fence = lastFence(in: lines) else {
            return Parsed(text: message, block: nil)
        }
        guard let close = fence.close else {
            return Parsed(text: trimmedTrailing(lines[..<fence.open].joined(separator: "\n")), block: nil)
        }
        let body = lines[(fence.open + 1)..<close].joined(separator: "\n")
        guard let block = decode(body) else {
            return Parsed(text: message, block: nil)
        }
        let kept = Array(lines[..<fence.open]) + Array(lines[(close + 1)...])
        return Parsed(text: trimmedTrailing(kept.joined(separator: "\n")), block: block)
    }

    /// The text the chat shows: no notice block and no choices block.
    public static func visibleText(_ message: String) -> String {
        BotChoicesBlock.parse(parse(message).text).text
    }

    /// The message with its notice block rewritten to `state`. Unchanged when it has no valid block.
    public static func withState(_ message: String, state: String) -> String {
        guard message.range(of: "```notice", options: .caseInsensitive) != nil else { return message }
        let lines = message.components(separatedBy: "\n")
        guard let fence = lastFence(in: lines), let close = fence.close,
              let block = decode(lines[(fence.open + 1)..<close].joined(separator: "\n")) else {
            return message
        }
        let rewritten = render(key: block.key, kind: block.kind, source: block.source, state: state)
        return (Array(lines[..<fence.open]) + [rewritten] + Array(lines[(close + 1)...])).joined(separator: "\n")
    }

    /// The ```notice fence with one-line JSON (sorted keys, unescaped slashes).
    public static func render(key: String, kind: String, source: [String: String], state: String) -> String {
        var object: [String: Any] = ["key": key, "kind": kind, "state": state]
        if !source.isEmpty { object["source"] = source }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return "```notice\n" + (String(data: data, encoding: .utf8) ?? "{}") + "\n```"
    }

    /// The last opening fence and the first closing fence after it (nil while unclosed).
    private static func lastFence(in lines: [String]) -> (open: Int, close: Int?)? {
        guard let open = lines.lastIndex(where: { isOpeningFence($0) }) else { return nil }
        let close = lines[(open + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "```"
        })
        return (open, close)
    }

    private static func isOpeningFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "```notice"
    }

    private static func decode(_ body: String) -> TitioNoticeBlock? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = nonEmpty(object["key"]),
              let kind = nonEmpty(object["kind"]) else { return nil }
        return TitioNoticeBlock(
            key: key,
            kind: kind,
            source: (object["source"] as? [String: Any] ?? [:]).compactMapValues(nonEmpty),
            state: nonEmpty(object["state"]) ?? "open"
        )
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func trimmedTrailing(_ text: String) -> String {
        var result = text
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return result
    }
}
