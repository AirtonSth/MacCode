import Foundation

struct StalenessInfo: Equatable {
  let label: String
  let isStale: Bool
}

func computeStaleness(updatedAtMs: Int?, nowMs: Int) -> StalenessInfo {
  guard let updatedAtMs, updatedAtMs > 0 else {
    return StalenessInfo(label: "", isStale: false)
  }

  let elapsedMs = nowMs - updatedAtMs
  guard elapsedMs > 0 else {
    return StalenessInfo(label: "Updated just now", isStale: false)
  }

  let elapsedSeconds = elapsedMs / 1000

  if elapsedSeconds < 30 {
    return StalenessInfo(label: "Updated just now", isStale: false)
  } else if elapsedSeconds < 60 {
    return StalenessInfo(label: "Updated \(elapsedSeconds)s ago", isStale: false)
  } else if elapsedSeconds < 3600 {
    let minutes = elapsedSeconds / 60
    return StalenessInfo(
      label: "Updated \(minutes)m ago",
      isStale: minutes >= 2
    )
  } else {
    let hours = elapsedSeconds / 3600
    return StalenessInfo(
      label: "Updated \(hours)h ago",
      isStale: true
    )
  }
}
