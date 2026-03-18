import Combine
import Foundation
import WatchConnectivity

private let watchSnapshotDefaultsKey = "remotecode.live_activity.shared_snapshot.watch"
private let watchSnapshotContextKey = "liveActivitySnapshot"

@MainActor
final class WatchSnapshotSession: NSObject, ObservableObject, WCSessionDelegate {
  @Published private(set) var presentation: WatchSnapshotPresentation

  private let defaults: UserDefaults
  private let store: WatchSnapshotStateStore
  private let session: WCSession?

  override init() {
    self.defaults = .standard
    self.store = WatchSnapshotStateStore()
    self.session = WCSession.isSupported() ? WCSession.default : nil

    let initialJSONString = defaults.string(forKey: watchSnapshotDefaultsKey)
    _ = store.applySnapshotJSONString(initialJSONString)
    self.presentation = store.currentPresentation()

    super.init()

    session?.delegate = self
    session?.activate()

    if let applicationContextValue = session?.receivedApplicationContext[watchSnapshotContextKey] as? String,
       !applicationContextValue.isEmpty {
      applySnapshotJSONString(applicationContextValue)
    }
  }

  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {}

  func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String : Any]
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
  }
}
