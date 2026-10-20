import CoreModel
import DesignSystemKit
import Surfaces
import SwiftUI

public struct BotScheduleTaskItem: Identifiable, Equatable {
    public let id: BotRoutineID
    public let botID: BotID
    public var name: String
    public var prompt: String
    public var scheduleNote: String
    public var scheduleSpecJSON: String
    public var isEnabled: Bool
    public var botName: String
    public var botHandle: String
    public var botAvatarSymbol: String
    public var lastTestRunRequestedAt: Date?

    public init(routine: BotRoutine, bot: BotDefinition) {
        self.id = routine.definition.id
        self.botID = bot.id
        self.name = routine.definition.name
        self.prompt = routine.definition.prompt
        self.scheduleNote = routine.definition.scheduleNote
        self.scheduleSpecJSON = routine.definition.scheduleSpecJSON
        self.isEnabled = routine.activation.isEnabled
        self.botName = bot.name
        self.botHandle = bot.handle
        self.botAvatarSymbol = bot.avatarSymbol
        self.lastTestRunRequestedAt = routine.activation.lastTestRunRequestedAt
    }

    /// Next run is when this task would actually fire, not whether it is armed.
    /// An enabled task still does not run while global autonomy is paused.
    public func nextRunLabel(isAutonomyActive: Bool) -> String {
        if !isEnabled { return "Paused" }
        if !isAutonomyActive { return "Scheduler paused" }
        return "While MacCode is open"
    }
}

public struct BotScheduleTaskDraft: Identifiable, Equatable {
    public var id: BotRoutineID
    public var botID: BotID
    public var name: String
    public var prompt: String
    public var scheduleNote: String
    public var spec: BotScheduleSpec
    public var isEnabled: Bool
    public var isNew: Bool

    public init(botID: BotID) {
        self.id = BotRoutineID()
        self.botID = botID
        self.name = ""
        self.prompt = ""
        self.scheduleNote = ""
        self.spec = BotScheduleSpec()
        self.isEnabled = true
        self.isNew = true
    }

    public init(item: BotScheduleTaskItem) {
        self.id = item.id
        self.botID = item.botID
        self.name = item.name
        self.prompt = item.prompt
        self.scheduleNote = item.scheduleNote
        var resolvedSpec = BotScheduleSpec.resolved(json: item.scheduleSpecJSON, note: item.scheduleNote)
        if resolvedSpec.provider == .distill { resolvedSpec.routingMode = .manual }
        self.spec = resolvedSpec
        self.isEnabled = item.isEnabled
        self.isNew = false
    }
}

public struct BotScheduleTasksRootView: View {
    @ObservedObject private var vm: BotsViewModel

