import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import DesignSystemKit

public enum ScheduledTaskStatusFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    public var id: String { rawValue }
}

public struct ScheduledTaskEditorDraft: Identifiable, Equatable {
    public let id: UUID
    public var originalCreatedAt: Date
    public var title: String
    public var prompt: String
    public var workspaceID: WorkspaceID?
    public var workspacePathSnapshot: String
    public var runAsUser: String
    public var runAsUID: UInt32
    public var provider: AgentProvider
    public var providerInstanceID: String
    public var model: String
    public var reasoningEffort: AgentReasoningEffort
    public var frequency: ScheduledTaskFrequency
    public var scheduledDate: Date
    public var intervalHours: Int
    public var localTime: Date
    public var weekdays: Set<ScheduledWeekday>
    public var monthlyDay: Int
    public var timeZoneIdentifier: String
    public var isEnabled: Bool

    public init(task: ScheduledTask? = nil, now: Date = Date()) {
        id = task?.id ?? UUID()
        originalCreatedAt = task?.createdAt ?? now
        title = task?.title ?? ""
        prompt = task?.prompt ?? ""
        workspaceID = task?.workspaceID
        workspacePathSnapshot = task?.workspacePathSnapshot ?? ""
        runAsUser = task?.runAsUser ?? NSUserName()
        runAsUID = task?.runAsUID ?? ScheduledSystemUserCatalog.user(named: NSUserName())?.uid ?? 0
        provider = task?.provider ?? .codex
        providerInstanceID = task?.providerInstanceID ?? "codex"
        model = task?.model ?? ""
        reasoningEffort = task?.reasoningEffort ?? .high
        timeZoneIdentifier = task?.timeZoneIdentifier ?? TimeZone.current.identifier
        isEnabled = task?.isEnabled ?? true
        scheduledDate = now.addingTimeInterval(60 * 60)
        intervalHours = 1
        localTime = now
        weekdays = [.monday]
        monthlyDay = 1
        frequency = .daily

        guard let recurrence = task?.recurrence else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        switch recurrence {
        case .once(let at):
            frequency = .once
            scheduledDate = at
        case .hourly(let anchor, let interval):
            frequency = .hourly
            scheduledDate = anchor
            intervalHours = interval
        case .daily(let time):
            frequency = .daily
            localTime = Self.date(for: time, calendar: calendar, now: now)
        case .weekdays(let time):
            frequency = .weekdays
            localTime = Self.date(for: time, calendar: calendar, now: now)
        case .weekly(let days, let time):
            frequency = .weekly
            weekdays = Set(days)
            localTime = Self.date(for: time, calendar: calendar, now: now)
        case .monthly(let day, let time):
            frequency = .monthly
            monthlyDay = day
            localTime = Self.date(for: time, calendar: calendar, now: now)
        }
    }

    public func makeTask(now: Date = Date()) throws -> ScheduledTask {
        guard let workspaceID else { throw ScheduledTaskPreflightError.invalidTask("Workspace is required.") }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw ScheduledTaskPreflightError.invalidTask("Select a valid IANA time zone.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let components = calendar.dateComponents([.hour, .minute], from: localTime)
        guard let time = ScheduledLocalTime(hour: components.hour ?? -1, minute: components.minute ?? -1) else {
            throw ScheduledTaskPreflightError.invalidTask("Select a valid local time.")
        }
        let recurrence: ScheduledTaskRecurrence
        switch frequency {
        case .once:
            recurrence = .once(at: scheduledDate)
        case .hourly:
            guard let value = ScheduledTaskRecurrence.makeHourly(anchor: scheduledDate, intervalHours: intervalHours) else {
                throw ScheduledTaskPreflightError.invalidTask("Hourly interval must be between 1 and 24.")
            }
            recurrence = value
        case .daily:
            recurrence = .daily(at: time)
        case .weekdays:
            recurrence = .weekdays(at: time)
        case .weekly:
            guard let value = ScheduledTaskRecurrence.makeWeekly(on: weekdays.sorted(), at: time) else {
                throw ScheduledTaskPreflightError.invalidTask("Select at least one weekday.")
            }
            recurrence = value
        case .monthly:
            guard let value = ScheduledTaskRecurrence.makeMonthly(day: monthlyDay, at: time) else {
                throw ScheduledTaskPreflightError.invalidTask("Monthly day must be between 1 and 28.")
            }
            recurrence = value
        }
        var task = ScheduledTask(
            id: id,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceID: workspaceID,
            workspacePathSnapshot: workspacePathSnapshot,
            runAsUser: runAsUser,
            runAsUID: runAsUID,
            provider: provider,
            providerInstanceID: providerInstanceID,
            model: model,
            reasoningEffort: reasoningEffort,
            recurrence: recurrence,
            timeZoneIdentifier: timeZoneIdentifier,
            isEnabled: isEnabled,
            createdAt: originalCreatedAt,
            updatedAt: now
        )
        task.nextRunAt = isEnabled ? task.calculatedNextRun(after: now.addingTimeInterval(-0.001)) : nil
        let errors = task.validationErrors()
        guard errors.isEmpty else { throw ScheduledTaskPreflightError.invalidTask(errors.joined(separator: " ")) }
        return task
    }

    private static func date(for time: ScheduledLocalTime, calendar: Calendar, now: Date) -> Date {
        calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) ?? now
    }
}

