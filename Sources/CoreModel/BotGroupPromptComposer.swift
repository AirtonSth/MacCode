import Foundation

/// Builds one participant's prompt for a group turn: a group identity header
/// plus the room messages it has not seen yet. Pure: the orchestrator
/// compiles the result through the bot's brain and advances the watermark.
public enum BotGroupPromptComposer {
    public static let defaultMaxDeltaCharacters = 24_000

    public struct Composition: Equatable, Sendable {
        public let prompt: String
        /// The new watermark once the turn completes, or nil when it must not
        /// move. It stops just before the first waiting row of another bot
        /// that can still become a reply: that row is replaced in place, so
        /// it is read again on this bot's next turn.
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
    ///   - groupTurns: the group's turns (any rounds, any state). A bot row
    ///     is attributed through its turn's `botID`, so a renamed or reused
    ///     handle never changes whose row it is; rows without a turn fall
    ///     back to the handle. A waiting row whose turn was cancelled,
    ///     failed, interrupted or skipped never holds the watermark.
    public static func compose(
        groupTitle: String,
        me: BotDefinition,
        participants: [BotDefinition],
        roomMessages: [AgentMessage],
        seenMessageID: AgentMessageID?,
        seenCreatedAt: Date?,
        groupTurns: [BotGroupTurn],
        maxDeltaCharacters: Int = defaultMaxDeltaCharacters
    ) -> Composition {
        let unseen = delta(roomMessages, seenMessageID: seenMessageID, seenCreatedAt: seenCreatedAt)
        let turnsByRow = Dictionary(
            groupTurns.map { ($0.roomMessageID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let entries = unseen.compactMap { entry(for: $0, me: me, turnsByRow: turnsByRow) }

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
                + " " + participantsAnswerOnTheirTurnsLine
        )
        sections.append(BotPeerTranscript.languageInstruction)

        let blocker = unseen.firstIndex { holdsWatermark($0, me: me, turnsByRow: turnsByRow) }
        let seenThrough = blocker.map { unseen[unseen.startIndex..<$0] } ?? unseen
        let last = seenThrough.last
        return Composition(
            prompt: sections.joined(separator: "\n\n"),
            lastSeenMessageID: last?.id,
            lastSeenCreatedAt: last?.createdAt,
            includedCount: kept.count,
            omittedCount: omitted
        )
    }

    /// A participant asked through `bot_ask_peer` starts a second, hidden
    /// run outside the room; a supervised turn then waits on an approval
    /// nobody sees. The room already gives every participant its own turn.
    static let participantsAnswerOnTheirTurnsLine =
        "The other participants answer in this group on their own turns: never use bot_ask_peer to ask them, and do not answer for them."

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
            // `>=`: the user row and the waiting rows of one send share a
            // timestamp, and the watermark can stop just before such a row.
            // Re-reading an equal-time row beats dropping it.
            return messages[(messages.firstIndex { $0.createdAt >= seenCreatedAt } ?? messages.endIndex)...]
        }
        return messages[...]
    }

    /// One room row as prompt text, or nil when it carries nothing for `me`:
    /// waiting/attention placeholders, `me`'s own replies (already in its
    /// member thread) and rows that are empty once markers are removed.
    /// User rows are quoted verbatim, even when they look like host markers.
    static func entry(
        for message: AgentMessage,
        me: BotDefinition,
        turnsByRow: [AgentMessageID: BotGroupTurn]
    ) -> String? {
        if message.role == .user {
            guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return "User:\n\(message.content)"
        }
        if BotPeerTranscript.parseActivity(message.content) != nil { return nil }
        if let reply = BotPeerTranscript.parse(message.content) {
            if isOwnRow(message, handle: reply.handle, me: me, turnsByRow: turnsByRow) { return nil }
            let body = strippingMarkers(reply.body)
            guard !body.isEmpty else { return nil }
            return "\(reply.name) (\(BotPeerTranscript.handleLabel(reply.handle))):\n\(body)"
        }
        let body = strippingMarkers(message.content)
        guard !body.isEmpty else { return nil }
        return "Group note:\n\(body)"
    }

    /// Another bot's waiting row that can still be replaced by its reply.
    static func holdsWatermark(
        _ message: AgentMessage,
        me: BotDefinition,
        turnsByRow: [AgentMessageID: BotGroupTurn]
    ) -> Bool {
        guard message.role != .user,
              let activity = BotPeerTranscript.parseActivity(message.content),
              activity.phase == .waiting,
              !isOwnRow(message, handle: activity.handle, me: me, turnsByRow: turnsByRow)
        else { return false }
        guard let turn = turnsByRow[message.id] else { return true }
        // A completed turn whose reply is not written yet still resolves.
        return !turn.state.isTerminal || turn.state == .completed
    }

    private static func isOwnRow(
        _ message: AgentMessage,
        handle: String,
        me: BotDefinition,
        turnsByRow: [AgentMessageID: BotGroupTurn]
    ) -> Bool {
        if let turn = turnsByRow[message.id] { return turn.botID == me.id }
        return BotHandle.normalize(handle) == BotHandle.normalize(me.handle)
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
