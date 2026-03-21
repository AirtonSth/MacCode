import Foundation

private let supportedSchemaVersion = 1

func formatFrozenDuration(seconds: Int) -> String {
  let clamped = max(0, seconds)
  let hours = clamped / 3600
  let minutes = (clamped % 3600) / 60
  let remainingSeconds = clamped % 60
  if hours > 0 {
    return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
  }
  return String(format: "%02d:%02d", minutes, remainingSeconds)
}

enum WatchSnapshotTimerState: Equatable {
  case frozen(seconds: Int)
  case live(startedAtMs: Int)
}

struct WatchSnapshotPresentation: Equatable {
  let activeCountLabel: String
  let badgeTitle: String
  let badgeStyle: WatchBadgeStyle
  let deepLink: String?
  let preview: String
  let statusLine: String
  let timerState: WatchSnapshotTimerState
  let title: String
  let updatedAtMs: Int?
}

enum WatchBadgeStyle: Equatable {
  case normal
  case error
}

func makeWatchSnapshotPresentation(snapshot: LiveActivitySharedSnapshot?) -> WatchSnapshotPresentation {
  guard let snapshot else {
    return WatchSnapshotPresentation(
      activeCountLabel: "No active threads",
      badgeTitle: "Idle",
      badgeStyle: .normal,
      deepLink: nil,
      preview: "Open RemoteCode on iPhone to start a session.",
      statusLine: "Waiting for a session",
      timerState: .frozen(seconds: 0),
      title: "RemoteCode",
      updatedAtMs: nil
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

  let badgeStyle: WatchBadgeStyle
  switch snapshot.phase {
  case .failed, .error:
    badgeStyle = .error
  case .running, .finalizing, .background, .completed:
    badgeStyle = .normal
  }

  return WatchSnapshotPresentation(
    activeCountLabel: activeCountLabel,
    badgeTitle: snapshot.phase.badgeTitle,
    badgeStyle: badgeStyle,
    deepLink: snapshot.deepLink,
    preview: snapshot.preview,
    statusLine: snapshot.statusLine,
    timerState: timerState,
    title: snapshot.chatTitle,
    updatedAtMs: snapshot.updatedAtMs
  )
}

final class WatchSnapshotStateStore {
  private(set) var snapshot: LiveActivitySharedSnapshot?
  private(set) var previousPhase: LiveActivitySharedPhase?
  private(set) var lastTransition: PhaseTransition?

  @discardableResult
  func applySnapshotJSONString(_ value: String?, force: Bool = false) -> Bool {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      let oldPhase = snapshot?.phase
      snapshot = nil
      previousPhase = oldPhase
      lastTransition = detectPhaseTransition(oldPhase: oldPhase, newPhase: nil)
      return true
    }

    guard let data = trimmed.data(using: .utf8) else {
      return false
    }

    do {
      let decoded = try JSONDecoder().decode(LiveActivitySharedSnapshot.self, from: data)

      guard decoded.schemaVersion == supportedSchemaVersion else {
        return false
      }

      if !force, let existing = snapshot, decoded.updatedAtMs <= existing.updatedAtMs {
        return false
      }

      let oldPhase = snapshot?.phase
      snapshot = decoded
      previousPhase = oldPhase
      lastTransition = detectPhaseTransition(oldPhase: oldPhase, newPhase: decoded.phase)
      return true
    } catch {
      return false
    }
  }

  func currentPresentation() -> WatchSnapshotPresentation {
    makeWatchSnapshotPresentation(snapshot: snapshot)
  }
}
