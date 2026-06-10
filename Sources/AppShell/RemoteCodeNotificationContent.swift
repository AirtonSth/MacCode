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
        title: String?,
        phase: AgentRunStatus
    ) -> RemoteCodeNotificationContent? {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (normalizedTitle?.isEmpty == false) ? normalizedTitle! : "Thread"

        guard let parts = outcomeNotificationParts(
            threadId: threadId,
            displayTitle: displayTitle,
            phase: phase
        ) else { return nil }

        let outcome = parts.identifierSuffix
        return RemoteCodeNotificationContent(
            identifier: "thread.\(threadId).\(outcome)",
            title: parts.title,
            body: parts.body,
            categoryIdentifier: Self.threadUpdateCategoryIdentifier,
            threadIdentifier: parts.threadIdentifier,
            userInfo: ["threadId": threadId, "outcome": outcome]
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
