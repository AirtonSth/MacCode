import Foundation

final class WebSocketEventBatcher: @unchecked Sendable {
    /// Default short window for nil-key (non-coalescing) events on Wi-Fi so
    /// high-frequency cross-kind events accumulate into fewer WS frames without
    /// perceptible latency. Cellular uses the larger `delay` window (100ms).
    static let crossKindDelay: TimeInterval = 0.015

    /// S10: admission bounds before dispatch backlog (bytes / count / time).
    static let defaultMaxPendingBytes: Int = 1_048_576
    static let defaultMaxPendingCount: Int = 512
    static let defaultMaxPendingAge: TimeInterval = 0.250

    /// PERF (token-delta frame churn): high-frequency streaming kinds that are
    /// safe to hold for the coalesce window. One provider token = one
    /// agent.item.delta event; without buffering, every token wakes the socket
    /// with its own frame. Ordering is preserved (all frames flow through the
    /// same nil-key buffer) and any non-delta event flushes the buffer
    /// immediately when only streaming coalescing is active.
    static let fullStreamCoalescedKinds: Set<String> = ["agent.item.delta"]

    private let enabled: Bool
    private let filter: EventStreamFilter
    private let delay: TimeInterval
    /// Window for nil-key / streaming-delta batching. Wi-Fi: 15ms; cellular: the
    /// configured `delay` (typically 100ms) so agent.item.delta bursts collapse.
    private let nilKeyDelay: TimeInterval
    /// When true, agent.item.delta frames buffer for `nilKeyDelay` and (when
    /// batching is otherwise off) everything else flushes the buffer then sends
    /// immediately. Independent of `enabled`, which drives the cellular-safe
    /// keyed/nil-key batching.
    private let coalescesStreamingDeltas: Bool
    /// Called when keyed last-write-wins drops a previously buffered frame.
    /// C-14: caller must `recordFilteredEvent` so collapsed summary seqs do not
    /// surface as spurious 1012 gaps.
    private let onCoalescedAway: (@Sendable (Data) -> Void)?
    /// S10: overflow records lost sequences and signals baseline recovery.
    private let onAdmissionOverflow: (@Sendable (_ lostSequences: [Int64], _ reason: String) -> Void)?
    private let send: @Sendable (Data) -> Void
    private let maxPendingBytes: Int
    private let maxPendingCount: Int
    private let maxPendingAge: TimeInterval
    private let queue = DispatchQueue(label: "io.remotecode.ws-event-batcher")
    // Keyed (coalescing) state
    private var pending: [String: Data] = [:]
    private var order: [String] = []
    private var scheduled = false
    // Nil-key (cross-kind) batch state
    private var nilKeyQueue: [Data] = []
    private var nilKeyScheduled = false
    private var stopped = false
    private var pendingBytes: Int = 0
    private var oldestEnqueueUptime: TimeInterval?
    private var overflowCount: Int = 0

    init(enabled: Bool,
         filter: EventStreamFilter,
         delay: TimeInterval = 0.075,
         coalescesStreamingDeltas: Bool = false,
         maxPendingBytes: Int = WebSocketEventBatcher.defaultMaxPendingBytes,
         maxPendingCount: Int = WebSocketEventBatcher.defaultMaxPendingCount,
         maxPendingAge: TimeInterval = WebSocketEventBatcher.defaultMaxPendingAge,
         onCoalescedAway: (@Sendable (Data) -> Void)? = nil,
         onAdmissionOverflow: (@Sendable (_ lostSequences: [Int64], _ reason: String) -> Void)? = nil,
         send: @escaping @Sendable (Data) -> Void) {
        self.enabled = enabled
        self.filter = filter
        self.delay = max(0, delay)
        // C-14/C-15: cellular gets the longer caller-supplied window (100–150ms);
        // Wi-Fi keeps the short cross-kind default so interactive latency stays low.
        self.nilKeyDelay = filter.isCellularSafe ? max(0, delay) : Self.crossKindDelay
        self.coalescesStreamingDeltas = coalescesStreamingDeltas
        self.maxPendingBytes = max(1, maxPendingBytes)
        self.maxPendingCount = max(1, maxPendingCount)
        self.maxPendingAge = max(0, maxPendingAge)
        self.onCoalescedAway = onCoalescedAway
        self.onAdmissionOverflow = onAdmissionOverflow
        self.send = send
    }