    public init(vm: BotsViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            if vm.scheduleTaskDraft != nil {
                editorScreen
            } else {
                overviewScreen
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                footerBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.Palette.bg)
        .accessibilityIdentifier("bots.scheduleTasks.screen")
        .onAppear { vm.scheduleFreshnessPass() }
    }

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Scheduled Tasks")
                        .font(DS.Font.title.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text(vm.scheduleTasksSubtitle)
                        .font(DS.Font.body)
                        .foregroundColor(vm.isAutonomyActive ? DS.Palette.textSecondary : DS.Palette.warning)
                }
                Spacer(minLength: DS.Space.lg)
                HStack(spacing: DS.Space.md) {
                    Button {
                        vm.createScheduleTask()
                    } label: {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .accessibilityIdentifier("bots.scheduleTasks.new")

                    autonomyControl
                }
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.top, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            HStack(spacing: DS.Space.md) {
                filterChips
                Spacer(minLength: DS.Space.lg)
                searchField
                    .frame(maxWidth: 280)
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.bottom, DS.Space.xl)

            if vm.scheduleTaskItems.isEmpty {
                DSEmptyState(
                    icon: "calendar.badge.clock",
                    title: vm.scheduleTaskSearchText.isEmpty ? "No scheduled tasks" : "No matching tasks",
                    subtitle: vm.scheduleTaskSearchText.isEmpty
                        ? "Create a task to run a bot automatically while MacCode is open."
                        : "Try another search or clear the status filter."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.scheduleTaskItems) { item in
                            BotScheduleTaskCard(
                                item: item,
                                isAutonomyActive: vm.isAutonomyActive,
                                isRunning: vm.isRoutineRunning(id: item.id),
                                onOpen: { vm.editScheduleTask(item) },
                                onToggle: { vm.setRoutineEnabled(id: item.id, enabled: !item.isEnabled) },
                                onRunNow: { vm.runRoutineNow(id: item.id) },
                                onEdit: { vm.editScheduleTask(item) },
                                onDelete: { vm.deleteScheduleTask(item) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("bots.scheduleTasks.list")
            }
        }
    }

    private var autonomyControl: some View {
        AgentKillSwitchControl(
            isActive: vm.isAutonomyActive,
            identifier: "bots.scheduleTasks.globalActive",
            accessibilityLabel: vm.isAutonomyActive ? "Schedules active" : "Schedules paused",
            onChange: { vm.setAutonomyActive($0) }
        )
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.sm) {
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.all.rawValue,
                count: vm.scheduleTaskFilterCounts.all,
                selected: vm.scheduleTaskStatusFilter == .all,
                identifier: "bots.scheduleTasks.filter.all"
            ) { vm.scheduleTaskStatusFilter = .all }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.active.rawValue,
                count: vm.scheduleTaskFilterCounts.active,
                selected: vm.scheduleTaskStatusFilter == .active,
                identifier: "bots.scheduleTasks.filter.active"
            ) { vm.scheduleTaskStatusFilter = .active }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.paused.rawValue,
                count: vm.scheduleTaskFilterCounts.paused,
                selected: vm.scheduleTaskStatusFilter == .paused,
                identifier: "bots.scheduleTasks.filter.paused"
            ) { vm.scheduleTaskStatusFilter = .paused }
        }
        .accessibilityIdentifier("bots.scheduleTasks.statusFilter")
    }

    private var searchField: some View {
        AgentListSearchField(
            text: $vm.scheduleTaskSearchText,
            placeholder: "Search tasks",
            identifier: "bots.scheduleTasks.search",
            accessibilityLabel: "Search tasks"
        )
        .accessibilityLabel("Search tasks")
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: vm.scheduleTasksFooterLine,
            pillTitle: vm.isAutonomyActive ? "Scheduler online" : "Scheduler paused",
            pillTone: vm.isAutonomyActive ? .success : .warning
        )
        .accessibilityLabel(vm.scheduleTasksFooterLine)
    }

    @ViewBuilder
    private var editorScreen: some View {
        if let draft = vm.scheduleTaskDraft {
            BotScheduleTaskEditorView(
                draft: draft,
                bots: vm.fleet,
                providers: vm.providers,
                providersLoading: false,
                onBack: { vm.scheduleTaskDraft = nil },
                onSave: { vm.saveScheduleTask($0) }
            )
        }
    }
}

struct BotScheduleTaskCard: View {
    let item: BotScheduleTaskItem
    let isAutonomyActive: Bool
    var isRunning = false
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: "calendar.badge.clock",
            iconColor: DS.Palette.accent,
            title: item.name,
            subtitle: "\(item.botName) · @\(item.botHandle)",
            identifier: "bots.scheduleTasks.task.\(item.id.value.uuidString.lowercased())",
            avatar: BotsAvatarView(
                name: item.botName, handle: item.botHandle, symbol: item.botAvatarSymbol,
                size: 36, attention: isRunning ? .working : .none
            ),
            onOpen: onOpen
        ) {
            if isRunning {
                HStack(spacing: DS.Space.xs) {
                    ProgressView().controlSize(.small)
                    DSPill("Running", tone: .success)
                }
                .accessibilityIdentifier("bots.scheduleTasks.running")
            } else if item.isEnabled {
                DSPill("Active", tone: .success)
            } else {
                DSPill("Paused", tone: .neutral)
            }
        } meta: {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                AgentOverviewMetaColumn(
                    title: "Schedule",
                    value: item.scheduleNote.isEmpty ? "When noted in the task" : item.scheduleNote
                )
                AgentOverviewMetaColumn(
                    title: "Next run",
                    value: item.nextRunLabel(isAutonomyActive: isAutonomyActive)
                )
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.lastTestRunRequestedAt == nil ? "0" : "1")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .monospacedDigit()
                }
                .frame(width: 44, alignment: .trailing)
            }
        } trailing: {
            Menu {
                Button(item.isEnabled ? "Pause" : "Resume", action: onToggle)
                Button("Run Now", action: onRunNow).disabled(isRunning)
                Button("Edit", action: onEdit)
                Divider()
                Button("Delete", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Task actions")
        }
    }
}

