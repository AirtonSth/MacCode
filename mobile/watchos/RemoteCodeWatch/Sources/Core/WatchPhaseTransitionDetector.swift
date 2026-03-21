import Foundation

enum WatchHapticType: Equatable {
  case success
  case failure
}

struct PhaseTransition: Equatable {
  let oldPhase: LiveActivitySharedPhase?
  let newPhase: LiveActivitySharedPhase?
  let hapticType: WatchHapticType?
  let shouldNotify: Bool
}

func detectPhaseTransition(
  oldPhase: LiveActivitySharedPhase?,
  newPhase: LiveActivitySharedPhase?
) -> PhaseTransition {
  guard oldPhase != newPhase else {
    return PhaseTransition(
      oldPhase: oldPhase,
      newPhase: newPhase,
      hapticType: nil,
      shouldNotify: false
    )
  }

  let hapticType: WatchHapticType?
  let shouldNotify: Bool

  switch newPhase {
  case .completed:
    hapticType = .success
    shouldNotify = true
  case .failed, .error:
    hapticType = .failure
    shouldNotify = true
  default:
    hapticType = nil
    shouldNotify = false
  }

  return PhaseTransition(
    oldPhase: oldPhase,
    newPhase: newPhase,
    hapticType: hapticType,
    shouldNotify: shouldNotify
  )
}

struct WatchNotificationContent: Equatable {
  let identifier: String
  let title: String
  let body: String
}

func makeNotificationContent(
  chatId: String,
  chatTitle: String,
  phase: LiveActivitySharedPhase
) -> WatchNotificationContent? {
  switch phase {
  case .completed:
    return WatchNotificationContent(
      identifier: chatId,
      title: "Session Completed",
      body: "\(chatTitle) finished successfully."
    )
  case .failed:
    return WatchNotificationContent(
      identifier: chatId,
      title: "Session Failed",
      body: "\(chatTitle) has failed."
    )
  case .error:
    return WatchNotificationContent(
      identifier: chatId,
      title: "Session Error",
      body: "\(chatTitle) encountered an error."
    )
  case .running, .finalizing, .background:
    return nil
  }
}
