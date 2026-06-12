import Foundation

final class WebSocketEventBatcher: @unchecked Sendable {
    /// Short window applied to nil-key (non-coalescing) events so high-frequency
    /// cross-kind events accumulate into fewer WS frames. Must stay small to avoid
    /// perceptible latency; keyed-batch events use the larger `delay` window.
    static let crossKindDelay: TimeInterval = 0.015

    private let enabled: Bool
    private let filter: EventStreamFilter
    private let delay: TimeInterval
    private let send: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "io.remotecode.ws-event-batcher")
    // Keyed (coalescing) state
    private var pending: [String: Data] = [:]
    private var order: [String] = []
    private var scheduled = false
    // Nil-key (cross-kind) batch state
    private var nilKeyQueue: [Data] = []
    private var nilKeyScheduled = false

    init(enabled: Bool,
         filter: EventStreamFilter,
         delay: TimeInterval = 0.075,
         send: @escaping @Sendable (Data) -> Void) {
        self.enabled = enabled
        self.filter = filter
        self.delay = max(0, delay)
        self.send = send
    }

    func enqueue(event: EventBus.Event, data: Data) {
        guard enabled else {
            queue.async { self.send(data) }
            return
        }

        if let key = filter.coalescingKey(for: event) {
            queue.async {
                if self.pending[key] == nil {
                    self.order.append(key)
                }
                self.pending[key] = data
                guard !self.scheduled else { return }
                self.scheduled = true
                self.queue.asyncAfter(deadline: .now() + self.delay) {
                    self.flushLocked()
                }
            }
        } else {
            // No coalescing key: buffer for the short cross-kind window so
            // bursts of mixed events coalesce into fewer frames.
            queue.async {
                self.nilKeyQueue.append(data)
                guard !self.nilKeyScheduled else { return }
                self.nilKeyScheduled = true
                self.queue.asyncAfter(deadline: .now() + Self.crossKindDelay) {
                    self.flushLocked()
                }
            }
        }
    }

    func flush() {
        queue.sync {
            flushLocked()
        }
    }

    private func flushLocked() {
        scheduled = false
        nilKeyScheduled = false

        // Keyed (coalescing) frames first, preserving arrival order of keys.
        if !pending.isEmpty {
            let keys = order
            let frames = keys.compactMap { pending[$0] }
            pending.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            for frame in frames {
                send(frame)
            }
        }

        // Then nil-key frames in arrival order.
        if !nilKeyQueue.isEmpty {
            let frames = nilKeyQueue
            nilKeyQueue.removeAll(keepingCapacity: true)
            for frame in frames {
                send(frame)
            }
        }
    }

    // MARK: - Testable grouping helper

    /// Pure helper: given a sequence of (key, data, relativeTimestamp) tuples,
    /// returns the flush groups that a batcher with `window` would produce.
    /// A group is the set of unique data values flushed together: keyed entries
    /// coalesce (last write wins per key), nil-key entries accumulate in order.
    /// Events with t <= window are in the first group; events with t > window
    /// start the next group. This models a single-timer flush per window.
    ///
    /// WHY this exists: timer-free unit tests can verify coalescing behavior and
    /// ordering guarantees without relying on real DispatchQueue timing.
    static func groupFlushes(
        events: [(key: String?, data: Data, t: TimeInterval)],
        window: TimeInterval
    ) -> [[Data]] {
        guard !events.isEmpty else { return [] }

        var groups: [[Data]] = []
        var windowStart = events[0].t
        // Keyed state within the current window
        var keyedOrder: [String] = []
        var keyedPending: [String: Data] = [:]
        // Nil-key state within the current window
        var nilKeyBuf: [Data] = []

        func flushWindow() {
            var group: [Data] = []
            for k in keyedOrder {
                if let d = keyedPending[k] { group.append(d) }
            }
            group.append(contentsOf: nilKeyBuf)
            if !group.isEmpty { groups.append(group) }
            keyedOrder.removeAll(keepingCapacity: true)
            keyedPending.removeAll(keepingCapacity: true)
            nilKeyBuf.removeAll(keepingCapacity: true)
        }

        for ev in events {
            if ev.t - windowStart > window {
                flushWindow()
                windowStart = ev.t
            }
            if let key = ev.key {
                if keyedPending[key] == nil { keyedOrder.append(key) }
                keyedPending[key] = ev.data
            } else {
                nilKeyBuf.append(ev.data)
            }
        }
        flushWindow()
        return groups
    }
}