struct BotScheduleTaskEditorView: View {
    @State private var draft: BotScheduleTaskDraft
    let bots: [BotDefinition]
    let providers: [AgentProviderSnapshot]
    let providersLoading: Bool
    let onBack: () -> Void
    let onSave: (BotScheduleTaskDraft) -> Void

    init(
        draft: BotScheduleTaskDraft,
        bots: [BotDefinition],
        providers: [AgentProviderSnapshot],
        providersLoading: Bool,
        onBack: @escaping () -> Void,
        onSave: @escaping (BotScheduleTaskDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self.bots = bots
        self.providers = providers
        self.providersLoading = providersLoading
        self.onBack = onBack
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.lg) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Text(draft.isNew ? "New Scheduled Task" : "Edit Scheduled Task")
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                Spacer()
                Button("Cancel") { onBack() }
                    .buttonStyle(DSSecondaryButtonStyle())
                Button("Save") { onSave(draft) }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .accessibilityIdentifier("bots.scheduleTasks.save")
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)
            .dsBar(edge: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    labeled("Bot") {
                        Picker("", selection: $draft.botID) {
                            ForEach(bots, id: \.id) { bot in
                                Text(bot.name).tag(bot.id)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("bots.scheduleTasks.editor.bot")
                    }
                    labeled("Name") {
                        TextField("Morning scan", text: $draft.name)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("bots.scheduleTasks.editor.name")
                    }
                    labeled("Instruction") {
                        TextEditor(text: $draft.prompt)
                            .font(DS.Font.body)
                            .frame(minHeight: 140)
                            .accessibilityIdentifier("bots.scheduleTasks.editor.instruction")
                    }
                    BotScheduleSpecEditor(
                        spec: $draft.spec,
                        providers: providers,
                        providersLoading: providersLoading
                    )
                    labeled("Run options") {
                        ScheduledRunOptionsEditor(
                            showsUltracode: draft.spec.provider == .distill,
                            ultracode: Binding(
                                get: { draft.spec.distillUltracode ?? false },
                                set: { draft.spec.distillUltracode = $0 }
                            ),
                            permission: Binding(
                                get: { draft.spec.permissionMode ?? .fullAccess },
                                set: { draft.spec.permissionMode = $0 }
                            ),
                            identifierPrefix: "bots.scheduleTasks.editor"
                        )
                    }
                    Toggle("Active", isOn: $draft.isEnabled)
                        .accessibilityIdentifier("bots.scheduleTasks.editor.active")
                    Text(BotRoutineCopy.testRunHonestyCaption)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: 920, alignment: .leading)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            content()
                .accessibilityLabel(title)
                .padding(DS.Space.lg)
                .background(DS.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                )
        }
    }
}

