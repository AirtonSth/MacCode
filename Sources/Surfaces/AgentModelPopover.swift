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

    /// Collapsed row budget per model list. The selected model always pins
    /// into view even when it falls outside the prefix.
    public static let collapsedRowLimit = 4
    /// Lists longer than this get an inline filter field.
    public static let searchThreshold = 6
    /// Expanded lists longer than this scroll instead of growing the popover.
    public static let scrollThreshold = 10
    /// Fixed width when the caller passes none (schedulers, Desk drafts).
    public static let defaultWidth: CGFloat = 280

    public static func filtered(_ models: [AgentModelDescriptor], query: String) -> [AgentModelDescriptor] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.label.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
    }

    public static func visibleModels(
        _ models: [AgentModelDescriptor],
        selectedID: String?,
        expanded: Bool,
        limit: Int = collapsedRowLimit
    ) -> [AgentModelDescriptor] {
        guard !expanded, models.count > limit else { return models }
        var visible = Array(models.prefix(limit))
        if let selectedID, !selectedID.isEmpty,
           let selected = models.first(where: { $0.id == selectedID }),
           !visible.contains(where: { $0.id == selected.id }) {
            visible.append(selected)
        }
        return visible
    }
}

public struct AgentDistillMainModelSection<Footer: View>: View {
    public let mainModel: String
    public let mainModels: [AgentModelDescriptor]
    public let customMainModels: [String]
    public let reasoningModel: String?
    public let mainEffortSelection: AgentEffortSelection
    public let mainEfforts: [AgentReasoningEffort]
    public let supportsMainEffortAuto: Bool
    public let width: CGFloat?
    public let isDisabled: Bool
    public let emptyListTitle: String
    public let onSelectMainModel: (String) -> Void
    public let onSelectCustomMainModel: (String) -> Void
    public let onSelectMainEffort: (AgentEffortSelection) -> Void
    private let footer: Footer
    @State private var showsAllModels = false
    @State private var filterQuery = ""

    public init(
        mainModel: String,
        mainModels: [AgentModelDescriptor],
        customMainModels: [String] = [],
        reasoningModel: String? = nil,
        mainEffortSelection: AgentEffortSelection = .automatic,
        mainEfforts: [AgentReasoningEffort] = [],
        supportsMainEffortAuto: Bool = false,
        width: CGFloat? = nil,
        isDisabled: Bool,
        emptyListTitle: String = "No models available",
        onSelectMainModel: @escaping (String) -> Void,
        onSelectCustomMainModel: @escaping (String) -> Void,
        onSelectMainEffort: @escaping (AgentEffortSelection) -> Void = { _ in },
        @ViewBuilder footer: () -> Footer
    ) {
        self.mainModel = mainModel
        self.mainModels = mainModels
        self.customMainModels = customMainModels
        self.reasoningModel = reasoningModel
        self.mainEffortSelection = mainEffortSelection
        self.mainEfforts = mainEfforts
        self.supportsMainEffortAuto = supportsMainEffortAuto
        self.width = width
        self.isDisabled = isDisabled
        self.emptyListTitle = emptyListTitle
        self.onSelectMainModel = onSelectMainModel
        self.onSelectCustomMainModel = onSelectCustomMainModel
        self.onSelectMainEffort = onSelectMainEffort
        self.footer = footer()
    }

