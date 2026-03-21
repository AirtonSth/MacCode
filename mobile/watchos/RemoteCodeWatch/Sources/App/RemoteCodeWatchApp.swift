import SwiftUI
import WatchKit

@main
struct RemoteCodeWatchApp: App {
  @StateObject private var session = WatchSnapshotSession()

  init() {
    #if !targetEnvironment(simulator)
    WatchLocalNotificationManager().requestAuthorization()
    #endif
  }

  var body: some Scene {
    WindowGroup {
      WatchSnapshotContentView(
        presentation: session.presentation,
        history: session.historyStore.history,
        onTapDeepLink: { session.openDeepLinkOnPhone() }
      )
    }
    .backgroundTask(.appRefresh("io.remotecode.watch.refresh")) {
      await session.handleBackgroundRefresh()
    }
  }
}
