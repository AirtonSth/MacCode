import AppKit
import CoreModel
import DesignSystemKit
import Persistence
import Surfaces
import SwiftUI

// MARK: - View model

@MainActor
public final class ActiveThreadsViewModel: ObservableObject {
    public enum Tab: String, CaseIterable, Identifiable {
        case active
        case lastFinished

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .active: return "Active"
            case .lastFinished: return "Last Finished"
            }
        }
    }

    @Published public private(set) var activeItems: [PetActiveThreadItem] = []
    @Published public private(set) var finishedItems: [FinishedThreadItem] = []
    @Published public var selectedTab: Tab = .active
    @Published public var errorMessage: String?

    private let context: AppContext
    private let router: AppCommandRouter
    private var startedAtByThread: [AgentThreadID: Date] = [:]
    private var freshnessTask: Task<Void, Never>?
    private var tabRefreshTask: Task<Void, Never>?
    private var navigationTask: Task<Void, Never>?
    private var freshnessGeneration: UInt64 = 0
    private var tabRefreshGeneration: UInt64 = 0
    private var navigationGeneration: UInt64 = 0
    fileprivate let deferHydration: Bool

    public init(context: AppContext, router: AppCommandRouter, loadImmediately: Bool = true) {
        self.context = context
        self.router = router
        self.deferHydration = !loadImmediately
        if loadImmediately {
            reload()
        }
    }

    deinit {
        freshnessTask?.cancel()
        tabRefreshTask?.cancel()
        navigationTask?.cancel()
    }

    /// Use the published cache for the first frame, then perform one
    /// cancellation-safe repository/coordinator refresh.
    public func scheduleFreshnessPass() {
        guard deferHydration else { return }
        freshnessTask?.cancel()
        freshnessGeneration &+= 1
        let generation = freshnessGeneration
        freshnessTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.freshnessGeneration == generation else { return }
            defer {
                if self.freshnessGeneration == generation {
                    self.freshnessTask = nil
                }
            }
            self.reload()
        }
    }

    public var activeCount: Int { activeItems.count }
    public var finishedCount: Int { finishedItems.count }

    public var footerLine: String {
        let activeLabel = activeCount == 1 ? "1 active" : "\(activeCount) active"
        let finishedLabel = finishedCount == 1 ? "1 recent finished" : "\(finishedCount) recent finished"
        return "\(activeLabel) · \(finishedLabel)"
    }

    public var subtitle: String {
        switch selectedTab {
        case .active:
            if activeCount == 0 {
                return "No agents running right now"
            }
            return activeCount == 1
                ? "1 agent thread is running"
                : "\(activeCount) agent threads are running"
        case .lastFinished:
            return "Recent completed, failed, cancelled, and interrupted runs"
        }
    }

    public func reload() {
        reloadActive()
        reloadFinished()
    }

    public func reloadActive() {
        // Primary threads only — delegated bot-peer runs show under Subagents.
        let threadIDs = Array(context.coordinator.primaryActiveThreadIdsSnapshot())
        let activeSet = Set(threadIDs)
        startedAtByThread = startedAtByThread.filter { activeSet.contains($0.key) }

        let missingStartedAt = threadIDs.filter { startedAtByThread[$0] == nil }
        var runIdByThread: [AgentThreadID: AgentRunID] = [:]
        var runIDs: [AgentRunID] = []
        runIDs.reserveCapacity(missingStartedAt.count)
        for threadID in missingStartedAt {
            guard let runId = context.coordinator.activeRunId(threadId: threadID) else { continue }
            runIdByThread[threadID] = runId
            runIDs.append(runId)
        }
        let stamps = (try? context.runRepo.startedAt(ids: runIDs)) ?? [:]
        for threadID in missingStartedAt {
            if let runId = runIdByThread[threadID], let startedAt = stamps[runId] {
                startedAtByThread[threadID] = startedAt
            } else if let durable = try? context.coordinator.durableActiveRun(threadId: threadID) {
                startedAtByThread[threadID] = durable.startedAt
            } else {
                startedAtByThread[threadID] = Date()
            }
        }

        let chrome = (try? context.threadRepo.listChrome(ids: threadIDs)) ?? [:]
        activeItems = PetActiveThreadProjector.items(threadIDs: threadIDs) { [weak self] threadID in
            guard let self, let meta = chrome[threadID] else { return nil }
            let workspaceName = meta.workspaceId.flatMap { self.context.state.workspaces[$0]?.name }
            return (
                workspaceID: meta.workspaceId,
                workspaceName: workspaceName,
                providerName: PetActiveThreadProjector.providerLabel(meta.provider),
                threadTitle: meta.title,
                startedAt: self.startedAtByThread[threadID],
                lastUpdatePreview: nil
            )
        }
    }

    public func reloadFinished() {
        do {
            let runs = try context.runRepo.listRecentFinished(limit: 50)
            let chrome = try context.threadRepo.listChrome(ids: runs.map(\.threadId))
            finishedItems = runs.map { run in
                let meta = chrome[run.threadId]
                let workspaceID = meta?.workspaceId
                let workspaceName = workspaceID.flatMap { context.state.workspaces[$0]?.name }
                return FinishedThreadItem(
                    run: run,
                    threadTitle: meta?.title,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    providerName: PetActiveThreadProjector.providerLabel(run.provider)
                )
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Tab changes only need the selected projection. Re-running `reload()`
    /// here also rebuilt the active projection and durable start-time map,
    /// which made a rapid Active ↔ Last Finished switch do twice the SQLite
    /// work and republish both lists.
    public func scheduleTabRefresh(_ tab: Tab) {
        guard deferHydration else { return }
        // The initial full pass already owns all projections. Let it finish
        // rather than enqueueing a second read for a click in the same turn.
        guard freshnessTask == nil else { return }
        tabRefreshTask?.cancel()
        tabRefreshGeneration &+= 1
        let generation = tabRefreshGeneration
        tabRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer {
                if self.tabRefreshGeneration == generation {
                    self.tabRefreshTask = nil
                }
            }
            guard !Task.isCancelled,
                  self.tabRefreshGeneration == generation,
                  self.selectedTab == tab else { return }
            switch tab {
            case .active:
                self.reloadActive()
            case .lastFinished:
                self.reloadFinished()
            }
        }
    }

    public func openActive(_ item: PetActiveThreadItem) {
        if case .botsDesk(let botID) = item.route {
            // Publish the shell destination in the click turn. Only the exact
            // Bot lookup/Desk hydration waits for the deferred pass.
            router.windowController?.presentBotsInMainContent()
            guard !deferHydration else {
                navigationTask?.cancel()
                navigationGeneration &+= 1
                let generation = navigationGeneration
                navigationTask = Task { @MainActor [weak self] in
                    await Task.yield()
                    guard let self,
                          !Task.isCancelled,
                          self.navigationGeneration == generation else { return }
                    defer {
                        if self.navigationGeneration == generation {
                            self.navigationTask = nil
                        }
                    }
                    do {
                        guard try self.router.openBotsDesk(botID: botID) else {
                            self.errorMessage = "Could not open bot Desk."
                            return
                        }
                    } catch {
                        self.errorMessage = "Could not open bot Desk: \(error.localizedDescription)"
                    }
                }
                return
            }
            do {
                guard try router.openBotsDesk(botID: botID) else {
                    errorMessage = "Could not open bot Desk."
                    return
                }
            } catch {
                errorMessage = "Could not open bot Desk: \(error.localizedDescription)"
            }
            return
        }
        openThread(item.threadID, workspaceID: workspaceID(from: item.route))
    }

    public func openFinished(_ item: FinishedThreadItem) {
        openThread(item.threadID, workspaceID: item.workspaceID)
    }

    private func workspaceID(from route: PetAttentionRoute) -> WorkspaceID? {
        if case .agentThread(_, let workspaceID) = route {
            return workspaceID
        }
        return nil
    }

    private func openThread(_ threadID: AgentThreadID, workspaceID: WorkspaceID?) {
        // Leave the shell destination first so the workspace cache can paint.
        router.windowController?.presentWorkspaceContent()
        guard deferHydration else {
            do { _ = try router.openAgentThread(thread: threadID, markRead: false) }
            catch { errorMessage = "Could not open thread: \(error.localizedDescription)" }
            return
        }
        navigationTask?.cancel()
        navigationGeneration &+= 1
        let generation = navigationGeneration
        navigationTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.navigationGeneration == generation else { return }
            defer {
                if self.navigationGeneration == generation {
                    self.navigationTask = nil
                }
            }
            do { _ = try self.router.openAgentThread(thread: threadID, markRead: false) }
            catch { self.errorMessage = "Could not open thread: \(error.localizedDescription)" }
        }
    }
}

