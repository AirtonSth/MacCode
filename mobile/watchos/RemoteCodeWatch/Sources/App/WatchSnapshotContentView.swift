import SwiftUI

private func formatFrozenDuration(seconds: Int) -> String {
  let clamped = max(0, seconds)
  let minutes = clamped / 60
  let remainingSeconds = clamped % 60
  return String(format: "%02d:%02d", minutes, remainingSeconds)
}

private struct WatchTimerText: View {
  let timerState: WatchSnapshotTimerState

  var body: some View {
    switch timerState {
    case .frozen(let seconds):
      Text(formatFrozenDuration(seconds: seconds))
        .monospacedDigit()
    case .live(let startedAtMs):
      let startedDate = Date(timeIntervalSince1970: TimeInterval(startedAtMs) / 1000)
      Text(timerInterval: startedDate...Date.distantFuture, countsDown: false)
        .monospacedDigit()
    }
  }
}

struct WatchSnapshotContentView: View {
  let presentation: WatchSnapshotPresentation

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 8) {
          Text(presentation.badgeTitle)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.cyan.opacity(0.16))
            .clipShape(Capsule())

          Spacer(minLength: 0)

          WatchTimerText(timerState: presentation.timerState)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
        }

        Text(presentation.title)
          .font(.headline.weight(.bold))
          .foregroundStyle(.white)
          .lineLimit(2)

        Text(presentation.activeCountLabel)
          .font(.caption.weight(.medium))
          .foregroundStyle(.cyan.opacity(0.92))
          .lineLimit(1)

        VStack(alignment: .leading, spacing: 4) {
          Text(presentation.statusLine)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.94))
            .lineLimit(2)

          Text(presentation.preview)
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.78))
            .lineLimit(4)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(
      LinearGradient(
        colors: [Color(red: 0.03, green: 0.06, blue: 0.12), Color(red: 0.02, green: 0.02, blue: 0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }
}
