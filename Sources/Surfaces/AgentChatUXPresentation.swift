import Foundation
import CoreModel

// MARK: - System status strip (severity-ordered, capped)

/// Severity for the unified system strip above the composer.
/// Higher raw value wins when collapsing overflow.
public enum AgentSystemStripSeverity: Int, Sendable, Comparable, Equatable {
    case info = 0
    case warning = 1
    case error = 2

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One dismissible/actionable status row candidate before collapse.
public struct AgentSystemStripItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: AgentSystemStripSeverity
    public let message: String
    public let offersCopy: Bool
    public let offersRetry: Bool
    public let offersDismiss: Bool

    public init(
        id: String,
        severity: AgentSystemStripSeverity,
        message: String,
        offersCopy: Bool = true,
        offersRetry: Bool = false,
        offersDismiss: Bool = true
    ) {
        self.id = id
        self.severity = severity
        self.message = message
        self.offersCopy = offersCopy
        self.offersRetry = offersRetry
        self.offersDismiss = offersDismiss
    }
}

/// Pure collapse for stacked banners → single strip.
/// WHY: stacked history/status/snapshot/queue banners compete for attention and
/// re-layout the composer; collapse keeps errors first and caps visible rows.
public enum AgentSystemStripPresentation {
    public static let defaultMaxVisible = 2

    public static func collapse(
        _ items: [AgentSystemStripItem],
        maxVisible: Int = defaultMaxVisible
    ) -> (visible: [AgentSystemStripItem], overflowCount: Int) {
        let cleaned = items.filter {
            !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // Stable sort: severity desc, then original order.
        let ranked = cleaned.enumerated().sorted { a, b in
            if a.element.severity != b.element.severity {
                return a.element.severity > b.element.severity
            }
            return a.offset < b.offset
        }.map(\.element)
        let cap = max(1, maxVisible)
        if ranked.count <= cap {
            return (ranked, 0)
        }
        return (Array(ranked.prefix(cap)), ranked.count - cap)
    }

    /// Build candidates from the classic Agent column banner sources.
    public static func items(
        historyReplayNotice: String?,
        statusMessage: String?,
        providerSnapshotStatus: String?,
        standaloneQueueStatus: String?
    ) -> [AgentSystemStripItem] {
        var out: [AgentSystemStripItem] = []
        if let message = normalized(historyReplayNotice) {
            out.append(AgentSystemStripItem(
                id: "agent.history.replay.notice",
                severity: .info,
                message: message,
                offersCopy: false,
                offersRetry: false
            ))
        }
        if let message = normalized(statusMessage) {
            let isFailure = message.localizedCaseInsensitiveContains("fail")
                || message.localizedCaseInsensitiveContains("error")
            out.append(AgentSystemStripItem(
                id: "agent.status.message",
                severity: isFailure ? .error : .warning,
                message: message,
                offersCopy: true,
                offersRetry: false
            ))
        }
        if let message = normalized(providerSnapshotStatus) {
            out.append(AgentSystemStripItem(
                id: "agent.provider.snapshot.stale",
                severity: .warning,
                message: message,
                offersCopy: true,
                offersRetry: true
            ))
        }
        if let message = normalized(standaloneQueueStatus) {
            let isFailure = message.localizedCaseInsensitiveContains("fail")
            out.append(AgentSystemStripItem(
                id: "agent.queue.status",
                severity: isFailure ? .error : .warning,
                message: message,
                offersCopy: true,
                offersRetry: true
            ))
        }
        return out
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Working phase strip

public enum AgentWorkingPhase: Sendable, Equatable {
    case idle
    case thinking
    case tools
    case awaitingBackground
    case subagents(Int)

    public var accessibilityLabel: String {
        switch self {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .tools: return "Running tools"
        case .awaitingBackground: return "Awaiting background work"
        case .subagents(let n): return n == 1 ? "1 subagent active" : "\(n) subagents active"
        }
    }
}

/// Pure working-phase resolution for the unified header strip.
/// WHY: separate status/awaiting/shells/subagent pills duplicate signal; one phase
/// + optional elapsed is enough for run awareness without chrome noise.
public enum AgentWorkingStripPresentation {
    public static func phase(
        runIsLive: Bool,
        isAwaitingBackground: Bool,
        backgroundShellCount: Int,
        activeSubagentCount: Int,
        hasStreamingTools: Bool
    ) -> AgentWorkingPhase {
        if isAwaitingBackground || backgroundShellCount > 0 {
            return .awaitingBackground
        }
        if activeSubagentCount > 0 {
            return .subagents(activeSubagentCount)
        }
        if runIsLive {
            return hasStreamingTools ? .tools : .thinking
        }
        return .idle
    }

    public static func label(
        phase: AgentWorkingPhase,
        elapsedSeconds: Int?
    ) -> String? {
        let base: String
        switch phase {
        case .idle:
            return nil
        case .thinking:
            base = "Thinking"
        case .tools:
            base = "Tools"
        case .awaitingBackground:
            base = "Awaiting"
        case .subagents(let n):
            base = n == 1 ? "1 subagent" : "\(n) subagents"
        }
        guard let elapsedSeconds, elapsedSeconds > 0 else { return base }
        return "\(base) · \(formatElapsed(elapsedSeconds))"
    }

    public static func formatElapsed(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return r == 0 ? "\(m)m" : "\(m)m \(r)s" }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h)h" : "\(h)h \(rm)m"
    }
}

// MARK: - Composer chrome Simple / Power

public enum AgentComposerChromeMode: String, Sendable, Equatable, CaseIterable {
    case simple
    case power

