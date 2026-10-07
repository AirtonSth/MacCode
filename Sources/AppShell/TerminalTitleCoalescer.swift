import CoreModel
import Foundation

/// H3: per-surface throttle for normalized terminal OSC titles. The first change
/// after a quiet `interval` commits on the same turn; later changes inside the
/// window collapse into one trailing commit of the latest title. Each scheduled
/// flush carries its own token, so a flush left over from a cancelled window can
/// never commit (or clear) newer pending work.
@MainActor
final class TerminalTitleCoalescer {
    private struct Pending {
        var title: String
        var commit: @MainActor (String) -> Void
        let token: UInt64
    }

    var interval: TimeInterval
    private var lastCommitAt: [SurfaceID: Date] = [:]
    private var pending: [SurfaceID: Pending] = [:]
    private var nextToken: UInt64 = 0

    init(interval: TimeInterval = 2.5) {
        self.interval = interval
    }

    func submit(_ surfaceID: SurfaceID, title: String, commit: @escaping @MainActor (String) -> Void) {
        let now = Date()
        if var entry = pending[surfaceID] {
            entry.title = title
            entry.commit = commit
            pending[surfaceID] = entry
            return
        }
        guard let last = lastCommitAt[surfaceID], now.timeIntervalSince(last) < interval else {
            lastCommitAt[surfaceID] = now
            commit(title)
            return
        }
        nextToken &+= 1
        let token = nextToken
        pending[surfaceID] = Pending(title: title, commit: commit, token: token)
        let delay = max(0, interval - now.timeIntervalSince(last))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.flush(surfaceID, token: token) }
        }
    }

    /// Drops pending work and the throttle window for a surface that is gone.
    func cancel(_ surfaceID: SurfaceID) {
        pending[surfaceID] = nil
        lastCommitAt[surfaceID] = nil
    }

    /// Drops a surface's pending title but keeps its throttle window, so a
    /// newer explicit rename is never overwritten by an older OSC title.
    func dropPending(_ surfaceID: SurfaceID) {
        pending[surfaceID] = nil
    }

    /// Commits every pending title now (quit/update path, before the final
    /// snapshot save). The scheduled flushes then find no entry and do nothing.
    func flushAll() {
        let entries = pending
        pending.removeAll()
        let now = Date()
        for (surfaceID, entry) in entries {
            lastCommitAt[surfaceID] = now
            entry.commit(entry.title)
        }
    }

    var hasPendingWorkForTesting: Bool { !pending.isEmpty }

    private func flush(_ surfaceID: SurfaceID, token: UInt64) {
        guard let entry = pending[surfaceID], entry.token == token else { return }
        pending[surfaceID] = nil
        lastCommitAt[surfaceID] = Date()
        entry.commit(entry.title)
    }
}
