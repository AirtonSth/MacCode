import AppKit
import CoreModel
import DesignSystemKit
import SwiftUI

/// Shared Model popover chrome for Agent App and Bots Desk.
///
/// WHY: Desk Auto was a header-only fork of the Agent App popover. Auto-on
/// must paint the same orchestration card from one component.

public enum AgentModelPopoverTransition: Equatable {
    case none
    case fadeAndSlide
}

public struct AgentModelPopoverPresentation: Equatable {
    public static let autoDisclaimer = "Remote Code will automatically orchestrate the model to maximize quality while using the fewest tokens."
    public static let autoStatus = "Orchestration active"
    public static let autoAccessibilityLabel = "Automatic model routing"
    public static let autoAccessibilityHint = "Turns automatic model routing on or off."

    public let mode: AgentRoutingMode
    public let reduceMotion: Bool
    public let autoRoutingLoading: Bool

    public init(mode: AgentRoutingMode, reduceMotion: Bool, autoRoutingLoading: Bool = false) {
        self.mode = mode
        self.reduceMotion = reduceMotion
        self.autoRoutingLoading = autoRoutingLoading
    }

    public static func current(mode: AgentRoutingMode, autoRoutingLoading: Bool = false) -> Self {
        Self(
            mode: mode,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            autoRoutingLoading: autoRoutingLoading
        )
    }

    public var showsModelControls: Bool { mode != .auto }
    public var showsReasoningControls: Bool { mode != .auto }
    public var showsServiceTierControls: Bool { mode != .auto }
    public var showsDisclaimer: Bool { mode == .auto }
    public var showsAutoLoadingIndicator: Bool { autoRoutingLoading }
    public var autoToggleEnabled: Bool { !autoRoutingLoading }
    public var transition: AgentModelPopoverTransition {
        reduceMotion ? .none : .fadeAndSlide
    }
    public var accessibilityLabel: String { Self.autoAccessibilityLabel }
    public var accessibilityValue: String { mode == .auto ? "On" : "Off" }
    public var accessibilityHint: String { Self.autoAccessibilityHint }
    public var disclaimer: String { Self.autoDisclaimer }
}

public struct AgentModelAutoRoutingCard: View {
    public let presentation: AgentModelPopoverPresentation

    public init(presentation: AgentModelPopoverPresentation) {
        self.presentation = presentation
    }

    public var body: some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            ZStack {
                Ellipse()
                    .stroke(
                        LinearGradient(
                            colors: [DS.Palette.accent, DS.Palette.success],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 40, height: 20)
                    .rotationEffect(.degrees(-12))
                Image(systemName: "sparkles")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(DS.Palette.text)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text(presentation.disclaimer)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(DS.Palette.success)
                    Text(AgentModelPopoverPresentation.autoStatus)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                }
            }
        }
        .padding(DS.Space.lg)
        .frame(width: 360, alignment: .leading)
        .background(
            LinearGradient(
                colors: [DS.Palette.surfaceRaised, DS.Palette.success.opacity(0.12)],
                startPoint: .leading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.accent.opacity(0.22), lineWidth: DS.Border.hairline)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("agent.model.auto.card")
    }
}

public struct AgentModelPopoverChrome<ManualContent: View>: View {
    let presentation: AgentModelPopoverPresentation
    let autoEnabled: Binding<Bool>
    let toggleDisabled: Bool
    let manualContent: ManualContent

    public init(
        presentation: AgentModelPopoverPresentation,
        autoEnabled: Binding<Bool>,
        toggleDisabled: Bool,
        @ViewBuilder manualContent: () -> ManualContent
    ) {
        self.presentation = presentation
        self.autoEnabled = autoEnabled
        self.toggleDisabled = toggleDisabled
        self.manualContent = manualContent()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            header
            Divider()
                .accessibilityIdentifier("agent.model.auto.divider")
            if presentation.showsDisclaimer {
                AgentModelAutoRoutingCard(presentation: presentation)
                    .transition(presentation.transition == .fadeAndSlide
                        ? .opacity.combined(with: .move(edge: .top))
                        : .identity)
            } else {
                manualContent
            }
        }
        .animation(
            presentation.transition == .fadeAndSlide
                ? .easeInOut(duration: 0.2)
                : nil,
            value: presentation.mode
        )
        .padding(DS.Space.sm)
        .background(DS.Palette.surfaceOverlay)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var header: some View {
        HStack(spacing: DS.Space.md) {
            Text("Model")
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.text)
            Spacer(minLength: DS.Space.xxl)
            Text("Auto")
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
            if presentation.showsAutoLoadingIndicator {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading automatic routing")
                    .accessibilityIdentifier("agent.model.auto.loading")
            }
            Toggle("", isOn: autoEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(DS.Palette.success)
                .disabled(toggleDisabled)
                .accessibilityLabel(presentation.accessibilityLabel)
                .accessibilityValue(presentation.accessibilityValue)
                .accessibilityHint(presentation.accessibilityHint)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
        }
    }
}
