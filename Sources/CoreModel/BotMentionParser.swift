import Foundation

/// `@handle` tokens in composer text. Handle match wins, then name.
public enum BotMentionParser {
    public static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            if before.isLetter || before.isNumber || before == "_" { return nil }
        }
        let after = text[text.index(after: at)...]
        if after.contains(where: \.isWhitespace) { return nil }
        return String(after)
    }

    public static func suggestions(
        query: String,
        bots: [BotDefinition],
        excluding: BotID?
    ) -> [BotDefinition] {
        let needle = query.lowercased()
        return bots.filter { bot in
            if bot.id == excluding { return false }
            if needle.isEmpty { return true }
            return bot.handle.lowercased().hasPrefix(needle)
                || bot.name.lowercased().contains(needle)
        }
    }

    public static func mentionedBots(
        in text: String,
        bots: [BotDefinition],
        excluding: BotID?
    ) -> [BotDefinition] {
        let tokens = mentionTokens(in: text)
        guard !tokens.isEmpty else { return [] }
        var seen = Set<BotID>()
        var result: [BotDefinition] = []
        for token in tokens {
            guard let bot = resolve(token, in: bots, excluding: excluding),
                  seen.insert(bot.id).inserted else { continue }
            result.append(bot)
        }
        return result
    }

    public static func applying(_ bot: BotDefinition, to text: String) -> String {
        guard let at = text.lastIndex(of: "@") else {
            return text + "@\(bot.handle) "
        }
        let prefix = text[..<at]
        return "\(prefix)@\(bot.handle) "
    }

    public static func resolve(
        _ token: String,
        in bots: [BotDefinition],
        excluding: BotID?
    ) -> BotDefinition? {
        let needle = token.lowercased()
        if let handle = BotHandle.normalize(token),
           let exact = bots.first(where: { $0.id != excluding && $0.handle == handle }) {
            return exact
        }
        return bots.first { bot in
            bot.id != excluding && bot.name.lowercased() == needle
        }
    }

    public static func mentionTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@" {
                let start = text.index(after: index)
                var end = start
                while end < text.endIndex {
                    let ch = text[end]
                    if ch.isWhitespace { break }
                    if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "_" || ch == "-") {
                        end = text.index(after: end)
                    } else {
                        break
                    }
                }
                if start < end {
                    tokens.append(String(text[start..<end]))
                }
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return tokens
    }
}

/// Persistable caption for a teammate turn inside an Agent App thread.
public enum BotPeerTranscript {
    private static let prefix = "[[rc:bot-from:"

    public static func encode(peer: BotDefinition, text: String) -> String {
        "\(prefix)\(peer.handle)|\(peer.name)|\(peer.title)]]\n\(text)"
    }

    public static func parse(_ content: String) -> (caption: String, body: String)? {
        guard content.hasPrefix(prefix),
              let end = content.range(of: "]]") else { return nil }
        let payload = content[content.index(content.startIndex, offsetBy: prefix.count)..<end.lowerBound]
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let handle = parts[0]
        let name = parts[1]
        let title = parts.count > 2 ? parts[2] : ""
        let identity = [name, title.isEmpty ? nil : title, handle]
            .compactMap { $0 }
            .joined(separator: " - ")
        let bodyStart = content.index(end.upperBound, offsetBy: 0)
        var body = String(content[bodyStart...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return ("Message from \(identity)", body)
    }

    public static func messagedCaption(for bot: BotDefinition) -> String {
        let identity = [bot.name, bot.title.isEmpty ? nil : bot.title, bot.handle]
            .compactMap { $0 }
            .joined(separator: " - ")
        return "Messaged \(identity)"
    }
}