/// Same Frequency + Provider / Model (Auto) / Reasoning rows as Agent App Schedule Tasks.
struct BotScheduleSpecEditor: View {
    @Binding var spec: BotScheduleSpec
    let providers: [AgentProviderSnapshot]
    let providersLoading: Bool
    @State private var showSourceOptions = false
    @State private var showModelOptions = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxl) {
            editorGroup("Details") {
                if AgentSourceCapsulePresentation.isVisible(entryCount: specSourceEntries.count) {
                    formRow("Provider") {
                        specSourceCapsule
                            .accessibilityIdentifier("bots.scheduleTasks.editor.provider")
                    }
                }
                if spec.provider != .distill {
                    formRow("Model routing") {
                        HStack(spacing: DS.Space.sm) {
                            if providersLoading {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Loading providers")
                            }
                            Toggle("Auto", isOn: Binding(
                                get: { spec.routingMode == .auto },
                                set: { enabled in
                                    spec.routingMode = spec.provider == .distill ? .manual : (enabled ? .auto : .manual)
                                }
                            ))
                            .toggleStyle(.switch)
                            .tint(DS.Palette.success)
                            .accessibilityIdentifier("bots.scheduleTasks.editor.autoRouting")
                        }
                    }
                }
                if spec.provider != .distill && spec.routingMode == .auto {
                    formRow("Model") {
                        Text("Auto selects the best model for the selected provider at run time.")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    formRow("Model") {
                        Button {
                            showModelOptions.toggle()
                        } label: {
                            AgentModelPillLabel(presentation: specModelPillPresentation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("bots.scheduleTasks.editor.model")
                        .popover(isPresented: $showModelOptions, arrowEdge: .bottom) {
                            specModelPopover
                        }
                    }
                }
            }

            editorGroup("Frequency") {
                ScheduledFrequencyEditor(
                    rules: $spec.frequencyRules,
                    timeZoneIdentifier: $spec.timeZoneIdentifier,
                    identifierPrefix: "bots.scheduleTasks.editor"
                )
            }
        }
        .onAppear { normalizeProviderInstance() }
        .onChange(of: providers.map(\.id)) { _ in normalizeProviderInstance() }
        .accessibilityIdentifier("bots.scheduleTasks.editor.spec")
    }

    static func models(providers: [AgentProviderSnapshot], provider: AgentProvider, instanceID: String) -> [AgentModelDescriptor] {
        providers.resolvedSnapshot(provider: provider, instanceID: instanceID)?.models ?? []
    }

    private var models: [AgentModelDescriptor] {
        Self.models(providers: providers, provider: spec.provider, instanceID: spec.providerInstanceID)
    }

    private func normalizeProviderInstance() {
        guard !providers.contains(where: { $0.provider == spec.provider && $0.id == spec.providerInstanceID }),
              let resolved = providers.resolvedSnapshot(provider: spec.provider, instanceID: spec.providerInstanceID) else { return }
        spec.providerInstanceID = resolved.id
    }

    private func snapshots(for provider: AgentProvider) -> [AgentProviderSnapshot] {
        providers.filter { $0.provider == provider }
    }

    private var specSourceEntries: [AgentSourceCapsulePresentation.MenuEntry] {
        AgentSourceCapsulePresentation.menuEntries(
            snapshots: providers,
            selectedSnapshotId: spec.providerInstanceID,
            selectedProvider: spec.provider,
            providerDisplayName: { $0.rawValue.capitalized }
        )
    }

    private var specSourceCapsule: some View {
        AgentSourceCapsule(
            label: AgentSourceCapsulePresentation.capsuleLabel(
                selected: providers.resolvedSnapshot(provider: spec.provider, instanceID: spec.providerInstanceID),
                fallbackProvider: spec.provider,
                fallbackInstanceId: spec.providerInstanceID,
                snapshots: providers
            ),
            entries: specSourceEntries,
            runLocked: false,
            providerLocked: false,
            accessibilityIdentifier: "bots.scheduleTasks.editor.provider",
            popoverIdentifier: "bots.scheduleTasks.editor.source.popover",
            isPresented: $showSourceOptions,
            onSelect: { selectSpecSource($0) }
        )
    }

    private var specModelPillPresentation: AgentModelPillPresentation {
        let selectableModels = spec.provider == .distill
            ? AgentDistillModelCatalog.selectableModels(models)
            : models
        let title = selectableModels.first(where: { $0.id == spec.model })?.label
            ?? (spec.model.isEmpty ? (spec.provider == .distill ? "Select Main model" : "Model") : spec.model)
        let effort = spec.provider == .distill
            ? (spec.distillMainEffortSelection ?? .fixed(spec.reasoningEffort)).effort?.displayName ?? "Auto"
            : spec.reasoningEffort.displayName
        return AgentModelPillPresentation(title: title, effort: effort)
    }

    private var specModelPopover: some View {
        let showsAutoRouting = spec.provider != .distill
        let snapshot = providers.resolvedSnapshot(provider: spec.provider, instanceID: spec.providerInstanceID)
        let mainEffortSelection = spec.distillMainEffortSelection ?? .fixed(spec.reasoningEffort)
        let reasoningEffortSelection = spec.distillReasoningEffortSelection ?? .automatic
        return AgentModelPopoverChrome(
            presentation: AgentModelPopoverPresentation.current(
                mode: showsAutoRouting ? spec.routingMode : .manual
            ),
            autoEnabled: Binding(
                get: { spec.routingMode == .auto },
                set: { enabled in
                    spec.routingMode = spec.provider == .distill ? .manual : (enabled ? .auto : .manual)
                }
            ),
            toggleDisabled: false,
            showsAutoRouting: showsAutoRouting
        ) {
            if spec.provider == .distill {
                AgentDistillModelSelectors(
                    mainModel: spec.model,
                    mainModels: AgentDistillModelCatalog.selectableModels(models),
                    reasoningModel: spec.reasoningModel,
                    reasoningModels: AgentDistillModelCatalog.selectableModels(models),
                    mainEffortSelection: mainEffortSelection,
                    mainEfforts: selectedMainEfforts,
                    reasoningEffortSelection: reasoningEffortSelection,
                    reasoningEfforts: selectedReasoningEfforts,
                    supportsMainEffortAuto: snapshot?.effectiveCapabilities.supportsDistillMainEffortAuto == true,
                    supportsReasoningModelEffort: snapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true,
                    configWorkerSummary: snapshot?.effectiveCapabilities.supportsDistillReasoningModelEffort == true
                        ? nil : AgentDistillModelCatalog.configWorkerSummary(homePath: snapshot?.homePath),
                    isDisabled: false,
                    onSelectMainModel: { model in
                        spec.model = model
                    },
                    onSelectCustomMainModel: { model in spec.model = model },
                    onSelectReasoningModel: { spec.reasoningModel = $0 },
                    onSelectMainEffort: { selection in
                        spec.distillMainEffortSelection = selection
                        if let effort = selection.effort { spec.reasoningEffort = effort }
                    },
                    onSelectReasoningEffort: { spec.distillReasoningEffortSelection = $0 },
                    mainFooter: { EmptyView() }
                )
            } else {
                AgentCompactMenuSection("Model")
                ForEach(AgentDistillModelCatalog.selectableModels(models), id: \.id) { model in
                    AgentCompactMenuRow(model.label, selected: model.id == spec.model) {
                        spec.model = model.id
                        if let effort = model.supportedReasoningEfforts.first {
                            spec.reasoningEffort = effort
                        }
                        showModelOptions = false
                    }
                }
                AgentCompactMenuDivider()
                AgentCompactMenuSection("Reasoning")
                ForEach(AgentReasoningEffort.allCases, id: \.self) { effort in
                    AgentCompactMenuRow(effort.displayName, selected: effort == spec.reasoningEffort) {
                        spec.reasoningEffort = effort
                        showModelOptions = false
                    }
                }
            }
        }
        .accessibilityIdentifier("bots.scheduleTasks.editor.reasoning")
    }

    private var selectedMainEfforts: [AgentReasoningEffort] {
        models.first(where: { $0.id == spec.model })?.supportedReasoningEfforts ?? []
    }

    private var selectedReasoningEfforts: [AgentReasoningEffort] {
        guard let reasoningModel = spec.reasoningModel else { return [] }
        return models.first(where: { $0.id == reasoningModel })?.supportedReasoningEfforts ?? []
    }

    private func selectSpecSource(_ entry: AgentSourceCapsulePresentation.MenuEntry) {
        if let snapshot = providers.first(where: { $0.id == entry.id }) {
            spec.provider = snapshot.provider
            spec.providerInstanceID = snapshot.id
            let models = snapshot.provider == .distill
                ? AgentDistillModelCatalog.selectableModels(snapshot.models)
                : snapshot.models
            spec.model = models.first?.id ?? ""
            spec.reasoningEffort = models.first?.supportedReasoningEfforts.first ?? .medium
            if snapshot.provider == .distill {
                spec.routingMode = .manual
                spec.distillMainEffortSelection = .automatic
                spec.distillReasoningEffortSelection = .automatic
            } else {
                spec.distillMainEffortSelection = nil
                spec.distillReasoningEffortSelection = nil
            }
            spec.reasoningModel = nil
            return
        }
        guard let provider = AgentProvider(rawValue: entry.id) else { return }
        spec.provider = provider
        if let snapshot = snapshots(for: provider).first {
            spec.providerInstanceID = snapshot.id
            let models = snapshot.provider == .distill
                ? AgentDistillModelCatalog.selectableModels(snapshot.models)
                : snapshot.models
            spec.model = models.first?.id ?? ""
            spec.reasoningEffort = models.first?.supportedReasoningEfforts.first ?? .medium
        } else {
            spec.providerInstanceID = provider.rawValue
            spec.model = ""
        }
        spec.reasoningModel = nil
        spec.distillMainEffortSelection = provider == .distill ? .automatic : nil
        spec.distillReasoningEffortSelection = provider == .distill ? .automatic : nil
        if provider == .distill { spec.routingMode = .manual }
    }

    private func editorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.textSecondary)
                .padding(.horizontal, DS.Space.lg)
                .padding(.vertical, DS.Space.md)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
        .accessibilityIdentifier("bots.scheduleTasks.editorSection.\(title)")
    }

    private func formRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            HStack {
                Text(label)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                Spacer(minLength: DS.Space.lg)
                content()
                    .frame(minWidth: 160, alignment: .trailing)
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
        }
    }
}

