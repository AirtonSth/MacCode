import Combine
import Foundation
import WatchConnectivity
import WatchKit
import WidgetKit

private let watchSnapshotDefaultsKey = "remotecode.live_activity.shared_snapshot.watch"
private let watchSnapshotContextKey = "liveActivitySnapshot"
private let appGroupSuiteName = "group.io.remotecode.watch"

protocol WatchSnapshotSessionDelegate: AnyObject {
  func snapshotSessionDidFailActivation(error: Error)
}

@MainActor
final class WatchSnapshotSession: NSObject, ObservableObject, WCSessionDelegate {
  @Published private(set) var presentation: WatchSnapshotPresentation
  @Published private(set) var activationError: Error?

  weak var sessionDelegate: WatchSnapshotSessionDelegate?

  private let defaults: UserDefaults
  private let sharedDefaults: UserDefaults?
  let store: WatchSnapshotStateStore
  let historyStore: WatchSessionHistoryStore
  private let session: WCSession?
  private let hapticPlayer: WatchHapticPlayer
  private let notificationManager: WatchLocalNotificationManager

  init(
    defaults: UserDefaults = .standard,
    sharedDefaults: UserDefaults? = UserDefaults(suiteName: appGroupSuiteName),
    sessionProvider: () -> WCSession? = { WCSession.isSupported() ? WCSession.default : nil },
    hapticPlayer: WatchHapticPlayer = WatchHapticPlayer(),
    notificationManager: WatchLocalNotificationManager = WatchLocalNotificationManager()
  ) {
    self.defaults = defaults
    self.sharedDefaults = sharedDefaults
    self.store = WatchSnapshotStateStore()
    self.historyStore = WatchSessionHistoryStore(defaults: defaults)
    self.session = sessionProvider()
    self.hapticPlayer = hapticPlayer
    self.notificationManager = notificationManager

    let initialJSONString = defaults.string(forKey: watchSnapshotDefaultsKey)
    _ = store.applySnapshotJSONString(initialJSONString, force: true)
    self.presentation = store.currentPresentation()

    super.init()

    session?.delegate = self
    session?.activate()

    if let applicationContextValue = session?.receivedApplicationContext[watchSnapshotContextKey] as? String,
       !applicationContextValue.isEmpty {
      applySnapshotJSONString(applicationContextValue)
    }
  }

  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard let error else { return }
    Task { @MainActor in
      activationError = error
      sessionDelegate?.snapshotSessionDidFailActivation(error: error)
    }
  }

  nonisolated func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    if let snapshotJSONString = applicationContext[watchSnapshotContextKey] as? String {
      Task { @MainActor in
        applySnapshotJSONString(snapshotJSONString)
      }
    }
  }

  private func applySnapshotJSONString(_ snapshotJSONString: String?) {
    guard store.applySnapshotJSONString(snapshotJSONString) else {
      return
    }

    if let snapshotJSONString, !snapshotJSONString.isEmpty {
      defaults.set(snapshotJSONString, forKey: watchSnapshotDefaultsKey)
    } else {
      defaults.removeObject(forKey: watchSnapshotDefaultsKey)
    }

    presentation = store.currentPresentation()

    if let transition = store.lastTransition {
      hapticPlayer.play(transition: transition)

      if transition.shouldNotify, let snapshot = store.snapshot {
        notificationManager.scheduleIfNeeded(snapshot: snapshot, phase: snapshot.phase)
      }
    }

    if let snapshot = store.snapshot {
      historyStore.addOrUpdate(snapshot: snapshot)

      if let shared = sharedDefaults {
        let complicationSnapshot = makeComplicationSnapshot(from: snapshot)
        persistComplicationSnapshot(complicationSnapshot, to: shared)
      }
    } else {
      if let shared = sharedDefaults {
        persistComplicationSnapshot(nil, to: shared)
      }
    }

    WidgetCenter.shared.reloadAllTimelines()
    scheduleBackgroundRefresh()
  }

  func scheduleBackgroundRefresh() {
    guard let interval = backgroundRefreshInterval(for: store.snapshot?.phase) else { return }
    let preferredDate = Date().addingTimeInterval(interval)
    WKApplication.shared().scheduleBackgroundRefresh(
      withPreferredDate: preferredDate,
      userInfo: nil
    ) { _ in }
  }

  func handleBackgroundRefresh() {
    let jsonString = defaults.string(forKey: watchSnapshotDefaultsKey)
    if store.applySnapshotJSONString(jsonString, force: true) {
      presentation = store.currentPresentation()
    }
    WidgetCenter.shared.reloadAllTimelines()
    scheduleBackgroundRefresh()
  }

  func openDeepLinkOnPhone() {
    guard let deepLink = store.snapshot?.deepLink,
          let url = URL(string: deepLink) else { return }
    WKApplication.shared().openSystemURL(url)
  }
}
