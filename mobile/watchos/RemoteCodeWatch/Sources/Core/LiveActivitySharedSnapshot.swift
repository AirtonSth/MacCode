import Foundation

enum LiveActivitySharedPhase: String, Codable, Equatable {
  case running
  case finalizing
  case background
  case completed
  case failed
  case error

  var badgeTitle: String {
    switch self {
    case .running, .background:
      return "Running"
    case .finalizing:
      return "Finalizing"
    case .completed:
      return "Completed"
    case .failed:
      return "Failed"
    case .error:
      return "Error"
    }
  }

  var isTerminal: Bool {
    switch self {
    case .completed, .failed, .error:
      return true
    case .running, .finalizing, .background:
      return false
    }
  }
}

struct LiveActivitySharedSnapshot: Codable, Equatable {
  let activeThreadCount: Int
  let chatId: String
  let chatTitle: String
  let deepLink: String
  let elapsedSecondsSnapshot: Int?
  let finalizingThreadCount: Int
  let phase: LiveActivitySharedPhase
  let preview: String
  let runningThreadCount: Int
  let schemaVersion: Int
  let startedAtMs: Int
  let statusLine: String
  let updatedAtMs: Int
}
