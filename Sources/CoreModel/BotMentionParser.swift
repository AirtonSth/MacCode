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
            // SEP-3: case-insensitive match without per-bot lowercased()
            // allocs on every keystroke (needle is already lowercase).
            return bot.handle.range(of: needle, options: [.caseInsensitive, .anchored]) != nil
                || bot.name.range(of: needle, options: .caseInsensitive) != nil
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
        mentionTokenRanges(in: text).map(\.token)
    }

    private static func mentionTokenRanges(
        in text: String
    ) -> [(token: String, range: Range<String.Index>)] {
        var ranges: [(token: String, range: Range<String.Index>)] = []
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
                    let token = String(text[start..<end])
                    ranges.append((token, index..<end))
                }
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return ranges
    }

}

public enum BotPeerActivityPhase: String, Codable, Sendable, Equatable {
    case waiting
    case needsAttention
}

public struct BotPeerActivitySnapshot: Sendable, Equatable {
    public let phase: BotPeerActivityPhase
    public let name: String
    public let title: String
    public let handle: String

    public init(phase: BotPeerActivityPhase, name: String, title: String, handle: String) {
        self.phase = phase
        self.name = name
        self.title = title
        self.handle = handle
    }

    public var identityLine: String {
        [name, title.isEmpty ? nil : title, handle]
            .compactMap { $0 }
            .joined(separator: " - ")
    }
}

/// Persistable state for a teammate turn inside an Agent App thread.
public enum BotPeerTranscript {
    private static let prefix = "[[rc:bot-from:"
    private static let activityPrefix = "[[rc:bot-activity:"
    public static let languageInstruction =
        "Reply in the language of what the user wrote."

    public static func toCaption(name: String) -> String { "To \(name)" }
    public static func fromCaption(name: String) -> String { "From \(name)" }

    public static func handleLabel(_ handle: String) -> String {
        handle.hasPrefix("@") ? handle : "@\(handle)"
    }

    public static func groupCaption(hostName: String, peerName: String, count: Int) -> String {
        if hostName.isEmpty {
            return "\(count) messages · \(peerName)"
        }
        return "\(count) messages · \(hostName) × \(peerName)"
    }

    public static func encode(peer: BotDefinition, text: String) -> String {
        "\(prefix)\(peer.handle)|\(peer.name)|\(peer.title)|\(peer.avatarSymbol)]]\n\(text)"
    }

    public static func parse(
        _ content: String
    ) -> (
        caption: String,
        body: String,
        name: String,
        title: String,
        handle: String,
        avatarSymbol: String
    )? {
        guard content.hasPrefix(prefix),
              let end = content.range(of: "]]") else { return nil }
        let payload = content[content.index(content.startIndex, offsetBy: prefix.count)..<end.lowerBound]
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let handle = parts[0]
        let name = parts[1]
        let title = parts.count > 2 ? parts[2] : ""
        let avatarSymbol = parts.count > 3 ? parts[3] : ""
        let bodyStart = content.index(end.upperBound, offsetBy: 0)
        var body = String(content[bodyStart...])
        if body.hasPrefix("\n") { body.removeFirst() }
        return (fromCaption(name: name), body, name, title, handle, avatarSymbol)
    }

    public static func encodeActivity(peer: BotDefinition, phase: BotPeerActivityPhase) -> String {
        "\(activityPrefix)\(phase.rawValue)|\(peer.handle)|\(peer.name)|\(peer.title)]]"
    }

    public static func parseActivity(_ content: String) -> BotPeerActivitySnapshot? {
        guard content.hasPrefix(activityPrefix),
              let end = content.range(of: "]]") else { return nil }
        let payload = content[
            content.index(content.startIndex, offsetBy: activityPrefix.count)..<end.lowerBound
        ]
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let phase = BotPeerActivityPhase(rawValue: parts[0]) else { return nil }
        return BotPeerActivitySnapshot(
            phase: phase,
            name: parts[2],
            title: parts[3],
            handle: parts[1]
        )
    }

    public static func mentionedCaption(for bot: BotDefinition) -> String {
        mentionedCaption(name: bot.name)
    }

    public static func mentionedCaption(name: String) -> String { "Mentions \(name)" }

    private static let peerAskMarker = " asked you:\n"

    /// Internal provider line on the asked bot's thread. Hide it; the Desk
    /// paints the original ask with From-host chrome instead.
    public static func isPeerAskUserText(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).contains(peerAskMarker)
    }

    public static func displayTextFromPeerAsk(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = trimmed.range(of: peerAskMarker) else { return trimmed }
        return String(trimmed[range.upperBound...])
    }

    /// Hop-1 host follow-up. Must include the peer reply and must not
    /// contain `@<handle>` or mention-send will loop. Keep the original
    /// user line so the host answers in that language.
    public static func hostHopPrompt(
        peerName: String,
        reply: String,
        userText: String = ""
    ) -> String {
        var lines: [String] = ["\(peerName) replied:\n\(reply)"]
        let ask = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ask.isEmpty {
            lines.append("The user wrote:\n\(ask)")
        }
        lines.append(languageInstruction)
        return strippingAtHandles(lines.joined(separator: "\n\n"))
    }

    public static func isHostHopUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.contains(languageInstruction) { return true }
        if trimmed.hasPrefix("The user wrote:\n") { return true }
        return trimmed.contains(" replied:\n")
    }

    public static func strippingAtHandles(_ text: String) -> String {
        var result = text
        for token in BotMentionParser.mentionTokens(in: text) {
            result = result.replacingOccurrences(of: "@\(token)", with: token)
        }
        return result
    }

    public static func containsMentionToken(_ text: String, handle: String) -> Bool {
        let needle = BotHandle.normalize(handle) ?? handle.lowercased()
        return BotMentionParser.mentionTokens(in: text).contains { token in
            (BotHandle.normalize(token) ?? token.lowercased()) == needle
        }
    }
}
