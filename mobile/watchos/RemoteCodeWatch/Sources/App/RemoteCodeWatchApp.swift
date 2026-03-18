import SwiftUI

@main
struct RemoteCodeWatchApp: App {
  @StateObject private var session = WatchSnapshotSession()

  var body: some Scene {
    WindowGroup {
      WatchSnapshotContentView(presentation: session.presentation)
    }
  }
}
