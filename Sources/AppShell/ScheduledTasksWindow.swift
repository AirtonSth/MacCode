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
            Divider()
            HSplitView {
                taskList.frame(minWidth: 310, idealWidth: 350, maxWidth: 430)
                detail.frame(minWidth: 520, maxWidth: .infinity)
            }
            Divider()
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text(vm.serviceStatus)
                if vm.serviceRequiresApproval {
                    Button("Open Login Items") { vm.openServiceSettings() }
                        .accessibilityIdentifier("scheduledTasks.openLoginItems")
                }
                Spacer()
                Text("Automatic runs continue when this window and RemoteCode are closed.")
                    .foregroundColor(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 16)
            .frame(height: 36)
        }
        .frame(minWidth: 940, minHeight: 650)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Scheduled Tasks").font(.system(size: 22, weight: .semibold))
                Text("Run a fresh Agent thread on a reliable local schedule.").font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Button { vm.createTask() } label: { Label("New Task", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("scheduledTasks.new")
        }
        .padding(16)
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search tasks", text: $vm.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("scheduledTasks.search")
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
            Picker("Status", selection: $vm.statusFilter) {
                ForEach(ScheduledTaskStatusFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("scheduledTasks.statusFilter")
            if vm.tasks.isEmpty {
                ContentUnavailableView(
                    vm.searchText.isEmpty ? "No scheduled tasks" : "No matching tasks",
                    systemImage: "calendar.badge.clock",
                    description: Text(vm.searchText.isEmpty ? "Create a task to run an Agent automatically." : "Try another search.")
                )
            } else {
                List(selection: $vm.selectedTaskID) {
                    ForEach(vm.tasks) { task in
                        ScheduledTaskRow(
                            task: task,
                            workspaceName: vm.workspaces.first { $0.id == task.workspaceID }?.name ?? "Missing workspace",
                            runCount: vm.runCounts[task.id, default: 0]
                        ).tag(task.id)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier("scheduledTasks.list")
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let task = vm.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(task.title).font(.title2.weight(.semibold))
                            Text(task.isEnabled ? "Active" : "Paused")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(task.isEnabled ? .green : .secondary)
                        }
                        Spacer()
                        Button(task.isEnabled ? "Pause" : "Resume") { vm.toggle(task) }
                            .accessibilityIdentifier("scheduledTasks.toggle")
                        Button("Run Now") { vm.runNow(task) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("scheduledTasks.runNow")
                        Menu {
                            Button("Edit") { vm.edit(task) }
                            Divider()
                            Button("Delete", role: .destructive) { vm.delete(task) }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    taskConfiguration(task)
                    Text("Prompt").font(.headline)
                    Text(task.prompt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Text("Run history").font(.headline)
                        Spacer()
                        Button { vm.reload() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh run history")
                    }
                    runHistory(task)
                }
                .padding(20)
            }
            .accessibilityIdentifier("scheduledTasks.detail")
        } else {
            ContentUnavailableView("Select a task", systemImage: "calendar.badge.clock")
        }
    }

    private func taskConfiguration(_ task: ScheduledTask) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 9) {
            detailRow("Workspace", vm.workspaces.first { $0.id == task.workspaceID }?.name ?? "Missing workspace")
            detailRow("Run as", task.runAsUser)
            detailRow("Provider", "\(task.provider.rawValue.capitalized) · \(task.providerInstanceID)")
            detailRow("Model", "\(task.model) · \(task.reasoningEffort.displayName)")
            detailRow("Time zone", task.timeZoneIdentifier)
            detailRow("Next run", task.nextRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
            detailRow("Access", "Full access")
        }
        .padding(14)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    private func detailRow(_ key: String, _ value: String) -> some View {
        GridRow {
            Text(key).foregroundColor(.secondary).frame(width: 90, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder private func runHistory(_ task: ScheduledTask) -> some View {
        if vm.runs.isEmpty {
            Text("No runs yet.").foregroundColor(.secondary).padding(.vertical, 12)
        } else {
            VStack(spacing: 0) {
                ForEach(vm.runs) { run in
                    HStack(spacing: 10) {
                        Image(systemName: runIcon(run.status)).foregroundStyle(runColor(run.status))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(run.status.rawValue.capitalized).font(.body.weight(.medium))
                            Text((run.startedAt ?? run.queuedAt).formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundColor(.secondary)
                            Text(run.trigger == .catchUp ? "Catch-up" : run.trigger.rawValue.capitalized)
                                .font(.caption2).foregroundColor(.secondary)
                            if let started = run.startedAt, let finished = run.finishedAt {
                                Text("Duration: \(finished.timeIntervalSince(started).formatted(.number.precision(.fractionLength(1))))s")
                                    .font(.caption2).foregroundColor(.secondary)
                            }
                            if let code = run.errorCode {
                                Text(code).font(.caption2.monospaced()).foregroundColor(.secondary)
                            }
                            if let error = run.errorSummary {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .lineLimit(expandedRunIDs.contains(run.id) ? nil : 2)
                                Button(expandedRunIDs.contains(run.id) ? "Hide details" : "Show details") {
                                    if !expandedRunIDs.insert(run.id).inserted { expandedRunIDs.remove(run.id) }
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                            }
                        }
                        Spacer()
                        if run.status == .failed { Button("Retry") { vm.runNow(task) } }
                        if run.threadID != nil { Button("Open Agent") { vm.openThread(run) } }
                    }
                    .padding(.vertical, 9)
                    if run.id != vm.runs.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("scheduledTasks.history")
        }
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
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        case .skipped: return .secondary
        case .queued: return .orange
        case .running: return .blue
        }
    }
}

private struct ScheduledTaskRow: View {
    let task: ScheduledTask
    let workspaceName: String
    let runCount: Int
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: task.isEnabled ? "calendar.badge.clock" : "pause.circle")
                .foregroundStyle(task.isEnabled ? .blue : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title).font(.body.weight(.medium)).lineLimit(1)
                Text(task.nextRunAt?.formatted(date: .abbreviated, time: .shortened) ?? "Paused")
                    .font(.caption).foregroundColor(.secondary)
                Text("\(workspaceName) · \(task.runAsUser)")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
                Text("\(task.provider.rawValue.capitalized) · \(task.model) · \(runCount) run\(runCount == 1 ? "" : "s")")
                    .font(.caption2).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scheduledTasks.task.\(task.id.uuidString.lowercased())")
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
            HStack {
                Text(draft.title.isEmpty ? "New Scheduled Task" : "Edit Scheduled Task").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel", action: onCancel).disabled(vm.isSavingEditor)
                    .keyboardShortcut(.cancelAction)
                Button(vm.isSavingEditor ? "Checking…" : "Save", action: confirmAndSave).buttonStyle(.borderedProminent)
                    .disabled(vm.isSavingEditor)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("scheduledTasks.editor.save")
            }
            .padding(18)
            Divider()
            Form {
                TextField("Title", text: $draft.title)
                    .accessibilityIdentifier("scheduledTasks.editor.title")
                Picker("Workspace", selection: $draft.workspaceID) {
                    Text("Select a workspace").tag(WorkspaceID?.none)
                    ForEach(vm.workspaces) { workspace in Text(workspace.name).tag(Optional(workspace.id)) }
                }
                .onChange(of: draft.workspaceID) { _, id in
                    draft.workspacePathSnapshot = vm.workspaces.first { $0.id == id }?.cwd ?? ""
                }
                Picker("System user (sudo -u)", selection: $draft.runAsUser) {
                    ForEach(vm.users) { user in Text("\(user.name) (uid \(user.uid))").tag(user.name) }
                }
                .onChange(of: draft.runAsUser) { _, name in
                    draft.runAsUID = vm.users.first { $0.name == name }?.uid ?? 0
                }
                Picker("Provider", selection: $draft.provider) {
                    ForEach(AgentProvider.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .onChange(of: draft.provider) { _, provider in
                    if let snapshot = vm.providerSnapshots(for: provider).first {
                        draft.providerInstanceID = snapshot.id
                        draft.model = snapshot.models.first?.id ?? ""
                    }
                }
                Picker("Provider instance", selection: $draft.providerInstanceID) {
                    ForEach(vm.providerSnapshots(for: draft.provider)) { Text($0.displayName).tag($0.id) }
                }
                Picker("Model", selection: $draft.model) {
                    ForEach(vm.models(provider: draft.provider, instanceID: draft.providerInstanceID), id: \.id) { Text($0.label).tag($0.id) }
                    if !draft.model.isEmpty && !vm.models(provider: draft.provider, instanceID: draft.providerInstanceID).contains(where: { $0.id == draft.model }) {
                        Text(draft.model).tag(draft.model)
                    }
                }
                Picker("Reasoning", selection: $draft.reasoningEffort) {
                    ForEach(AgentReasoningEffort.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Frequency", selection: $draft.frequency) {
                    ForEach(ScheduledTaskFrequency.allCases) { Text($0.displayName).tag($0) }
                }
                scheduleControls
                Picker("Time zone", selection: $draft.timeZoneIdentifier) {
                    ForEach(Self.commonTimeZones, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                    if !Self.commonTimeZones.contains(draft.timeZoneIdentifier) { Text(draft.timeZoneIdentifier).tag(draft.timeZoneIdentifier) }
                }
                Toggle("Enabled", isOn: $draft.isEnabled)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Prompt")
                    TextEditor(text: $draft.prompt).font(.body).frame(minHeight: 130)
                        .accessibilityIdentifier("scheduledTasks.editor.prompt")
                }
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.shield.fill").foregroundColor(.orange)
                    Text("Scheduled tasks run with Full Access. RemoteCode may read, edit, execute, and delete files available to the selected system user. Review the prompt and workspace carefully.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(10).background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
        }
        .frame(width: 670, height: 720)
    }

    @ViewBuilder private var scheduleControls: some View {
        switch draft.frequency {
        case .once:
            DatePicker("Run at", selection: $draft.scheduledDate)
        case .hourly:
            Stepper("Every \(draft.intervalHours) hour\(draft.intervalHours == 1 ? "" : "s")", value: $draft.intervalHours, in: 1...24)
        case .daily, .weekdays:
            DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
        case .weekly:
            DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
            HStack {
                Text("Days")
                Spacer()
                ForEach(ScheduledWeekday.allCases, id: \.self) { day in
                    Toggle(dayLabel(day), isOn: Binding(
                        get: { draft.weekdays.contains(day) },
                        set: { enabled in if enabled { draft.weekdays.insert(day) } else { draft.weekdays.remove(day) } }
                    )).toggleStyle(.button)
                }
            }
        case .monthly:
            Stepper("Day \(draft.monthlyDay)", value: $draft.monthlyDay, in: 1...28)
            DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
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
        let preferred = [TimeZone.current.identifier, "UTC", "America/Asuncion", "America/New_York", "America/Los_Angeles", "America/Sao_Paulo", "Europe/London", "Europe/Berlin", "Asia/Tokyo"]
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
            contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Scheduled Tasks"
        window.minSize = NSSize(width: 940, height: 650)
        window.center()
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
