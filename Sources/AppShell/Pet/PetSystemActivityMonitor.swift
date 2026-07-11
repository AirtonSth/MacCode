import AppKit
import Foundation

@MainActor
public final class PetSystemActivityMonitor {
    public var onScreenLockChanged: ((Bool) -> Void)?
    public var onWake: (() -> Void)?
    public var onScreenParametersChanged: (() -> Void)?
    public var onAccessibilityDisplayOptionsChanged: (() -> Void)?

    private let workspaceNotificationCenter: NotificationCenter
    private let applicationNotificationCenter: NotificationCenter
    private var notificationTokens: [(NotificationCenter, NSObjectProtocol)] = []

    public init(
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        applicationNotificationCenter: NotificationCenter = .default
    ) {
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.applicationNotificationCenter = applicationNotificationCenter
    }

    public func start() {
        guard notificationTokens.isEmpty else { return }
        let workspaceCenter = workspaceNotificationCenter
        observe(workspaceCenter, name: NSWorkspace.sessionDidResignActiveNotification) { [weak self] in
            self?.onScreenLockChanged?(true)
        }
        observe(workspaceCenter, name: NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in
            self?.onScreenLockChanged?(false)
        }
        observe(workspaceCenter, name: NSWorkspace.willSleepNotification) { [weak self] in
            self?.onScreenLockChanged?(true)
        }
        observe(workspaceCenter, name: NSWorkspace.didWakeNotification) { [weak self] in
            self?.onScreenLockChanged?(false)
            self?.onWake?()
        }
        observe(workspaceCenter, name: NSWorkspace.screensDidSleepNotification) { [weak self] in
            self?.onScreenLockChanged?(true)
        }
        observe(workspaceCenter, name: NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.onScreenLockChanged?(false)
            self?.onWake?()
        }
        observe(workspaceCenter, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { [weak self] in
            self?.onAccessibilityDisplayOptionsChanged?()
        }
        observe(applicationNotificationCenter, name: NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.onScreenParametersChanged?()
        }
    }

    public func stop() {
        for (center, token) in notificationTokens {
            center.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func observe(
        _ center: NotificationCenter,
        name: Notification.Name,
        handler: @escaping @MainActor () -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in handler() }
        }
        notificationTokens.append((center, token))
    }
}
