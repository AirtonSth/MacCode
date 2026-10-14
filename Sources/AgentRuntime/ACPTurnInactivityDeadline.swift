import Foundation

/// One reschedulable inactivity deadline for an in-flight ACP turn.
///
/// `refresh()` only moves the deadline; a single timer source wakes at the
/// first deadline and re-arms itself for whatever time the stream bought since.
/// Field 2026-10-14: one `asyncAfter` work item per stream event left every
/// cancelled item queued in libdispatch until its 900 s deadline (~12k live
/// timers, ~7 MB, for each long Distill run).
final class ACPTurnInactivityDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let timer: DispatchSourceTimer
    private var deadline = DispatchTime.now()
    private var armed = false
    private var cancelled = false

    init(
        timeout: TimeInterval,
        queue: DispatchQueue = .global(qos: .utility),
        onExpire: @escaping @Sendable () -> Void
    ) {
        self.timeout = timeout
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            if self?.consumeExpiry() == true { onExpire() }
        }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// Restarts the full inactivity window from now.
    func refresh() {
        lock.withLock {
            guard !cancelled else { return }
            deadline = .now() + timeout
            guard !armed else { return }
            armed = true
            timer.schedule(deadline: deadline)
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            armed = false
        }
        timer.cancel()
    }

    /// True once when the latest deadline has passed; an early wake re-arms.
    private func consumeExpiry() -> Bool {
        lock.withLock {
            guard armed, !cancelled else { return false }
            guard DispatchTime.now() >= deadline else {
                timer.schedule(deadline: deadline)
                return false
            }
            armed = false
            return true
        }
    }
}
