import CoreModel
import DesignSystemKit
import SwiftUI

public struct BotScheduleTaskItem: Identifiable, Equatable {
    public let id: BotRoutineID
    public let botID: BotID
    public var name: String
    public var prompt: String
    public var scheduleNote: String
    public var isEnabled: Bool
    public var botName: String
    public var botHandle: String
    public var lastTestRunRequestedAt: Date?

    public init(routine: BotRoutine, bot: BotDefinition) {
        self.id = routine.definition.id
        self.botID = bot.id
        self.name = routine.definition.name
        self.prompt = routine.definition.prompt
        self.scheduleNote = routine.definition.scheduleNote
        self.isEnabled = routine.activation.isEnabled
        self.botName = bot.name
        self.botHandle = bot.handle
        self.lastTestRunRequestedAt = routine.activation.lastTestRunRequestedAt
    }
}

public struct BotScheduleTaskDraft: Identifiable, Equatable {
    public var id: BotRoutineID
    public var botID: BotID
    public var name: String
    public var prompt: String
    public var scheduleNote: String
    public var isEnabled: Bool
    public var isNew: Bool

    public init(botID: BotID) {
        self.id = BotRoutineID()
        self.botID = botID
        self.name = ""
        self.prompt = ""
        self.scheduleNote = ""
        self.isEnabled = true
        self.isNew = true
    }

