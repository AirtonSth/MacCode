import Foundation
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter. Requests authorization
/// once; subsequent posts are best-effort. If authorization is denied
/// notifications still get persisted via the NotificationRepository so
/// the in-app feed is unaffected.
public final class SystemNotifier {
    public static let shared = SystemNotifier()
    private var authorized = false

    public func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    public func post(title: String, body: String?, category: String?) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let b = body { content.body = b }
        if let c = category { content.categoryIdentifier = c }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