// MARK: - Finished row model

public struct FinishedThreadItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let runID: AgentRunID
    public let threadID: AgentThreadID
    public let workspaceID: WorkspaceID?
    public let title: String
    public let detail: String
    public let status: AgentRunStatus
    public let finishedAt: Date?
    public let startedAt: Date

    public init(
        run: AgentRun,
        threadTitle: String?,
        workspaceID: WorkspaceID?,
        workspaceName: String?,
        providerName: String?
    ) {
        self.id = "finished:\(run.id.value.uuidString)"
        self.runID = run.id
        self.threadID = run.threadId
        self.workspaceID = workspaceID
        let safeTitle = PetAttentionRedactor.safeContextLabel(threadTitle) ?? "Agent thread"
        self.title = safeTitle
        let workspace = PetAttentionRedactor.safeContextLabel(workspaceName) ?? "Other"
        let provider = providerName ?? PetActiveThreadProjector.providerLabel(run.provider)
        let model = run.model.isEmpty ? provider : "\(provider) · \(run.model)"
        self.detail = "\(workspace) · \(model)"
        self.status = run.status
        self.finishedAt = run.finishedAt
        self.startedAt = run.startedAt
    }
}

// MARK: - Root view

public struct ActiveThreadsRootView: View {
    @ObservedObject private var vm: ActiveThreadsViewModel