    public var body: some View {
        let selectable = AgentDistillModelCatalog.selectableModels(mainModels)
        let trimmedQuery = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !trimmedQuery.isEmpty
        let matches = AgentDistillModelCatalog.filtered(selectable, query: trimmedQuery)
        let displayed = isFiltering
            ? matches
            : AgentDistillModelCatalog.visibleModels(selectable, selectedID: mainModel, expanded: showsAllModels)
        let customMatches = isFiltering
            ? customMainModels.filter { $0.lowercased().contains(trimmedQuery.lowercased()) }
            : customMainModels
        return VStack(alignment: .leading, spacing: 0) {
            AgentCompactMenuSection("Main model")
                .accessibilityIdentifier("agent.distill.mainModel.section")
            if isMainUnavailable(in: selectable) {
                Text("Selected Main model unavailable: \(mainModel). Choose a model below or add it as Custom.")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: rowWidth, alignment: .leading)
                    .padding(.bottom, DS.Space.xs)
            }
            if selectable.isEmpty {
                Text(emptyListTitle)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: rowWidth, alignment: .leading)
            } else {
                if selectable.count > AgentDistillModelCatalog.searchThreshold {
                    AgentModelSearchField(query: $filterQuery, width: rowWidth, accessibilityIdentifier: "agent.distill.mainModel.search")
                        .disabled(isDisabled)
                }
                if isFiltering && matches.isEmpty && customMatches.isEmpty {
                    Text("No models match \"\(trimmedQuery)\".")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: rowWidth, alignment: .leading)
                }
                modelRows(displayed)
                ForEach(customMatches, id: \.self) { model in
                    AgentCompactMenuRow(model, selected: model == mainModel, width: rowWidth) {
                        onSelectCustomMainModel(model)
                    }
                    .disabled(isDisabled || reasoningModel == model)
                    .help(model)
                }
                if !isFiltering, selectable.count > displayed.count {
                    AgentCompactMenuRow("Show all \(selectable.count) models", selected: false, width: rowWidth) {
                        showsAllModels = true
                    }
                }
                footer
            }
            AgentCompactMenuDivider(width: rowWidth)
            AgentCompactMenuSection("Main effort")
                .accessibilityIdentifier("agent.distill.mainEffort.section")
            AgentCompactMenuRow(
                "Auto",
                selected: mainEffortSelection.isAutomatic,
                width: rowWidth
            ) {
                onSelectMainEffort(.automatic)
            }
            .disabled(isDisabled || !supportsMainEffortAuto)
            .help("Let Distill pick the effort for this model")
            ForEach(mainEfforts, id: \.self) { effort in
                AgentCompactMenuRow(
                    effort.displayName,
                    selected: mainEffortSelection.effort == effort,
                    width: rowWidth
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
                    .frame(width: rowWidth, alignment: .leading)
            }
            if !supportsMainEffortAuto {
                Text("Auto Main effort requires an updated Distill ACP session.")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: rowWidth, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Main model selection")
        .accessibilityIdentifier("agent.distill.mainModel")
    }

    private var rowWidth: CGFloat { width ?? AgentDistillModelCatalog.defaultWidth }

    private func isMainUnavailable(in selectable: [AgentModelDescriptor]) -> Bool {
        guard !mainModel.isEmpty,
              !selectable.contains(where: { $0.id == mainModel }),
              !customMainModels.contains(mainModel) else { return false }
        return true
    }

    @ViewBuilder
    private func modelRows(_ displayed: [AgentModelDescriptor]) -> some View {
        if displayed.count > AgentDistillModelCatalog.scrollThreshold {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayed, id: \.id) { modelRow($0) }
                }
            }
            .frame(width: rowWidth)
            .frame(maxHeight: 308)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayed, id: \.id) { modelRow($0) }
            }
        }
    }

    private func modelRow(_ model: AgentModelDescriptor) -> some View {
        AgentCompactMenuRow(
            model.label,
            detail: model.contextWindowLabel,
            selected: model.id == mainModel,
            width: rowWidth
        ) {
            onSelectMainModel(model.id)
        }
        .disabled(isDisabled || reasoningModel == model.id)
        .help("\(model.label)\n\(model.id)")
    }
}

public struct AgentDistillReasoningModelSection: View {
    public let mainModel: String
    public let reasoningModel: String?
    public let reasoningModels: [AgentModelDescriptor]
    public let reasoningEffortSelection: AgentEffortSelection
    public let reasoningEfforts: [AgentReasoningEffort]
    public let supportsReasoningModelEffort: Bool
    public let width: CGFloat?
    public let isDisabled: Bool
    public let emptyListTitle: String
    public let onSelectReasoningModel: (String?) -> Void
    public let onSelectReasoningEffort: (AgentEffortSelection) -> Void
    @State private var showsAllModels = false
    @State private var filterQuery = ""

