import SwiftUI

struct WatchSessionHistoryView: View {
  let history: [WatchSessionHistorySummary]

  var body: some View {
    if history.isEmpty {
      Text("No recent sessions")
        .font(.caption)
        .foregroundStyle(.white.opacity(0.6))
    } else {
      ScrollView {
        VStack(alignment: .leading, spacing: 6) {
          Text("Recent Sessions")
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.bottom, 2)

          ForEach(history, id: \.chatId) { session in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(session.chatTitle)
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.white)
                  .lineLimit(1)

                Text(session.phase.badgeTitle)
                  .font(.system(size: 10, weight: .medium))
                  .foregroundStyle(
                    session.phase.isTerminal && session.phase != .completed
                      ? .red.opacity(0.8)
                      : .cyan.opacity(0.8)
                  )
              }

              Spacer()

              if let elapsed = session.elapsedSeconds {
                Text(formatFrozenDuration(seconds: elapsed))
                  .font(.caption2)
                  .monospacedDigit()
                  .foregroundStyle(.white.opacity(0.5))
              }
            }
            .padding(8)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
        }
        .padding(.horizontal, 12)
      }
    }
  }
}
