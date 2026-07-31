import CoreModel
import Foundation
import UserNotifications

public struct RemoteCodeNotificationContent: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String
    public let categoryIdentifier: String
    public let threadIdentifier: String
    public let userInfo: [String: String]

    public static let threadUpdateCategoryIdentifier = "RemoteCodeThreadUpdate"
    public static let openActionIdentifier = "thread.open"

    /// Agent App visible push policy (main agent only).
    ///
    /// - Subagent / nested orchestration workers never produce push banners.
    /// - Main agent banners only for terminal outcomes or user-action requests
    ///   (approval / question). Mid-run progress stays stream-only.
    public enum AgentAppPushPolicy: Sendable {
        /// Orchestration receipts with a parent are nested workers (subagents).
        public static func isNestedWorker(
            parentReceiptId: UUID?,
            nodeId: String?
        ) -> Bool {
            if parentReceiptId != nil { return true }
            guard let nodeId else { return false }
            let trimmed = nodeId.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && trimmed != "root"
        }

        public static func shouldNotifyThreadOutcome(
            phase: AgentRunStatus,
            isNestedWorker: Bool
        ) -> Bool {
            guard !isNestedWorker else { return false }
            switch phase {
            case .completed, .failed, .interrupted, .cancelled:
                return true
            case .pending, .running:
                return false
            }
        }

        public static func shouldNotifyUserAction(isNestedWorker: Bool) -> Bool {
            !isNestedWorker
        }

        /// Remote terminal APNs banner when a Live Activity card can already
        /// show the outcome. Attention (approval/question) is never gated here.
        ///
        /// - Not armed → always deliver (no LA cover).
        /// - Armed + cancelled → still deliver: LA soft-maps cancel toward a
        ///   "ready" phase, so the explicit "Thread cancelled" banner is the
        ///   only clear stop signal.
        /// - Armed + completed/failed/interrupted → suppress (LA covers it).
        public static func shouldDeliverRemoteFinishAlert(
            phase: AgentRunStatus,
            liveActivityUpdateChannelArmed: Bool
        ) -> Bool {
            guard liveActivityUpdateChannelArmed else { return true }
            switch phase {
            case .cancelled:
                return true
            case .completed, .failed, .interrupted:
                return false
            case .pending, .running:
                return false
            }
        }

        /// Host-side armed check: a **current** activity_update courier (not
        /// push-to-start / legacy liveActivityToken). Legacy start tokens latch
        /// for the life of the install and would suppress finish banners forever
        /// even with no card on Lock Screen.
        public static func isLiveActivityUpdateChannelArmed(
            activityUpdateTokens: [String]
        ) -> Bool {
            activityUpdateTokens.contains {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }

    /// Pure helper: maps a run outcome to (title, body, identifier suffix, threadIdentifier).
    /// Extracted for testability without touching UNUserNotificationCenter.
    nonisolated static func outcomeNotificationParts(
        threadId: String,
        displayTitle: String,
        phase: AgentRunStatus
    ) -> (title: String, body: String, identifierSuffix: String, threadIdentifier: String)? {
        switch phase {
        case .completed:
            return (
                title: "Thread finished",
                body: "\(displayTitle) response is ready.",
                identifierSuffix: "completed",
                threadIdentifier: threadId
            )
        case .failed, .interrupted:
            return (
                title: "Thread failed",
                body: "\(displayTitle) ended with an error.",
                identifierSuffix: "failed",
                threadIdentifier: threadId
            )
        case .cancelled:
            return (
                title: "Thread cancelled",
                body: "\(displayTitle) was stopped before finishing.",
                identifierSuffix: "cancelled",
                threadIdentifier: threadId
            )
        case .pending, .running:
            return nil
        }
    }

    public static func threadOutcome(
        threadId: String,
        workspaceId: String? = nil,
        title: String?,
        phase: AgentRunStatus,
        isNestedWorker: Bool = false
    ) -> RemoteCodeNotificationContent? {
        guard AgentAppPushPolicy.shouldNotifyThreadOutcome(
            phase: phase,
            isNestedWorker: isNestedWorker
        ) else { return nil }

        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (normalizedTitle?.isEmpty == false) ? normalizedTitle! : "Thread"

        guard let parts = outcomeNotificationParts(
            threadId: threadId,
            displayTitle: displayTitle,
            phase: phase
        ) else { return nil }

        let outcome = parts.identifierSuffix
        // userInfo doubles as the remote-push `data` dictionary. The iOS tap
        // handler (AppRouter.routeIntent) reads workspaceId + threadId to open the
        // exact thread; `category` lets it pick the right notification actions.
        // Without workspaceId the tap can only fall back to the Activity tab.
        var userInfo: [String: String] = [
            "threadId": threadId,
            "outcome": outcome,
            "category": Self.threadUpdateCategoryIdentifier,
        ]
        if let workspaceId, !workspaceId.trimmingCharacters(in: .whitespaces).isEmpty {
            userInfo["workspaceId"] = workspaceId
        }
        return RemoteCodeNotificationContent(
            identifier: "thread.\(threadId).\(outcome)",
            title: parts.title,
            body: parts.body,
            categoryIdentifier: Self.threadUpdateCategoryIdentifier,
            threadIdentifier: parts.threadIdentifier,
            userInfo: userInfo
        )
    }

    /// Visible push when the main agent needs the user (approval / question).
    /// Never used for nested/subagent workers.
    public static func userActionNeeded(
        threadId: String,
        workspaceId: String? = nil,
        threadTitle: String?,
        actionTitle: String,
        requestId: String,
        isNestedWorker: Bool = false
    ) -> RemoteCodeNotificationContent? {
        guard AgentAppPushPolicy.shouldNotifyUserAction(isNestedWorker: isNestedWorker) else {
            return nil
        }
        let normalizedThread = threadTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayThread = (normalizedThread?.isEmpty == false) ? normalizedThread! : "Thread"
        let normalizedAction = actionTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let action = normalizedAction.isEmpty ? "Action needed" : normalizedAction
        var userInfo: [String: String] = [
            "threadId": threadId,
            "outcome": "attention",
            "requestId": requestId,
            "category": Self.threadUpdateCategoryIdentifier,
        ]
        if let workspaceId, !workspaceId.trimmingCharacters(in: .whitespaces).isEmpty {
            userInfo["workspaceId"] = workspaceId
        }
        return RemoteCodeNotificationContent(
            identifier: "thread.\(threadId).attention.\(requestId)",
            title: action,
            body: "\(displayThread) needs your attention.",
            categoryIdentifier: Self.threadUpdateCategoryIdentifier,
            threadIdentifier: threadId,
            userInfo: userInfo
        )
    }

    public func makeRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = threadIdentifier
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
