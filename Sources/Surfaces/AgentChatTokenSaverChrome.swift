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

    public static func footerText(
        displayTokens: Int,
        measuredTokens: Int,
        enabled: Bool,
        autoRoutingActive: Bool
    ) -> String? {
        AgentAppView.tokenSaverThreadFooterText(
            displayTokens: displayTokens,
            measuredTokens: measuredTokens,
            enabled: enabled,
            autoRoutingActive: autoRoutingActive
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

public struct AgentChatTokenSaverThreadFooter: View {
    public let text: String
    public var autoRouting: Bool = false

    public init(text: String, autoRouting: Bool = false) {
        self.text = text
        self.autoRouting = autoRouting
    }

    public var body: some View {
        HStack(spacing: DS.Space.xs) {
            Image(systemName: "leaf.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(DS.Palette.success)
                .accessibilityHidden(true)
            Text(text)
                .font(DS.Font.caption2.weight(.medium))
                .foregroundColor(DS.Palette.success)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 5)
        .background(DS.Palette.success.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier("agent.tokenSaver.threadFooter")
        .help(
            autoRouting
                ? "Measured tool/command-output savings from the local Token Saver ledger (not full provider usage), plus Auto routing to cheaper models"
                : "Measured tool/command-output savings from the local Token Saver ledger only — not total provider or context tokens"
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
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
        observation: Observation
    ) -> Snapshot {
        let display = AgentAppView.tokenSaverThreadFooterDisplayTokens(
            measuredDelivered: measuredDelivered,
            assistantChars: observation.assistantChars,
            tokenSaverEnabled: eligible,
            graphifyActive: graphifyActive,
            graphifySignalCount: observation.graphifySignalCount,
            turnCount: observation.turnCount,
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

    public static func loadMeasured(
        eligible: Bool,
        threadId: AgentThreadID?,
        repo: TokenSaverSavingsRepository?
    ) async -> Int {
        guard eligible, let threadId, let repo else { return 0 }
        let id = threadId.value.uuidString
        return await Task.detached(priority: .utility) {
            (try? repo.savedTokens(forThreadID: id)) ?? 0
        }.value
    }
}
