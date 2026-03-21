import Foundation

struct WatchComplicationSnapshot: Codable, Equatable {
  let activeThreadCount: Int
  let badgeTitle: String
  let deepLink: String
  let isTerminal: Bool
  let phase: LiveActivitySharedPhase
  let timerFrozenSeconds: Int?
  let timerStartedAtMs: Int?
  let updatedAtMs: Int
}

private let complicationDefaultsKey = "remotecode.watch.complication_snapshot"

func makeComplicationSnapshot(from snapshot: LiveActivitySharedSnapshot?) -> WatchComplicationSnapshot? {
  guard let snapshot else { return nil }

  let timerFrozenSeconds: Int?
  let timerStartedAtMs: Int?

  if snapshot.phase.isTerminal {
    timerFrozenSeconds = max(0, snapshot.elapsedSecondsSnapshot ?? 0)
    timerStartedAtMs = nil
  } else if let frozen = snapshot.elapsedSecondsSnapshot {
    timerFrozenSeconds = max(0, frozen)
    timerStartedAtMs = nil
  } else {
    timerFrozenSeconds = nil
    timerStartedAtMs = snapshot.startedAtMs
  }

  return WatchComplicationSnapshot(
    activeThreadCount: snapshot.activeThreadCount,
    badgeTitle: snapshot.phase.badgeTitle,
    deepLink: snapshot.deepLink,
    isTerminal: snapshot.phase.isTerminal,
    phase: snapshot.phase,
    timerFrozenSeconds: timerFrozenSeconds,
    timerStartedAtMs: timerStartedAtMs,
    updatedAtMs: snapshot.updatedAtMs
  )
}

func persistComplicationSnapshot(_ snapshot: WatchComplicationSnapshot?, to defaults: UserDefaults) {
  guard let snapshot else {
    defaults.removeObject(forKey: complicationDefaultsKey)
    return
  }
  if let data = try? JSONEncoder().encode(snapshot) {
    defaults.set(data, forKey: complicationDefaultsKey)
  }
}

func loadComplicationSnapshot(from defaults: UserDefaults) -> WatchComplicationSnapshot? {
  guard let data = defaults.data(forKey: complicationDefaultsKey) else { return nil }
  return try? JSONDecoder().decode(WatchComplicationSnapshot.self, from: data)
}
