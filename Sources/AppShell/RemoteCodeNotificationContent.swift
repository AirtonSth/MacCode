import CoreModel
import Foundation
import UserNotifications

public struct RemoteCodeNotificationContent: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String
    public let categoryIdentifier: String
    public let userInfo: [String: String]

    public static let threadUpdateCategoryIdentifier = "RemoteCodeThreadUpdate"
    public static let openActionIdentifier = "thread.open"

    public static func threadOutcome(
        threadId: String,
        title: String?,
        phase: AgentRunStatus
    ) -> RemoteCodeNotificationContent? {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (normalizedTitle?.isEmpty == false) ? normalizedTitle! : "Thread"

        switch phase {
        case .completed:
            return RemoteCodeNotificationContent(
                identifier: "thread.\(threadId).completed",
                title: "Thread finished",
                body: "\(displayTitle) response is ready.",
                categoryIdentifier: Self.threadUpdateCategoryIdentifier,
                userInfo: ["threadId": threadId, "outcome": "completed"]
            )
        case .failed, .cancelled, .interrupted:
            return RemoteCodeNotificationContent(
                identifier: "thread.\(threadId).failed",
                title: "Thread failed",
                body: "\(displayTitle) ended with an error.",
                categoryIdentifier: Self.threadUpdateCategoryIdentifier,
                userInfo: ["threadId": threadId, "outcome": "failed"]
            )
        case .pending, .running:
            return nil
        }
    }

    public func makeRequest() -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}
