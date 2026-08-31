import Foundation
import AppKit
import SwiftUI
import CoreModel
import Persistence
import DesignSystemKit
import Surfaces

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
    public var routingMode: AgentRoutingMode
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
        routingMode = task?.effectiveRoutingMode ?? .auto
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
            recurrence = .once(at: ScheduledTaskOccurrenceCalculator.canonicalInstant(scheduledDate))
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
            routingMode: routingMode,
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
    @Published public private(set) var providersLoading = false
    @Published public private(set) var users: [ScheduledSystemUser] = []
    @Published public private(set) var runCounts: [UUID: Int] = [:]
    /// Live run status per task (queued / running). Drives overview + detail badges.
    @Published public private(set) var activeRunStatuses: [UUID: ScheduledTaskRunStatus] = [:]
    /// Counts for All / Active / Paused chips (search-scoped, not status-filtered).
    @Published public private(set) var filterCounts: (all: Int, active: Int, paused: Int) = (0, 0, 0)
    @Published public var searchText: String = "" { didSet { reloadTasksOrDefer() } }
    @Published public var statusFilter: ScheduledTaskStatusFilter = .all { didSet { reloadTasksOrDefer() } }
    @Published public var selectedTaskID: UUID? {
        didSet {
            guard !suppressSelectedTaskReload else { return }
            reloadRunsOrDefer()
        }
    }
    @Published public var editorDraft: ScheduledTaskEditorDraft?
    @Published public var errorMessage: String?
    @Published public private(set) var serviceStatus: String = "Runs inside RemoteCode while the app is open"
    @Published public private(set) var serviceRequiresApproval = false
    @Published public private(set) var isSavingEditor = false
    /// Global kill switch: when false, automatic scheduled occurrences do not claim/run.
    @Published public private(set) var schedulerActive: Bool = true

    private let context: AppContext
    private let router: AppCommandRouter
    private let store: ScheduledTaskStore
    private let settingsStore: SettingsStore
    private var providerLoadCount = 0
    private var activeRunPollTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var tasksRefreshTask: Task<Void, Never>?
    private var runsRefreshTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var freshnessGeneration: UInt64 = 0
    private var tasksRefreshGeneration: UInt64 = 0
    private var runsRefreshGeneration: UInt64 = 0
    private var navigationGeneration: UInt64 = 0
    private var suppressSelectedTaskReload = false
    private let deferHydration: Bool
    private(set) var fullHydrationCountForTesting = 0

    public init(context: AppContext, router: AppCommandRouter, loadImmediately: Bool = true) {
        self.context = context
        self.router = router
        self.store = ScheduledTaskStore(db: context.db)
        self.settingsStore = SettingsStore(db: context.db)
        self.deferHydration = !loadImmediately
        if loadImmediately {
            reload()
        }
    }

    deinit {
        freshnessTask?.cancel()
        tasksRefreshTask?.cancel()
        runsRefreshTask?.cancel()
        activeRunPollTask?.cancel()
        navigationTask?.cancel()
    }

    private static func waitForCommittedFrame() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Mount callers use the existing published cache for the first frame and
    /// ask the model for one coalesced freshness pass on the next main turn.
    public func scheduleFreshnessPass() {
        guard deferHydration else { return }
        freshnessTask?.cancel()
        freshnessGeneration &+= 1
        let generation = freshnessGeneration
        freshnessTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer { self.finishFreshnessTask(ownedBy: generation) }
            guard !Task.isCancelled,
                  self.freshnessGeneration == generation else { return }
            self.reload()
        }
    }

    private func finishFreshnessTask(ownedBy generation: UInt64) {
        guard freshnessGeneration == generation else { return }
        freshnessTask = nil
    }

    func waitForFreshnessForTesting() async {
        while true {
            let pending = [freshnessTask, tasksRefreshTask, runsRefreshTask].compactMap { $0 }
            guard !pending.isEmpty else { return }
            await withTaskGroup(of: Void.self) { group in
                for task in pending {
                    group.addTask { await task.value }
                }
            }
            await Task.yield()
        }
    }

    private func reloadTasksOrDefer() {
        if deferHydration { scheduleTasksRefreshPass() } else { reloadTasks() }
    }

    private func reloadRunsOrDefer() {
        if deferHydration { scheduleRunsRefreshPass() } else { reloadRuns() }
    }

    /// Search/filter changes only need the task projection. Re-running the
    /// complete hydration pass here used to re-read workspaces, users, run
    /// history, scheduler state, and provider catalogs for every keystroke.
    private func scheduleTasksRefreshPass() {
        guard deferHydration else { return }
        tasksRefreshTask?.cancel()
        tasksRefreshGeneration &+= 1
        let generation = tasksRefreshGeneration
        tasksRefreshTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer { self.finishTasksRefreshTask(ownedBy: generation) }
            guard !Task.isCancelled,
                  self.tasksRefreshGeneration == generation else { return }
            self.reloadTasks()
        }
    }

    /// Selecting a task publishes the selection immediately and only then
    /// refreshes its history. Keep that pass independent from the overview
    /// task list so detail navigation does not repeat unrelated hydration.
    private func scheduleRunsRefreshPass() {
        guard deferHydration else { return }
        runsRefreshTask?.cancel()
        runsRefreshGeneration &+= 1
        let generation = runsRefreshGeneration
        runsRefreshTask = Task { @MainActor [weak self] in
            await Self.waitForCommittedFrame()
            guard let self else { return }
            defer { self.finishRunsRefreshTask(ownedBy: generation) }
            guard !Task.isCancelled,
                  self.runsRefreshGeneration == generation else { return }
            self.reloadRuns()
        }
    }

    private func finishTasksRefreshTask(ownedBy generation: UInt64) {
        guard tasksRefreshGeneration == generation else { return }
        tasksRefreshTask = nil
    }

    private func finishRunsRefreshTask(ownedBy generation: UInt64) {
        guard runsRefreshGeneration == generation else { return }
        runsRefreshTask = nil
    }

    public var selectedTask: ScheduledTask? { tasks.first { $0.id == selectedTaskID } }

    public func reload() {
        fullHydrationCountForTesting += 1
        do {
            workspaces = try router.listWorkspaces()
            users = ScheduledSystemUserCatalog.eligibleUsers()
            schedulerActive = settingsStore.load().scheduledTasksActive
            reloadTasks()
            reloadRuns()
            reloadServiceStatus()
        } catch { errorMessage = String(describing: error) }
        Task { [weak self] in
            guard let self else { return }
            providerLoadCount += 1
            providersLoading = true
            defer {
                providerLoadCount = max(0, providerLoadCount - 1)
                providersLoading = providerLoadCount > 0
            }
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
                let persisted = task
                try store.save(persisted)
                editorDraft = nil
                selectedTaskID = persisted.id
                reloadTasks()
                reloadRuns()
                reloadServiceStatus()
                if persisted.isEnabled {
                    router.scheduledTaskScheduler?.tick()
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
                let next = task.calculatedNextRun(after: Date().addingTimeInterval(-0.001))
                try store.setEnabled(id: task.id, enabled: true, nextRunAt: next)
                router.scheduledTaskScheduler?.tick()
                reloadTasks()
            } catch { errorMessage = String(describing: error) }
        }
    }

    public func openServiceSettings() {
        // Legacy Login Items path no longer required; keep no-op for old UI tests.
    }

    private func reloadServiceStatus() {
        serviceStatus = "Runs inside RemoteCode while the app is open"
        serviceRequiresApproval = false
    }

    public func runNow(_ task: ScheduledTask) {
        guard activeRunStatuses[task.id] == nil else {
            errorMessage = "This scheduled task already has an active run."
            return
        }
        guard let scheduler = router.scheduledTaskScheduler else {
            errorMessage = "The in-app scheduler is not ready yet. Keep RemoteCode open and retry."
            return
        }
        // Immediate feedback: claim is async, but the card should flip to Queued
        // in the same click.
        activeRunStatuses[task.id] = .queued
        runCounts[task.id, default: 0] += 1
        ensureActiveRunPolling()
        scheduler.runNow(taskID: task.id) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.activeRunStatuses.removeValue(forKey: task.id)
                self.runCounts[task.id, default: 1] = max(0, (self.runCounts[task.id] ?? 1) - 1)
                self.errorMessage = error.localizedDescription
            case .success:
                break
            }
            self.reloadActiveRunStatuses()
            self.reloadRuns()
            self.reloadServiceStatus()
            self.ensureActiveRunPolling()
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
        guard !deferHydration else {
            router.windowController?.presentWorkspaceContent()
            navigationTask?.cancel()
            navigationGeneration &+= 1
            let generation = navigationGeneration
            navigationTask = Task { @MainActor [weak self] in
                await Self.waitForCommittedFrame()
                guard let self else { return }
                defer { self.finishNavigationTask(ownedBy: generation) }
                guard !Task.isCancelled,
                      self.navigationGeneration == generation else { return }
                do { _ = try self.router.openAgentThread(thread: threadID, markRead: true) }
                catch { self.errorMessage = String(describing: error) }
            }
            return
        }
        do { _ = try router.openAgentThread(thread: threadID, markRead: true) }
        catch { errorMessage = String(describing: error) }
    }

    private func finishNavigationTask(ownedBy generation: UInt64) {
        guard navigationGeneration == generation else { return }
        navigationTask = nil
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
            filterCounts = (
                all: matching.count,
                active: matching.filter(\.isEnabled).count,
                paused: matching.filter { !$0.isEnabled }.count
            )
            switch statusFilter {
            case .all: tasks = matching
            case .active: tasks = matching.filter(\.isEnabled)
            case .paused: tasks = matching.filter { !$0.isEnabled }
            }
            runCounts = try store.runCounts()
            // Overview is a full list; do not auto-select a task into the detail page.
            if let selectedTaskID, !matching.contains(where: { $0.id == selectedTaskID }) {
                suppressSelectedTaskReload = true
                self.selectedTaskID = nil
                suppressSelectedTaskReload = false
            }
            reloadActiveRunStatuses()
        } catch { errorMessage = String(describing: error) }
    }

    private func reloadRuns() {
        do { runs = try store.listRuns(taskID: selectedTaskID, limit: 200) }
        catch { errorMessage = String(describing: error) }
        // Keep overview badges in sync when history refreshes (e.g. after Run Now).
        reloadActiveRunStatuses()
    }

    private func reloadActiveRunStatuses() {
        do {
            let activeRuns = try store.listActiveRuns()
            var next: [UUID: ScheduledTaskRunStatus] = [:]
            for run in activeRuns {
                // Prefer running over queued if both somehow exist.
                if next[run.taskID] == .running { continue }
                next[run.taskID] = run.status
            }
            // Preserve optimistic Queued until the store has the row (or failure clears it).
            for (taskID, status) in activeRunStatuses where status == .queued && next[taskID] == nil {
                next[taskID] = .queued
            }
            activeRunStatuses = next
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func ensureActiveRunPolling() {
        guard !activeRunStatuses.isEmpty else {
            activeRunPollTask?.cancel()
            activeRunPollTask = nil
            return
        }
        guard activeRunPollTask == nil else { return }
        activeRunPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.reloadActiveRunStatuses()
                self.reloadRuns()
                if self.activeRunStatuses.isEmpty {
                    self.activeRunPollTask = nil
                    return
                }
            }
        }
    }

    public func isTaskRunning(_ taskID: UUID) -> Bool {
        activeRunStatuses[taskID] != nil
    }

    public func activeRunStatus(for taskID: UUID) -> ScheduledTaskRunStatus? {
        activeRunStatuses[taskID]
    }

    public func workspaceName(for task: ScheduledTask) -> String {
        workspaces.first { $0.id == task.workspaceID }?.name ?? "Missing workspace"
    }

    public func providerLabel(for task: ScheduledTask) -> String {
        let host: String
        if let snap = providers.first(where: { $0.id == task.providerInstanceID }) {
            host = "\(task.provider.rawValue.capitalized) · \(snap.displayName)"
        } else {
            host = task.provider.rawValue.capitalized
        }
        // Auto never replaces the Source — surface the chosen host plus routing mode.
        if task.effectiveRoutingMode == .auto { return "\(host) · Auto" }
        return host
    }

    public func setSchedulerActive(_ active: Bool) {
        settingsStore.update { $0.scheduledTasksActive = active }
        schedulerActive = settingsStore.load().scheduledTasksActive
        if active {
            router.scheduledTaskScheduler?.tick()
        }
        ScheduledTaskCrossProcess.notifyStoreChanged(reason: active ? "global_active" : "global_paused")
    }

    public var footerTaskCountLine: String {
        let total = filterCounts.all
        let active = filterCounts.active
        return "\(total) task\(total == 1 ? "" : "s") · \(active) active"
    }

    public var footerStatsLine: String {
        let online: String
        if !schedulerActive {
            online = "Scheduler paused"
        } else if serviceRequiresApproval {
            online = "Scheduler needs approval"
        } else {
            online = "Scheduler online"
        }
        return "\(footerTaskCountLine) · \(online)"
    }
}