    public init(vm: ActiveThreadsViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            overviewHeader
            tabBar
            content
            Rectangle().fill(DS.Palette.line).frame(height: DS.Border.hairline)
            footerBar
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(DS.Palette.bg)
        .alert("Active Threads", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .onAppear { vm.scheduleFreshnessPass() }
        .onChange(of: vm.selectedTab) { tab in
            if vm.deferHydration { vm.scheduleTabRefresh(tab) }
            else if tab == .lastFinished { vm.reloadFinished() }
            else { vm.reloadActive() }
        }
    }

    private var overviewHeader: some View {
        HStack(alignment: .center, spacing: DS.Space.lg) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Active Threads")
                    .font(DS.Font.title.weight(.semibold))
                    .foregroundColor(DS.Palette.text)
                Text(vm.subtitle)
                    .font(DS.Font.body)
                    .foregroundColor(DS.Palette.textSecondary)
            }
            Spacer(minLength: DS.Space.lg)
            if let badge = PetActiveThreadCountFormatter.badgeText(count: vm.activeCount) {
                Text(badge)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .frame(minWidth: 28, minHeight: 28)
                    .background(Circle().fill(Color.blue))
                    .accessibilityLabel(PetActiveThreadCountFormatter.accessibilityValue(count: vm.activeCount))
            }
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.top, DS.Space.xxl)
        .padding(.bottom, DS.Space.xl)
    }

    private var tabBar: some View {
        HStack(spacing: DS.Space.md) {
            ForEach(ActiveThreadsViewModel.Tab.allCases, id: \.self) { tab in
                let count: Int = {
                    switch tab {
                    case .active: return vm.activeCount
                    case .lastFinished: return vm.finishedCount
                    }
                }()
                AgentListFilterChip(
                    title: tab.title,
                    count: count,
                    selected: vm.selectedTab == tab,
                    identifier: "activeThreads.tab.\(tab.rawValue)"
                ) {
                    vm.selectedTab = tab
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.xxl)
        .padding(.bottom, DS.Space.xl)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.selectedTab {
        case .active:
            activeList
        case .lastFinished:
            finishedList
        }
    }

    private var activeList: some View {
        Group {
            if vm.activeItems.isEmpty {
                DSEmptyState(
                    icon: "bolt.horizontal.circle",
                    title: "No active threads",
                    subtitle: "Agent runs in progress will show up here with workspace and provider context."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.activeItems) { item in
                            ActiveThreadCard(item: item) {
                                vm.openActive(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeThreads.activeList")
            }
        }
    }

    private var finishedList: some View {
        Group {
            if vm.finishedItems.isEmpty {
                DSEmptyState(
                    icon: "checkmark.circle",
                    title: "No recent finished runs",
                    subtitle: "Completed, failed, cancelled, and interrupted runs appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.md) {
                        ForEach(vm.finishedItems) { item in
                            FinishedThreadCard(item: item) {
                                vm.openFinished(item)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.xxl)
                    .padding(.bottom, DS.Space.xxl)
                }
                .accessibilityIdentifier("activeThreads.finishedList")
            }
        }
    }

    private var footerBar: some View {
        AgentListFooterBar(
            caption: vm.footerLine,
            pillTitle: vm.activeCount > 0 ? "Live" : "Idle",
            pillTone: vm.activeCount > 0 ? .warning : .neutral
        )
        .accessibilityLabel(vm.footerLine)
    }
}

// MARK: - Cards

private struct ActiveThreadCard: View {
    let item: PetActiveThreadItem
    let onOpen: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: "bolt.horizontal.circle.fill",
            iconColor: Color.blue,
            title: item.title,
            subtitle: item.detail ?? item.workspaceName ?? "Agent",
            preview: {
                guard let preview = item.lastUpdatePreview, !preview.isEmpty else { return nil }
                return preview
            }(),
            identifier: "activeThreads.active.\(item.threadID.value.uuidString.lowercased())",
            onOpen: onOpen
        ) {
            DSPill("Running", tone: .warning)
        } meta: {
            EmptyView()
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
        }
    }
}

private struct FinishedThreadCard: View {
    let item: FinishedThreadItem
    let onOpen: () -> Void

    var body: some View {
        AgentOverviewCard(
            icon: statusIcon,
            iconColor: statusColor,
            title: item.title,
            subtitle: item.detail,
            identifier: "activeThreads.finished.\(item.runID.value.uuidString.lowercased())",
            onOpen: onOpen
        ) {
            statusPill
        } meta: {
            AgentOverviewMetaColumn(
                title: "Finished",
                value: finishedLabel,
                alignment: .trailing,
                multilineTextAlignment: .trailing
            )
        } trailing: {
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Palette.textTertiary)
        }
    }

    private var finishedLabel: String {
        guard let finished = item.finishedAt else { return "—" }
        return finished.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var statusIcon: String {
        switch item.status {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .interrupted: return "exclamationmark.triangle.fill"
        case .pending, .running: return "circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .completed: return DS.Palette.success
        case .failed: return DS.Palette.danger
        case .cancelled, .interrupted: return DS.Palette.warning
        case .pending, .running: return DS.Palette.textTertiary
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch item.status {
        case .completed: DSPill("Completed", tone: .success)
        case .failed: DSPill("Failed", tone: .danger)
        case .cancelled: DSPill("Cancelled", tone: .neutral)
        case .interrupted: DSPill("Interrupted", tone: .warning)
        case .pending: DSPill("Pending", tone: .warning)
        case .running: DSPill("Running", tone: .warning)
        }
    }
}
