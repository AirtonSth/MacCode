import SwiftUI
import WidgetKit

@main
struct RemoteCodeWatchComplicationBundle: WidgetBundle {
  var body: some Widget {
    RemoteCodeWatchComplication()
  }
}

struct RemoteCodeWatchComplication: Widget {
  let kind = "io.remotecode.watch.complication"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: RemoteCodeComplicationTimelineProvider()) { entry in
      RemoteCodeComplicationEntryView(entry: entry)
    }
    .configurationDisplayName("RemoteCode")
    .description("Monitor your active sessions.")
    .supportedFamilies([
      .accessoryCircular,
      .accessoryCorner,
      .accessoryRectangular,
      .accessoryInline,
    ])
  }
}
