import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI

/// Shared live-turn chrome for Agent App chat composition on Bots Desk.
///
/// WHY: Desk must paint the same live turn Agent App does — user bubble →
/// Work so far (Thinking…/Thought + tools) → final markdown — from the linked
/// thread's persisted stream events. A composer Thinking pill is not enough.
public enum AgentChatLiveTurnChrome {
    public static func timelineByReplaying(_ events: [AssistantEvent]) -> AssistantTimelineState {
        var next = AssistantTimelineState()
        for event in events {
            next.apply(event, nowMs: nil)
        }
        next.enforceAggregateHotTextBudget()
        return next
    }

    public static func turnDurationLabel(_ turn: AssistantTurnSnapshot) -> String? {
        // Sum each item's own span. Min-start to max-finish counted idle
        // hours between tools as work ("Worked for 258m" on a greeting).
        guard !turn.items.isEmpty else { return nil }
        var totalMs: Int64 = 0
        for item in turn.items {
            guard let end = item.finishedAtMs, end >= item.startedAtMs else { return nil }
            totalMs += end - item.startedAtMs
        }
        let seconds = Int(totalMs / 1000)
        guard seconds > 0 else { return nil }
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }

    public static func completedWorkLabel(
        _ turn: AssistantTurnSnapshot,
        live: Bool = false,
        workBlockCount: Int = 0
    ) -> String {
        if live {
            if workBlockCount > 1 {
                return "Work so far · \(workBlockCount) steps in this turn"
            }
            return "Work so far"
        }
        if let duration = turnDurationLabel(turn) {
            return "Worked for \(duration)"
        }
        return "Worked"
    }

    public static func reasoningTitle(isStreaming: Bool) -> String {
        isStreaming ? "Thinking…" : "Thought"
    }

    public static func reasoningText(_ item: AssistantItem) -> String {
        item.body.isEmpty ? (AgentTimelineItemPresentation.make(for: item).detail ?? "") : item.body
    }

    public static func isGroupableTool(_ type: AssistantItemType) -> Bool {
        switch type {
        case .tool, .commandExecution, .mcpToolCall, .dynamicToolCall, .collabToolCall, .webSearch, .imageView, .fileChange:
            return true
        case .reasoning, .plan, .assistantMessage, .review, .contextCompaction, .error:
            return false
        }
    }

    public static func hasStreamingTools(in timeline: AssistantTimelineState) -> Bool {
        timeline.turns.contains { turn in
            !turn.finished && turn.items.contains {
                $0.state == .streaming && isGroupableTool($0.type)
            }
        }
    }

    public static func splitTurn(_ turn: AssistantTurnSnapshot) -> (work: [AssistantItem], outside: [AssistantItem]) {
        AgentTurnChatComposition.splitItems(
            turn.items,
            turnFinished: turn.finished,
            isFinalItem: { $0.type == .assistantMessage }
        )
    }

    /// Desk / Agent App live composition: Thinking…/Thought stays a visible
    /// row. Work so far owns the non-final tools. Final markdown sits outside.
    public static func compose(_ turn: AssistantTurnSnapshot) -> (
        reasoning: [AssistantItem],
        work: [AssistantItem],
        outside: [AssistantItem]
    ) {
        let split = splitTurn(turn)
        var reasoning: [AssistantItem] = []
        var work: [AssistantItem] = []
        reasoning.reserveCapacity(split.work.count)
        work.reserveCapacity(split.work.count)
        for item in split.work {
            if item.type == .reasoning {
                reasoning.append(item)
            } else {
                work.append(item)
            }
        }
        return (reasoning, work, deduplicatedAssistantItems(split.outside))
    }

    /// Claude often emits a streaming assistantMessage and then a snapshot
    /// item with the same body in one turn. Paint that answer once.
    static func deduplicatedAssistantItems(_ items: [AssistantItem]) -> [AssistantItem] {
        var result: [AssistantItem] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard item.type == .assistantMessage else {
                result.append(item)
                continue
            }
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = result.firstIndex(where: {
                $0.type == .assistantMessage && assistantTextsMatch($0.body, body)
            }) {
                let existing = result[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.count > existing.count {
                    result[index] = item
                }
                continue
            }
            result.append(item)
        }
        return result
    }

    public static func workItems(in turn: AssistantTurnSnapshot) -> [AssistantItem] {
        compose(turn).work
    }

