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

    /// A completed turn on the open Desk is already being read — do not badge it Unread.
    static func conversationState(for status: AgentRunStatus, viewingDesk: Bool) -> BotAttentionState {
        let state = conversationState(for: status)
        if viewingDesk && state == .unreadActivity { return .none }
        return state
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

    static func workLogRows(for run: AgentRun?) -> [BotDeskWorkLogRow] {
        guard let run else { return [] }
        return [workLogRow(for: run)]
    }

    static func workLogRow(for run: AgentRun) -> BotDeskWorkLogRow {
        BotDeskWorkLogRow(
            id: run.id.value,
            title: "Supervised run",
            detail: workLogDetail(provider: run.provider, model: run.model),
            statusLabel: workLogStatusLabel(for: run.status),
            createdAt: run.finishedAt ?? run.startedAt,
            runID: run.id
        )
    }

    static func workLogDetail(provider: AgentProvider, model: String) -> String {
        let route: String
        switch provider {
        case .claude: route = "Claude"
        case .codex: route = "Codex"
        case .grok: route = "Grok"
        }
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return route }
        return "\(route) · \(trimmed)"
    }

    static func workLogStatusLabel(for status: AgentRunStatus) -> String {
        switch status {
        case .pending, .running:
            return "Working"
        case .completed:
            return "Done"
        case .failed, .interrupted:
            return "Needs you"
        case .cancelled:
            return "Cancelled"
        }
    }

    /// Messages stay the conversation; a work-log row appears only when a
    /// linked Agent run exists. Same-timestamp work-log sits between You and
    /// the assistant so it reads as the turn's activity, not a fake Desktop.
    static func timeline(
        messages: [BotDeskMessage],
        workLog: [BotDeskWorkLogRow]
    ) -> [BotDeskTimelineItem] {
        let items = messages.map(BotDeskTimelineItem.message) + workLog.map(BotDeskTimelineItem.workLog)
        return items.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.stableOrder < rhs.stableOrder
        }
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
