import Foundation

struct WatchSessionHistorySummary: Codable, Equatable {
  let chatId: String
  let chatTitle: String
  let phase: LiveActivitySharedPhase
  let startedAtMs: Int
  var endedAtMs: Int?
  var elapsedSeconds: Int?
}

private let historyDefaultsKey = "remotecode.watch.session_history"
private let maxHistoryCount = 5

final class WatchSessionHistoryStore {
  private let defaults: UserDefaults
  private(set) var history: [WatchSessionHistorySummary]

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    self.history = Self.load(from: defaults)
  }

  func addOrUpdate(snapshot: LiveActivitySharedSnapshot) {
    if let index = history.firstIndex(where: { $0.chatId == snapshot.chatId }) {
      history[index] = WatchSessionHistorySummary(
        chatId: snapshot.chatId,
        chatTitle: snapshot.chatTitle,
        phase: snapshot.phase,
        startedAtMs: snapshot.startedAtMs,
        endedAtMs: snapshot.phase.isTerminal ? snapshot.updatedAtMs : nil,
        elapsedSeconds: snapshot.elapsedSecondsSnapshot
      )
    } else {
      let summary = WatchSessionHistorySummary(
        chatId: snapshot.chatId,
        chatTitle: snapshot.chatTitle,
        phase: snapshot.phase,
        startedAtMs: snapshot.startedAtMs,
        endedAtMs: snapshot.phase.isTerminal ? snapshot.updatedAtMs : nil,
        elapsedSeconds: snapshot.elapsedSecondsSnapshot
      )
      history.insert(summary, at: 0)
    }

    if history.count > maxHistoryCount {
      history = Array(history.prefix(maxHistoryCount))
    }

    save()
  }

  func clear() {
    history = []
    defaults.removeObject(forKey: historyDefaultsKey)
  }

  private func save() {
    guard let data = try? JSONEncoder().encode(history) else { return }
    defaults.set(data, forKey: historyDefaultsKey)
  }

  private static func load(from defaults: UserDefaults) -> [WatchSessionHistorySummary] {
    guard let data = defaults.data(forKey: historyDefaultsKey) else { return [] }
    return (try? JSONDecoder().decode([WatchSessionHistorySummary].self, from: data)) ?? []
  }
}
