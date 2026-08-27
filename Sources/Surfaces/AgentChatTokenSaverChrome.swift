import CoreModel
import DesignSystemKit
import Persistence
import SwiftUI

/// Shared Token Saver transcript chrome. Agent App and Bot Desk mount these
/// views so the optimized badge, Human/RCW1 control, and thread footer stay
/// one control — not a Desk lookalike.
public enum AgentChatTokenSaverDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case human
    case rcw1

    public var id: String { rawValue }
    public var label: String { self == .human ? "Human" : "RCW1" }

    public var agentAppMode: AgentAppView.TokenSaverDisplayMode {
        self == .rcw1 ? .original : .translated
    }

    public static func from(displaysOriginal: Bool) -> Self {
        displaysOriginal ? .rcw1 : .human
    }

    public static func userMessageDisplayText(
        human: String,
        wireRequest: String?,
        mode: AgentChatTokenSaverDisplayMode
    ) -> String {
        AgentAppView.tokenSaverUserMessageDisplayText(
            human: human,
            wireRequest: wireRequest,
            mode: mode.agentAppMode
        )
    }

    public static func copyText(
        translated: String,
        original: String,
        request: String?,
        mode: AgentChatTokenSaverDisplayMode
    ) -> String {
        AgentAppView.tokenSaverCopyText(
            translated: translated,
            original: original,
            request: request,
            mode: mode.agentAppMode
        )
    }

    public static func showsDisplayControl(
        original: String,
        request: String?,
        allowsRequestOnlyRCW1: Bool
    ) -> Bool {
        AgentAppView.showsTokenSaverDisplayControl(
            original: original,
            request: request,
            allowsRequestOnlyRCW1: allowsRequestOnlyRCW1
        )
    }

    public static func showsOriginalContent(
        original: String,
        mode: AgentChatTokenSaverDisplayMode
    ) -> Bool {
        AgentAppView.showsTokenSaverOriginalContent(
            original: original,
            mode: mode.agentAppMode
        )
    }

    public static func showsOptimizedBadge(wasTokenSaverOptimized: Bool) -> Bool {
        AgentAppView.showsTokenSaverOptimizedBadge(wasTokenSaverOptimized: wasTokenSaverOptimized)
    }

    public static func footerPresentation(
        enabled: Bool,
        measuredTokens: Int = 0,
        snapshotReady: Bool = true
    ) -> AgentChatTokenSaverThreadFooterPresentation? {
        AgentAppView.tokenSaverThreadFooterPresentation(
            enabled: enabled,
            measuredTokens: measuredTokens,
            snapshotReady: snapshotReady
        )
    }

    public static func footerText(
        displayTokens: Int,
        measuredTokens: Int,
        enabled: Bool,
        autoRoutingActive: Bool,
        snapshotReady: Bool = true
    ) -> String? {
        AgentAppView.tokenSaverThreadFooterText(
            displayTokens: displayTokens,
            measuredTokens: measuredTokens,
            enabled: enabled,
            autoRoutingActive: autoRoutingActive,
            snapshotReady: snapshotReady
        )
    }

    public static func messageDisplayKey(_ messageId: String) -> String {
        AgentAppView.tokenSaverMessageDisplayKey(messageId)
    }
}

public struct AgentChatTokenSaverOptimizedBadge: View {
    public let messageId: String

    public init(messageId: String) {
        self.messageId = messageId
    }

    public var body: some View {
        Text(AgentAppView.tokenSaverBadgeLabel(hasOriginalText: false))
            .font(DS.Font.caption2)
            .foregroundColor(DS.Palette.textTertiary)
            .accessibilityLabel("Token Saver optimized this reply")
            .accessibilityIdentifier("agent.assistantMessage.tokenSaverBadge.\(messageId)")
    }
}

public struct AgentChatTokenSaverDisplayControl: View {
    @Binding public var mode: AgentChatTokenSaverDisplayMode
    public var identifier: String
    public var alignment: Alignment = .leading

    public init(
        mode: Binding<AgentChatTokenSaverDisplayMode>,
        identifier: String,
        alignment: Alignment = .leading
    ) {
        self._mode = mode
        self.identifier = identifier
        self.alignment = alignment
    }

