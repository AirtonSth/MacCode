import Foundation
import Network

/// F5: turns network path updates into at most one call per settled change.
@MainActor
final class TailcatNetworkPathObserver {
    typealias Cancellation = @MainActor () -> Void
    typealias Scheduler = @MainActor (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> Cancellation

    /// A design constant with no measured basis.
    nonisolated static let settleInterval: TimeInterval = 2

    private let settle: TimeInterval
    private let schedule: Scheduler
    private let onUsable: @MainActor () -> Void
    private var monitor: NWPathMonitor?
    private var sawBaseline = false
    private var cancelPending: Cancellation?
    /// Same guard as `DirectAccessLifecycleSupervisor.retryGeneration`: the
    /// default scheduler hops DispatchWorkItem → Task, and a cancel between
    /// those hops is lost. Every update and `stop()` bump the generation; an
    /// action whose captured generation is stale must no-op.
    private var generation: UInt64 = 0

    init(
        settle: TimeInterval = TailcatNetworkPathObserver.settleInterval,
        schedule: @escaping Scheduler = TailcatNetworkPathObserver.defaultScheduler,
        onUsable: @escaping @MainActor () -> Void
    ) {
        self.settle = settle
        self.schedule = schedule
        self.onUsable = onUsable
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let usable = path.status == .satisfied
            Task { @MainActor in
                // An update that was already hopping when `stop()` ran is dropped.
                guard let self, self.monitor != nil else { return }
                self.pathUpdated(usable: usable)
            }
        }
        self.monitor = monitor
        monitor.start(queue: .main)
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        cancelPendingAction()
    }

    /// The monitor's handler calls it; tests drive it directly.
    func pathUpdated(usable: Bool) {
        // The first update only says what the path is: launch costs no reconcile.
        guard sawBaseline else {
            sawBaseline = true
            return
        }
        // A loss takes effect at once; a regain, or a change of a path that
        // stays usable, restarts the settle wait.
        cancelPendingAction()
        guard usable else { return }
        let scheduled = generation
        cancelPending = schedule(settle) { [weak self] in
            guard let self, self.generation == scheduled else { return }
            self.cancelPending = nil
            self.onUsable()
        }
    }

    private func cancelPendingAction() {
        generation &+= 1
        cancelPending?()
        cancelPending = nil
    }

    private static func defaultScheduler(
        delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> Cancellation {
        let item = DispatchWorkItem {
            Task { @MainActor in action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}