    public mutating func toggle() {
        self = self == .simple ? .power : .simple
    }
}

public enum AgentComposerChromeControl: String, Sendable, Equatable, CaseIterable {
    case attach
    case model
    case sendStop
    case source
    case permission
    case execution
    case runAsUser
    case effort
}

/// Pure control visibility for composer Simple vs Power chrome.
/// WHY: default power users still need attach/model/send; advanced identity and
/// safety controls stay one gesture away to reduce footer density.
public enum AgentComposerChromePresentation {
    public static func controls(for mode: AgentComposerChromeMode) -> Set<AgentComposerChromeControl> {
        switch mode {
        case .simple:
            return [.attach, .model, .sendStop]
        case .power:
            return Set(AgentComposerChromeControl.allCases)
        }
    }

    public static func shows(_ control: AgentComposerChromeControl, mode: AgentComposerChromeMode) -> Bool {
        controls(for: mode).contains(control)
    }

    public static let toggleAccessibilityLabelSimple = "Show advanced composer controls"
    public static let toggleAccessibilityLabelPower = "Hide advanced composer controls"
}

// MARK: - Completed work density (perf)

/// Pure gate: whether finished-turn work blocks must be fully built.
/// WHY: stream ticks must not allocate tool groups when the disclosure is collapsed.
public enum AgentCompletedWorkPresentation {
    public static func shouldBuildBlocks(expandCompletedWork: Bool, workItemCount: Int) -> Bool {
        expandCompletedWork && workItemCount > 0
    }

    public static func collapsedLabel(workBlockCount: Int, durationText: String?) -> String {
        if let durationText, !durationText.isEmpty {
            return "Worked for \(durationText)"
        }
        if workBlockCount <= 0 { return "Worked" }
        return workBlockCount == 1 ? "Worked · 1 step" : "Worked · \(workBlockCount) steps"
    }
}

// MARK: - Thread rail row copy

/// Pure thread-row subtitle + monogram for denser rail scanning.
public enum AgentThreadRailRowCopy {
    public static func monogram(for provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "X"
        case .claude: return "C"
        case .grok: return "G"
        }
    }

    public static func subtitle(
        provider: AgentProvider,
        model: String,
        updatedAt: Date,
        now: Date = Date()
    ) -> String {
        let modelPart = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = relativeTime(from: updatedAt, now: now)
        if modelPart.isEmpty {
            return "\(provider.rawValue) · \(time)"
        }
        return "\(provider.rawValue) · \(shortModel(modelPart)) · \(time)"
    }

    public static func shortModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 28 { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    public static func relativeTime(from date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 45 { return "now" }
        if seconds < 3600 { return "\(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "\(max(1, seconds / 3600))h" }
        if seconds < 86_400 * 7 { return "\(max(1, seconds / 86_400))d" }
        return "\(max(1, seconds / (86_400 * 7)))w"
    }
}

// MARK: - Empty starters (shared copy)

public struct AgentEmptyConversationStarter: Sendable, Equatable, Identifiable {
    public var id: String { title }
    public let icon: String
    public let title: String
    public let prompt: String

    public init(icon: String, title: String, prompt: String) {
        self.icon = icon
        self.title = title
        self.prompt = prompt
    }
}

public enum AgentEmptyConversationStarters {
    /// Canonical starters — keep macOS/iOS copy aligned.
    public static let all: [AgentEmptyConversationStarter] = [
        AgentEmptyConversationStarter(
            icon: "magnifyingglass",
            title: "Explain this codebase",
            prompt: "Give me a high-level tour of this codebase: the main modules, how they fit together, and where to start reading."
        ),
        AgentEmptyConversationStarter(
            icon: "ant",
            title: "Find and fix a bug",
            prompt: "Find a bug in the current changes and fix it. Show me the diff and explain the root cause."
        ),
        AgentEmptyConversationStarter(
            icon: "checklist",
            title: "Plan a change",
            prompt: "I want to add a feature. Help me plan it step by step before writing any code."
        ),
        AgentEmptyConversationStarter(
            icon: "text.alignleft",
            title: "Write tests",
            prompt: "Add tests for the most recently changed files. Cover the edge cases."
        )
    ]
}