@MainActor
public final class ScheduledTasksViewModel: ObservableObject {
    @Published public private(set) var tasks: [ScheduledTask] = []
    @Published public private(set) var runs: [ScheduledTaskRun] = []
    @Published public private(set) var workspaces: [Workspace] = []
    @Published public private(set) var providers: [AgentProviderSnapshot] = []
    @Published public private(set) var users: [ScheduledSystemUser] = []
    @Published public private(set) var runCounts: [UUID: Int] = [:]
    @Published public var searchText: String = "" { didSet { reloadTasks() } }
    @Published public var statusFilter: ScheduledTaskStatusFilter = .all { didSet { reloadTasks() } }
    @Published public var selectedTaskID: UUID? { didSet { reloadRuns() } }
    @Published public var editorDraft: ScheduledTaskEditorDraft?
    @Published public var errorMessage: String?
    @Published public private(set) var serviceStatus: String = "Checking background scheduler…"
    @Published public private(set) var serviceRequiresApproval = false
    @Published public private(set) var isSavingEditor = false

    private let context: AppContext
    private let router: AppCommandRouter
    private let store: ScheduledTaskStore
    private let service = ScheduledTaskAgentServiceManager()

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        self.store = ScheduledTaskStore(db: context.db)
        reload()
    }

    public var selectedTask: ScheduledTask? { tasks.first { $0.id == selectedTaskID } }

    public func reload() {
        do {
            workspaces = try router.listWorkspaces()
            users = ScheduledSystemUserCatalog.eligibleUsers()
            reloadTasks()
            reloadRuns()
            reloadServiceStatus()
        } catch { errorMessage = String(describing: error) }
        Task { [weak self] in
            guard let self else { return }
            providers = await router.listAgentProviderSnapshots()
        }
    }

    public func createTask() {
        var draft = ScheduledTaskEditorDraft()
        draft.workspaceID = workspaces.first?.id
        draft.workspacePathSnapshot = workspaces.first?.cwd ?? ""
        if let user = users.first(where: { $0.name == draft.runAsUser }) {
            draft.runAsUID = user.uid
        }
        if let provider = providers.first(where: { $0.enabled && $0.installed }) ?? providers.first {
            draft.provider = provider.provider
            draft.providerInstanceID = provider.id
            draft.model = provider.models.first?.id ?? ""
            draft.reasoningEffort = provider.models.first?.supportedReasoningEfforts.first ?? .high
        }
        editorDraft = draft
    }

    public func edit(_ task: ScheduledTask) { editorDraft = ScheduledTaskEditorDraft(task: task) }

    public func saveEditor(_ draft: ScheduledTaskEditorDraft) {
        guard !isSavingEditor else { return }
        isSavingEditor = true
        Task { [weak self] in
            guard let self else { return }
            defer { isSavingEditor = false }
            do {
                let task = try draft.makeTask()
                _ = try await ScheduledTaskExecutor(context: context, router: router).preflight(task)
                var persisted = task
                if task.isEnabled {
                    try service.register()
                    if service.status == .requiresApproval {
                        persisted.isEnabled = false
                        persisted.nextRunAt = nil
                    }
                }
                try store.save(persisted)
                editorDraft = nil
                selectedTaskID = persisted.id
                reloadTasks()
                reloadRuns()
                reloadServiceStatus()
                if task.isEnabled, service.status == .requiresApproval {
                    errorMessage = "Task saved paused. Approve RemoteCode in System Settings > General > Login Items, then resume it."
                } else if persisted.isEnabled {
                    service.wake { _ in }
                }
            } catch { errorMessage = String(describing: error) }
        }
    }

    public func toggle(_ task: ScheduledTask) {
        if task.isEnabled {
            do {
                try store.setEnabled(id: task.id, enabled: false, nextRunAt: nil)
                reloadTasks()
            } catch { errorMessage = String(describing: error) }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await ScheduledTaskExecutor(context: context, router: router).preflight(task)
                try service.register()
                reloadServiceStatus()
                guard service.status != .requiresApproval else {
                    errorMessage = "Approve RemoteCode in System Settings > General > Login Items before resuming this task."
                    return
                }
                let next = task.calculatedNextRun(after: Date().addingTimeInterval(-0.001))
                try store.setEnabled(id: task.id, enabled: true, nextRunAt: next)
                service.wake { _ in }
                reloadTasks()
            } catch { errorMessage = String(describing: error) }
        }
    }

    public func openServiceSettings() { service.openSystemSettings() }

    private func reloadServiceStatus() {
        serviceStatus = service.statusDescription
        serviceRequiresApproval = service.status == .requiresApproval
    }

    public func runNow(_ task: ScheduledTask) {
        do { try service.register() } catch {
            errorMessage = "Background scheduler registration failed: \(error.localizedDescription)"
            return
        }
        reloadServiceStatus()
        guard service.status != .requiresApproval else {
            errorMessage = "Approve RemoteCode in System Settings > General > Login Items before running this task."
            return
        }
        service.wake(taskID: task.id) { [weak self] result in
            if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
            self?.reloadRuns()
            self?.reloadServiceStatus()
        }
    }

    public func delete(_ task: ScheduledTask) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete \"\(task.title)\"?"
        alert.informativeText = "The schedule and its run history will be deleted. Agent threads created by prior runs are preserved."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.delete(id: task.id)
            if selectedTaskID == task.id { selectedTaskID = nil }
            reloadTasks()
            reloadRuns()
        } catch { errorMessage = String(describing: error) }
    }

    public func openThread(_ run: ScheduledTaskRun) {
        guard let threadID = run.threadID else { return }
        do { _ = try router.openAgentThread(thread: threadID, markRead: true) }
        catch { errorMessage = String(describing: error) }
    }

    public func providerSnapshots(for provider: AgentProvider) -> [AgentProviderSnapshot] {
        providers.filter { $0.provider == provider }
    }

    public func models(provider: AgentProvider, instanceID: String) -> [AgentModelDescriptor] {
        providers.first { $0.provider == provider && $0.id == instanceID }?.models ?? []
    }

    private func reloadTasks() {
        do {
            let matching = try store.list(search: searchText)
            switch statusFilter {
            case .all: tasks = matching
            case .active: tasks = matching.filter(\.isEnabled)
            case .paused: tasks = matching.filter { !$0.isEnabled }
            }
            runCounts = try store.runCounts()
            if selectedTaskID == nil { selectedTaskID = tasks.first?.id }
            if let selectedTaskID, !tasks.contains(where: { $0.id == selectedTaskID }) { self.selectedTaskID = tasks.first?.id }
        } catch { errorMessage = String(describing: error) }
    }

    private func reloadRuns() {
        do { runs = try store.listRuns(taskID: selectedTaskID, limit: 200) }
        catch { errorMessage = String(describing: error) }
    }
}