/// Bot schedules inside the Schedule Tasks screen: the same cards and actions as the Bots screen.
struct BotScheduleTasksSection: View {
    @ObservedObject var vm: BotsViewModel

    var body: some View {
        if !vm.scheduleTaskItems.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.md) {
                Text("Bot schedules")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textTertiary)
                LazyVStack(spacing: DS.Space.md) {
                    ForEach(vm.scheduleTaskItems) { item in
                        BotScheduleTaskCard(
                            item: item,
                            isAutonomyActive: vm.isAutonomyActive,
                            isRunning: vm.isRoutineRunning(id: item.id),
                            onOpen: { vm.editScheduleTask(item) },
                            onToggle: { vm.setRoutineEnabled(id: item.id, enabled: !item.isEnabled) },
                            onRunNow: { vm.runRoutineNow(id: item.id) },
                            onEdit: { vm.editScheduleTask(item) },
                            onDelete: { vm.deleteScheduleTask(item) }
                        )
                    }
                }
            }
            .accessibilityIdentifier("scheduledTasks.botSchedules")
        }
    }
}

/// Full-page editor for one bot schedule, shown in place of the Schedule Tasks overview.
struct BotScheduleTaskEditorScreen: View {
    @ObservedObject var vm: BotsViewModel

    var body: some View {
        if let draft = vm.scheduleTaskDraft {
            BotScheduleTaskEditorView(
                draft: draft,
                bots: vm.fleet,
                providers: vm.providers,
                providersLoading: false,
                onBack: { vm.scheduleTaskDraft = nil },
                onSave: { vm.saveScheduleTask($0) }
            )
        }
    }
}
