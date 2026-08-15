import Foundation
import CoreModel

/// Maps a linked Agent run onto Bot Desk / Attention so a teammate turn
/// does not stay stuck on "Working…".
enum BotsDeskFollowThrough {
    static func conversationState(for status: AgentRunStatus) -> BotAttentionState {
        switch status {
        case .pending, .running:
            return .working
        case .completed:
            return .unreadActivity
        case .failed, .cancelled, .interrupted:
            return .needsAttention
        }
    }

    static func attentionKind(for status: AgentRunStatus) -> BotAttentionItemKind? {
        switch status {
        case .pending, .running, .completed:
            return nil
        case .failed, .interrupted:
            return .blocked
        case .cancelled:
            return .question
        }
    }

    static let workingPlaceholder = "Working…"
    static let noRouterPlaceholder =
        "Supervised run starts from this conversation; provider turn is the next slice"

    static func visibleDeskMessages(
        cached: [BotDeskMessage],
        persisted: [BotDeskMessage]
    ) -> [BotDeskMessage] {
        let persistedHasResult = persisted.contains { message in
            message.role == .assistant &&
            message.text != workingPlaceholder &&
            message.text != noRouterPlaceholder
        }
        if persistedHasResult { return persisted }
        if persisted.isEmpty { return cached }
        return persisted
    }

    /// Persist stores the provider envelope; the desk must show the teammate line.
    static func displayUserText(from persisted: String) -> String {
        let marker = "User request:"
        guard let range = persisted.range(of: marker) else { return persisted }
        return persisted[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isTerminal(_ status: AgentRunStatus) -> Bool {
        switch status {
        case .completed, .failed, .cancelled, .interrupted:
            return true
        case .pending, .running:
            return false
        }
    }

    static func composeRunPrompt(
        bot: BotDefinition,
        revision: BotRevision,
        userText: String,
        memory: [BotMemoryItem] = [],
        skills: [BotSkillBinding] = []
    ) -> String {
        var lines: [String] = []
        let job = [bot.name, revision.title].filter { !$0.isEmpty }.joined(separator: " — ")
        if !job.isEmpty {
            lines.append("You are \(job).")
        }
        let description = revision.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            lines.append(description)
        }
        let soul = revision.soul.trimmingCharacters(in: .whitespacesAndNewlines)
        if !soul.isEmpty {
            lines.append("Standing instructions:")
            lines.append(soul)
        }
        let liveMemory = memory.filter { $0.forgottenAt == nil && $0.trusted }
        if !liveMemory.isEmpty {
            lines.append("Trusted memory:")
            lines.append(contentsOf: liveMemory.map { "- \($0.content)" })
        }
        let enabled = skills.filter(\.enabled).map(\.skillID).sorted()
        if !enabled.isEmpty {
            lines.append("Enabled skills: \(enabled.joined(separator: ", "))")
        }
        lines.append("User request:")
        lines.append(userText)
        return lines.joined(separator: "\n\n")
    }
}