    public var body: some View {
        HStack(spacing: DS.Space.sm) {
            Label("Token Saver optimized", systemImage: "arrow.left.arrow.right")
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1)
            Picker("Token Saver display", selection: $mode) {
                Text("Human").tag(AgentChatTokenSaverDisplayMode.human)
                Text("RCW1").tag(AgentChatTokenSaverDisplayMode.rcw1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 150)
            .accessibilityLabel("Token Saver display")
            .accessibilityValue(mode.label)
            .accessibilityHint("Switches only this transcript item between readable and original transport text.")
            .accessibilityIdentifier("agent.tokenSaver.displayMode.\(identifier)")
            .help("Show translated text or the exact Token Saver transport")
        }
        .frame(minHeight: 32)
        .frame(maxWidth: .infinity, alignment: alignment)
    }
}

public struct AgentChatTokenSaverOriginalContent: View {
    public let original: String
    public let request: String?
    public let identifierSuffix: String
    public var onCopy: (String) -> Void
    public var retryLabel: String? = nil
    public var retryDisabled: Bool = false
    public var retryIdentifier: String? = nil
    public var onRetry: (() -> Void)? = nil

    public init(
        original: String,
        request: String?,
        identifierSuffix: String,
        onCopy: @escaping (String) -> Void,
        retryLabel: String? = nil,
        retryDisabled: Bool = false,
        retryIdentifier: String? = nil,
        onRetry: (() -> Void)? = nil
    ) {
        self.original = original
        self.request = request
        self.identifierSuffix = identifierSuffix
        self.onCopy = onCopy
        self.retryLabel = retryLabel
        self.retryDisabled = retryDisabled
        self.retryIdentifier = retryIdentifier
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            if let request, !request.isEmpty {
                Text("What was sent")
                    .font(DS.Font.caption2.weight(.semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                Text(request)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(DS.Palette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy what was sent") { onCopy(request) }
                    .buttonStyle(.plain)
                    .font(DS.Font.caption2)
                    .accessibilityIdentifier("agent.tokenSaver.copyRequest.\(identifierSuffix)")
            }
            Text("Original provider response")
                .font(DS.Font.caption2.weight(.semibold))
                .foregroundColor(DS.Palette.textTertiary)
            Text(original)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(DS.Palette.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("Copy original provider response") { onCopy(original) }
                .buttonStyle(.plain)
                .font(DS.Font.caption2)
                .accessibilityIdentifier("agent.tokenSaver.copyOriginal.\(identifierSuffix)")
            if let retryLabel, let onRetry {
                Button(retryLabel, action: onRetry)
                    .buttonStyle(.plain)
                    .font(DS.Font.caption2)
                    .disabled(retryDisabled)
                    .accessibilityLabel("Retry local translation")
                    .accessibilityIdentifier(retryIdentifier ?? "agent.tokenSaver.retry.\(identifierSuffix)")
            }
        }
        .padding(DS.Space.md)
        .background(DS.Palette.surface.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Green savings, yellow on-zero problem, red off-state. Both surfaces
/// consume this so Desk cannot stay green-only or hide the chip.
public enum AgentChatTokenSaverThreadFooterPresentation: Equatable, Sendable {
    case savings
    case problem
    case deactivated
}

public struct AgentChatTokenSaverThreadFooter: View {
    public let text: String
    public var autoRouting: Bool = false
    public var presentation: AgentChatTokenSaverThreadFooterPresentation = .savings

    public init(
        text: String,
        autoRouting: Bool = false,
        presentation: AgentChatTokenSaverThreadFooterPresentation = .savings
    ) {
        self.text = text
        self.autoRouting = autoRouting
        self.presentation = presentation
    }

    private var tint: Color {
        switch presentation {
        case .savings: return DS.Palette.success
        case .problem: return DS.Palette.warning
        case .deactivated: return DS.Palette.danger
        }
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.caption2.weight(.medium))
                .foregroundColor(tint)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 5)
        .background(tint.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier("agent.tokenSaver.threadFooter")
        .help(helpText)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var helpText: String {
        switch presentation {
        case .deactivated:
            return "Token Saver is off, so this thread saved 0 tokens"
        case .problem:
            return "Token Saver is on, but this thread recorded 0 saved tokens"
        case .savings:
            return autoRouting
                ? "Measured tool/command-output savings from the local Token Saver ledger (not full provider usage), plus Auto routing to cheaper models"
                : "Measured tool/command-output savings from the local Token Saver ledger only — not total provider or context tokens"
        }
    }
}

/// Shared off-main ledger reload used by Agent App and Bot Desk so footer
/// figures cannot drift. Callers supply the same observation inputs the
/// Agent App calculator already consumes.
public enum TokenSaverThreadFooterReload {
    public struct Observation: Sendable {
        public var assistantChars: Int
        public var turnCount: Int
        public var cacheReadInputTokens: Int
        public var providerRawTokens: Int
        public var providerBilledTokenUnits: Double?
        public var autoRoutingActive: Bool
        public var graphifySignalCount: Int

        public init(
            assistantChars: Int,
            turnCount: Int,
            cacheReadInputTokens: Int,
            providerRawTokens: Int,
            providerBilledTokenUnits: Double?,
            autoRoutingActive: Bool,
            graphifySignalCount: Int = 0
        ) {
            self.assistantChars = assistantChars
            self.turnCount = turnCount
            self.cacheReadInputTokens = cacheReadInputTokens
            self.providerRawTokens = providerRawTokens
            self.providerBilledTokenUnits = providerBilledTokenUnits
            self.autoRoutingActive = autoRoutingActive
            self.graphifySignalCount = graphifySignalCount
        }
    }

    public struct Snapshot: Equatable, Sendable {
        public var enabled: Bool
        public var measuredTokens: Int
        public var displayTokens: Int

        public init(enabled: Bool, measuredTokens: Int, displayTokens: Int) {
            self.enabled = enabled
            self.measuredTokens = measuredTokens
            self.displayTokens = displayTokens
        }
    }

    public static func snapshot(
        measuredDelivered: Int,
        eligible: Bool,
        graphifyActive: Bool,
        observation: Observation,
        deliveredRuns: Int = 0
    ) -> Snapshot {
        // Permanent `runs` is the same extra-turn floor the day/week card uses.
        // Cache-first timeline paint can be 0–1 turns and would otherwise drop
        // the chip from measured×(runs−1) down to bare measured.
        let turnCount = max(observation.turnCount, max(0, deliveredRuns))
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measuredDelivered,
            assistantChars: observation.assistantChars,
            tokenSaverEnabled: eligible,
            graphifyActive: graphifyActive,
            graphifySignalCount: observation.graphifySignalCount,
            turnCount: turnCount,
            cacheReadInputTokens: observation.cacheReadInputTokens,
            providerRawTokens: observation.providerRawTokens,
            providerBilledTokenUnits: observation.providerBilledTokenUnits,
            autoRoutingActive: observation.autoRoutingActive
        )
        return Snapshot(
            enabled: eligible,
            measuredTokens: max(0, measuredDelivered),
            displayTokens: display
        )
    }

    public static func shouldPublish(
        current: Snapshot,
        next: Snapshot
    ) -> Bool {
        AgentAppViewModel.shouldPublishTokenSaverFooter(
            currentEnabled: current.enabled,
            nextEnabled: next.enabled,
            currentMeasured: current.measuredTokens,
            nextMeasured: next.measuredTokens,
            currentDisplay: current.displayTokens,
            nextDisplay: next.displayTokens
        )
    }

    public struct DeliveredTotal: Equatable, Sendable {
        public var savedTokens: Int
        public var runs: Int

        public init(savedTokens: Int, runs: Int) {
            self.savedTokens = max(0, savedTokens)
            self.runs = max(0, runs)
        }
    }

    public static func loadDeliveredTotal(
        eligible: Bool,
        threadId: AgentThreadID?,
        repo: TokenSaverSavingsRepository?
    ) async -> DeliveredTotal? {
        guard eligible, let threadId, let repo else {
            return DeliveredTotal(savedTokens: 0, runs: 0)
        }
        let id = threadId.value.uuidString
        return await Task.detached(priority: .utility) {
            guard let total = try? repo.deliveredTotal(forThreadID: id) else { return nil }
            return DeliveredTotal(savedTokens: total.savedTokens, runs: total.runs)
        }.value
    }

    public static func loadMeasured(
        eligible: Bool,
        threadId: AgentThreadID?,
        repo: TokenSaverSavingsRepository?
    ) async -> Int? {
        await loadDeliveredTotal(eligible: eligible, threadId: threadId, repo: repo)?
            .savedTokens
    }

    public static func currentDayGraphifySignalCount(
        repo: GraphifyUsageRepository,
        now: Date = Date()
    ) -> Int {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let fromMs = Int64(start.timeIntervalSince1970 * 1_000)
        let toMs = Int64(calendar.date(byAdding: .day, value: 1, to: start)!.timeIntervalSince1970 * 1_000)
        return (try? repo.signalCount(fromMs: fromMs, toMsExclusive: toMs)) ?? 0
    }
}
