import Foundation
import CoreModel
import Persistence

public final class PetAttentionStore {
    private let threadRepository: AgentThreadRepository
    private let callbackRepository: ProviderPendingCallbackRepository
    private let notificationRepository: NotificationRepository
    private let markAgentThreadReadMutation: (AgentThreadID) throws -> Void
    private let markNotificationReadMutation: (String) throws -> Void

    public init(
        threadRepository: AgentThreadRepository,
        callbackRepository: ProviderPendingCallbackRepository,
        notificationRepository: NotificationRepository,
        markAgentThreadRead: ((AgentThreadID) throws -> Void)? = nil,
        markNotificationRead: ((String) throws -> Void)? = nil
    ) {
        self.threadRepository = threadRepository
        self.callbackRepository = callbackRepository
        self.notificationRepository = notificationRepository
        self.markAgentThreadReadMutation = markAgentThreadRead ?? { threadID in
            guard var thread = try threadRepository.get(id: threadID) else { return }
            thread.hasUnread = false
            try threadRepository.upsert(thread)
        }
        self.markNotificationReadMutation = markNotificationRead ?? { id in
            try notificationRepository.markRead(id: id)
        }
    }

    public func refresh(filter: PetAttentionFilter = .all) throws -> PetAttentionSnapshot {
        let threads = try threadRepository.list()
        let threadsByID = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let callbacks = try callbackRepository.list(states: [.pending, .stale])
        let blockedThreadIDs = Set(callbacks.map(\.threadId))

        let callbackItems = callbacks.map { callback in
            Self.callbackItem(callback, thread: threadsByID[callback.threadId])
        }
        let threadItems = threads
            .filter { $0.hasUnread && !blockedThreadIDs.contains($0.id) }
            .compactMap(Self.threadItem)
        let notificationItems = try notificationRepository.list(unreadOnly: true)
            .compactMap(Self.notificationItem)

        let allItems = (callbackItems + threadItems + notificationItems)
            .sorted(by: Self.attentionOrder)
        let filtered: [PetAttentionItem]
        switch filter {
        case .all:
            filtered = allItems
        case .completed:
            filtered = allItems.filter { $0.classification == .completed }
        case .needsYou:
            filtered = allItems.filter { $0.classification == .needsYou }
        }
        return PetAttentionSnapshot(items: filtered)
    }

    /// Opens the stored route first and mutates persistence only after the caller
    /// confirms that the exact destination is visible. Provider callbacks remain
    /// blockers until their normal approval/question response resolves them.
    public func openAndMarkRead(
        itemID: String,
        verifyRoute: (PetAttentionRoute) throws -> Bool
    ) throws -> PetAttentionMarkResult {
        guard let item = try refresh().items.first(where: { $0.id == itemID }) else {
            return .notFound
        }
        guard try verifyRoute(item.route) else { return .routeRejected }

        switch item.source {
        case .callback(let threadID, let requestID, let kind):
            guard case .callback(_, let isStale) = item.kind, isStale else {
                return .retainedBlocker
            }
            try callbackRepository.resolve(
                threadId: threadID,
                requestId: requestID,
                kind: kind == .approval ? .approval : .userInput,
                state: .acknowledged
            )
            return .marked
        case .agentThread(let threadID):
            guard try threadRepository.get(id: threadID) != nil else { return .notFound }
            try markAgentThreadReadMutation(threadID)
            return .marked
        case .notification(let id):
            guard !item.kind.needsUserAction else { return .retainedBlocker }
            try markNotificationReadMutation(id)
            return .marked
        }
    }

    /// Marks projected outcome rows read. It deliberately never calls any
    /// callback-repository mutation, so approvals/questions cannot be bulk-resolved.
    @discardableResult
    public func markAllRead() throws -> Int {
        var marked = 0
        for thread in try threadRepository.list()
            where thread.hasUnread && Self.outcome(for: thread.status) != nil {
            try markAgentThreadReadMutation(thread.id)
            marked += 1
        }
        for notification in try notificationRepository.list(unreadOnly: true)
            where Self.notificationItem(notification)?.classification == .completed {
            try markNotificationReadMutation(notification.id)
            marked += 1
        }
        return marked
    }

