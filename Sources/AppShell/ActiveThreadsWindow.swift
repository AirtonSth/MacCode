import AppKit
import CoreModel
import DesignSystemKit
import Persistence
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

    public init(context: AppContext, router: AppCommandRouter) {
        self.context = context
        self.router = router
        reload()
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
        let threadIDs = Array(context.coordinator.activeThreadIdsSnapshot())
        let activeSet = Set(threadIDs)
        startedAtByThread = startedAtByThread.filter { activeSet.contains($0.key) }

        for threadID in threadIDs {
            if startedAtByThread[threadID] == nil {
                if let runId = context.coordinator.activeRunId(threadId: threadID),
                   let run = try? context.runRepo.get(id: runId) {
                    startedAtByThread[threadID] = run.startedAt
                } else if let durable = try? context.coordinator.durableActiveRun(threadId: threadID) {
                    startedAtByThread[threadID] = durable.startedAt
                } else {
                    startedAtByThread[threadID] = Date()
                }
            }
        }

        activeItems = PetActiveThreadProjector.items(threadIDs: threadIDs) { [weak self] threadID in
            guard let self,
                  let thread = try? self.context.threadRepo.get(id: threadID) else {
                return nil
            }
            let workspaceName = thread.workspaceId.flatMap { self.context.state.workspaces[$0]?.name }
            return (
                workspaceID: thread.workspaceId,
                workspaceName: workspaceName,
                providerName: PetActiveThreadProjector.providerLabel(thread.provider),
                threadTitle: thread.title,
                startedAt: self.startedAtByThread[threadID],
                lastUpdatePreview: nil
            )
        }
    }

    public func reloadFinished() {
        do {
            let runs = try context.runRepo.listRecentFinished(limit: 50)
            finishedItems = runs.compactMap { run in
                let thread = try? context.threadRepo.get(id: run.threadId)
                let workspaceID = thread?.workspaceId
                let workspaceName = workspaceID.flatMap { context.state.workspaces[$0]?.name }
                return FinishedThreadItem(
                    run: run,
                    threadTitle: thread?.title,
                    workspaceID: workspaceID,
                    workspaceName: workspaceName,
                    providerName: PetActiveThreadProjector.providerLabel(run.provider)
                )
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func openActive(_ item: PetActiveThreadItem) {
        if case .botsDesk(let botID) = item.route {
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
        do {
            // Leave the shell destination first so Agent App can mount in the
            // main content column (same bug class as Schedule Tasks open).
            router.windowController?.presentWorkspaceContent()
            _ = try router.openAgentThread(thread: threadID, markRead: false)
        } catch {
            errorMessage = "Could not open thread: \(error.localizedDescription)"
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
        .onAppear { vm.reload() }
        .onChange(of: vm.selectedTab) { tab in
            if tab == .lastFinished {
                vm.reloadFinished()
            } else {
                vm.reloadActive()
            }
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
                let selected = vm.selectedTab == tab
                let count: Int = {
                    switch tab {
                    case .active: return vm.activeCount
                    case .lastFinished: return vm.finishedCount
                    }
                }()
                Button {
                    vm.selectedTab = tab
                } label: {
                    HStack(spacing: DS.Space.xs) {
                        Text(tab.title)
                            .font(DS.Font.body.weight(selected ? .semibold : .regular))
                        Text("\(count)")
                            .font(DS.Font.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundColor(selected ? DS.Palette.accent : DS.Palette.textTertiary)
                    }
                    .foregroundColor(selected ? DS.Palette.text : DS.Palette.textSecondary)
                    .padding(.horizontal, DS.Space.md)
                    .padding(.vertical, DS.Space.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(selected ? DS.Palette.selection : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(selected ? DS.Palette.accent.opacity(0.35) : DS.Palette.line,
                                          lineWidth: DS.Border.hairline)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("activeThreads.tab.\(tab.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
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
        HStack(spacing: DS.Space.md) {
            Text(vm.footerLine)
                .font(DS.Font.caption)
                .foregroundColor(DS.Palette.textSecondary)
            if vm.activeCount > 0 {
                DSPill("Live", tone: .warning)
                    .accessibilityHidden(true)
            } else {
                DSPill("Idle", tone: .neutral)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: DS.Space.md)
        }
        .padding(.horizontal, DS.Space.xxl)
        .frame(height: 40)
        .background(DS.Palette.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(vm.footerLine)
    }
}

// MARK: - Cards

private struct ActiveThreadCard: View {
    let item: PetActiveThreadItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(Color.blue)
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
                        Text(item.title)
                            .font(DS.Font.body.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(1)
                        DSPill("Running", tone: .warning)
                    }
                    Text(item.detail ?? item.workspaceName ?? "Agent")
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                    if let preview = item.lastUpdatePreview, !preview.isEmpty {
                        Text(preview)
                            .font(DS.Font.caption)
                            .foregroundColor(DS.Palette.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
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
        .accessibilityIdentifier("activeThreads.active.\(item.threadID.value.uuidString.lowercased())")
    }
}

private struct FinishedThreadCard: View {
    let item: FinishedThreadItem
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: DS.Space.xl) {
                Image(systemName: statusIcon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(statusColor)
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
                        Text(item.title)
                            .font(DS.Font.body.weight(.semibold))
                            .foregroundColor(DS.Palette.text)
                            .lineLimit(1)
                        statusPill
                    }
                    Text(item.detail)
                        .font(DS.Font.caption)
                        .foregroundColor(DS.Palette.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 2) {
                    Text("Finished")
                        .font(DS.Font.caption2)
                        .foregroundColor(DS.Palette.textTertiary)
                    Text(finishedLabel)
                        .font(DS.Font.caption.weight(.medium))
                        .foregroundColor(DS.Palette.text)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                .frame(width: 140, alignment: .trailing)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Palette.textTertiary)
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
        .accessibilityIdentifier("activeThreads.finished.\(item.runID.value.uuidString.lowercased())")
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
