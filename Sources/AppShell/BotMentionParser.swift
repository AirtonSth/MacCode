import Foundation
import CoreModel

/// `@handle` tokens in Desk composer text. Handle match wins, then name.
enum BotMentionParser {
    static func activeQuery(in text: String) -> String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at > text.startIndex {
            let before = text[text.index(before: at)]
            if before.isLetter || before.isNumber || before == "_" { return nil }
        }
        let after = text[text.index(after: at)...]
        if after.contains(where: \.isWhitespace) { return nil }
        return String(after)
    }

    static func suggestions(
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

    static func mentionedBots(
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

    static func applying(_ bot: BotDefinition, to text: String) -> String {
        guard let at = text.lastIndex(of: "@") else {
            return text + "@\(bot.handle) "
        }
        let prefix = text[..<at]
        return "\(prefix)@\(bot.handle) "
    }

    static func resolve(
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

    static func mentionTokens(in text: String) -> [String] {
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
