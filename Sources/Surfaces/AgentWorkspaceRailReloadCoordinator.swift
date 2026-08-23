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
/// - One shared subagent activity poll round runs across all workspaces.
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
    private var subagentPollTask: Task<Void, Never>?
    /// Debounce window for EventBus fan-out storms.
    public var debounceNanoseconds: UInt64 = 50_000_000
    /// Shared subagent badge poll interval (was 2s per open surface).
    public var subagentPollNanoseconds: UInt64 = 2_000_000_000

    #if DEBUG
    private var subagentPollHasMembersForTesting: (() -> Bool)?
    private var subagentPollSleepForTesting: ((UInt64) async throws -> Void)?
    private var subagentPollRoundForTesting: (() async -> Void)?
    var subagentPollIsRunningForTesting: Bool { subagentPollTask != nil }
    #endif

    private init() {}

    #if DEBUG
    init(
        subagentPollNanoseconds: UInt64,
        hasMembers: @escaping () -> Bool,
        sleep: @escaping (UInt64) async throws -> Void,
        pollRound: @escaping () async -> Void
    ) {
        self.subagentPollNanoseconds = subagentPollNanoseconds
        subagentPollHasMembersForTesting = hasMembers
        subagentPollSleepForTesting = sleep
        subagentPollRoundForTesting = pollRound
    }

    func reconcileSubagentPollForTesting() {
        guard hasSubagentPollMembers else { return }
        ensureSubagentPoll()
    }

    func cancelSubagentPollForTesting() {
        let task = subagentPollTask
        task?.cancel()
    }
    #endif

    public func register(_ viewModel: AgentAppViewModel) {
        let key = ObjectIdentifier(viewModel)
        var bucket = members[viewModel.workspaceID] ?? [:]
        bucket[key] = WeakBox(viewModel: viewModel)
        members[viewModel.workspaceID] = bucket
        ensureSubagentPoll()
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
        } else {
            members[workspaceID] = bucket
        }
        // The shared loop observes empty membership before its next round and
        // exits itself. Do not cancel here: a detached receipt read cannot be
        // cancelled safely, and a replacement loop could overlap it.
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

    private func ensureSubagentPoll() {
        guard subagentPollTask == nil else { return }
        // One loop owns every workspace round. The receipt reads themselves run
        // off-main, but they must not overlap: all workspaces share one receipt
        // store and its cross-process mutex. Starting one repeating task per
        // workspace caused concurrent full scans every two seconds.
        subagentPollTask = Task { @MainActor [weak self] in
            defer { self?.subagentPollTask = nil }
            while !Task.isCancelled {
                let interval = self?.subagentPollNanoseconds ?? 2_000_000_000
                #if DEBUG
                if let sleep = self?.subagentPollSleepForTesting {
                    try? await sleep(interval)
                } else {
                    try? await Task.sleep(nanoseconds: interval)
                }
                #else
                try? await Task.sleep(nanoseconds: interval)
                #endif
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard self.hasSubagentPollMembers else { return }
                await self.runSubagentPollRound()
                guard self.hasSubagentPollMembers else { return }
            }
        }
    }

    private var hasSubagentPollMembers: Bool {
        #if DEBUG
        if let hasMembers = subagentPollHasMembersForTesting {
            return hasMembers()
        }
        #endif
        return !members.isEmpty
    }

    private func runSubagentPollRound() async {
        #if DEBUG
        if let pollRound = subagentPollRoundForTesting {
            await pollRound()
            return
        }
        #endif
        let workspaceIDs = Array(members.keys)
        await flushSubagents(workspaceIDs)
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

    private func flushSubagents(_ workspaceIDs: [WorkspaceID]) async {
        // One receipt-store scan serves the complete app round. Surfaces with no
        // selected thread stay empty without adding work.
        let targets: [(viewModel: AgentAppViewModel, threadId: AgentThreadID)] = workspaceIDs.flatMap { workspaceID in
            liveViewModels(for: workspaceID).compactMap { viewModel in
                guard let threadId = viewModel.selectedThreadId else { return nil }
                guard viewModel.selectedThreadRunIsStartingOrRunning || viewModel.subagentActivity.isLive else {
                    return nil
                }
                return (viewModel, threadId)
            }
        }
        guard let lead = targets.first else { return }
        let threadIDs = Array(Set(targets.map(\.threadId)))
        let snapshots = await lead.viewModel.loadSubagentActivitySnapshotsOffMainActor(for: threadIDs)
        for target in targets {
            target.viewModel.applySubagentActivity(
                snapshots[target.threadId] ?? .empty,
                loadedFor: target.threadId
            )
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
