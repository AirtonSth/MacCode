import Foundation
import AppKit
import UserNotifications

/// Thin wrapper around UNUserNotificationCenter. Requests authorization
/// once; subsequent posts are best-effort. If authorization is denied
/// notifications still get persisted via the NotificationRepository so
/// the in-app feed is unaffected.
public final class SystemNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = SystemNotifier()

    // `authorized` is written from UNUserNotificationCenter's authorization
    // callback (arbitrary queue) and read from `post(...)` on arbitrary
    // callers. Guard both with a lock so the access is a proper barrier
    // (previously a plain Bool, which TSan flagged and could drop the first
    // post after launch).
    private let authLock = NSLock()
    private var _authorized = false
    private var authorized: Bool {
        get { authLock.lock(); defer { authLock.unlock() }; return _authorized }
        set { authLock.lock(); _authorized = newValue; authLock.unlock() }
    }

    private override init() {
        super.init()
    }

    public func bootstrap() {
        // UNUserNotificationCenter requires the process to be a real
        // bundled .app. Running from `swift run` produces a binary
        // without a bundle identifier and would crash on .current().
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: RemoteCodeNotificationContent.threadUpdateCategoryIdentifier,
                actions: [
                    UNNotificationAction(
                        identifier: RemoteCodeNotificationContent.openActionIdentifier,
                        title: "Open",
                        options: [.foreground]
                    )
                ],
                intentIdentifiers: [],
                options: []
            )
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    public func post(title: String, body: String?, category: String?) {
        guard authorized, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let b = body { content.body = b }
        if let c = category { content.categoryIdentifier = c }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    public func post(_ content: RemoteCodeNotificationContent) {
        guard authorized, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().add(content.makeRequest(), withCompletionHandler: nil)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions(appIsForeground: true))
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        completionHandler()
    }

    public static func presentationOptions(appIsForeground: Bool) -> UNNotificationPresentationOptions {
        appIsForeground ? [] : [.banner, .list, .sound]
    }
}
