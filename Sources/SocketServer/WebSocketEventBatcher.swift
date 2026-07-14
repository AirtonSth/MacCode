import Foundation

final class WebSocketEventBatcher: @unchecked Sendable {
    /// Short window applied to nil-key (non-coalescing) events so high-frequency
    /// cross-kind events accumulate into fewer WS frames. Must stay small to avoid
    /// perceptible latency; keyed-batch events use the larger `delay` window.
    static let crossKindDelay: TimeInterval = 0.015

    /// PERF (token-delta frame churn): high-frequency streaming kinds that are
    /// safe to hold for the short cross-kind window on .full connections. One
    /// provider token = one agent.item.delta event; without buffering, every
    /// token wakes the socket with its own frame. Ordering is preserved (all
    /// frames flow through the same nil-key buffer) and any non-delta event
    /// flushes the buffer immediately, so interactive events are never delayed.
    static let fullStreamCoalescedKinds: Set<String> = ["agent.item.delta"]

    private let enabled: Bool
    private let filter: EventStreamFilter
    private let delay: TimeInterval
    /// When true (full-filter connections), agent.item.delta frames buffer for
    /// `crossKindDelay` and everything else flushes the buffer then sends
    /// immediately. Independent of `enabled`, which drives the cellular-safe
    /// keyed/nil-key batching.
    private let coalescesStreamingDeltas: Bool
    private let send: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "io.remotecode.ws-event-batcher")
    // Keyed (coalescing) state
    private var pending: [String: Data] = [:]
    private var order: [String] = []
    private var scheduled = false
    // Nil-key (cross-kind) batch state
    private var nilKeyQueue: [Data] = []
    private var nilKeyScheduled = false
    private var stopped = false

    init(enabled: Bool,
         filter: EventStreamFilter,
         delay: TimeInterval = 0.075,
         coalescesStreamingDeltas: Bool = false,
         send: @escaping @Sendable (Data) -> Void) {
        self.enabled = enabled
        self.filter = filter
        self.delay = max(0, delay)
        self.coalescesStreamingDeltas = coalescesStreamingDeltas
        self.send = send
    }

    func enqueue(event: EventBus.Event, data: Data) {
        guard enabled else {
            guard coalescesStreamingDeltas else {
                queue.async {
                    guard !self.stopped else { return }
                    self.send(data)
                }
                return
            }
            if Self.fullStreamCoalescedKinds.contains(event.kind) {
                queue.async {
                    guard !self.stopped else { return }
                    self.nilKeyQueue.append(data)
                    guard !self.nilKeyScheduled else { return }
                    self.nilKeyScheduled = true
                    self.queue.asyncAfter(deadline: .now() + Self.crossKindDelay) {
                        self.flushLocked()
                    }
                }
            } else {
                // Non-delta: append after any buffered deltas (order preserved)
                // and flush NOW so interactive events pay zero added latency.
                queue.async {
                    guard !self.stopped else { return }
                    self.nilKeyQueue.append(data)
                    self.flushLocked()
                }
            }
            return
        }

        if let key = filter.coalescingKey(for: event) {
            queue.async {
                guard !self.stopped else { return }
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
                guard !self.stopped else { return }
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

    func stop() {
        queue.sync {
            stopped = true
            scheduled = false
            nilKeyScheduled = false
            pending.removeAll(keepingCapacity: false)
            order.removeAll(keepingCapacity: false)
            nilKeyQueue.removeAll(keepingCapacity: false)
        }
    }

    private func flushLocked() {
        guard !stopped else { return }
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
    /// A group contains every frame in arrival order. Keyed last-write-wins
    /// coalescing is intentionally disabled because it can remove sequence
    /// numbers and reorder mixed event streams.
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
        var frames: [Data] = []

        func flushWindow() {
            if !frames.isEmpty { groups.append(frames) }
            frames.removeAll(keepingCapacity: true)
        }

        for ev in events {
            if ev.t - windowStart > window {
                flushWindow()
                windowStart = ev.t
            }
            frames.append(ev.data)
        }
        flushWindow()
        return groups
    }
}
