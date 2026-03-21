import WidgetKit

private let appGroupSuiteName = "group.io.remotecode.watch"

struct RemoteCodeComplicationEntry: TimelineEntry {
  let date: Date
  let snapshot: WatchComplicationSnapshot?
}

struct RemoteCodeComplicationTimelineProvider: TimelineProvider {
  func placeholder(in context: Context) -> RemoteCodeComplicationEntry {
    RemoteCodeComplicationEntry(date: Date(), snapshot: nil)
  }

  func getSnapshot(in context: Context, completion: @escaping (RemoteCodeComplicationEntry) -> Void) {
    let snapshot = loadFromSharedDefaults()
    completion(RemoteCodeComplicationEntry(date: Date(), snapshot: snapshot))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<RemoteCodeComplicationEntry>) -> Void) {
    let snapshot = loadFromSharedDefaults()
    let entry = RemoteCodeComplicationEntry(date: Date(), snapshot: snapshot)

    let reloadInterval: TimeInterval
    if let snapshot, !snapshot.isTerminal {
      reloadInterval = 5 * 60
    } else {
      reloadInterval = 15 * 60
    }

    let nextUpdate = Date().addingTimeInterval(reloadInterval)
    let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
    completion(timeline)
  }

  private func loadFromSharedDefaults() -> WatchComplicationSnapshot? {
    guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else { return nil }
    return loadComplicationSnapshot(from: defaults)
  }
}