    private static func callbackItem(
        _ callback: ProviderPendingCallback,
        thread: AgentThread?
    ) -> PetAttentionItem {
        let kind: PetAttentionCallbackKind = callback.kind == .approval ? .approval : .question
        let isStale = callback.state == .stale
        let context = PetAttentionContext(providerName: thread.map { providerLabel($0.provider) })
        let title: String
        if isStale {
            title = kind == .approval ? "Approval expired" : "Input request expired"
        } else {
            title = kind == .approval
                ? PetAttentionPresentation.safe(kind: .approval).title
                : PetAttentionPresentation.safe(kind: .question(isSecret: false)).title
        }
        return PetAttentionItem(
            id: "callback:\(callback.threadId.value.uuidString):\(kind.rawValue):\(callback.requestId)",
            kind: .callback(kind, isStale: isStale),
            title: title,
            detail: PetAttentionPresentation.safe(
                kind: kind == .approval ? .approval : .question(isSecret: false),
                context: context
            ).detail,
            createdAt: callback.createdAt,
            route: .agentThread(threadID: callback.threadId, workspaceID: thread?.workspaceId),
            source: .callback(
                threadID: callback.threadId,
                requestID: callback.requestId,
                kind: kind
            )
        )
    }

    private static func threadItem(_ thread: AgentThread) -> PetAttentionItem? {
        guard let outcome = outcome(for: thread.status) else { return nil }
        let presentation = PetAttentionPresentation.safe(
            kind: .agentOutcome(outcome),
            context: PetAttentionContext(providerName: providerLabel(thread.provider))
        )
        return PetAttentionItem(
            id: "thread:\(thread.id.value.uuidString)",
            kind: .agentOutcome(outcome),
            title: presentation.title,
            detail: presentation.detail,
            createdAt: thread.updatedAt,
            route: .agentThread(threadID: thread.id, workspaceID: thread.workspaceId),
            source: .agentThread(threadID: thread.id)
        )
    }

    private static func notificationItem(_ notification: AppNotification) -> PetAttentionItem? {
        guard let rawCategory = notification.category,
              let category = PetNotificationCategory(rawValue: rawCategory) else { return nil }
        let presentation = category.presentation
        let route: PetAttentionRoute
        switch category {
        case .providerUpdateFailed:
            route = .settings(.providers)
        case .serverListenerFailed:
            route = .settings(.general)
        case .gitCompleted, .gitFailed:
            if let surfaceID = notification.surfaceId {
                route = .surface(surfaceID: surfaceID, workspaceID: notification.workspaceId)
            } else if let workspaceID = notification.workspaceId {
                route = .workspace(workspaceID: workspaceID)
            } else {
                return nil
            }
        case .projectScriptCompleted, .projectScriptFailed,
             .sshTransferCompleted, .sshTransferFailed, .sshUnexpectedDisconnect,
             .fileConflict:
            guard let surfaceID = notification.surfaceId else { return nil }
            route = .surface(surfaceID: surfaceID, workspaceID: notification.workspaceId)
        }
        return PetAttentionItem(
            id: "notification:\(notification.id)",
            kind: .notification(category),
            title: presentation.title,
            detail: presentation.detail,
            createdAt: notification.createdAt,
            route: route,
            source: .notification(id: notification.id)
        )
    }

    private static func outcome(for status: AgentRunStatus) -> PetAttentionOutcome? {
        switch status {
        case .completed:
            return .completed
        case .failed:
            return .failed
        case .cancelled, .interrupted:
            return .interrupted
        case .pending, .running:
            return nil
        }
    }

    private static func attentionOrder(_ lhs: PetAttentionItem, _ rhs: PetAttentionItem) -> Bool {
        if lhs.classification != rhs.classification {
            return lhs.classification == .needsYou
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id < rhs.id
    }

    private static func providerLabel(_ provider: AgentProvider) -> String {
        switch provider {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}
