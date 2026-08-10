import Foundation
import CoreModel
import Persistence
import AgentRuntime

/// Coalesces multi-surface Agent App work for one workspace.
///
/// Without this, N open Agent tabs each subscribe to EventBus and each call
/// `reloadThreads()` / `reloadQueuedMessages()` / subagent poll on their own.
/// One create/delete therefore became N SQLite cap transactions and N queue reads.
///
/// Contract:
/// - At most one cap+list per workspace per debounce window.
/// - At most one queue reload apply pass per workspace per debounce window.
/// - At most one subagent activity poll tick per workspace (not per surface).
/// - Cap/list run off the MainActor; apply stays on MainActor.
@MainActor
public final class AgentWorkspaceRailReloadCoordinator {
    public static let shared = AgentWorkspaceRailReloadCoordinator()

    public struct RailSnapshot: Sendable {
        public let workspaceID: WorkspaceID
        public let threads: [AgentThread]
        public let prunedThreadIDs: [AgentThreadID]
        public let errorDescription: String?

        public init(
            workspaceID: WorkspaceID,
            threads: [AgentThread],
            prunedThreadIDs: [AgentThreadID],
            errorDescription: String? = nil
        ) {
            self.workspaceID = workspaceID
            self.threads = threads
            self.prunedThreadIDs = prunedThreadIDs
            self.errorDescription = errorDescription
        }
    }

    private struct WeakBox {
        weak var viewModel: AgentAppViewModel?
    }

    private var members: [WorkspaceID: [ObjectIdentifier: WeakBox]] = [:]
    private var railDebounceTasks: [WorkspaceID: Task<Void, Never>] = [:]
    private var queueDebounceTasks: [WorkspaceID: Task<Void, Never>] = [:]
    private var subagentPollTasks: [WorkspaceID: Task<Void, Never>] = [:]
    /// Debounce window for EventBus fan-out storms.
    public var debounceNanoseconds: UInt64 = 50_000_000
    /// Shared subagent badge poll interval (was 2s per open surface).
    public var subagentPollNanoseconds: UInt64 = 2_000_000_000

    private init() {}

    public func register(_ viewModel: AgentAppViewModel) {
        let key = ObjectIdentifier(viewModel)
        var bucket = members[viewModel.workspaceID] ?? [:]
        bucket[key] = WeakBox(viewModel: viewModel)
        members[viewModel.workspaceID] = bucket
        ensureSubagentPoll(for: viewModel.workspaceID)
    }

    public func unregister(_ viewModel: AgentAppViewModel) {
        let key = ObjectIdentifier(viewModel)
        let workspaceID = viewModel.workspaceID
        guard var bucket = members[workspaceID] else { return }
        bucket.removeValue(forKey: key)
        if bucket.isEmpty {
            members.removeValue(forKey: workspaceID)
            railDebounceTasks[workspaceID]?.cancel()
            railDebounceTasks.removeValue(forKey: workspaceID)
            queueDebounceTasks[workspaceID]?.cancel()
            queueDebounceTasks.removeValue(forKey: workspaceID)
            subagentPollTasks[workspaceID]?.cancel()
            subagentPollTasks.removeValue(forKey: workspaceID)
        } else {
            members[workspaceID] = bucket
        }
    }

    /// EventBus / external path: coalesce N surface notifications into one rail load.
    public func requestCoalescedReload(workspaceID: WorkspaceID) {
        railDebounceTasks[workspaceID]?.cancel()
        railDebounceTasks[workspaceID] = Task { @MainActor [weak self] in
            let delay = self?.debounceNanoseconds ?? 50_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.flushRail(workspaceID)
        }
    }

    /// Coalesce queue reloads so N tabs do not each hit SQLite on the same event.
    public func requestCoalescedQueueReload(workspaceID: WorkspaceID) {
        queueDebounceTasks[workspaceID]?.cancel()
        queueDebounceTasks[workspaceID] = Task { @MainActor [weak self] in
            let delay = self?.debounceNanoseconds ?? 50_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.flushQueue(workspaceID)
        }
    }

    private func ensureSubagentPoll(for workspaceID: WorkspaceID) {
        guard subagentPollTasks[workspaceID] == nil else { return }
        // Intentionally NOT @MainActor for the whole loop: sleep + SQLite/JSON
        // load run off the main thread; only snapshot apply hops to MainActor.
        // WHY: sample stacks under 5 agent threads showed hang_breach on
        // refreshSubagentActivity → activityReceipts decode on the main thread.
        subagentPollTasks[workspaceID] = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { self?.subagentPollNanoseconds ?? 2_000_000_000 }
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.flushSubagent(workspaceID)
            }
        }
    }

    private func flushRail(_ workspaceID: WorkspaceID) async {
        let live = liveViewModels(for: workspaceID)
        guard let lead = live.first else { return }
        let snapshot = await lead.loadRailSnapshotOffMainActor()
        for viewModel in live {
            viewModel.applyRailSnapshot(snapshot)
        }
    }

    private func flushQueue(_ workspaceID: WorkspaceID) {
        for viewModel in liveViewModels(for: workspaceID) {
            viewModel.reloadQueuedMessages()
        }
    }

    private func flushSubagent(_ workspaceID: WorkspaceID) async {
        // One tick per workspace: only surfaces with a selected thread (badge context)
        // refresh; others stay empty without extra SQLite work.
        let targets: [(viewModel: AgentAppViewModel, threadId: AgentThreadID)] = await MainActor.run {
            liveViewModels(for: workspaceID).compactMap { viewModel in
                guard let threadId = viewModel.selectedThreadId else { return nil }
                return (viewModel, threadId)
            }
        }
        for target in targets {
            let snapshot = await target.viewModel.loadSubagentActivitySnapshotOffMainActor(
                for: target.threadId
            )
            await MainActor.run {
                target.viewModel.applySubagentActivity(snapshot, loadedFor: target.threadId)
            }
        }
    }

    private func liveViewModels(for workspaceID: WorkspaceID) -> [AgentAppViewModel] {
        guard var bucket = members[workspaceID] else { return [] }
        var live: [AgentAppViewModel] = []
        for (key, box) in bucket {
            if let vm = box.viewModel, !vm.isDisposedForReloadCoordination {
                live.append(vm)
            } else {
                bucket.removeValue(forKey: key)
            }
        }
        if bucket.isEmpty {
            members.removeValue(forKey: workspaceID)
        } else {
            members[workspaceID] = bucket
        }
        return live.sorted { ObjectIdentifier($0).debugDescription < ObjectIdentifier($1).debugDescription }
    }
}
