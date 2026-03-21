import SwiftUI
import WidgetKit

struct RemoteCodeComplicationEntryView: View {
  @Environment(\.widgetFamily) var family
  let entry: RemoteCodeComplicationEntry

  var body: some View {
    switch family {
    case .accessoryCircular:
      circularView
    case .accessoryCorner:
      cornerView
    case .accessoryRectangular:
      rectangularView
    case .accessoryInline:
      inlineView
    default:
      circularView
    }
  }

  private var circularView: some View {
    ZStack {
      AccessoryWidgetBackground()
      VStack(spacing: 1) {
        if let snapshot = entry.snapshot {
          Image(systemName: iconName(for: snapshot.phase))
            .font(.system(size: 14, weight: .semibold))
          Text("\(snapshot.activeThreadCount)")
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
        } else {
          Image(systemName: "chevron.left.forwardslash.chevron.right")
            .font(.system(size: 16, weight: .medium))
          Text("--")
            .font(.system(size: 11))
        }
      }
    }
  }

  private var cornerView: some View {
    VStack {
      if let snapshot = entry.snapshot {
        Image(systemName: iconName(for: snapshot.phase))
          .font(.system(size: 20, weight: .semibold))
          .widgetLabel {
            Text(snapshot.badgeTitle)
          }
      } else {
        Image(systemName: "chevron.left.forwardslash.chevron.right")
          .font(.system(size: 20, weight: .medium))
          .widgetLabel {
            Text("RemoteCode")
          }
      }
    }
  }

  private var rectangularView: some View {
    VStack(alignment: .leading, spacing: 2) {
      if let snapshot = entry.snapshot {
        HStack(spacing: 4) {
          Image(systemName: iconName(for: snapshot.phase))
            .font(.caption2.weight(.semibold))
          Text(snapshot.badgeTitle)
            .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(snapshot.phase == .failed || snapshot.phase == .error ? .red : .cyan)

        if let frozenSeconds = snapshot.timerFrozenSeconds {
          Text(formatFrozenDuration(seconds: frozenSeconds))
            .font(.caption.weight(.bold))
            .monospacedDigit()
        } else if let startedAtMs = snapshot.timerStartedAtMs {
          let startDate = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000)
          Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
            .font(.caption.weight(.bold))
            .monospacedDigit()
        }

        Text("\(snapshot.activeThreadCount) thread\(snapshot.activeThreadCount == 1 ? "" : "s")")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      } else {
        Text("RemoteCode")
          .font(.caption2.weight(.semibold))
        Text("No active session")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var inlineView: some View {
    if let snapshot = entry.snapshot {
      Text("\(snapshot.badgeTitle) \u{2022} \(snapshot.activeThreadCount) thread\(snapshot.activeThreadCount == 1 ? "" : "s")")
    } else {
      Text("RemoteCode \u{2022} Idle")
    }
  }

  private func iconName(for phase: LiveActivitySharedPhase) -> String {
    switch phase {
    case .running, .background:
      return "play.circle.fill"
    case .finalizing:
      return "hourglass"
    case .completed:
      return "checkmark.circle.fill"
    case .failed:
      return "xmark.circle.fill"
    case .error:
      return "exclamationmark.triangle.fill"
    }
  }
}