    public static func assistantBodies(in turn: AssistantTurnSnapshot) -> [String] {
        var texts: [String] = []
        for item in turn.items where item.type == .assistantMessage {
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { texts.append(body) }
        }
        if let final = turn.finalAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !final.isEmpty {
            texts.append(final)
        }
        return texts
    }

    public static func assistantTextsMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Persisted assistant bubbles must not sit next to the same turn-owned answer.
    public static func messageDuplicatesTurn(_ text: String, turns: [AssistantTurnSnapshot]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return turns.contains { turn in
            assistantBodies(in: turn).contains { assistantTextsMatch(trimmed, $0) }
        }
    }

    /// Later turns that only repeat an earlier final must not paint that answer again.
    public static func shouldHideAssistantOutput(
        _ turn: AssistantTurnSnapshot,
        previousTurns: [AssistantTurnSnapshot]
    ) -> Bool {
        let bodies = assistantBodies(in: turn)
        guard !bodies.isEmpty else { return false }
        return bodies.contains { body in
            previousTurns.contains { assistantBodies(in: $0).contains { assistantTextsMatch(body, $0) } }
        }
    }

    public static func paintsLiveTurnChrome(_ timeline: AssistantTimelineState) -> Bool {
        timeline.turns.contains {
            let composition = compose($0)
            return !composition.reasoning.isEmpty || !composition.work.isEmpty
        }
    }

    /// Keep a live in-memory apply when SQLite replay is still catching up.
    public static func isRicher(_ lhs: AssistantTimelineState, than rhs: AssistantTimelineState) -> Bool {
        let lhsFinished = lhs.turns.filter(\.finished).count
        let rhsFinished = rhs.turns.filter(\.finished).count
        if rhsFinished > lhsFinished { return false }
        let lhsItems = lhs.turns.flatMap(\.items)
        let rhsItems = rhs.turns.flatMap(\.items)
        if lhsItems.count != rhsItems.count { return lhsItems.count > rhsItems.count }
        return liveTextWeight(lhsItems) > liveTextWeight(rhsItems)
    }

    private static func liveTextWeight(_ items: [AssistantItem]) -> Int {
        items.reduce(0) { $0 + $1.body.utf8.count + ($1.output?.utf8.count ?? 0) }
    }