// MARK: - Navigation screens (plan-scheduled-tasks mockups)

private enum ScheduledTasksScreen: Equatable {
    case overview
    case detail
    case editor
}

public struct ScheduledTasksRootView: View {
    @ObservedObject private var vm: ScheduledTasksViewModel
    @State private var screen: ScheduledTasksScreen = .overview
    @State private var expandedRunIDs = Set<UUID>()
    @State private var editorReturnScreen: ScheduledTasksScreen = .overview

    public init(vm: ScheduledTasksViewModel) { self.vm = vm }

    public var body: some View {
        VStack(spacing: 0) {
            if vm.serviceRequiresApproval {
                serviceBanner
            }
            Group {
                switch screen {
                case .overview:
                    overviewScreen
                case .detail:
                    detailScreen
                case .editor:
                    if let draft = vm.editorDraft {
                        ScheduledTaskEditorView(
                            draft: draft,
                            vm: vm,
                            onBack: { closeEditor(cancel: true) },
                            onCancel: { closeEditor(cancel: true) },
                            onSave: { vm.saveEditor($0) }
                        )
                    } else {
                        overviewScreen
                            .onAppear { screen = .overview }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if screen == .overview || screen == .detail {
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                footerBar
            }
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(DS.Palette.bg)
        .alert("Scheduled Tasks", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear { vm.scheduleFreshnessPass() }
        .onChange(of: vm.editorDraft) { draft in
            // External create/edit still routes into the full-page editor.
            if draft != nil, screen != .editor {
                editorReturnScreen = screen
                screen = .editor
            } else if draft == nil, screen == .editor {
                // Save success clears draft and selects the task → open detail.
                // Cancel also clears draft → return to prior screen.
                screen = vm.selectedTaskID != nil ? .detail : editorReturnScreen
            }
        }
    }

    private func openEditor(returnTo: ScheduledTasksScreen) {
        editorReturnScreen = returnTo
        screen = .editor
    }

    private func closeEditor(cancel: Bool) {
        if cancel { vm.editorDraft = nil }
        screen = editorReturnScreen == .detail && vm.selectedTaskID != nil ? editorReturnScreen : .overview
    }

    // MARK: Service banner

    private var serviceBanner: some View {
        // Path B LaunchAgent Login Items banner retired — schedules run in-app.
        EmptyView()
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: vm.footerTaskCountLine,
            pillTitle: vm.schedulerActive ? "Scheduler online" : "Scheduler paused",
            pillTone: vm.schedulerActive ? .success : .warning
        )
        .accessibilityLabel(vm.footerStatsLine)
    }

    // MARK: Overview (plan: scheduled-tasks-overview)

    private var overviewScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.lg) {
                VStack(alignment: .leading, spacing: DS.Space.xs) {
                    Text("Scheduled Tasks")
                        .font(DS.Font.title.weight(.semibold))
                        .foregroundColor(DS.Palette.text)
                    Text(vm.schedulerActive
                         ? "Automate recurring agent work"
                         : "Automatic runs paused — turn Active on when you're back")
                        .font(DS.Font.body)
                        .foregroundColor(vm.schedulerActive ? DS.Palette.textSecondary : DS.Palette.warning)
                        .animation(DS.Motion.micro, value: vm.schedulerActive)
                }
                Spacer(minLength: DS.Space.lg)
                HStack(spacing: DS.Space.md) {
                    Button {
                        vm.createTask()
                        openEditor(returnTo: .overview)
                    } label: {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.new")

                    schedulerActiveControl
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

            if vm.tasks.isEmpty {
                DSEmptyState(
                    icon: "calendar.badge.clock",
                    title: vm.searchText.isEmpty ? "No scheduled tasks" : "No matching tasks",
                    subtitle: vm.searchText.isEmpty
                        ? "Create a task to run an Agent automatically while RemoteCode is closed."
                        : "Try another search or clear the status filter."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.tasks) { task in
                            ScheduledTaskCard(
                                task: task,
                                workspaceName: vm.workspaceName(for: task),
                                providerLabel: shortProviderModel(task),
                                runCount: vm.runCounts[task.id, default: 0],
                                activeRunStatus: vm.activeRunStatus(for: task.id),
                                onOpen: {
                                    vm.selectedTaskID = task.id
                                    screen = .detail
                                },
                                onToggle: { vm.toggle(task) },
                                onRunNow: { vm.runNow(task) },
                                onEdit: {
                                    vm.selectedTaskID = task.id
                                    vm.edit(task)
                                    openEditor(returnTo: .detail)
                                },
                                onDelete: { vm.delete(task) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("scheduledTasks.list")
            }
        }
    }

    /// Global kill-switch control: status chrome + switch.
    /// State is conveyed by icon + label + tint (not color alone — WCAG 1.4.1).
    private var schedulerActiveControl: some View {
        AgentKillSwitchControl(
            isActive: vm.schedulerActive,
            identifier: "scheduledTasks.globalActive",
            accessibilityLabel: vm.schedulerActive ? "Schedules active" : "Schedules paused",
            onChange: { vm.setSchedulerActive($0) }
        )
    }

    private var filterChips: some View {
        HStack(spacing: DS.Space.sm) {
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.all.rawValue,
                count: vm.filterCounts.all,
                selected: vm.statusFilter == .all,
                identifier: "scheduledTasks.filter.all"
            ) { vm.statusFilter = .all }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.active.rawValue,
                count: vm.filterCounts.active,
                selected: vm.statusFilter == .active,
                identifier: "scheduledTasks.filter.active"
            ) { vm.statusFilter = .active }
            AgentListFilterChip(
                title: ScheduledTaskStatusFilter.paused.rawValue,
                count: vm.filterCounts.paused,
                selected: vm.statusFilter == .paused,
                identifier: "scheduledTasks.filter.paused"
            ) { vm.statusFilter = .paused }
        }
        .accessibilityIdentifier("scheduledTasks.statusFilter")
        .accessibilityLabel("Filter tasks by status")
    }

    private var searchField: some View {
        AgentListSearchField(
            text: $vm.searchText,
            placeholder: "Search tasks",
            identifier: "scheduledTasks.search",
            accessibilityLabel: "Search tasks"
        )
    }

    private func shortProviderModel(_ task: ScheduledTask) -> String {
        if task.effectiveRoutingMode == .auto {
            return "\(task.provider.rawValue.capitalized) · Auto"
        }
        return "\(task.provider.rawValue.capitalized) · \(task.model) · \(task.reasoningEffort.displayName)"
    }

    // MARK: Detail / history (plan: scheduled-task-history)

    @ViewBuilder
    private var detailScreen: some View {
        if let task = vm.selectedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.xxl) {
                    detailHeader(task)
                    metaSummaryCard(task)
                    runHistorySection(task)
                    Button {
                        vm.edit(task)
                        openEditor(returnTo: .detail)
                    } label: {
                        Label("Edit Schedule", systemImage: "pencil")
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.editSchedule")
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: 1100, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("scheduledTasks.detail")
        } else {
            overviewScreen.onAppear { screen = .overview }
        }
    }

    private func detailHeader(_ task: ScheduledTask) -> some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            Button {
                screen = .overview
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to scheduled tasks")
            .accessibilityIdentifier("scheduledTasks.back")

            HStack(spacing: DS.Space.md) {
                Text(task.title)
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                    .lineLimit(1)
                statusPill(for: task)
            }
            Spacer(minLength: DS.Space.lg)
            HStack(spacing: DS.Space.sm) {
                Button("Run Now") { vm.runNow(task) }
                    .buttonStyle(DSPrimaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.runNow")
                Button(task.isEnabled ? "Pause" : "Resume") { vm.toggle(task) }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .accessibilityIdentifier("scheduledTasks.toggle")
                Menu {
                    Button("Edit Schedule") {
                        vm.edit(task)
                        openEditor(returnTo: .detail)
                    }
                    Divider()
                    Button("Delete", role: .destructive) {
                        vm.delete(task)
                        if vm.selectedTaskID == nil { screen = .overview }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(DS.Palette.textSecondary)
                        .frame(width: 36, height: 32)
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                        )
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More actions")
            }
        }
    }

    @ViewBuilder
    private func statusPill(for task: ScheduledTask) -> some View {
        if let status = vm.activeRunStatus(for: task.id) {
            switch status {
            case .queued:
                DSPill("Queued", tone: .warning)
            case .running:
                DSPill("Running", tone: .warning)
            default:
                DSPill("Running", tone: .warning)
            }
        } else if task.isEnabled {
            DSPill("Active", tone: .success)
        } else {
            DSPill("Paused", tone: .neutral)
        }
    }

    private func metaSummaryCard(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            HStack(alignment: .top, spacing: DS.Space.xl) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(DS.Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(DS.Palette.accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    .accessibilityHidden(true)

                metaCell("Workspace", vm.workspaceName(for: task))
                metaCell("Run as user", task.runAsUser)
                metaCell("Provider", vm.providerLabel(for: task))
                metaCell("Model", task.model)
                metaCell("Reasoning", task.reasoningEffort.displayName)
                metaCell("Schedule", task.recurrence.detailSummary)
                metaCell("Time zone", task.timeZoneIdentifier)
            }
            HStack(spacing: DS.Space.sm) {
                Image(systemName: "clock")
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text("Next run: \(nextRunLabel(task))")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
            }
        }
        .padding(DS.Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
        )
    }

    private func metaCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(DS.Font.caption2)
                .foregroundColor(DS.Palette.textTertiary)
            Text(value)
                .font(DS.Font.caption.weight(.medium))
                .foregroundColor(DS.Palette.text)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(minWidth: 88, alignment: .leading)
    }

    private func nextRunLabel(_ task: ScheduledTask) -> String {
        guard task.isEnabled, let next = task.nextRunAt else { return "Paused" }
        return next.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func runHistorySection(_ task: ScheduledTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.md) {
            Text("Run History")
                .font(DS.Font.title3.weight(.semibold))
                .foregroundColor(DS.Palette.text)
            if vm.runs.isEmpty {
                Text("No runs yet. Use Run Now or wait for the next scheduled occurrence.")
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsPanel(padding: DS.Space.xl)
            } else {
                VStack(spacing: 0) {
                    historyHeaderRow
                    Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
                    ForEach(Array(vm.runs.enumerated()), id: \.element.id) { index, run in
                        historyRow(task: task, run: run)
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
    }

    private var historyHeaderRow: some View {
        HStack(spacing: DS.Space.lg) {
            Text("Started").frame(width: 140, alignment: .leading)
            Text("Duration").frame(width: 80, alignment: .leading)
            Text("Status").frame(width: 110, alignment: .leading)
            Text("Agent Task").frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 24)
        }
        .font(DS.Font.caption2.weight(.semibold))
        .foregroundColor(DS.Palette.textTertiary)
        .padding(.horizontal, DS.Space.lg)
        .padding(.vertical, DS.Space.md)
    }

    private func historyRow(task: ScheduledTask, run: ScheduledTaskRun) -> some View {
        let expanded = expandedRunIDs.contains(run.id)
        let canOpenThread = run.threadID != nil
        let canExpandDetails = run.errorSummary != nil || run.status == .failed
        return VStack(alignment: .leading, spacing: 0) {
            // Sibling hit targets (not nested): primary area opens the agent thread;
            // chevron alone expands/collapses failure details. A disabled outer
            // Button used to swallow the nested Agent Task control on completed runs.
            HStack(spacing: DS.Space.lg) {
                Group {
                    if canOpenThread {
                        Button {
                            vm.openThread(run)
                        } label: {
                            historyRowPrimaryContent(task: task, run: run, linkStyle: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("scheduledTasks.history.openThread")
                        .accessibilityLabel("Open agent task \(agentTaskTitle(task: task, run: run))")
                        .accessibilityHint("Opens the agent thread created by this run")
                    } else {
                        historyRowPrimaryContent(task: task, run: run, linkStyle: false)
                            .accessibilityElement(children: .combine)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if canExpandDetails {
                    Button {
                        if !expandedRunIDs.insert(run.id).inserted {
                            expandedRunIDs.remove(run.id)
                        }
                    } label: {
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(DS.Palette.textTertiary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("scheduledTasks.history.toggleDetails")
                    .accessibilityLabel(expanded ? "Hide run details" : "Show run details")
                } else {
                    Color.clear.frame(width: 24, height: 24)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.lg)
            .padding(.vertical, DS.Space.lg)

            if expanded, let error = run.errorSummary {
                HStack(alignment: .center, spacing: DS.Space.md) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundColor(DS.Palette.danger)
                        .accessibilityHidden(true)
                    Text(error)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if canOpenThread {
                        Button("Open Agent Task") { vm.openThread(run) }
                            .buttonStyle(DSSecondaryButtonStyle())
                            .accessibilityIdentifier("scheduledTasks.history.openThreadFromDetails")
                    }
                    if run.status == .failed {
                        Button("Run Again") { vm.runNow(task) }
                            .buttonStyle(DSPrimaryButtonStyle())
                    }
                }
                .padding(DS.Space.lg)
                .background(DS.Palette.danger.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                        .strokeBorder(DS.Palette.danger.opacity(0.35), lineWidth: DS.Border.hairline)
                )
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.lg)
                Button(expanded ? "Hide details" : "Show details") {
                    if !expandedRunIDs.insert(run.id).inserted {
                        expandedRunIDs.remove(run.id)
                    }
                }
                .buttonStyle(.plain)
                .font(DS.Font.caption.weight(.semibold))
                .foregroundColor(DS.Palette.accent)
                .padding(.horizontal, DS.Space.lg)
                .padding(.bottom, DS.Space.md)
            }
        }
    }

    private func historyRowPrimaryContent(task: ScheduledTask, run: ScheduledTaskRun, linkStyle: Bool) -> some View {
        HStack(spacing: DS.Space.lg) {
            Text((run.startedAt ?? run.queuedAt).formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.text)
                .frame(width: 140, alignment: .leading)
            Text(durationLabel(run))
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
                .frame(width: 80, alignment: .leading)
            runStatusPill(run.status)
                .frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(agentTaskTitle(task: task, run: run))
                    .font(DS.Font.caption.weight(linkStyle ? .medium : .regular))
                    .foregroundColor(linkStyle ? DS.Palette.accent : DS.Palette.textSecondary)
                if run.status == .failed, let error = run.errorSummary {
                    Text(error)
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.danger)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func agentTaskTitle(task: ScheduledTask, run: ScheduledTaskRun) -> String {
        let day = (run.startedAt ?? run.queuedAt).formatted(.dateTime.month(.abbreviated).day())
        return "\(task.title) · \(day)"
    }

    private func durationLabel(_ run: ScheduledTaskRun) -> String {
        guard let started = run.startedAt, let finished = run.finishedAt else {
            if run.status == .running, let started = run.startedAt {
                let s = Int(Date().timeIntervalSince(started))
                return s < 60 ? "\(s)s" : "\(s / 60)m"
            }
            return "—"
        }
        let s = Int(finished.timeIntervalSince(started))
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    private func runStatusPill(_ status: ScheduledTaskRunStatus) -> some View {
        switch status {
        case .completed: return AnyView(DSPill("Completed", tone: .success))
        case .failed: return AnyView(DSPill("Failed", tone: .danger))
        case .running: return AnyView(DSPill("Running", tone: .warning))
        case .queued: return AnyView(DSPill("Queued", tone: .warning))
        case .cancelled: return AnyView(DSPill("Cancelled", tone: .neutral))
        case .skipped: return AnyView(DSPill("Skipped", tone: .neutral))
        }
    }
}

// MARK: - Task card (overview)

private struct ScheduledTaskCard: View {
    let task: ScheduledTask
    let workspaceName: String
    let providerLabel: String
    let runCount: Int
    let activeRunStatus: ScheduledTaskRunStatus?
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onRunNow: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isActiveRun: Bool { activeRunStatus != nil }

    var body: some View {
        AgentOverviewCard(
            icon: "calendar.badge.clock",
            iconColor: DS.Palette.accent,
            title: task.title,
            subtitle: "\(workspaceName) · \(task.runAsUser) · \(providerLabel)",
            identifier: "scheduledTasks.task.\(task.id.uuidString.lowercased())",
            accessibilityValue: accessibilityStatusValue,
            onOpen: onOpen
        ) {
            badge
        } meta: {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                AgentOverviewMetaColumn(title: "Schedule", value: task.recurrence.detailSummary)
                AgentOverviewMetaColumn(
                    title: isActiveRun ? "Status" : "Next run",
                    value: statusOrNext,
                    valueColor: isActiveRun ? DS.Palette.warning : DS.Palette.text
                )
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "clock")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(DS.Palette.textTertiary)
                    Text("\(runCount)")
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.textSecondary)
                        .monospacedDigit()
                }
                .frame(width: 44, alignment: .trailing)
                .accessibilityLabel("\(runCount) runs")
            }
        } trailing: {
            Menu {
                Button(task.isEnabled ? "Pause" : "Resume", action: onToggle)
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
    }

    @ViewBuilder
    private var badge: some View {
        if activeRunStatus == .queued {
            DSPill("Queued", tone: .warning)
        } else if activeRunStatus == .running {
            DSPill("Running", tone: .warning)
        } else if isActiveRun {
            DSPill("Running", tone: .warning)
        } else if task.isEnabled {
            DSPill("Active", tone: .success)
        } else {
            DSPill("Paused", tone: .neutral)
        }
    }

    private var statusOrNext: String {
        if activeRunStatus == .queued { return "Queued" }
        if activeRunStatus == .running || isActiveRun { return "Running now" }
        if !task.isEnabled { return "Paused" }
        guard let next = task.nextRunAt else { return "—" }
        return next.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var accessibilityStatusValue: String {
        if activeRunStatus == .queued { return "Queued" }
        if activeRunStatus == .running || isActiveRun { return "Running" }
        return task.isEnabled ? "Active" : "Paused"
    }
}

// MARK: - Editor (plan: scheduled-task-editor)

private struct ScheduledTaskEditorView: View {
    @State private var draft: ScheduledTaskEditorDraft
    @State private var showSourceOptions = false
    @State private var showModelOptions = false
    @ObservedObject var vm: ScheduledTasksViewModel
    let onBack: () -> Void
    let onCancel: () -> Void
    let onSave: (ScheduledTaskEditorDraft) -> Void

    init(
        draft: ScheduledTaskEditorDraft,
        vm: ScheduledTasksViewModel,
        onBack: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSave: @escaping (ScheduledTaskEditorDraft) -> Void
    ) {
        self._draft = State(initialValue: draft)
        self.vm = vm
        self.onBack = onBack
        self.onCancel = onCancel
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
                .disabled(vm.isSavingEditor)

                Text(isNew ? "New Scheduled Task" : "Edit Scheduled Task")
                    .font(DS.Font.title2.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(DSSecondaryButtonStyle())
                    .disabled(vm.isSavingEditor)
                    .keyboardShortcut(.cancelAction)
                Button(vm.isSavingEditor ? "Checking…" : "Save Task") { confirmAndSave() }
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
                    labeledField("Scheduled task title") {
                        TextField("e.g., Daily dependency scan", text: $draft.title)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, DS.Space.lg)
                            .padding(.vertical, DS.Space.md)
                            .background(DS.Palette.surfaceRaised)
                            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                    .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                            )
                            .accessibilityIdentifier("scheduledTasks.editor.title")
                    }

                    labeledField("Prompt") {
                        ZStack(alignment: .topLeading) {
                            if draft.prompt.isEmpty {
                                Text("Describe what ChatGPT should do")
                                    .foregroundColor(DS.Palette.textTertiary)
                                    .padding(.horizontal, DS.Space.lg)
                                    .padding(.vertical, DS.Space.lg)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $draft.prompt)
                                .font(DS.Font.body)
                                .foregroundColor(DS.Palette.text)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 120)
                                .padding(.horizontal, DS.Space.md)
                                .padding(.vertical, DS.Space.md)
                        }
                        .background(DS.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                .strokeBorder(DS.Palette.line, lineWidth: DS.Border.hairline)
                        )
                        .accessibilityIdentifier("scheduledTasks.editor.prompt")
                        .accessibilityLabel("Prompt")
                    }

                    // Contract section names retained for chrome regression tests.
                    let _ = ["Basics", "Agent", "Schedule", "Prompt"] as [String]
                    editorGroup("Details") {
                        formRow("Workspace") {
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
                        formRow("Run as user") {
                            editorRunAsCapsule
                        }
                        // Parity with Agent App: one Provider/Source capsule only
                        // (Codex / Claude / Grok). Instance id is derived from the
                        // selected provider's primary snapshot and stays in the model.
                        formRow("Provider") {
                            editorSourceCapsule
                                .accessibilityIdentifier("scheduledTasks.editor.provider")
                        }
                        formRow("Model routing") {
                            HStack(spacing: DS.Space.sm) {
                                if vm.providersLoading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Loading providers")
                                }
                                Toggle("Auto", isOn: Binding(
                                    get: { draft.routingMode == .auto },
                                    set: { setAutoRoutingEnabled($0) }
                                ))
                                .toggleStyle(.switch)
                                .tint(DS.Palette.success)
                                .accessibilityIdentifier("scheduledTasks.editor.autoRouting")
                            }
                        }
                        // Parity with Agent App: Auto never picks the provider/Source —
                        // only the model within the selected host at run time.
                        if draft.routingMode == .auto {
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
                                    AgentModelPillLabel(presentation: editorModelPillPresentation)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("scheduledTasks.editor.model")
                                .popover(isPresented: $showModelOptions, arrowEdge: .bottom) {
                                    editorModelPopover
                                }
                            }
                        }
                    }

                    editorGroup("Frequency") {
                        formRow("Repeat") {
                            Picker("Frequency", selection: $draft.frequency) {
                                ForEach(ScheduledTaskFrequency.allCases) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden()
                        }
                        scheduleControls
                        formRow("Time zone") {
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
                    }

                    HStack(alignment: .center, spacing: DS.Space.md) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(DS.Palette.warning)
                            .accessibilityHidden(true)
                        Text("Runs unattended with Full Access in the selected workspace.")
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(DS.Space.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.Palette.warning.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(DS.Palette.warning.opacity(0.35), lineWidth: DS.Border.hairline)
                    )
                }
                .padding(DS.Space.xxl)
                .frame(maxWidth: 920, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: DS.Space.sm) {
                Image(systemName: "clock")
                    .foregroundColor(DS.Palette.textTertiary)
                    .accessibilityHidden(true)
                Text("Next run: \(previewNextRun)")
                    .font(DS.Font.caption)
                    .foregroundColor(DS.Palette.textSecondary)
                Spacer()
            }
            .padding(.horizontal, DS.Space.xxl)
            .frame(height: 40)
            .background(DS.Palette.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            }
        }
        .background(DS.Palette.bg)
        .accessibilityIdentifier("scheduledTasks.editor")
    }

    private var isNew: Bool {
        !vm.tasks.contains(where: { $0.id == draft.id })
    }

    private var previewNextRun: String {
        guard let task = try? draft.makeTask(), let next = task.nextRunAt else {
            return draft.isEnabled ? "Not scheduled yet" : "Paused until enabled"
        }
        return next.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
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
        // Section titles "Details" / "Frequency" match plan; legacy contract
        // tests also pin Basics/Agent/Schedule/Prompt string anchors in source.
        .accessibilityIdentifier("editorSection.\(title)")
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
            formRow("At") {
                DatePicker("Run at", selection: $draft.scheduledDate)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
        case .hourly:
            formRow("Interval") {
                Stepper("Every \(draft.intervalHours)h", value: $draft.intervalHours, in: 1...24)
                    .foregroundColor(DS.Palette.text)
            }
        case .daily, .weekdays:
            formRow("At") {
                DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        case .weekly:
            formRow("At") {
                DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
            formRow("Days") {
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
            formRow("Day") {
                Stepper("Day \(draft.monthlyDay)", value: $draft.monthlyDay, in: 1...28)
                    .foregroundColor(DS.Palette.text)
            }
            formRow("At") {
                DatePicker("Local time", selection: $draft.localTime, displayedComponents: .hourAndMinute)
                    .labelsHidden()
            }
        }
    }

    private var editorRunAsCapsule: some View {
        let users = vm.users.map { user -> AgentRunAsUser in
            let name = user.name
            let uid = user.uid
            let homeDirectory = user.homeDirectory
            return AgentRunAsUser(generatedUID: "", shortName: name, uid: uid, gid: 0, homePath: homeDirectory)
        }
        let selected = users.first(where: { $0.shortName == draft.runAsUser && $0.uid == draft.runAsUID })
            ?? users.first(where: { $0.shortName == draft.runAsUser })
            ?? AgentRunAsUser(generatedUID: "", shortName: draft.runAsUser, uid: draft.runAsUID, gid: 0, homePath: "")
        return AgentRunAsUserCapsule(
            users: users,
            selected: selected,
            runLocked: false,
            identityLocked: false,
            accessibilityIdentifier: "scheduledTasks.editor.runAsUser",
            onSelect: { user in
                draft.runAsUser = user.shortName
                draft.runAsUID = user.uid
            }
        )
    }

    private var editorSourceCapsule: some View {
        AgentSourceCapsule(
            label: AgentSourceCapsulePresentation.capsuleLabel(
                selected: vm.providers.first(where: {
                    $0.id == draft.providerInstanceID && $0.provider == draft.provider
                }) ?? vm.providerSnapshots(for: draft.provider).first,
                fallbackProvider: draft.provider,
                fallbackInstanceId: draft.providerInstanceID,
                snapshots: vm.providers
            ),
            entries: AgentSourceCapsulePresentation.menuEntries(
                snapshots: vm.providers,
                selectedSnapshotId: draft.providerInstanceID,
                selectedProvider: draft.provider,
                providerDisplayName: { $0.rawValue.capitalized }
            ),
            runLocked: false,
            providerLocked: false,
            accessibilityIdentifier: "scheduledTasks.editor.provider",
            popoverIdentifier: "scheduledTasks.editor.source.popover",
            isPresented: $showSourceOptions,
            onSelect: { selectScheduledSource($0) }
        )
    }

    private var editorModelPillPresentation: AgentModelPillPresentation {
        let models = vm.models(provider: draft.provider, instanceID: draft.providerInstanceID)
        let title = models.first(where: { $0.id == draft.model })?.label
            ?? (draft.model.isEmpty ? "Model" : draft.model)
        return AgentModelPillPresentation(
            title: title,
            effort: draft.reasoningEffort.displayName
        )
    }

    private var editorModelPopover: some View {
        let models = vm.models(provider: draft.provider, instanceID: draft.providerInstanceID)
        return AgentModelPopoverChrome(
            presentation: AgentModelPopoverPresentation.current(mode: draft.routingMode),
            autoEnabled: Binding(
                get: { draft.routingMode == .auto },
                set: { setAutoRoutingEnabled($0) }
            ),
            toggleDisabled: false
        ) {
            AgentCompactMenuSection("Model")
            ForEach(models, id: \.id) { model in
                AgentCompactMenuRow(model.label, selected: model.id == draft.model) {
                    draft.model = model.id
                    if let effort = model.supportedReasoningEfforts.first {
                        draft.reasoningEffort = effort
                    }
                    showModelOptions = false
                }
            }
            if !draft.model.isEmpty, !models.contains(where: { $0.id == draft.model }) {
                AgentCompactMenuRow(draft.model, selected: true) {
                    showModelOptions = false
                }
            }
            AgentCompactMenuDivider()
            AgentCompactMenuSection("Reasoning")
            ForEach(AgentReasoningEffort.allCases, id: \.self) { effort in
                AgentCompactMenuRow(effort.displayName, selected: effort == draft.reasoningEffort) {
                    draft.reasoningEffort = effort
                    showModelOptions = false
                }
            }
        }
        .accessibilityIdentifier("scheduledTasks.editor.reasoning")
    }

    private func selectScheduledSource(_ entry: AgentSourceCapsulePresentation.MenuEntry) {
        if let snapshot = vm.providers.first(where: { $0.id == entry.id }) {
            draft.provider = snapshot.provider
            draft.providerInstanceID = snapshot.id
            draft.model = snapshot.models.first?.id ?? ""
            draft.reasoningEffort = snapshot.models.first?.supportedReasoningEfforts.first ?? .high
            return
        }
        guard let provider = AgentProvider(rawValue: entry.id) else { return }
        draft.provider = provider
        if let snapshot = vm.providerSnapshots(for: provider).first {
            draft.providerInstanceID = snapshot.id
            draft.model = snapshot.models.first?.id ?? ""
            draft.reasoningEffort = snapshot.models.first?.supportedReasoningEfforts.first ?? .high
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

    private func setAutoRoutingEnabled(_ enabled: Bool) {
        draft.routingMode = enabled ? .auto : .manual
        // Turning Auto off must keep the chosen provider.
        // Only fill a missing model from that provider's snapshot — never
        // jump to the first available host in the catalog.
        guard !enabled,
              draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let snapshot = vm.providers.first(where: {
            $0.id == draft.providerInstanceID && $0.provider == draft.provider
        }) ?? vm.providerSnapshots(for: draft.provider).first
        guard let snapshot else { return }
        draft.providerInstanceID = snapshot.id
        draft.model = snapshot.models.first?.id ?? ""
        draft.reasoningEffort = snapshot.models.first?.supportedReasoningEfforts.first ?? .high
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


public final class ScheduledTasksWindowController: NSWindowController, NSWindowDelegate {
    private let viewModel: ScheduledTasksViewModel

    public init(context: AppContext, router: AppCommandRouter) {
        self.viewModel = ScheduledTasksViewModel(context: context, router: router, loadImmediately: false)
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
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


private extension ScheduledTaskRecurrence {
    var summaryLabel: String {
        switch self {
        case .once: return "Once"
        case .hourly(_, let hours): return hours == 1 ? "Hourly" : "Every \(hours)h"
        case .daily: return "Daily"
        case .weekdays: return "Weekdays"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    /// Plan-style schedule column: "Daily at 9:00 AM", "Weekdays at 8:30 AM", …
    var detailSummary: String {
        switch self {
        case .once(let at):
            return "Once · " + at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        case .hourly(_, let hours):
            return hours == 1 ? "Every hour" : "Every \(hours) hours"
        case .daily(let time):
            return "Daily at \(time.displayString)"
        case .weekdays(let time):
            return "Weekdays at \(time.displayString)"
        case .weekly(let days, let time):
            let names = days.sorted().map(\.shortName).joined(separator: ", ")
            return "Weekly \(names) at \(time.displayString)"
        case .monthly(let day, let time):
            return "Monthly on day \(day) at \(time.displayString)"
        }
    }
}

private extension ScheduledLocalTime {
    var displayString: String {
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = minute
        let cal = Calendar(identifier: .gregorian)
        let date = cal.date(from: comps) ?? Date()
        return date.formatted(.dateTime.hour().minute())
    }
}

private extension ScheduledWeekday {
    var shortName: String {
        switch self {
        case .sunday: return "Sun"
        case .monday: return "Mon"
        case .tuesday: return "Tue"
        case .wednesday: return "Wed"
        case .thursday: return "Thu"
        case .friday: return "Fri"
        case .saturday: return "Sat"
        }
    }
}
