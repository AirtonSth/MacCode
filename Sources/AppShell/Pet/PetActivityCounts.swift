import Foundation
import CoreModel
import SocketServer

struct PetActivityCounts: Equatable {
    let running: Int
    let needsYou: Int
    let newResults: Int
    let isAvailable: Bool

    static let zero = PetActivityCounts(running: 0, needsYou: 0, newResults: 0, isAvailable: false)

    init(running: Int, needsYou: Int, newResults: Int, isAvailable: Bool = true) {
        self.running = running
        self.needsYou = needsYou
        self.newResults = newResults
        self.isAvailable = isAvailable
    }

    init(_ counts: ActivityCounts) {
        running = counts.running
        needsYou = counts.needsYou
        newResults = counts.newResults
        isAvailable = true
    }
}

@MainActor
final class PetActivityCountsProjection {
    static let shared = PetActivityCountsProjection()

    private(set) var global = PetActivityCounts.zero
    private(set) var byWorkspace: [String: PetActivityCounts] = [:]
    private var observers: [UUID: (PetActivityCounts, [String: PetActivityCounts]) -> Void] = [:]
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var refreshPending = false
    private var refreshDirty = false
    private var latestWorkspaceIDs: Set<WorkspaceID> = []
    private weak var latestRouter: AppCommandRouter?
    private var eventSubscription: UUID?

    func observe(_ observer: @escaping (PetActivityCounts, [String: PetActivityCounts]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        observer(global, byWorkspace)
        return id
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func refresh(router: AppCommandRouter, workspaceIDs: [WorkspaceID]) {
        if latestRouter !== router {
            task?.cancel()
            generation &+= 1
            refreshPending = false
            refreshDirty = false
            global = .zero
            byWorkspace = [:]
        }
        latestRouter = router
        latestWorkspaceIDs = Set(workspaceIDs)
        if eventSubscription == nil {
            eventSubscription = EventBus.shared.subscribeFromCurrent { [weak self] event in
                let kinds: Set<String> = [
                    "notification.created", "notification.read", "notification.dismissed", "bot.attention.updated", "bot.scheduler.updated",
                    "agent.run.started", "agent.run.finished", "agent.run.completed", "agent.run.failed", "agent.run.cancelled",
                    "agent.request.opened", "agent.request.resolved", "agent.user_input.requested", "agent.user_input.resolved",
                    "agent.thread.read", "agent.thread.updated", "agent.thread.renamed", "agent.thread.deleted", "agent.thread.deleted_many",
                    "bots.attention.changed", "bot.attention.updated", "bot.scheduler.updated", "bot.routine.updated", "bot.routine.run_requested",
                    "bot.run.started", "bot.run.completed", "bot.run.failed",
                ]
                guard kinds.contains(event.kind) else { return }
                Task { @MainActor [weak self] in
                    guard let self, let router = self.latestRouter else { return }
                    self.refresh(router: router, workspaceIDs: Array(self.latestWorkspaceIDs))
                }
            }.id
        }
        guard !refreshPending else { refreshDirty = true; return }
        refreshDirty = false
        let requestedWorkspaceIDs = latestWorkspaceIDs
        refreshPending = true
        generation &+= 1
        let request = generation
        task?.cancel()
        task = Task { @MainActor [weak self, weak router] in
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            guard let self, self.generation == request else { return }
            defer {
                if self.generation == request {
                    self.refreshPending = false
                    self.task = nil
                    if (self.refreshDirty || requestedWorkspaceIDs != self.latestWorkspaceIDs), let latestRouter = self.latestRouter {
                        self.refresh(router: latestRouter, workspaceIDs: Array(self.latestWorkspaceIDs))
                    }
                }
            }
            guard let router, !Task.isCancelled, self.latestRouter === router else { return }
            do {
                let globalPage = try await Self.load(router: router, workspaceID: nil)
                var workspacePages: [String: PetActivityCounts] = [:]
                for workspaceID in requestedWorkspaceIDs {
                    guard !Task.isCancelled, self.generation == request else { return }
                    if let counts = globalPage.workspaceCounts {
                        workspacePages[workspaceID.value.uuidString] = PetActivityCounts(counts[workspaceID.value.uuidString] ?? ActivityCounts(running: 0, queued: 0, needsYou: 0, finished: 0, newResults: 0))
                    } else {
                        let workspacePage = try await Self.load(router: router, workspaceID: workspaceID.value.uuidString)
                        workspacePages[workspaceID.value.uuidString] = PetActivityCounts(workspacePage.counts)
                    }
                }
                guard !Task.isCancelled, self.generation == request else { return }
                self.global = PetActivityCounts(globalPage.counts)
                self.byWorkspace = workspacePages
                for observer in self.observers.values { observer(self.global, self.byWorkspace) }
            } catch {
                guard !Task.isCancelled, self.generation == request, self.latestRouter === router else { return }
                self.global = Self.unavailable(self.global)
                self.byWorkspace = self.byWorkspace.mapValues(Self.unavailable)
                for observer in self.observers.values { observer(self.global, self.byWorkspace) }
            }
        }
    }

    private static func unavailable(_ counts: PetActivityCounts) -> PetActivityCounts {
        PetActivityCounts(
            running: counts.running,
            needsYou: counts.needsYou,
            newResults: counts.newResults,
            isAvailable: false
        )
    }

    private static func load(router: AppCommandRouter, workspaceID: String?) async throws -> ActivityPage {
        var params: [String: JSONValue] = ["limit": .number(1)]
        if let workspaceID { params["workspace_id"] = .string(workspaceID) }
        let value = try await router.activityListOffMain(params: params)
        return try ActivityPage.makeJSONDecoder().decode(ActivityPage.self, from: JSONEncoder().encode(value))
    }
}