    public init(item: BotScheduleTaskItem) {
        self.id = item.id
        self.botID = item.botID
        self.name = item.name
        self.prompt = item.prompt
        self.scheduleNote = item.scheduleNote
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
        .onAppear { vm.reloadScheduleTasks() }
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
                        ? "Create a task to run a bot automatically while RemoteCode is open."
                        : "Try another search or clear the status filter."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.scheduleTaskItems) { item in
                            BotScheduleTaskCard(
                                item: item,
                                onOpen: { vm.editScheduleTask(item) },
                                onToggle: { vm.setRoutineEnabled(id: item.id, enabled: !item.isEnabled) },
                                onRunNow: { vm.requestRoutineTestRun(id: item.id) },
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
        let active = vm.isAutonomyActive
        let tone = active ? DS.Palette.success : DS.Palette.warning
        return HStack(spacing: DS.Space.md) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: active ? "bolt.fill" : "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(tone)
                    .frame(width: 22, height: 22)
                    .background(tone.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(active ? "Active" : "Paused")
                        .font(DS.Font.captionStrong)
                        .foregroundColor(DS.Palette.text)
                    Text(active ? "Schedules on" : "Travel pause")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                }
            }
            .accessibilityHidden(true)
            Toggle(isOn: Binding(
                get: { vm.isAutonomyActive },
                set: { vm.setAutonomyActive($0) }
            )) {
                Text("Active")
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DS.Palette.success)
            .accessibilityIdentifier("bots.scheduleTasks.globalActive")
            .accessibilityLabel(active ? "Schedules active" : "Schedules paused")
        }
        .padding(.leading, DS.Space.lg)
        .padding(.trailing, DS.Space.md)
        .padding(.vertical, DS.Space.sm)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Palette.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(active ? tone.opacity(0.45) : DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.sm) {
            filterChip(.all, count: vm.scheduleTaskFilterCounts.all)
            filterChip(.active, count: vm.scheduleTaskFilterCounts.active)
            filterChip(.paused, count: vm.scheduleTaskFilterCounts.paused)
        }
        .accessibilityIdentifier("bots.scheduleTasks.statusFilter")
    }

    private func filterChip(_ filter: ScheduledTaskStatusFilter, count: Int) -> some View {
        let selected = vm.scheduleTaskStatusFilter == filter
        return Button {
            vm.scheduleTaskStatusFilter = filter
        } label: {
            HStack(spacing: DS.Space.xs) {
                Text(filter.rawValue)
                    .font(DS.Font.caption.weight(.semibold))
                Text("\(count)")
                    .font(DS.Font.caption2.weight(.bold))
                    .opacity(selected ? 0.9 : 0.7)
            }
            .foregroundColor(selected ? DS.Palette.onAccent : DS.Palette.textSecondary)
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.sm)
            .background(selected ? DS.Palette.accent : DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(selected ? Color.clear : DS.Palette.line, lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("bots.scheduleTasks.filter.\(filter.rawValue.lowercased())")
    }

    private var searchField: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            TextField("Search tasks", text: $vm.scheduleTaskSearchText)
                .textFieldStyle(.plain)
                .foregroundColor(DS.Palette.text)
                .accessibilityIdentifier("bots.scheduleTasks.search")
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
        .background(DS.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    private var footerBar: some View {
        HStack(spacing: DS.Space.md) {
            Text(vm.scheduleTasksFooterLine)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            DSPill(
                vm.isAutonomyActive ? "Scheduler online" : "Scheduler paused",
                tone: vm.isAutonomyActive ? .success : .warning
            )
            .accessibilityHidden(true)
            Spacer(minLength: DS.Space.md)
        }
        .padding(.horizontal, DS.Space.xxl)
        .frame(height: 40)
        .background(DS.Palette.surface)
        .accessibilityLabel(vm.scheduleTasksFooterLine)
    }

    @ViewBuilder
    private var editorScreen: some View {
        if let draft = vm.scheduleTaskDraft {
            BotScheduleTaskEditorView(
                draft: draft,
                bots: vm.fleet,
                onBack: { vm.scheduleTaskDraft = nil },
                onSave: { vm.saveScheduleTask($0) }
            )
        }
    }
}

private struct BotScheduleTaskCard: View {
    let item: BotScheduleTaskItem
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(DS.Palette.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    HStack(spacing: DS.Space.sm) {
                        Text(item.name)
                            .font(DS.Font.body.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(1)
                        if item.isEnabled {
                            DSPill("Active", tone: .success)
                        } else {
                            DSPill("Paused", tone: .neutral)
                        }
                    }
                    Text("\(item.botName) · @\(item.botHandle)")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Schedule")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.scheduleNote.isEmpty ? "When noted in the task" : item.scheduleNote)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                }
                .frame(width: 140, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Next run")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(item.isEnabled ? "While RemoteCode is open" : "Paused")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                }
                .frame(width: 140, alignment: .leading)

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

                Menu {
                    Button(item.isEnabled ? "Pause" : "Resume", action: onToggle)
                    Button("Run Now", action: onRunNow)
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
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.lg)
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("bots.scheduleTasks.task.\(item.id.value.uuidString.lowercased())")
    }
}

private struct BotScheduleTaskEditorView: View {
    @State private var draft: BotScheduleTaskDraft
    let bots: [BotDefinition]
    let onBack: () -> Void
    let onSave: (BotScheduleTaskDraft) -> Void

    init(
        draft: BotScheduleTaskDraft,
        bots: [BotDefinition],
        onBack: @escaping () -> Void,
        onSave: @escaping (BotScheduleTaskDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self.bots = bots
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
                        Picker("Bot", selection: $draft.botID) {
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
                    labeled("When") {
                        TextField("Weekdays 9:00", text: $draft.scheduleNote)
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("bots.scheduleTasks.editor.when")
                    }
                    labeled("Instruction") {
                        TextEditor(text: $draft.prompt)
                            .font(DS.Font.body)
                            .frame(minHeight: 140)
                            .accessibilityIdentifier("bots.scheduleTasks.editor.instruction")
                    }
                    Toggle("Active", isOn: $draft.isEnabled)
                        .accessibilityIdentifier("bots.scheduleTasks.editor.active")
                    Text(BotRoutineCopy.testRunHonestyCaption)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: 720, alignment: .leading)
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(title)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textTertiary)
            content()
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
