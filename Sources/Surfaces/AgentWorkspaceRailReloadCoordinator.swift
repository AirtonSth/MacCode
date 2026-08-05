import Foundation
import CoreModel
import Persistence
import AgentRuntime

/// Coalesces multi-surface Agent App rail reloads for one workspace.
///
/// Without this, N open Agent tabs each subscribe to EventBus and each call
/// `reloadThreads()` (cap enforce + list) on every `agent.thread.*` event.
/// One create/delete therefore became N SQLite cap transactions.
///
/// Contract:
/// - At most one cap+list per workspace per debounce window.
/// - All live surfaces for that workspace apply the same snapshot.
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
    private var debounceTasks: [WorkspaceID: Task<Void, Never>] = [:]
    /// Debounce window for EventBus fan-out storms.
    public var debounceNanoseconds: UInt64 = 50_000_000

    private init() {}

    public func register(_ viewModel: AgentAppViewModel) {
        let key = ObjectIdentifier(viewModel)
        var bucket = members[viewModel.workspaceID] ?? [:]
        bucket[key] = WeakBox(viewModel: viewModel)
        members[viewModel.workspaceID] = bucket
    }

    public func unregister(_ viewModel: AgentAppViewModel) {
        let key = ObjectIdentifier(viewModel)
        guard var bucket = members[viewModel.workspaceID] else { return }
        bucket.removeValue(forKey: key)
        if bucket.isEmpty {
            members.removeValue(forKey: viewModel.workspaceID)
            debounceTasks[viewModel.workspaceID]?.cancel()
            debounceTasks.removeValue(forKey: viewModel.workspaceID)
        } else {
            members[viewModel.workspaceID] = bucket
        }
    }

    /// EventBus / external path: coalesce N surface notifications into one rail load.
    public func requestCoalescedReload(workspaceID: WorkspaceID) {
        debounceTasks[workspaceID]?.cancel()
        debounceTasks[workspaceID] = Task { @MainActor [weak self] in
            let delay = self?.debounceNanoseconds ?? 50_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.flush(workspaceID)
        }
    }

    private func flush(_ workspaceID: WorkspaceID) async {
        let live = liveViewModels(for: workspaceID)
        guard let lead = live.first else { return }
        let snapshot = await lead.loadRailSnapshotOffMainActor()
        for viewModel in live {
            viewModel.applyRailSnapshot(snapshot)
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
        // Stable order so the same lead tends to own cap work.
        return live.sorted { ObjectIdentifier($0).debugDescription < ObjectIdentifier($1).debugDescription }
    }
}
