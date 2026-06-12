import Foundation
import AppKit
import UserNotifications

// MARK: - NotificationCenterClient DI seam (QA :96)

/// Abstracts the `UNUserNotificationCenter` calls that `SystemNotifier` makes
/// so unit tests can intercept posting without a real app bundle (the
/// `canUseNotificationCenter` guard makes UNCenter a no-op under `swift test`).
/// Production code uses `LiveNotificationCenterClient` which delegates to
/// `UNUserNotificationCenter.current()`.
public protocol NotificationCenterClient: Sendable {
    /// Schedules a notification request.
    func add(_ request: UNNotificationRequest, withCompletionHandler: ((Error?) -> Void)?)
    /// Registers the delegate for presentation callbacks.
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?)
    /// Registers notification categories.
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    /// Requests authorization; calls back with (granted, error).
    func requestAuthorization(options: UNAuthorizationOptions,
                              completionHandler: @escaping (Bool, Error?) -> Void)
    /// Returns the current notification settings.
    func notificationSettings() async -> UNNotificationSettings
}

/// Live implementation that delegates to `UNUserNotificationCenter.current()`.
public struct LiveNotificationCenterClient: NotificationCenterClient {
    public init() {}
    public func add(_ request: UNNotificationRequest, withCompletionHandler handler: ((Error?) -> Void)?) {
        UNUserNotificationCenter.current().add(request, withCompletionHandler: handler)
    }
    public func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        UNUserNotificationCenter.current().delegate = delegate
    }
    public func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
    public func requestAuthorization(options: UNAuthorizationOptions,
                                     completionHandler: @escaping (Bool, Error?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: options,
                                                                completionHandler: completionHandler)
    }
    public func notificationSettings() async -> UNNotificationSettings {
        await UNUserNotificationCenter.current().notificationSettings()
    }
}

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

    /// Called on the main thread whenever the user taps a delivered
    /// notification. Set by AppDelegate at launch to wire deep-linking.
    public var onNotificationResponse: ((UNNotificationResponse) -> Void)?

    /// Called when a `post(_:)` is silently dropped because the user has
    /// denied OS-level notification permission. Use this seam to surface
    /// an in-app fallback (e.g. badge, feed entry, alert) so a finished
    /// agent run is not invisible on a denied system (UX-MAC_APPSHELL-P2).
    public var onDeniedPost: ((RemoteCodeNotificationContent) -> Void)?

    /// Posted on the main thread the first time a `post(_:)` call is dropped
    /// because the user has denied OS-level notification permission. Observers
    /// (e.g. a status-bar notice or settings prompt) can react to this name.
    /// Posted at most once per app session; the gating flag lives in AppDelegate
    /// so multiple denied posts never spam the user (UX-MAC_APPSHELL-P2).
    public static let rc2NotificationsDeniedPost = Notification.Name("rc2NotificationsDeniedPost")

    /// Injected notification center. Default = LiveNotificationCenterClient (real UNCenter).
    /// Tests inject a fake so posting is unit-testable without a bundled .app (QA :96).
    let notificationCenterClient: any NotificationCenterClient

    private override init() {
        self.notificationCenterClient = LiveNotificationCenterClient()
        super.init()
    }

    /// Designated init for test injection. Not exposed via `shared`.
    init(notificationCenterClient: any NotificationCenterClient) {
        self.notificationCenterClient = notificationCenterClient
        super.init()
    }

    private static var canUseNotificationCenter: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Sets the authorization state for tests. Not callable in production because
    /// `authorized` is always set via the `requestAuthorization` callback.
    /// Internal so `@testable import AppShell` can reach it without reflection.
    func setAuthorizedForTesting(_ value: Bool) {
        authorized = value
    }

    public func bootstrap() {
        // UNUserNotificationCenter requires the process to be a real
        // bundled .app. Running from `swift run` produces a binary
        // without an app bundle and would crash on .current().
        guard Self.canUseNotificationCenter else { return }
        notificationCenterClient.setDelegate(self)
        notificationCenterClient.setNotificationCategories([
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
        notificationCenterClient.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            self.authorized = granted
        }
    }

    public func post(title: String, body: String?, category: String?) {
        guard authorized, Self.canUseNotificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let b = body { content.body = b }
        if let c = category { content.categoryIdentifier = c }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        notificationCenterClient.add(req, withCompletionHandler: nil)
    }

    public func post(_ content: RemoteCodeNotificationContent) {
        guard authorized, Self.canUseNotificationCenter else {
            // Notify the caller so an in-app fallback can surface the result
            // when OS-level delivery is blocked (permission denied).
            DispatchQueue.main.async { [weak self] in
                self?.onDeniedPost?(content)
            }
            return
        }
        notificationCenterClient.add(content.makeRequest(), withCompletionHandler: nil)
    }

    /// Current OS authorization status, used by Settings to decide whether to
    /// show a "Test notification" button or a "permission denied" prompt.
    /// Returns `.notDetermined` for non-bundled (`swift run`) processes where
    /// UNUserNotificationCenter is unavailable.
    public func authorizationStatus() async -> UNAuthorizationStatus {
        guard Self.canUseNotificationCenter else { return .notDetermined }
        return await notificationCenterClient.notificationSettings().authorizationStatus
    }

    /// Best-effort test notification for the Settings "Test notification"
    /// button. Re-requests authorization when still undetermined so the first
    /// press also triggers the OS prompt.
    public func postTestNotification() {
        guard Self.canUseNotificationCenter else { return }
        let deliver = { [notificationCenterClient] in
            let content = UNMutableNotificationContent()
            content.title = "RemoteCode"
            content.body = "Test notification — delivery is working."
            content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            notificationCenterClient.add(req, withCompletionHandler: nil)
        }
        if authorized {
            deliver()
        } else {
            notificationCenterClient.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                self.authorized = granted
                if granted { deliver() }
            }
        }
    }

    /// Deep-links to System Settings > Notifications so a user who denied the
    /// permission can re-enable it without hunting through panes.
    @MainActor
    public func openSystemNotificationSettings() {
        let fallback = "x-apple.systempreferences:com.apple.preference.notifications"
        let url = Bundle.main.bundleIdentifier
            .map { "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\($0)" }
            .flatMap(URL.init(string:)) ?? URL(string: fallback)!
        NSWorkspace.shared.open(url)
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
        DispatchQueue.main.async { [weak self] in
            self?.onNotificationResponse?(response)
        }
        completionHandler()
    }

    public static func presentationOptions(appIsForeground: Bool) -> UNNotificationPresentationOptions {
        appIsForeground ? [] : [.banner, .list, .sound]
    }
}