    public init(
        mainModel: String,
        reasoningModel: String?,
        reasoningModels: [AgentModelDescriptor],
        reasoningEffortSelection: AgentEffortSelection = .automatic,
        reasoningEfforts: [AgentReasoningEffort] = [],
        supportsReasoningModelEffort: Bool = false,
        width: CGFloat? = nil,
        isDisabled: Bool,
        emptyListTitle: String = "No models available",
        onSelectReasoningModel: @escaping (String?) -> Void,
        onSelectReasoningEffort: @escaping (AgentEffortSelection) -> Void = { _ in }
    ) {
        self.mainModel = mainModel
        self.reasoningModel = reasoningModel
        self.reasoningModels = reasoningModels
        self.reasoningEffortSelection = reasoningEffortSelection
        self.reasoningEfforts = reasoningEfforts
        self.supportsReasoningModelEffort = supportsReasoningModelEffort
        self.width = width
        self.isDisabled = isDisabled
        self.emptyListTitle = emptyListTitle
        self.onSelectReasoningModel = onSelectReasoningModel
        self.onSelectReasoningEffort = onSelectReasoningEffort
    }

    public var body: some View {
        let selectable = AgentDistillModelCatalog.selectableModels(reasoningModels)
        let eligible = selectable.filter { $0.id != mainModel }
        let trimmedQuery = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFiltering = !trimmedQuery.isEmpty
        let matches = AgentDistillModelCatalog.filtered(eligible, query: trimmedQuery)
        let displayed = isFiltering
            ? matches
            : AgentDistillModelCatalog.visibleModels(eligible, selectedID: reasoningModel, expanded: showsAllModels)
        return VStack(alignment: .leading, spacing: 0) {
            AgentCompactMenuSection("Reasoning model")
                .accessibilityIdentifier("agent.distill.reasoningModel.section")
            if let warning = reasoningWarning(in: selectable) {
                Text(warning)
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: rowWidth, alignment: .leading)
                    .padding(.bottom, DS.Space.xs)
            }
            AgentCompactMenuRow("Off", selected: reasoningModel == nil, width: rowWidth) {
                onSelectReasoningModel(nil)
            }
            .disabled(isDisabled)
            .help("Run without a separate reasoning model")
            if eligible.isEmpty {
                Text(emptyListTitle)
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: rowWidth, alignment: .leading)
            } else {
                if eligible.count > AgentDistillModelCatalog.searchThreshold {
                    AgentModelSearchField(query: $filterQuery, width: rowWidth, accessibilityIdentifier: "agent.distill.reasoningModel.search")
                        .disabled(isDisabled)
                }
                if isFiltering && matches.isEmpty {
                    Text("No models match \"\(trimmedQuery)\".")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: rowWidth, alignment: .leading)
                }
                modelRows(displayed)
                if !isFiltering, eligible.count > displayed.count {
                    AgentCompactMenuRow("Show all \(eligible.count) models", selected: false, width: rowWidth) {
                        showsAllModels = true
                    }
                }
            }
            if reasoningModel != nil {
                AgentCompactMenuDivider(width: rowWidth)
                AgentCompactMenuSection("Reasoning effort")
                    .accessibilityIdentifier("agent.distill.reasoningEffort.section")
                if supportsReasoningModelEffort {
                    AgentCompactMenuRow(
                        "Auto",
                        selected: reasoningEffortSelection.isAutomatic,
                        width: rowWidth
                    ) {
                        onSelectReasoningEffort(.automatic)
                    }
                    .disabled(isDisabled)
                    .help("Let Distill pick the effort for this model")
                    ForEach(reasoningEfforts, id: \.self) { effort in
                        AgentCompactMenuRow(
                            effort.displayName,
                            selected: reasoningEffortSelection.effort == effort,
                            width: rowWidth
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
                            .frame(width: rowWidth, alignment: .leading)
                    }
                } else {
                    Text("Reasoning effort follows the model default in this Distill version.")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: rowWidth, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reasoning model selection")
        .accessibilityIdentifier("agent.distill.reasoningModel")
    }

    private var rowWidth: CGFloat { width ?? AgentDistillModelCatalog.defaultWidth }

    private func reasoningWarning(in selectable: [AgentModelDescriptor]) -> String? {
        guard let reasoningModel else { return nil }
        if reasoningModel == mainModel {
            return "Main and Reasoning models must differ. Select Off or choose a different Reasoning model."
        }
        if !selectable.contains(where: { $0.id == reasoningModel }) {
            return "Selected Reasoning model unavailable: \(reasoningModel). Choose Off or a model below."
        }
        return nil
    }

    @ViewBuilder
    private func modelRows(_ displayed: [AgentModelDescriptor]) -> some View {
        if displayed.count > AgentDistillModelCatalog.scrollThreshold {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayed, id: \.id) { modelRow($0) }
                }
            }
            .frame(width: rowWidth)
            .frame(maxHeight: 308)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(displayed, id: \.id) { modelRow($0) }
            }
        }
    }

    private func modelRow(_ model: AgentModelDescriptor) -> some View {
        AgentCompactMenuRow(
            model.label,
            detail: model.contextWindowLabel,
            selected: model.id == reasoningModel,
            width: rowWidth
        ) {
            onSelectReasoningModel(model.id)
        }
        .disabled(isDisabled)
        .help("\(model.label)\n\(model.id)")
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
        VStack(alignment: .leading, spacing: 0) {
            AgentDistillMainModelSection(
                mainModel: mainModel,
                mainModels: mainModels,
                customMainModels: customMainModels,
                reasoningModel: reasoningModel,
                mainEffortSelection: mainEffortSelection,
                mainEfforts: mainEfforts,
                supportsMainEffortAuto: supportsMainEffortAuto,
                width: width,
                isDisabled: isDisabled,
                onSelectMainModel: onSelectMainModel,
                onSelectCustomMainModel: onSelectCustomMainModel,
                onSelectMainEffort: onSelectMainEffort,
                footer: { mainFooter }
            )
            AgentCompactMenuDivider(width: width)
            AgentDistillReasoningModelSection(
                mainModel: mainModel,
                reasoningModel: reasoningModel,
                reasoningModels: reasoningModels,
                reasoningEffortSelection: reasoningEffortSelection,
                reasoningEfforts: reasoningEfforts,
                supportsReasoningModelEffort: supportsReasoningModelEffort,
                width: width,
                isDisabled: isDisabled,
                onSelectReasoningModel: onSelectReasoningModel,
                onSelectReasoningEffort: onSelectReasoningEffort
            )
        }
    }
}

public struct AgentModelPopoverChrome<ManualContent: View>: View {
    let presentation: AgentModelPopoverPresentation
    let autoEnabled: Binding<Bool>
    let toggleDisabled: Bool
    let showsAutoRouting: Bool
    let title: String
    let manualContent: ManualContent

    public init(
        presentation: AgentModelPopoverPresentation,
        autoEnabled: Binding<Bool>,
        toggleDisabled: Bool,
        showsAutoRouting: Bool = true,
        title: String = "Model",
        @ViewBuilder manualContent: () -> ManualContent
    ) {
        self.presentation = presentation
        self.autoEnabled = autoEnabled
        self.toggleDisabled = toggleDisabled
        self.showsAutoRouting = showsAutoRouting
        self.title = title
        self.manualContent = manualContent()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            if showsAutoRouting {
                header
                Divider()
                    .accessibilityIdentifier("agent.model.auto.divider")
            } else {
                Text(title)
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
