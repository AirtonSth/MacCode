import Foundation
import CoreModel
import Surfaces

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
    ///
    /// When the linked thread has live-turn chrome (Thinking / Work so far),
    /// hide the generic Supervised-run card and the Working… placeholder so
    /// Desk matches Agent App: user → work disclosure → final markdown.
    static func timeline(
        messages: [BotDeskMessage],
        workLog: [BotDeskWorkLogRow],
        turns: [AssistantTurnSnapshot] = [],
        hideWorkLog: Bool = false,
        hideWorkingPlaceholder: Bool = false
    ) -> [BotDeskTimelineItem] {
        let visibleMessages = messages.filter { message in
            guard message.role == .assistant else { return true }
            if hideWorkingPlaceholder, message.text == workingPlaceholder { return false }
            if AgentChatLiveTurnChrome.messageDuplicatesTurn(message.text, turns: turns) {
                return false
            }
            return true
        }
        let logs = hideWorkLog ? [] : workLog
        let visibleTurns = turns.filter { turn in
            let composition = AgentChatLiveTurnChrome.compose(turn)
            return !composition.reasoning.isEmpty
                || !composition.work.isEmpty
                || AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn)
                || turn.items.contains {
                    $0.type == .assistantMessage
                        && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
        }
        var previousTurns: [AssistantTurnSnapshot] = []
        previousTurns.reserveCapacity(visibleTurns.count)
        let liveItems: [BotDeskTimelineItem] = visibleTurns
            .sorted { AgentChatLiveTurnChrome.turnSortDate($0) < AgentChatLiveTurnChrome.turnSortDate($1) }
            .map { turn in
                let hide = AgentChatLiveTurnChrome.shouldHideAssistantOutput(
                    turn,
                    previousTurns: previousTurns
                )
                previousTurns.append(turn)
                return .liveTurn(turn, hideAssistantOutput: hide)
            }
        return composeConversationOrder(
            messages: visibleMessages,
            workLog: logs,
            liveTurns: liveItems
        )
    }

    /// User bubble, then that turn's work, then the answer — never a pile of
    /// user bubbles followed by every Worked row at the bottom.
    static func composeConversationOrder(
        messages: [BotDeskMessage],
        workLog: [BotDeskWorkLogRow],
        liveTurns: [BotDeskTimelineItem]
    ) -> [BotDeskTimelineItem] {
        let users = messages.filter { $0.role == .user }.sorted { $0.createdAt < $1.createdAt }
        let assistants = messages.filter { $0.role != .user }.sorted { $0.createdAt < $1.createdAt }
        let logs = workLog.sorted { $0.createdAt < $1.createdAt }
        let turns = liveTurns.sorted { $0.createdAt < $1.createdAt }
        if users.isEmpty {
            return (assistants.map(BotDeskTimelineItem.message)
                + logs.map(BotDeskTimelineItem.workLog)
                + turns)
                .sorted { lhs, rhs in
                    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                    return lhs.stableOrder < rhs.stableOrder
                }
        }
        var result: [BotDeskTimelineItem] = []
        var turnIndex = 0
        var assistantIndex = 0
        var logIndex = 0
        func appendDue(before limit: Date) {
            while true {
                var next: BotDeskTimelineItem?
                if turnIndex < turns.count, turns[turnIndex].createdAt < limit {
                    next = turns[turnIndex]
                }
                if assistantIndex < assistants.count, assistants[assistantIndex].createdAt < limit {
                    let item = BotDeskTimelineItem.message(assistants[assistantIndex])
                    if next == nil || item.createdAt < next!.createdAt
                        || (item.createdAt == next!.createdAt && item.stableOrder < next!.stableOrder) {
                        next = item
                    }
                }
                if logIndex < logs.count, logs[logIndex].createdAt < limit {
                    let item = BotDeskTimelineItem.workLog(logs[logIndex])
                    if next == nil || item.createdAt < next!.createdAt
                        || (item.createdAt == next!.createdAt && item.stableOrder < next!.stableOrder) {
                        next = item
                    }
                }
                guard let item = next else { return }
                result.append(item)
                switch item {
                case .liveTurn: turnIndex += 1
                case .message: assistantIndex += 1
                case .workLog: logIndex += 1
                }
            }
        }
        for (index, user) in users.enumerated() {
            appendDue(before: user.createdAt)
            result.append(.message(user))
            let nextUserDate = index + 1 < users.count ? users[index + 1].createdAt : Date.distantFuture
            appendDue(before: nextUserDate)
        }
        appendDue(before: Date.distantFuture)
        return result
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
        skills: [BotSkillBinding] = [],
        routines: [BotRoutine] = [],
        workspace: BotWorkspaceHonesty? = nil,
        browser: BotBrowserTarget? = nil
    ) -> String {
        BotBrainCompiler.composeRunPrompt(
            bot: bot,
            revision: revision,
            userText: userText,
            memory: memory,
            skills: skills,
            routines: routines,
            workspace: workspace,
            browser: browser
        )
    }
}