    /// Test/telemetry seam: current bounded pending admission footprint.
    func admissionSnapshot() -> (bytes: Int, count: Int, overflowCount: Int) {
        queue.sync { (pendingBytes, pending.count + nilKeyQueue.count, overflowCount) }
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
                    if self.wouldExceedAdmissionLocked(additionalBytes: data.count) {
                        self.handleOverflowLocked(reason: "admission_bytes_or_count")
                    }
                    guard self.canAdmitSingleFrameLocked(byteCount: data.count) else {
                        // Frame alone exceeds budget: record its sequence as lost and drop.
                        var lost: [Int64] = []
                        if let seq = WebSocketOutboundQueue.eventSequence(in: data) { lost.append(seq) }
                        self.overflowCount += 1
                        self.onAdmissionOverflow?(lost, "frame_exceeds_budget")
                        return
                    }
                    self.noteEnqueueLocked(data)
                    self.nilKeyQueue.append(data)
                    if self.isAdmissionAgedLocked() {
                        self.flushLocked()
                        return
                    }
                    guard !self.nilKeyScheduled else { return }
                    self.nilKeyScheduled = true
                    self.queue.asyncAfter(deadline: .now() + self.nilKeyDelay) {
                        self.flushLocked()
                    }
                }
            } else {
                // Non-delta: append after any buffered deltas (order preserved)
                // and flush NOW so interactive events pay zero added latency.
                queue.async {
                    guard !self.stopped else { return }
                    self.noteEnqueueLocked(data)
                    self.nilKeyQueue.append(data)
                    self.flushLocked()
                }
            }
            return
        }

        if let key = filter.coalescingKey(for: event) {
            queue.async {
                guard !self.stopped else { return }
                if self.wouldExceedAdmissionLocked(additionalBytes: data.count) {
                    self.handleOverflowLocked(reason: "admission_bytes_or_count")
                }
                guard self.canAdmitSingleFrameLocked(byteCount: data.count) else {
                    var lost: [Int64] = []
                    if let seq = WebSocketOutboundQueue.eventSequence(in: data) { lost.append(seq) }
                    self.overflowCount += 1
                    self.onAdmissionOverflow?(lost, "frame_exceeds_budget")
                    return
                }
                if let previous = self.pending[key] {
                    if self.filter.coalescingMergesByConcatenation(for: event),
                       let merged = Self.mergeAgentItemDeltaFrames(previous, data) {
                        // C-16: absorb previous sequence via onCoalescedAway so the
                        // client watermark advances without a 1012 gap, then keep
                        // the higher-sequence merged frame.
                        self.onCoalescedAway?(previous)
                        self.pendingBytes -= previous.count
                        self.noteEnqueueLocked(merged)
                        self.pending[key] = merged
                    } else {
                        // Last-write-wins: superseded summary never hits the socket.
                        self.onCoalescedAway?(previous)
                        self.pendingBytes -= previous.count
                        self.noteEnqueueLocked(data)
                        self.pending[key] = data
                    }
                } else {
                    self.order.append(key)
                    self.noteEnqueueLocked(data)
                    self.pending[key] = data
                }
                if self.isAdmissionAgedLocked() {
                    self.flushLocked()
                    return
                }
                guard !self.scheduled else { return }
                self.scheduled = true
                self.queue.asyncAfter(deadline: .now() + self.delay) {
                    self.flushLocked()
                }
            }
        } else {
            // No coalescing key: buffer for the nil-key window so bursts of
            // mixed events (incl. agent.item.delta on Wi-Fi) coalesce into
            // fewer frames; C-16 also concatenates same-item deltas on flush.
            queue.async {
                guard !self.stopped else { return }
                if self.wouldExceedAdmissionLocked(additionalBytes: data.count) {
                    self.handleOverflowLocked(reason: "admission_bytes_or_count")
                }
                self.noteEnqueueLocked(data)
                self.nilKeyQueue.append(data)
                if self.isAdmissionAgedLocked() {
                    self.flushLocked()
                    return
                }
                guard !self.nilKeyScheduled else { return }
                self.nilKeyScheduled = true
                self.queue.asyncAfter(deadline: .now() + self.nilKeyDelay) {
                    self.flushLocked()
                }
            }
        }
    }

    private func noteEnqueueLocked(_ data: Data) {
        pendingBytes += data.count
        if oldestEnqueueUptime == nil {
            oldestEnqueueUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    private func wouldExceedAdmissionLocked(additionalBytes: Int) -> Bool {
        let count = pending.count + nilKeyQueue.count
        if count + 1 > maxPendingCount { return true }
        if pendingBytes + additionalBytes > maxPendingBytes { return true }
        return false
    }

    private func isAdmissionAgedLocked() -> Bool {
        guard maxPendingAge > 0, let oldest = oldestEnqueueUptime else { return false }
        return ProcessInfo.processInfo.systemUptime - oldest >= maxPendingAge
    }

    private func handleOverflowLocked(reason: String) {
        overflowCount += 1
        var lost: [Int64] = []
        for data in pending.values {
            if let seq = WebSocketOutboundQueue.eventSequence(in: data) {
                lost.append(seq)
            }
        }
        for data in nilKeyQueue {
            if let seq = WebSocketOutboundQueue.eventSequence(in: data) {
                lost.append(seq)
            }
        }
        pending.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        nilKeyQueue.removeAll(keepingCapacity: false)
        pendingBytes = 0
        oldestEnqueueUptime = nil
        scheduled = false
        nilKeyScheduled = false
        // Always notify; production must supply a handler that advances watermark
        // and emits baseline_required. Nil still counts as explicit overflow for tests.
        onAdmissionOverflow?(lost.sorted(), reason)
    }

    /// Whether a single frame may be admitted after an overflow clear.
    private func canAdmitSingleFrameLocked(byteCount: Int) -> Bool {
        byteCount <= maxPendingBytes
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
            pendingBytes = 0
            oldestEnqueueUptime = nil
        }
    }

    private func flushLocked() {
        guard !stopped else { return }
        scheduled = false
        nilKeyScheduled = false

        var frames: [Data] = []
        if !pending.isEmpty {
            let keys = order
            frames.append(contentsOf: keys.compactMap { pending[$0] })
            pending.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
        }
        if !nilKeyQueue.isEmpty {
            // C-16 (Wi-Fi / nil-key path): concatenate same item_id deltas that
            // landed in one window so N tokens become one frame before send.
            let (merged, absorbed) = Self.mergeAgentItemDeltasInOrder(nilKeyQueue)
            for dropped in absorbed {
                onCoalescedAway?(dropped)
            }
            frames.append(contentsOf: merged)
            nilKeyQueue.removeAll(keepingCapacity: true)
        }
        pendingBytes = 0
        oldestEnqueueUptime = nil
        // C-14: emit by event sequence when present so keyed LWW + nil-key
        // events in the same window cannot invent host-side 1012 gaps.
        // Frames without a parseable sequence keep relative order (stable sort).
        frames.sort { lhs, rhs in
            let l = WebSocketOutboundQueue.eventSequence(in: lhs) ?? Int64.max
            let r = WebSocketOutboundQueue.eventSequence(in: rhs) ?? Int64.max
            return l < r
        }
        for frame in frames {
            send(frame)
        }
    }

    // MARK: - C-16 agent.item.delta concatenation

    /// Merge two encoded `agent.item.delta` frames for the same `item_id` by
    /// concatenating append fields. Returns nil when kinds/ids do not match.
    /// WHY: last-write-wins would drop tokens and corrupt agent text.
    static func mergeAgentItemDeltaFrames(_ earlier: Data, _ later: Data) -> Data? {
        guard var left = parseEventObject(earlier),
              var right = parseEventObject(later),
              (left["kind"] as? String) == "agent.item.delta",
              (right["kind"] as? String) == "agent.item.delta",
              var leftPayload = left["payload"] as? [String: Any],
              var rightPayload = right["payload"] as? [String: Any] else {
            return nil
        }
        let leftItem = leftPayload["item_id"] as? String
        let rightItem = rightPayload["item_id"] as? String
        guard let leftItem, leftItem == rightItem else { return nil }

        for field in ["body_append", "output_append", "text"] {
            let a = leftPayload[field] as? String ?? ""
            let b = rightPayload[field] as? String ?? ""
            if !a.isEmpty || !b.isEmpty {
                rightPayload[field] = a + b
            }
        }
        // summary / progress: last write wins (non-append semantics).
        right["payload"] = rightPayload
        // Keep the later (higher) sequence / eventId so the client watermark
        // advances once; earlier seq is reported via onCoalescedAway.
        guard let data = try? JSONSerialization.data(withJSONObject: right) else {
            return nil
        }
        return data
    }

    /// Walk frames in arrival order; concatenate consecutive same-item deltas.
    /// Returns (frames to send, frames absorbed whose sequences must be filtered).
    static func mergeAgentItemDeltasInOrder(_ frames: [Data]) -> (merged: [Data], absorbed: [Data]) {
        var result: [Data] = []
        var absorbed: [Data] = []
        var pendingDelta: Data?

        func flushPending() {
            if let pendingDelta {
                result.append(pendingDelta)
            }
            pendingDelta = nil
        }

        for frame in frames {
            guard let object = parseEventObject(frame),
                  (object["kind"] as? String) == "agent.item.delta" else {
                flushPending()
                result.append(frame)
                continue
            }
            if let current = pendingDelta,
               let merged = mergeAgentItemDeltaFrames(current, frame) {
                absorbed.append(current)
                pendingDelta = merged
            } else {
                flushPending()
                pendingDelta = frame
            }
        }
        flushPending()
        return (result, absorbed)
    }

    private static func parseEventObject(_ data: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "event" else { return nil }
        return object
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
