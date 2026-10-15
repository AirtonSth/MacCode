import Foundation

/// Ready-made answers a Bot offers at the end of a message:
///
///     ```choices
///     {"question":"Which one?","hint":"…","multiple":false,"options":["A","B"]}
///     ```
///
/// The chat hides the block and shows a card of tappable options instead.
/// iOS parses the same block with the same rules, so both sides show the
/// same card for the same message.
public struct BotChoicesBlock: Equatable, Sendable {
    public static let maximumOptions = 6

    public let question: String?
    public let hint: String?
    public let multiple: Bool
    public let options: [String]
    /// Titio notice key (`"notice"` in the block). Set only on cards the host
    /// writes for a ledger notice: a tap then acts through the host ledger
    /// instead of sending the option text. Blocks without it parse as before.
    public let notice: String?

    public init(question: String?, hint: String?, multiple: Bool, options: [String], notice: String? = nil) {
        self.question = question
        self.hint = hint
        self.multiple = multiple
        self.options = options
        self.notice = notice
    }

    public struct Parsed: Equatable, Sendable {
        /// The message as the chat shows it.
        public let text: String
        public let choices: BotChoicesBlock?
    }

    /// Splits a message into its visible text and its choices card.
    /// - A valid block is removed and becomes the card.
    /// - An unclosed block (still streaming) is hidden; no card yet.
    /// - A closed but invalid block stays as written, so nothing is lost.
    public static func parse(_ message: String) -> Parsed {
        // PERF: transcript rows parse on every paint; most messages have no block.
        guard message.range(of: "```choices", options: .caseInsensitive) != nil else {
            return Parsed(text: message, choices: nil)
        }
        let lines = message.components(separatedBy: "\n")
        guard let open = lines.lastIndex(where: { isOpeningFence($0) }) else {
            return Parsed(text: message, choices: nil)
        }
        guard let close = lines[(open + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "```"
        }) else {
            return Parsed(text: trimmedTrailing(lines[..<open].joined(separator: "\n")), choices: nil)
        }
        let body = lines[(open + 1)..<close].joined(separator: "\n")
        guard let choices = decode(body) else {
            return Parsed(text: message, choices: nil)
        }
        let kept = Array(lines[..<open]) + Array(lines[(close + 1)...])
        return Parsed(text: trimmedTrailing(kept.joined(separator: "\n")), choices: choices)
    }

    /// The text sent back when the user picks.
    public func answer(selecting indexes: Set<Int>) -> String? {
        let picked = options.indices.filter { indexes.contains($0) }.map { options[$0] }
        return picked.isEmpty ? nil : picked.joined(separator: ", ")
    }

    /// A, B, C… for the option at `index`.
    public static func letter(at index: Int) -> String {
        guard let scalar = UnicodeScalar(65 + index) else { return "\(index + 1)" }
        return String(Character(scalar))
    }

    private static func isOpeningFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "```choices"
    }

    private static func decode(_ body: String) -> BotChoicesBlock? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawOptions = object["options"] as? [Any] else { return nil }
        var seen = Set<String>()
        var options: [String] = []
        for case let raw as String in rawOptions {
            let option = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !option.isEmpty, seen.insert(option).inserted else { continue }
            options.append(option)
            if options.count == maximumOptions { break }
        }
        guard options.count >= 2 else { return nil }
        return BotChoicesBlock(
            question: nonEmpty(object["question"]),
            hint: nonEmpty(object["hint"]),
            multiple: object["multiple"] as? Bool ?? false,
            options: options,
            notice: nonEmpty(object["notice"])
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