public struct ScheduledTasksRootView: View {
    @ObservedObject private var vm: ScheduledTasksViewModel
    @State private var expandedRunIDs = Set<UUID>()

    public init(vm: ScheduledTasksViewModel) { self.vm = vm }

    public var body: some View {
        VStack(spacing: 0) {
            header
            serviceBanner
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            HSplitView {
                taskList
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                    .background(DS.Palette.sidebar)
                detail
                    .frame(minWidth: 540, maxWidth: .infinity)
                    .background(DS.Palette.bg)
            }
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            footer
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(DS.Palette.bg)
        .sheet(item: $vm.editorDraft) { draft in
            ScheduledTaskEditorView(
                draft: draft,
                vm: vm,
                onCancel: { vm.editorDraft = nil },
                onSave: { vm.saveEditor($0) }
            )
        }
        .alert("Scheduled Tasks", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear { vm.reload() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            HStack(spacing: DS.Space.md) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 36, height: 36)
                    .background(DS.Palette.accent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Scheduled Tasks")
                        .font(DS.Font.title2.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text("Fresh full-access Agent runs on a durable local schedule.")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                }
            }
            Spacer(minLength: DS.Space.lg)
            Button {
                vm.createTask()
            } label: {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(DSPrimaryButtonStyle())
            .accessibilityIdentifier("scheduledTasks.new")
            .accessibilityHint("Create a new scheduled agent task")
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.vertical, DS.Space.xl)
        .dsBar(edge: .bottom)
    }

    @ViewBuilder
    private var serviceBanner: some View {
        if vm.serviceRequiresApproval {
            HStack(alignment: .center, spacing: DS.Space.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DS.Palette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text("Background scheduler needs Login Items approval")
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text(vm.serviceStatus)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer(minLength: DS.Space.md)
                Button("Open Login Items") { vm.openServiceSettings() }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.openLoginItems")
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.lg)
            .background(DS.Palette.warning.opacity(0.10))
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Palette.warning.opacity(0.35)).frame(height: DS.Border.hairline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Background scheduler needs Login Items approval. \(vm.serviceStatus)")
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.sm) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundColor(DS.Palette.textTertiary)
                .accessibilityHidden(true)
            Text(vm.serviceStatus)
                .foregroundColor(DS.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: DS.Space.md)
            Text("Automatic runs continue when this window and RemoteCode are closed.")
                .foregroundColor(DS.Palette.textTertiary)
                .lineLimit(1)
        }
        .font(DS.Font.caption)
        .padding(.horizontal, DS.Space.xxl)
        .frame(height: 40)
        .background(DS.Palette.surface)
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                TextField("Search tasks", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .foregroundColor(DS.Palette.text)
                    .accessibilityIdentifier("scheduledTasks.search")
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.md)
            .background(DS.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .padding(.horizontal, DS.Space.lg)
            .padding(.top, DS.Space.lg)
            .padding(.bottom, DS.Space.md)

            Picker("Status", selection: $vm.statusFilter) {
                ForEach(ScheduledTaskStatusFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, DS.Space.lg)
            .padding(.bottom, DS.Space.md)
            .accessibilityIdentifier("scheduledTasks.statusFilter")
            .accessibilityLabel("Filter tasks by status")

            if vm.tasks.isEmpty {
                DSEmptyState(
                    icon: "calendar.badge.clock",
                    title: vm.searchText.isEmpty ? "No scheduled tasks" : "No matching tasks",
                    subtitle: vm.searchText.isEmpty
                        ? "Create a task to run an Agent automatically while RemoteCode is closed."
                        : "Try another search or clear the status filter.",
                    background: DS.Palette.sidebar
                )
            } else {
                List(selection: $vm.selectedTaskID) {
                    ForEach(vm.tasks) { task in
                        ScheduledTaskRow(
                            task: task,
                            workspaceName: vm.workspaces.first { $0.id == task.workspaceID }?.name ?? "Missing workspace",
                            runCount: vm.runCounts[task.id, default: 0],
                            isSelected: vm.selectedTaskID == task.id
                        )
                        .tag(task.id)
                        .listRowBackground(
                            (vm.selectedTaskID == task.id ? DS.Palette.selection : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(DS.Palette.sidebar)
                .accessibilityIdentifier("scheduledTasks.list")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let task = vm.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    detailHero(task)
                    configurationGrid(task)
                    promptCard(task)
                    historySection(task)
                }
                .padding(DS.Space.xxl)
            }
            .accessibilityIdentifier("scheduledTasks.detail")
        } else {
            DSEmptyState(
                icon: "calendar.badge.clock",
                title: "Select a task",
                subtitle: "Choose a schedule on the left to inspect configuration and run history."
            )
        }
    }

    private func detailHero(_ task: ScheduledTask) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.sm) {
                Text(task.title)
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                    .textSelection(.enabled)
                HStack(spacing: DS.Space.sm) {
                    DSPill(task.isEnabled ? "Active" : "Paused", tone: task.isEnabled ? .success : .neutral)
                    DSPill(task.recurrence.summaryLabel, tone: .accent)
                    DSPill("Full access", tone: .warning)
                }
                Text(task.nextRunAt.map { "Next run · \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "No next run while paused")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            Spacer(minLength: DS.Space.lg)
            HStack(spacing: DS.Space.sm) {
                Button(task.isEnabled ? "Pause" : "Resume") { vm.toggle(task) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.toggle")
                Button("Run Now") { vm.runNow(task) }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.runNow")
                Menu {
                    Button("Edit") { vm.edit(task) }
                    Divider()
                    Button("Delete", role: .destructive) { vm.delete(task) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .help("More actions")
                .accessibilityLabel("More actions")
            }
        }
        .dsPanel(padding: DS.Space.xl, raised: true)
    }

    private func configurationGrid(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Configuration")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.md), GridItem(.flexible(), spacing: DS.Space.md)], spacing: DS.Space.md) {
                configTile(icon: "folder", label: "Workspace", value: vm.workspaces.first { $0.id == task.workspaceID }?.name ?? "Missing workspace")
                configTile(icon: "person", label: "Run as", value: task.runAsUser)
                configTile(icon: "cpu", label: "Provider", value: "\(task.provider.rawValue.capitalized) · \(task.providerInstanceID)")
                configTile(icon: "brain", label: "Model", value: "\(task.model) · \(task.reasoningEffort.displayName)")
                configTile(icon: "globe", label: "Time zone", value: task.timeZoneIdentifier)
                configTile(icon: "clock", label: "Next run", value: task.nextRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            }
            .padding(.horizontal, DS.Space.lg)
        }
    }

    private func configTile(icon: String, label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.accent)
                .frame(width: 24, height: 24)
                .background(DS.Palette.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(label.uppercased())
                    .font(DS.Font.caption2.weight(.semibold))
                    .tracking(0.5)
                    .foregroundColor(DS.Palette.textTertiary)
                Text(value)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.text)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .dsPanel(padding: DS.Space.lg)
    }

    private func promptCard(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Prompt")
            Text(task.prompt)
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsPanel(padding: DS.Space.xl)
                .padding(.horizontal, DS.Space.lg)
        }
    }

    private func historySection(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            DSSectionHeaderG("Run history") {
                Button {
                    vm.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(DS.Palette.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Refresh run history")
                .accessibilityLabel("Refresh run history")
            }
            runHistory(task)
                .padding(.horizontal, DS.Space.lg)
        }
    }

    @ViewBuilder
    private func runHistory(_ task: ScheduledTask) -> some View {
        if vm.runs.isEmpty {
            Text("No runs yet. Use Run Now or wait for the next scheduled occurrence.")
                .font(DS.Font.body)
                .foregroundColor(DS.Palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsPanel(padding: DS.Space.xl)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(vm.runs.enumerated()), id: \.element.id) { index, run in
                    runRow(task: task, run: run)
                    if index != vm.runs.count - 1 {
                        Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                    }
                }
            }
            .background(DS.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
            )
            .accessibilityIdentifier("scheduledTasks.history")
        }
    }

    private func runRow(task: ScheduledTask, run: ScheduledTaskRun) -> some View {
        HStack(alignment: .top, spacing: DS.Space.lg) {
            Image(systemName: runIcon(run.status))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(runColor(run.status))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.sm) {
                    Text(run.status.rawValue.capitalized)
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    DSPill(run.trigger == .catchUp ? "Catch-up" : run.trigger.rawValue.capitalized, tone: .neutral)
                }
                Text((run.startedAt ?? run.queuedAt).formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                if let started = run.startedAt, let finished = run.finishedAt {
                    Text("Duration \(finished.timeIntervalSince(started).formatted(.number.precision(.fractionLength(1))))s")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                }
                if let code = run.errorCode {
                    Text(code)
                        .font(DS.Font.caption2.monospaced())
                        .foregroundColor(DS.Palette.textSecondary)
                }
                if let error = run.errorSummary {
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.danger)
                        .lineLimit(expandedRunIDs.contains(run.id) ? nil : 2)
                    Button(expandedRunIDs.contains(run.id) ? "Hide details" : "Show details") {
                        if !expandedRunIDs.insert(run.id).inserted { expandedRunIDs.remove(run.id) }
                    }
                    .buttonStyle(.plain)
                    .font(DS.Font.caption.weight(.semibold))
                    .foregroundColor(DS.Palette.accent)
                }
            }
            Spacer(minLength: DS.Space.md)
            HStack(spacing: DS.Space.sm) {
                if run.status == .failed {
                    Button("Retry") { vm.runNow(task) }
                        .buttonStyle(DSSecondaryButtonStyle())
                }
                if run.threadID != nil {
                    Button("Open Agent") { vm.openThread(run) }
                        .buttonStyle(DSSecondaryButtonStyle())
                }
            }
        }
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.lg)
        .accessibilityElement(children: .combine)
    }

    private func runIcon(_ status: ScheduledTaskRunStatus) -> String {
        switch status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        case .skipped: return "forward.end.circle.fill"
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        }
    }

    private func runColor(_ status: ScheduledTaskRunStatus) -> Color {
        switch status {
        case .completed: return DS.Palette.success
        case .failed: return DS.Palette.danger
        case .cancelled, .skipped: return DS.Palette.textTertiary
        case .queued: return DS.Palette.warning
        case .running: return DS.Palette.accent
        }
    }
}

private struct ScheduledTaskRow: View {
    let task: ScheduledTask
    let workspaceName: String
    let runCount: Int
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.md) {
            Image(systemName: task.isEnabled ? "calendar.badge.clock" : "pause.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(task.isEnabled ? DS.Palette.accent : DS.Palette.textTertiary)
                .frame(width: 22, height: 22)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                HStack(spacing: DS.Space.sm) {
                    Text(task.title)
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    DSPill(task.isEnabled ? "Active" : "Paused", tone: task.isEnabled ? .success : .neutral)
                }
                Text(task.nextRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "Paused")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                Text("\(workspaceName) · \(task.runAsUser)")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
                Text("\(task.provider.rawValue.capitalized) · \(task.model) · \(runCount) run\(runCount == 1 ? "" : "s")")
                    .font(DS.Font.caption2)
                    .foregroundColor(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, DS.Space.sm)
        .padding(.horizontal, DS.Space.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scheduledTasks.task.\(task.id.uuidString.lowercased())")
        .accessibilityValue(task.isEnabled ? "Active" : "Paused")
    }
}

private struct ScheduledTaskEditorView: View {
    @State private var draft: ScheduledTaskEditorDraft
    @ObservedObject var vm: ScheduledTasksViewModel
    let onCancel: () -> Void
    let onSave: (ScheduledTaskEditorDraft) -> Void

    init(
        draft: ScheduledTaskEditorDraft,
        vm: ScheduledTasksViewModel,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ScheduledTaskEditorDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self.vm = vm
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(draft.title.isEmpty ? "New Scheduled Task" : "Edit Scheduled Task")
                        .font(DS.Font.title2.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text("Frozen configuration is used for every occurrence.")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textSecondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.isSavingEditor)
                    .keyboardShortcut(.cancelAction)
                Button(vm.isSavingEditor ? "Checking…" : "Save") { confirmAndSave() }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .disabled(vm.isSavingEditor)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("scheduledTasks.editor.save")
            }
            .padding(.horizontal, DS.Space.xxl)
            .padding(.vertical, DS.Space.xl)
            .dsBar(edge: .bottom)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    editorSection("Basics") {
                        labeledField("Title") {
                            TextField("Nightly audit", text: $draft.title)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("scheduledTasks.editor.title")
                        }
                        labeledField("Workspace") {
                            Picker("Workspace", selection: $draft.workspaceID) {
                                Text("Select a workspace").tag(WorkspaceID?.none)
                                ForEach(vm.workspaces) { workspace in
                                    Text(workspace.name).tag(Optional(workspace.id))
                                }
                            }
                            .labelsHidden()
                            .onChange(of: draft.workspaceID) { _, id in
                                draft.workspacePathSnapshot = vm.workspaces.first { $0.id == id }?.cwd ?? ""
                            }
                        }
                        labeledField("System user") {
                            Picker("System user", selection: $draft.runAsUser) {
                                ForEach(vm.users) { user in
                                    Text("\(user.name) (uid \(user.uid))").tag(user.name)
                                }
                            }
                            .labelsHidden()
                            .onChange(of: draft.runAsUser) { _, name in
                                draft.runAsUID = vm.users.first { $0.name == name }?.uid ?? 0
                            }
                        }
                    }

                    editorSection("Agent") {
                        labeledField("Provider") {
                            Picker("Provider", selection: $draft.provider) {
                                ForEach(AgentProvider.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: draft.provider) { _, provider in
                                if let snapshot = vm.providerSnapshots(for: provider).first {
                                    draft.providerInstanceID = snapshot.id
                                    draft.model = snapshot.models.first?.id ?? ""
                                }
                            }
                        }
                        labeledField("Instance") {
                            Picker("Provider instance", selection: $draft.providerInstanceID) {
                                ForEach(vm.providerSnapshots(for: draft.provider)) { Text($0.displayName).tag($0.id) }
                            }
                            .labelsHidden()
                        }
                        labeledField("Model") {
                            Picker("Model", selection: $draft.model) {
                                ForEach(vm.models(provider: draft.provider, instanceID: draft.providerInstanceID), id: \.id) {
                                    Text($0.label).tag($0.id)
                                }
                                if !draft.model.isEmpty,
                                   !vm.models(provider: draft.provider, instanceID: draft.providerInstanceID).contains(where: { $0.id == draft.model }) {
                                    Text(draft.model).tag(draft.model)
                                }
                            }
                            .labelsHidden()
                        }
                        labeledField("Reasoning") {
                            Picker("Reasoning", selection: $draft.reasoningEffort) {
                                ForEach(AgentReasoningEffort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                        }
                    }

                    editorSection("Schedule") {
                        labeledField("Frequency") {
                            Picker("Frequency", selection: $draft.frequency) {
                                ForEach(ScheduledTaskFrequency.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                        }
                        scheduleControls
                        labeledField("Time zone") {
                            Picker("Time zone", selection: $draft.timeZoneIdentifier) {
                                ForEach(Self.commonTimeZones, id: \.self) {
                                    Text($0.replacingOccurrences(of: "_", with: " ")).tag($0)
                                }
                                if !Self.commonTimeZones.contains(draft.timeZoneIdentifier) {
                                    Text(draft.timeZoneIdentifier).tag(draft.timeZoneIdentifier)
                                }
                            }
                            .labelsHidden()
                        }
                        Toggle("Enabled after save", isOn: $draft.isEnabled)
                            .toggleStyle(.switch)
                            .foregroundColor(DS.Palette.text)
                    }

                    editorSection("Prompt") {
                        TextEditor(text: $draft.prompt)
                            .font(DS.Font.body)
                            .foregroundColor(DS.Palette.text)
                            .frame(minHeight: 140)
                            .padding(DS.Space.md)
                            .background(DS.Palette.bg)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                            )
                            .accessibilityIdentifier("scheduledTasks.editor.prompt")
                            .accessibilityLabel("Prompt")
                    }

                    HStack(alignment: .top, spacing: DS.Space.md) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundColor(DS.Palette.warning)
                            .accessibilityHidden(true)
                        Text("Scheduled tasks always run with Full Access. RemoteCode may read, edit, execute, and delete files available to the selected system user. Review the prompt and workspace carefully.")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(DS.Space.lg)
                    .background(DS.Palette.warning.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(DS.Palette.warning.opacity(0.35), lineWidth: DS.Border.hairline)
                    )
                }
                .padding(DS.Space.xxl)
            }
            .background(DS.Palette.bg)
        }
        .frame(width: 720, height: 780)
        .background(DS.Palette.bg)
    }

    private func editorSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text(title.uppercased())
                .font(DS.Font.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundColor(DS.Palette.textTertiary)
            VStack(alignment: .leading, spacing: DS.Space.lg) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsPanel(padding: DS.Space.xl, raised: true)
        }
    }

    private func labeledField<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(label)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.textSecondary)
            content()
        }
    }

    @ViewBuilder
    private var scheduleControls: some View {
        switch draft.frequency {
        case .once:
            labeledField("Run at") {
                DatePicker("Run at", selection: $draft.scheduledDate)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        case .hourly:
            labeledField("Interval") {
                Stepper("Every \(draft.intervalHours) hour\(draft.intervalHours == 1 ? "" : "s")", value: $draft.intervalHours, in: 1...24)
                    .foregroundColor(DS.Palette.text)
            }
        case .daily, .weekdays:
            labeledField("Local time") {
                DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        case .weekly:
            labeledField("Local time") {
                DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            labeledField("Days") {
                HStack(spacing: DS.Space.xs) {
                    ForEach(ScheduledWeekday.allCases, id: \.self) { day in
                        Toggle(dayLabel(day), isOn: Binding(
                            get: { draft.weekdays.contains(day) },
                            set: { enabled in
                                if enabled { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) }
                            }
                        ))
                        .toggleStyle(.button)
                        .font(DS.Font.caption.weight(.semibold))
                    }
                }
            }
        case .monthly:
            labeledField("Day of month") {
                Stepper("Day \(draft.monthlyDay)", value: $draft.monthlyDay, in: 1...28)
                    .foregroundColor(DS.Palette.text)
            }
            labeledField("Local time") {
                DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
    }

    private func confirmAndSave() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Allow this task to run with Full Access?"
        alert.informativeText = "Each occurrence starts a fresh Agent thread as \(draft.runAsUser) in the selected workspace. It may execute commands without further approval."
        alert.addButton(withTitle: "Save Full-Access Task")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { onSave(draft) }
    }

    private func dayLabel(_ day: ScheduledWeekday) -> String {
        switch day {
        case .sunday: return "S"
        case .monday: return "M"
        case .tuesday: return "T"
        case .wednesday: return "W"
        case .thursday: return "T"
        case .friday: return "F"
        case .saturday: return "S"
        }
    }

    private static let commonTimeZones: [String] = {
        let preferred = [
            TimeZone.current.identifier,
            "UTC",
            "America/Asuncion",
            "America/New_York",
            "America/Los_Angeles",
            "America/Sao_Paulo",
            "Europe/London",
            "Europe/Berlin",
            "Asia/Tokyo"
        ]
        var seen = Set<String>()
        return preferred.filter { TimeZone(identifier: $0) != nil && seen.insert($0).inserted }
    }()
}

@MainActor
public final class ScheduledTasksWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: ScheduledTasksViewModel

    public init(context: AppContext, router: AppCommandRouter) {
        self.viewModel = ScheduledTasksViewModel(context: context, router: router)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scheduled Tasks"
        window.minSize = NSSize(width: 980, height: 680)
        window.center()
        window.backgroundColor = DS.NS.bg
        window.contentView = NSHostingView(rootView: ScheduledTasksRootView(vm: viewModel))
        window.setAccessibilityIdentifier("scheduledTasks.window")
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public func show() {
        viewModel.reload()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private extension ScheduledTaskRecurrence {
    var summaryLabel: String {
        switch self {
        case .once: return "Once"
        case .hourly(let _, let hours): return hours == 1 ? "Hourly" : "Every \(hours)h"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}
