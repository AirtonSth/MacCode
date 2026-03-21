import SwiftUI

// MARK: - Timer

private struct WatchTimerText: View {
  let timerState: WatchSnapshotTimerState

  var body: some View {
    switch timerState {
    case .frozen(let seconds):
      Text(formatFrozenDuration(seconds: seconds))
        .monospacedDigit()
        .contentTransition(.numericText())
    case .live(let startedAtMs):
      let startedDate = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000)
      Text(timerInterval: startedDate...Date.distantFuture, countsDown: false)
        .monospacedDigit()
    }
  }
}

// MARK: - Staleness

private struct WatchStalenessLabel: View {
  let updatedAtMs: Int?

  var body: some View {
    TimelineView(.periodic(from: Date(), by: 30)) { context in
      let nowMs = Int(context.date.timeIntervalSince1970 * 1000)
      let staleness = computeStaleness(updatedAtMs: updatedAtMs, nowMs: nowMs)
      if !staleness.label.isEmpty {
        Text(staleness.label)
          .font(.system(size: 10))
          .foregroundStyle(staleness.isStale ? .orange.opacity(0.8) : .white.opacity(0.5))
      }
    }
  }
}

// MARK: - Content View

struct WatchSnapshotContentView: View {
  let presentation: WatchSnapshotPresentation
  let history: [WatchSessionHistorySummary]
  var onTapDeepLink: (() -> Void)?

  private var accentColor: Color {
    switch presentation.badgeTitle {
    case "Completed": return .green
    case "Finalizing": return .yellow
    case "Failed", "Error": return .red
    case "Idle": return .gray
    default: return .cyan
    }
  }

  private var isIdle: Bool {
    presentation.badgeTitle == "Idle"
  }

  var body: some View {
    TabView {
      statusPage
        .containerBackground(for: .tabView) {
          LinearGradient(
            colors: [accentColor.opacity(0.1), Color(red: 0.02, green: 0.02, blue: 0.05)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
          )
        }

      if !history.isEmpty {
        WatchSessionHistoryView(history: history)
          .containerBackground(for: .tabView) {
            Color(red: 0.03, green: 0.03, blue: 0.06)
          }
      }
    }
    .tabViewStyle(.verticalPage)
    .animation(.easeInOut(duration: 0.3), value: presentation.badgeTitle)
  }

  // MARK: - Status Page

  private var statusPage: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Main status card
      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text(presentation.badgeTitle)
            .font(.caption2.weight(.bold))
            .textCase(.uppercase)
            .foregroundStyle(accentColor)
            .accessibilityLabel("Status: \(presentation.badgeTitle)")

          Spacer()

          WatchTimerText(timerState: presentation.timerState)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .accessibilityLabel("Elapsed time")
        }

        Text(presentation.title)
          .font(.headline.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(2)
          .accessibilityAddTraits(.isHeader)

        if !isIdle {
          Text(presentation.activeCountLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(accentColor.opacity(0.8))
        }

        if !presentation.preview.isEmpty && (!isIdle || history.isEmpty) {
          Text(presentation.preview)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(3)
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(accentColor.opacity(0.12))
      .overlay(alignment: .top) {
        Rectangle()
          .fill(accentColor)
          .frame(height: 2)
      }
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .accessibilityElement(children: .combine)

      if isIdle {
        if let lastSession = history.first {
          HStack(spacing: 4) {
            Circle()
              .fill(lastSession.phase == .completed ? .green : .red)
              .frame(width: 6, height: 6)
            Text("Last: \(lastSession.chatTitle)")
              .font(.system(size: 10))
              .foregroundStyle(.white.opacity(0.5))
              .lineLimit(1)
          }
        }
      } else {
        WatchStalenessLabel(updatedAtMs: presentation.updatedAtMs)
      }

      if presentation.deepLink != nil {
        Button(action: { onTapDeepLink?() }) {
          HStack(spacing: 4) {
            Image(systemName: "iphone.and.arrow.forward")
            Text("Open on iPhone")
          }
          .font(.caption2.weight(.semibold))
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.cyan)
        .accessibilityLabel("Open session on iPhone")
      }
    }
    .padding(.horizontal, 12)
  }
}
