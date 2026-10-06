import Foundation

/// Builds one participant's prompt for a group turn: a group identity header
/// plus the room messages it has not seen yet. Pure: the orchestrator
/// compiles the result through the bot's brain and advances the watermark.
public enum BotGroupPromptComposer {
    public static let defaultMaxDeltaCharacters = 24_000

    public struct Composition: Equatable, Sendable {
        public let prompt: String
        /// Newest room message at compose time; the new watermark once the
        /// turn starts. Nil when the room has nothing past the watermark.
        public let lastSeenMessageID: AgentMessageID?
        public let lastSeenCreatedAt: Date?
        public let includedCount: Int
        public let omittedCount: Int
    }

    /// - Parameters:
    ///   - roomMessages: the room transcript, oldest first.
    ///   - participants: active participants in group order (includes `me`).
    ///   - seenMessageID/seenCreatedAt: `me`'s watermark. The id wins; the
    ///     timestamp covers a watermark row that no longer exists.
    public static func compose(
        groupTitle: String,
        me: BotDefinition,
        participants: [BotDefinition],
        roomMessages: [AgentMessage],
        seenMessageID: AgentMessageID?,
        seenCreatedAt: Date?,
        maxDeltaCharacters: Int = defaultMaxDeltaCharacters
    ) -> Composition {
        let unseen = delta(roomMessages, seenMessageID: seenMessageID, seenCreatedAt: seenCreatedAt)
        let entries = unseen.compactMap { entry(for: $0, me: me) }

        // Keep the newest entries that fit; the newest one is always kept
        // whole so the message that triggered this turn is never cut.
        var kept: [String] = []
        var used = 0
        for entry in entries.reversed() {
            if !kept.isEmpty, used + entry.count > maxDeltaCharacters { break }
            kept.insert(entry, at: 0)
            used += entry.count
        }
        let omitted = entries.count - kept.count

        var sections = [header(groupTitle: groupTitle, me: me, participants: participants)]
        if omitted > 0 {
            sections.append(omissionLine(omitted))
        }
        if kept.isEmpty {
            sections.append("There are no new messages in the group since your last turn.")
        } else {
            sections.append("New messages in the group since your last turn:")
            sections.append(contentsOf: kept)
        }
        sections.append(
            "Reply to the group as \(me.name). To hand the floor to another participant, @mention them."
        )
        sections.append(BotPeerTranscript.languageInstruction)

        let last = unseen.last
        return Composition(
            prompt: sections.joined(separator: "\n\n"),
            lastSeenMessageID: last?.id,
            lastSeenCreatedAt: last?.createdAt,
            includedCount: kept.count,
            omittedCount: omitted
        )
    }

    public static func omissionLine(_ count: Int) -> String {
        count == 1
            ? "(1 earlier message since your last turn was left out to fit this prompt.)"
            : "(\(count) earlier messages since your last turn were left out to fit this prompt.)"
    }

    static func header(groupTitle: String, me: BotDefinition, participants: [BotDefinition]) -> String {
        var lines = [
            "You are \(identity(me)) in the group conversation \"\(groupTitle)\" with the user and other bots.",
            "Participants:",
        ]
        for bot in participants {
            var line = "- \(identity(bot))"
            if !bot.title.isEmpty { line += ", \(bot.title)" }
            if bot.id == me.id { line += " (you)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func delta(
        _ messages: [AgentMessage],
        seenMessageID: AgentMessageID?,
        seenCreatedAt: Date?
    ) -> ArraySlice<AgentMessage> {
        if let seenMessageID, let index = messages.firstIndex(where: { $0.id == seenMessageID }) {
            return messages[messages.index(after: index)...]
        }
        if let seenCreatedAt {
            return messages[(messages.firstIndex { $0.createdAt > seenCreatedAt } ?? messages.endIndex)...]
        }
        return messages[...]
    }

    /// One room row as prompt text, or nil when it carries nothing for `me`:
    /// waiting/attention placeholders, `me`'s own replies (already in its
    /// member thread) and rows that are empty once markers are removed.
    /// User text is quoted verbatim.
    static func entry(for message: AgentMessage, me: BotDefinition) -> String? {
        if BotPeerTranscript.parseActivity(message.content) != nil { return nil }
        if let reply = BotPeerTranscript.parse(message.content) {
            if BotHandle.normalize(reply.handle) == BotHandle.normalize(me.handle) { return nil }
            let body = strippingMarkers(reply.body)
            guard !body.isEmpty else { return nil }
            return "\(reply.name) (\(BotPeerTranscript.handleLabel(reply.handle))):\n\(body)"
        }
        switch message.role {
        case .user:
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "User:\n\(message.content)"
        case .assistant, .system:
            let body = strippingMarkers(message.content)
            guard !body.isEmpty else { return nil }
            return "Group note:\n\(body)"
        }
    }

    private static let hostMarkerRegex = try! NSRegularExpression(pattern: #"\[\[rc:[^\]\n]*\]\]"#)

    /// Removes host-internal markers (`[[RC_AWAITING]]`, the uncalled-tool
    /// marker and any `[[rc:…]]` token) from a bot-authored row.
    static func strippingMarkers(_ text: String) -> String {
        let withoutAwaiting = BackgroundAwaitContinuation.strippingAwaitingMarker(text)
        let range = NSRange(withoutAwaiting.startIndex..<withoutAwaiting.endIndex, in: withoutAwaiting)
        return hostMarkerRegex
            .stringByReplacingMatches(in: withoutAwaiting, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func identity(_ bot: BotDefinition) -> String {
        "\(bot.name) (\(BotPeerTranscript.handleLabel(bot.handle)))"
    }
}
