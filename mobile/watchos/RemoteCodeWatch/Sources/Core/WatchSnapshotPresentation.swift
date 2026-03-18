import Foundation

enum WatchSnapshotTimerState: Equatable {
  case frozen(seconds: Int)
  case live(startedAtMs: Int)
}

struct WatchSnapshotPresentation: Equatable {
  let activeCountLabel: String
  let badgeTitle: String
  let preview: String
  let statusLine: String
  let timerState: WatchSnapshotTimerState
  let title: String
}

func makeWatchSnapshotPresentation(snapshot: LiveActivitySharedSnapshot?) -> WatchSnapshotPresentation {
  guard let snapshot else {
    return WatchSnapshotPresentation(
      activeCountLabel: "No active threads",
      badgeTitle: "Idle",
      preview: "Open RemoteCode on iPhone to start a session.",
      statusLine: "Waiting for a session",
      timerState: .frozen(seconds: 0),
      title: "RemoteCode"
    )
  }

  let activeCountLabel: String
  if snapshot.activeThreadCount == 1 {
    activeCountLabel = "1 active thread"
  } else if snapshot.activeThreadCount > 1 {
    activeCountLabel = "\(snapshot.activeThreadCount) active threads"
  } else {
    activeCountLabel = "No active threads"
  }

  let timerState: WatchSnapshotTimerState
  if snapshot.phase.isTerminal {
    timerState = .frozen(seconds: max(0, snapshot.elapsedSecondsSnapshot ?? 0))
  } else if let frozenSeconds = snapshot.elapsedSecondsSnapshot {
    timerState = .frozen(seconds: max(0, frozenSeconds))
  } else {
    timerState = .live(startedAtMs: max(0, snapshot.startedAtMs))
  }

  return WatchSnapshotPresentation(
    activeCountLabel: activeCountLabel,
    badgeTitle: snapshot.phase.badgeTitle,
    preview: snapshot.preview,
    statusLine: snapshot.statusLine,
    timerState: timerState,
    title: snapshot.chatTitle
  )
}

final class WatchSnapshotStateStore {
  private(set) var snapshot: LiveActivitySharedSnapshot?

  @discardableResult
  func applySnapshotJSONString(_ value: String?) -> Bool {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      snapshot = nil
      return true
    }

    guard let data = trimmed.data(using: .utf8) else {
      return false
    }

    do {
      snapshot = try JSONDecoder().decode(LiveActivitySharedSnapshot.self, from: data)
      return true
    } catch {
      return false
    }
  }

  func currentPresentation() -> WatchSnapshotPresentation {
    makeWatchSnapshotPresentation(snapshot: snapshot)
  }
}
