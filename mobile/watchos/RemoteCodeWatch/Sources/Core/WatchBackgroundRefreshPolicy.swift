import Foundation

func backgroundRefreshInterval(for phase: LiveActivitySharedPhase?) -> TimeInterval? {
  switch phase {
  case .running, .background:
    return 5 * 60
  case .finalizing:
    return 2 * 60
  case .completed, .failed, .error:
    return nil
  case nil:
    return 15 * 60
  }
}
