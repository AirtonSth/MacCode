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

public enum AgentDistillModelCatalog {
    public static func selectableModels(_ models: [AgentModelDescriptor]) -> [AgentModelDescriptor] {
        models.filter { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct AgentDistillModelSelectors<MainFooter: View>: View {
    public let mainModel: String
    public let mainModels: [AgentModelDescriptor]
    public let customMainModels: [String]
    public let reasoningModel: String?
    public let reasoningModels: [AgentModelDescriptor]
    public let mainEffortSelection: AgentEffortSelection
    public let mainEfforts: [AgentReasoningEffort]
    public let reasoningEffortSelection: AgentEffortSelection
    public let reasoningEfforts: [AgentReasoningEffort]
    public let supportsMainEffortAuto: Bool
    public let supportsReasoningModelEffort: Bool
    public let width: CGFloat?
    public let isDisabled: Bool
    public let onSelectMainModel: (String) -> Void
    public let onSelectReasoningModel: (String?) -> Void
    public let onSelectMainEffort: (AgentEffortSelection) -> Void
    public let onSelectReasoningEffort: (AgentEffortSelection) -> Void
    private let mainFooter: MainFooter
    @State private var showsAllMainModels = false

    public init(
        mainModel: String,
        mainModels: [AgentModelDescriptor],
        customMainModels: [String] = [],
        reasoningModel: String?,
        reasoningModels: [AgentModelDescriptor],
        mainEffortSelection: AgentEffortSelection = .automatic,
        mainEfforts: [AgentReasoningEffort] = [],
        reasoningEffortSelection: AgentEffortSelection = .automatic,
        reasoningEfforts: [AgentReasoningEffort] = [],
        supportsMainEffortAuto: Bool = false,
        supportsReasoningModelEffort: Bool = false,
        width: CGFloat? = nil,
        isDisabled: Bool,
        onSelectMainModel: @escaping (String) -> Void,
        onSelectCustomMainModel: @escaping (String) -> Void,
        onSelectReasoningModel: @escaping (String?) -> Void,
        onSelectMainEffort: @escaping (AgentEffortSelection) -> Void = { _ in },
        onSelectReasoningEffort: @escaping (AgentEffortSelection) -> Void = { _ in },
        @ViewBuilder mainFooter: () -> MainFooter
    ) {
        self.mainModel = mainModel
        self.mainModels = mainModels
        self.customMainModels = customMainModels
        self.reasoningModel = reasoningModel
        self.reasoningModels = reasoningModels
        self.mainEffortSelection = mainEffortSelection
        self.mainEfforts = mainEfforts
        self.reasoningEffortSelection = reasoningEffortSelection
        self.reasoningEfforts = reasoningEfforts
        self.supportsMainEffortAuto = supportsMainEffortAuto
        self.supportsReasoningModelEffort = supportsReasoningModelEffort
        self.onSelectMainEffort = onSelectMainEffort
        self.onSelectReasoningEffort = onSelectReasoningEffort
        self.width = width
        self.isDisabled = isDisabled
        self.onSelectMainModel = onSelectMainModel
        self.onSelectReasoningModel = onSelectReasoningModel
        self.mainFooter = mainFooter()
        self.onSelectCustomMainModel = onSelectCustomMainModel
    }

    private let onSelectCustomMainModel: (String) -> Void

    public var body: some View {
        let selectableMainModels = AgentDistillModelCatalog.selectableModels(mainModels)
        let selectableReasoningModels = AgentDistillModelCatalog.selectableModels(reasoningModels)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                AgentCompactMenuSection("Main model")
                    .accessibilityIdentifier("agent.distill.mainModel.section")
                ForEach(visibleMainModels, id: \.id) { model in
                    AgentCompactMenuRow(model.label, selected: model.id == mainModel, width: width) {
                        onSelectMainModel(model.id)
                    }
                    .disabled(isDisabled || reasoningModel == model.id)
                }
                ForEach(customMainModels, id: \.self) { model in
                    AgentCompactMenuRow(model, selected: model == mainModel, width: width) {
                        onSelectCustomMainModel(model)
                    }
                    .disabled(isDisabled || reasoningModel == model)
                }
                if selectableMainModels.count > 3, !showsAllMainModels {
                    AgentCompactMenuRow("More...", selected: false, width: width) {
                        showsAllMainModels = true
                    }
                }
                AgentCompactMenuDivider(width: width)
                AgentCompactMenuSection("Main effort")
                    .accessibilityIdentifier("agent.distill.mainEffort.section")
                AgentCompactMenuRow(
                    "Auto",
                    selected: mainEffortSelection.isAutomatic,
                    width: width
                ) {
                    onSelectMainEffort(.automatic)
                }
                .disabled(isDisabled || !supportsMainEffortAuto)
                ForEach(mainEfforts, id: \.self) { effort in
                    AgentCompactMenuRow(
                        effort.displayName,
                        selected: mainEffortSelection.effort == effort,
                        width: width
                    ) {
                        onSelectMainEffort(.fixed(effort))
                    }
                    .disabled(isDisabled)
                    .help(effort.pickerHelpText)
                }
                if let effort = mainEffortSelection.effort,
                   !mainEfforts.isEmpty,
                   !mainEfforts.contains(effort) {
                    Text("Selected Main effort \(effort.displayName) is unavailable for this model. Choose Auto or a supported level.")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !supportsMainEffortAuto {
                    Text("Auto Main effort requires an updated Distill ACP session.")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !mainModel.isEmpty,
                   !selectableMainModels.contains(where: { $0.id == mainModel }),
                   !customMainModels.contains(mainModel) {
                    Text("Selected Main model unavailable: \(mainModel)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                mainFooter
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Main model selection")
            .accessibilityIdentifier("agent.distill.mainModel")
            AgentCompactMenuDivider(width: width)
            VStack(alignment: .leading, spacing: 0) {
                AgentCompactMenuSection("Reasoning model")
                    .accessibilityIdentifier("agent.distill.reasoningModel.section")
                AgentCompactMenuRow("Off", selected: reasoningModel == nil, width: width) {
                    onSelectReasoningModel(nil)
                }
                .disabled(isDisabled)
                ForEach(selectableReasoningModels.filter { $0.id != mainModel }, id: \.id) { model in
                    AgentCompactMenuRow(model.label, selected: model.id == reasoningModel, width: width) {
                        onSelectReasoningModel(model.id)
                    }
                    .disabled(isDisabled)
                }
                if reasoningModel != nil {
                    AgentCompactMenuDivider(width: width)
                    AgentCompactMenuSection("Reasoning effort")
                        .accessibilityIdentifier("agent.distill.reasoningEffort.section")
                    if supportsReasoningModelEffort {
                        AgentCompactMenuRow(
                            "Auto",
                            selected: reasoningEffortSelection.isAutomatic,
                            width: width
                        ) {
                            onSelectReasoningEffort(.automatic)
                        }
                        .disabled(isDisabled)
                        ForEach(reasoningEfforts, id: \.self) { effort in
                            AgentCompactMenuRow(
                                effort.displayName,
                                selected: reasoningEffortSelection.effort == effort,
                                width: width
                            ) {
                                onSelectReasoningEffort(.fixed(effort))
                            }
                            .disabled(isDisabled)
                            .help(effort.pickerHelpText)
                        }
                        if let effort = reasoningEffortSelection.effort,
                           !reasoningEfforts.isEmpty,
                           !reasoningEfforts.contains(effort) {
                            Text("Selected Reasoning effort \(effort.displayName) is unavailable for this model. Choose Auto or a supported level.")
                                .font(DS.Font.caption2)
                                .foregroundColor(DS.Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("Reasoning effort follows the model default in this Distill version.")
                            .font(DS.Font.caption2)
                            .foregroundColor(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let reasoningModel, reasoningModel == mainModel {
                    Text("Main and Reasoning models must differ. Select Off or choose a different Reasoning model.")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let reasoningModel,
                          !selectableReasoningModels.contains(where: { $0.id == reasoningModel }) {
                    Text("Selected Reasoning model unavailable: \(reasoningModel)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Reasoning model selection")
            .accessibilityIdentifier("agent.distill.reasoningModel")
        }
    }

    private var visibleMainModels: [AgentModelDescriptor] {
        let selectable = AgentDistillModelCatalog.selectableModels(mainModels)
        guard !showsAllMainModels else { return selectable }
        let visible = Array(selectable.prefix(3))
        guard let selected = selectable.first(where: { $0.id == mainModel }),
              !visible.contains(where: { $0.id == selected.id }) else { return visible }
        return visible + [selected]
    }
}

public struct AgentModelPopoverChrome<ManualContent: View>: View {
    let presentation: AgentModelPopoverPresentation
    let autoEnabled: Binding<Bool>
    let toggleDisabled: Bool
    let showsAutoRouting: Bool
    let manualContent: ManualContent

    public init(
        presentation: AgentModelPopoverPresentation,
        autoEnabled: Binding<Bool>,
        toggleDisabled: Bool,
        showsAutoRouting: Bool = true,
        @ViewBuilder manualContent: () -> ManualContent
    ) {
        self.presentation = presentation
        self.autoEnabled = autoEnabled
        self.toggleDisabled = toggleDisabled
        self.showsAutoRouting = showsAutoRouting
        self.manualContent = manualContent()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if showsAutoRouting {
                header
                Divider()
                    .accessibilityIdentifier("agent.model.auto.divider")
            } else {
                Text("Model")
                    .font(DS.Font.caption.weight(.medium))
                    .foregroundColor(DS.Palette.text)
            }
            if showsAutoRouting && presentation.showsDisclaimer {
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