    public static func shouldRenderFinalMessage(_ turn: AssistantTurnSnapshot) -> Bool {
        guard turn.finished else { return false }
        let final = turn.finalAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !final.isEmpty else { return false }
        return !turn.items.contains {
            $0.type == .assistantMessage && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    public static func turnSortDate(_ turn: AssistantTurnSnapshot) -> Date {
        // Replay applies turnStarted with Date(), which dumps every historical
        // Worked block at "now". Item timestamps survive persist and keep
        // user → work → answer in conversation order.
        if let ms = turn.items.map(\.startedAtMs).min(), ms > 0 {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        if let ms = turn.startedAtMs {
            return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        }
        return Date.distantPast
    }

    public static func workBlocks(from items: [AssistantItem], groupThreshold: Int = 2) -> [AgentChatWorkBlock] {
        var blocks: [AgentChatWorkBlock] = []
        var run: [AssistantItem] = []
        func flushRun() {
            guard !run.isEmpty else { return }
            if run.count >= groupThreshold,
               !AgentTimelineItemPresentation.mustKeepToolsUngrouped(run) {
                blocks.append(.toolGroup(id: run[0].id, items: run))
            } else {
                blocks.append(contentsOf: run.map { .item($0) })
            }
            run.removeAll(keepingCapacity: true)
        }
        for item in items {
            if isGroupableTool(item.type) {
                run.append(item)
            } else {
                flushRun()
                blocks.append(.item(item))
            }
        }
        flushRun()
        return blocks
    }

    public static func toolGroupSummary(_ items: [AssistantItem]) -> String {
        let noun: String = {
            let plural = items.count != 1
            switch Set(items.map(\.type)) {
            case [.fileChange]: return plural ? "files" : "file"
            case [.webSearch]: return plural ? "searches" : "search"
            case [.imageView]: return plural ? "images" : "image"
            default: return plural ? "commands" : "command"
            }
        }()
        if items.contains(where: { AgentTimelineItemPresentation.showsLiveToolElapsed(for: $0)
            && AgentTimelineItemPresentation.isTaskWaitTool(for: $0) }) {
            return "Waiting \(items.count) \(noun)…"
        }
        if items.contains(where: { $0.state == .streaming }) {
            return "Running \(items.count) \(noun)…"
        }
        let verbs = Set(items.map { AgentTimelineItemPresentation.make(for: $0).verb })
        let verb = verbs.count == 1 ? (verbs.first ?? "Ran") : "Ran"
        return "\(verb) \(items.count) \(noun)"
    }
}

public enum AgentChatWorkBlock: Identifiable, Equatable, Sendable {
    case item(AssistantItem)
    case toolGroup(id: String, items: [AssistantItem])

    public var id: String {
        switch self {
        case .item(let item): return "block-item-\(item.id)"
        case .toolGroup(let id, _): return "block-group-\(id)"
        }
    }
}

// MARK: - Reasoning

public struct AgentChatReasoningRow: View {
    public let item: AssistantItem
    @Binding public var expandedIDs: Set<String>

    public init(item: AssistantItem, expandedIDs: Binding<Set<String>>) {
        self.item = item
        self._expandedIDs = expandedIDs
    }

    public var body: some View {
        let text = AgentChatLiveTurnChrome.reasoningText(item)
        let streaming = item.state == .streaming
        let expanded = streaming || expandedIDs.contains(item.id)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard !streaming, !text.isEmpty else { return }
                if expanded { expandedIDs.remove(item.id) } else { expandedIDs.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    if !streaming, !text.isEmpty {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: streaming))
                        .font(DS.Font.caption2.weight(.semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(streaming ? "" : (text.isEmpty ? "" : (expanded ? "Hide reasoning" : "Show reasoning")))
            if expanded, !text.isEmpty {
                Text(text)
                    .font(DS.Font.bodyDense)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.reasoning.\(item.id)")
    }
}

// MARK: - Tool rows

public struct AgentChatLiveToolRow: View {
    public let item: AssistantItem
    @Binding public var expandedIDs: Set<String>

    public init(item: AssistantItem, expandedIDs: Binding<Set<String>>) {
        self.item = item
        self._expandedIDs = expandedIDs
    }

    public var body: some View {
        if let editModel = AgentFileEditDiffPresentation.model(for: item),
           editModel.hasRenderableCode || item.type == .fileChange {
            AgentFileEditDiffCard(
                model: editModel,
                initiallyExpanded: AgentWorkDisclosureLayout.diffDefaultExpanded
            )
        } else {
            standardBody
        }
    }

    private var standardBody: some View {
        let presentation = AgentTimelineItemPresentation.make(for: item)
        let displayLabel = AgentTimelineItemPresentation.toolDisplayLabel(for: item)
        let commandFull = AgentTimelineItemPresentation.rawShellCommand(for: item)
            ?? AgentTimelineItemPresentation.toolCommandPreview(for: item)
        let commandSummary = AgentTimelineItemPresentation.toolCommandSummary(for: item)
        let isBackground = AgentTimelineItemPresentation.isBackgroundTool(for: item)
        let output = presentation.detail
        let hasOutput = (output?.isEmpty == false)
        let activityHint = AgentTimelineItemPresentation.toolActivityHint(for: item, hasOutput: hasOutput)
        let fullDiffersFromSummary = (commandFull != nil && commandFull != commandSummary)
        let canExpand = hasOutput
            || fullDiffersFromSummary
            || (commandFull.map { $0.count > 96 || $0.contains("\n") } ?? false)
            || AgentTimelineItemPresentation.toolCanExpandWithoutOutput(for: item)
        let expanded = expandedIDs.contains(item.id)
        let statusColor: Color = {
            switch item.state {
            case .streaming: return DS.Palette.accent
            case .failed: return DS.Palette.danger
            case .cancelled: return DS.Palette.textTertiary
            case .completed: return DS.Palette.textSecondary
            }
        }()
        return VStack(alignment: .leading, spacing: DS.Space.xs) {
            Button {
                guard canExpand else { return }
                if expanded { expandedIDs.remove(item.id) } else { expandedIDs.insert(item.id) }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: presentation.icon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(statusColor)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    (Text("\(presentation.verb) ")
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                     + Text(displayLabel)
                        .font(DS.Font.bodyStrong).foregroundColor(DS.Palette.text))
                    .lineLimit(1).truncationMode(.tail)
                    if isBackground {
                        Text("Background")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(DS.Palette.accent.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer(minLength: 0)
                    if item.state == .streaming {
                        Text(AgentTimelineItemPresentation.toolStreamingStatusLabel(for: item))
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.accent)
                    } else if item.state == .failed {
                        Text("Failed")
                            .font(DS.Font.caption2.weight(.semibold))
                            .foregroundColor(DS.Palette.danger)
                    }
                    if canExpand {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8)).foregroundColor(DS.Palette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AgentTimelineItemPresentation.toolAccessibilityLabel(for: item))

            if let summary = commandSummary, !summary.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.xs) {
                    Text(summary)
                        .font(DS.Font.monoSmall).foregroundColor(DS.Palette.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let full = commandFull, !full.isEmpty {
                        Button {
                            AgentChatTranscriptChrome.copyToPasteboard(full)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundColor(DS.Palette.textTertiary)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy full command")
                        .accessibilityIdentifier("agent.tool.copyCommand.\(item.id)")
                    }
                }
                .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let activityHint {
                HStack(alignment: .center, spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityHidden(true)
                    Text(activityHint)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.accent.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityIdentifier("agent.tool.activityHint.\(item.id)")
            }

            if expanded, let full = commandFull, fullDiffersFromSummary, !full.isEmpty {
                Text(full)
                    .font(DS.Font.monoSmall)
                    .foregroundColor(DS.Palette.textTertiary)
                    .textSelection(.enabled)
                    .padding(.horizontal, DS.Space.sm).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .accessibilityIdentifier("agent.tool.fullCommand.\(item.id)")
            }

            if expanded, let o = output, !o.isEmpty {
                Text(AgentTimelineItemPresentation.cappedDetail(o, for: item))
                    .font(DS.Font.mono).foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
                    .padding(DS.Space.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.tool.row.\(item.id)")
    }
}

public struct AgentChatToolGroupRow: View {
    public let id: String
    public let items: [AssistantItem]
    @Binding public var expandedGroupIDs: Set<String>
    @Binding public var expandedToolIDs: Set<String>

    public init(
        id: String,
        items: [AssistantItem],
        expandedGroupIDs: Binding<Set<String>>,
        expandedToolIDs: Binding<Set<String>>
    ) {
        self.id = id
        self.items = items
        self._expandedGroupIDs = expandedGroupIDs
        self._expandedToolIDs = expandedToolIDs
    }

    public var body: some View {
        let streaming = items.contains { $0.state == .streaming }
        let failed = items.contains { $0.state == .failed }
        let expanded = expandedGroupIDs.contains(id)
        let headerIcon = streaming
            ? "circle.dotted"
            : (failed ? "exclamationmark.triangle" : "terminal")
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    if expanded { expandedGroupIDs.remove(id) } else { expandedGroupIDs.insert(id) }
                }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                        .frame(width: 10)
                    Image(systemName: headerIcon)
                        .font(.system(size: 11))
                        .foregroundColor(failed ? DS.Palette.danger : DS.Palette.textSecondary)
                    Text(AgentChatLiveTurnChrome.toolGroupSummary(items))
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !expanded {
                        Text("\(items.count)")
                            .font(DS.Font.caption2.weight(.semibold).monospacedDigit())
                            .foregroundColor(DS.Palette.textTertiary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(DS.Palette.surface)
                            .clipShape(Capsule())
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    ForEach(items) { item in
                        AgentChatLiveToolRow(item: item, expandedIDs: $expandedToolIDs)
                    }
                }
                .padding(.leading, DS.Space.md)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("agent.toolGroup.\(id)")
    }
}

// MARK: - Work so far

public struct AgentChatWorkSoFarDisclosure: View {
    public let turn: AssistantTurnSnapshot
    public let live: Bool
    public let blocks: [AgentChatWorkBlock]
    public let workBlockCount: Int
    public let isExpanded: Bool
    public let onToggle: () -> Void
    @Binding public var expandedReasoning: Set<String>
    @Binding public var expandedTools: Set<String>
    @Binding public var expandedToolGroups: Set<String>

    public init(
        turn: AssistantTurnSnapshot,
        live: Bool,
        blocks: [AgentChatWorkBlock],
        workBlockCount: Int,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        expandedReasoning: Binding<Set<String>>,
        expandedTools: Binding<Set<String>>,
        expandedToolGroups: Binding<Set<String>>
    ) {
        self.turn = turn
        self.live = live
        self.blocks = blocks
        self.workBlockCount = workBlockCount
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self._expandedReasoning = expandedReasoning
        self._expandedTools = expandedTools
        self._expandedToolGroups = expandedToolGroups
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { onToggle() }
            } label: {
                HStack(spacing: DS.Space.sm) {
                    if live {
                        Image(systemName: "circle.dotted")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                    }
                    Text(AgentChatLiveTurnChrome.completedWorkLabel(
                        turn,
                        live: live,
                        workBlockCount: workBlockCount
                    ))
                    .font(DS.Font.body.weight(.medium))
                    .foregroundColor(DS.Palette.textTertiary)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide work details" : "Show work details")
            .accessibilityLabel(isExpanded ? "Hide work details" : "Show work details")
            .accessibilityIdentifier(live ? "agent.liveWork.\(turn.turnId)" : "agent.completedWork.\(turn.turnId)")

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Space.lg) {
                    ForEach(blocks) { block in
                        AgentChatWorkBlockView(
                            block: block,
                            expandedReasoning: $expandedReasoning,
                            expandedTools: $expandedTools,
                            expandedToolGroups: $expandedToolGroups
                        )
                    }
                }
                .padding(.leading, DS.Space.md)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("agent.work.lazyList.\(turn.turnId)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct AgentChatWorkBlockView: View {
    public let block: AgentChatWorkBlock
    @Binding public var expandedReasoning: Set<String>
    @Binding public var expandedTools: Set<String>
    @Binding public var expandedToolGroups: Set<String>

    public var body: some View {
        switch block {
        case .item(let item):
            AgentChatLiveItemRow(
                item: item,
                expandedReasoning: $expandedReasoning,
                expandedTools: $expandedTools
            )
        case .toolGroup(let id, let items):
            AgentChatToolGroupRow(
                id: id,
                items: items,
                expandedGroupIDs: $expandedToolGroups,
                expandedToolIDs: $expandedTools
            )
        }
    }
}

public struct AgentChatLiveItemRow: View {
    public let item: AssistantItem
    @Binding public var expandedReasoning: Set<String>
    @Binding public var expandedTools: Set<String>

    public var body: some View {
        switch item.type {
        case .reasoning:
            AgentChatReasoningRow(item: item, expandedIDs: $expandedReasoning)
        case .assistantMessage:
            if !item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AgentChatAssistantReply(text: item.body)
            }
        case .plan:
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("PLAN").font(DS.Font.caption2.weight(.semibold)).tracking(0.6)
                    .foregroundColor(DS.Palette.accent)
                AgentMessageMarkdownView(text: item.body)
                    .foregroundColor(DS.Palette.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .tool, .commandExecution, .fileChange, .mcpToolCall, .dynamicToolCall,
                .collabToolCall, .webSearch, .review, .contextCompaction, .error, .imageView:
            AgentChatLiveToolRow(item: item, expandedIDs: $expandedTools)
        }
    }
}

// MARK: - Turn

public struct AgentChatLiveTurnView: View {
    public let turn: AssistantTurnSnapshot
    public let live: Bool
    public let hideAssistantOutput: Bool
    public var renderFinal: ((String) -> AnyView)?
    public var afterWork: AnyView?

    @State private var userExpanded: Set<String> = []
    @State private var userCollapsedLive: Set<String> = []
    @State private var expandedReasoning: Set<String> = []
    @State private var expandedTools: Set<String> = []
    @State private var expandedToolGroups: Set<String> = []

    public init(
        turn: AssistantTurnSnapshot,
        live: Bool,
        hideAssistantOutput: Bool = false,
        renderFinal: ((String) -> AnyView)? = nil,
        afterWork: AnyView? = nil
    ) {
        self.turn = turn
        self.live = live
        self.hideAssistantOutput = hideAssistantOutput
        self.renderFinal = renderFinal
        self.afterWork = afterWork
    }

    public var body: some View {
        let composition = AgentChatLiveTurnChrome.compose(turn)
        let blocks = AgentChatLiveTurnChrome.workBlocks(from: composition.work)
        let expanded = AgentCompletedWorkExpandPolicy.isExpanded(
            isLive: live,
            isLatestLiveTurn: live,
            userExplicitlyExpanded: userExpanded.contains(turn.turnId),
            userCollapsedWhileLive: userCollapsedLive.contains(turn.turnId)
        )
        VStack(alignment: .leading, spacing: DS.Space.xl) {
            if !composition.reasoning.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.md) {
                    ForEach(composition.reasoning) { item in
                        AgentChatReasoningRow(item: item, expandedIDs: $expandedReasoning)
                    }
                }
                .accessibilityIdentifier("bots.desk.thought")
            }
            if !composition.work.isEmpty {
                AgentChatWorkSoFarDisclosure(
                    turn: turn,
                    live: live,
                    blocks: AgentCompletedWorkPresentation.shouldBuildBlocks(
                        expandCompletedWork: expanded,
                        workItemCount: blocks.count
                    ) ? blocks : [],
                    workBlockCount: blocks.count,
                    isExpanded: expanded,
                    onToggle: toggleWork,
                    expandedReasoning: $expandedReasoning,
                    expandedTools: $expandedTools,
                    expandedToolGroups: $expandedToolGroups
                )
            }
            if let afterWork {
                afterWork
            }
            if !hideAssistantOutput {
                ForEach(composition.outside) { item in
                    AgentChatLiveItemRow(
                        item: item,
                        expandedReasoning: $expandedReasoning,
                        expandedTools: $expandedTools
                    )
                }
                if AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn),
                   let final = turn.finalAssistantMessage {
                    if let renderFinal {
                        renderFinal(final)
                    } else {
                        AgentChatAssistantReply(text: final)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.desk.liveTurn.\(turn.turnId)")
        .onChange(of: turn.finished) { _, finished in
            if finished {
                let cleared = AgentCompletedWorkExpandPolicy.clearedExpansionState()
                userExpanded = cleared.expanded
                userCollapsedLive = cleared.collapsedLive
            }
        }
    }

    private func toggleWork() {
        let currently = AgentCompletedWorkExpandPolicy.isExpanded(
            isLive: live,
            isLatestLiveTurn: live,
            userExplicitlyExpanded: userExpanded.contains(turn.turnId),
            userCollapsedWhileLive: userCollapsedLive.contains(turn.turnId)
        )
        let next = AgentCompletedWorkExpandPolicy.toggle(
            turnId: turn.turnId,
            currentlyExpanded: currently,
            isLive: live,
            isLatestLiveTurn: live,
            userExpanded: userExpanded,
            userCollapsedLive: userCollapsedLive
        )
        userExpanded = next.expanded
        userCollapsedLive = next.collapsedLive
    }
}

// MARK: - Working status

/// Window between the user bubble and a real run — same as Agent App Loading….
public struct AgentChatLoadingStatusStrip: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading")
                Text("Loading…")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .accessibilityIdentifier("agent.loading.status")
            }
            Rectangle()
                .fill(DS.Palette.line)
                .frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("bots.desk.loading")
    }
}

public struct AgentChatWorkingStatusStrip: View {
    public let startedAt: Date
    public let isStopping: Bool
    public let onStop: () -> Void

    public init(startedAt: Date, isStopping: Bool, onStop: @escaping () -> Void) {
        self.startedAt = startedAt
        self.isStopping = isStopping
        self.onStop = onStop
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            TimelineView(AgentChatElapsedTickSchedule(start: startedAt)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                let seed = UInt64(max(0, startedAt.timeIntervalSince1970 * 1000))
                HStack(spacing: DS.Space.sm) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Running")
                    Text(AgentWorkingCatCopy.statusLabel(elapsedSeconds: seconds, seed: seed))
                        .font(DS.Font.body).foregroundColor(DS.Palette.textSecondary)
                        .accessibilityLabel(AgentWorkingCatCopy.accessibilityLabel(elapsedSeconds: seconds))
                        .accessibilityIdentifier("agent.workingStatus")
                    Button(isStopping ? "Stopping… (click to force)" : "Stop", action: onStop)
                        .buttonStyle(.plain)
                        .font(DS.Font.body.weight(.medium))
                        .foregroundColor(DS.Palette.danger)
                        .help(isStopping
                              ? "Still stopping — click again to force-stop the provider"
                              : "Stop running agent (press Esc to interrupt)")
                        .accessibilityIdentifier("agent.working.stop")
                }
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 1s cadence for the first minute, 5s after — same as Agent App workingStatus.
struct AgentChatElapsedTickSchedule: TimelineSchedule {
    let start: Date

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        var next = startDate
        return AnyIterator {
            let current = next
            let elapsed = current.timeIntervalSince(start)
            let step: TimeInterval = elapsed < 60 ? 1 : 5
            next = current.addingTimeInterval(step)
            return current
        }
    }
}
