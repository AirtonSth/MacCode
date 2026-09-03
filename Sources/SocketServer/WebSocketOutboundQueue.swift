import Foundation
import Darwin

/// Serializes complete WebSocket frames for one TCP connection.
///
/// Application frames are written by `WebSocketOutboundQueue`, while pong and
/// close frames are produced by the receive loop. Both paths share this writer
/// so bytes from two frames can never interleave on the socket.
final class WebSocketConnectionWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writeFrame: @Sendable (UInt8, Data) -> Bool

    init(writeFrame: @escaping @Sendable (UInt8, Data) -> Bool) {
        self.writeFrame = writeFrame
    }

    func send(opcode: UInt8, data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writeFrame(opcode, data)
    }
}

/// FIFO storage with O(1) head advancement and occasional amortized compaction.
/// Dequeued slots are cleared immediately so frame payloads are released even
/// before the backing array is compacted.
struct WebSocketFrameFIFO<Element> {
    struct Diagnostics: Equatable {
        let queuedCount: Int
        let storageCount: Int
        let headIndex: Int
        let compactionCount: Int
    }

    private static var compactionThreshold: Int { 1_024 }

    private var storage: [Element?] = []
    private var headIndex = 0
    private var compactionCount = 0

    var diagnostics: Diagnostics {
        Diagnostics(
            queuedCount: storage.count - headIndex,
            storageCount: storage.count,
            headIndex: headIndex,
            compactionCount: compactionCount
        )
    }

    mutating func append(_ element: Element) {
        storage.append(element)
    }

    mutating func popFirst() -> Element? {
        guard headIndex < storage.count,
              let element = storage[headIndex] else {
            return nil
        }
        storage[headIndex] = nil
        headIndex += 1
        compactIfNeeded()
        return element
    }

    private mutating func compactIfNeeded() {
        if headIndex == storage.count {
            storage.removeAll(keepingCapacity: true)
            headIndex = 0
            compactionCount += 1
        } else if headIndex >= Self.compactionThreshold,
                  headIndex >= storage.count - headIndex {
            storage.removeFirst(headIndex)
            headIndex = 0
            compactionCount += 1
        }
    }
}

/// Aggregate enqueue→dequeue wait for one outbound application priority lane.
/// Secret-free: counts and milliseconds only (no payloads, tokens, hosts).
/// Public so `connectionMetricsJSON` can accept a typed default argument.
public struct OutboundQueueWaitLaneMetrics: Equatable, Sendable {
    public var count: UInt64
    public var totalMilliseconds: Double
    public var maxMilliseconds: Double

    public static let zero = OutboundQueueWaitLaneMetrics(
        count: 0,
        totalMilliseconds: 0,
        maxMilliseconds: 0
    )

    public init(count: UInt64, totalMilliseconds: Double, maxMilliseconds: Double) {
        self.count = count
        self.totalMilliseconds = totalMilliseconds
        self.maxMilliseconds = maxMilliseconds
    }

    public mutating func record(waitMilliseconds: Double) {
        let bounded: Double
        if waitMilliseconds.isFinite {
            bounded = max(0, waitMilliseconds)
        } else {
            bounded = 0
        }
        count &+= 1
        totalMilliseconds += bounded
        maxMilliseconds = max(maxMilliseconds, bounded)
    }
}

/// Process-safe snapshot of queue wait aggregates by existing application lane.
/// Public fixed numeric shape only (priority/normal/bulk count/total/max).
public struct OutboundQueueWaitMetricsSnapshot: Equatable, Sendable {
    public var priority: OutboundQueueWaitLaneMetrics
    public var normal: OutboundQueueWaitLaneMetrics
    public var bulk: OutboundQueueWaitLaneMetrics

    public static let zero = OutboundQueueWaitMetricsSnapshot(
        priority: .zero,
        normal: .zero,
        bulk: .zero
    )

    public init(
        priority: OutboundQueueWaitLaneMetrics,
        normal: OutboundQueueWaitLaneMetrics,
        bulk: OutboundQueueWaitLaneMetrics
    ) {
        self.priority = priority
        self.normal = normal
        self.bulk = bulk
    }

    func metrics(for priority: WebSocketOutboundQueue.ApplicationPriority) -> OutboundQueueWaitLaneMetrics {
        switch priority {
        case .priority: return self.priority
        case .normal: return normal
        case .bulk: return bulk
        }
    }
}

final class WebSocketOutboundQueue: @unchecked Sendable {
    enum EnqueueResult: Equatable {
        case accepted
        case queueFull
        case closed
    }

    /// Application-frame priority derived only from existing wire fields
    /// (`type` / sheddable `kind`). Does not invent input/stop semantics.
    enum ApplicationPriority: Equatable, Hashable {
        /// Transport recovery / liveness frames that are not event-stream
        /// sequenced with client gap detection: error, closing, baselineRequired, heartbeat.
        case priority
        /// Non-sheddable events and opaque frames — FIFO with bulk to preserve sequence.
        case normal
        /// Snapshots and existing sheddable bulk/diagnostic event kinds.
        case bulk
    }

    /// Opaque transport data remains raw. Known events retain typed metadata and
    /// are encoded only when the serial writer dequeues them.
    private enum ApplicationFrame {
        case raw(Data)
        case knownEvent(KnownConnectionEventFrame)

        var byteCount: Int {
            switch self {
            case .raw(let data): return data.count
            case .knownEvent(let frame): return frame.encodedByteCount
            }
        }

        var priority: ApplicationPriority {
            switch self {
            case .raw(let data): return WebSocketOutboundQueue.applicationPriority(of: data)
            case .knownEvent(let frame):
                return WebSocketOutboundQueue.isSheddableKind(frame.event.kind.rawValue)
                    ? .bulk
                    : .normal
            }
        }

        var eventSequence: Int64? {
            switch self {
            case .raw(let data): return WebSocketOutboundQueue.eventSequence(in: data)
            case .knownEvent(let frame): return frame.event.seq
            }
        }

        var reportableDroppedSequence: Int64? {
            switch self {
            case .raw(let data):
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                return WebSocketOutboundQueue.reportableDroppedSequence(object: object)
            case .knownEvent(let frame): return frame.event.seq
            }
        }

        var isSheddable: Bool {
            switch self {
            case .raw(let data): return WebSocketOutboundQueue.isSheddableApplicationFrame(data)
            case .knownEvent(let frame):
                return WebSocketOutboundQueue.isSheddableKind(frame.event.kind.rawValue)
            }
        }

        var knownCoalescingKey: String? {
            switch self {
            case .raw: return nil
            case .knownEvent(let frame):
                let payload = frame.event.payload
                switch frame.event.kind {
                case .surfaceOutput, .surfaceOutputSummary, .surfaceBrowser:
                    guard let surfaceID = payload["surface_id"]?.stringValue else { return nil }
                    return "\(frame.event.kind.rawValue):\(surfaceID)"
                case .agentItemDelta:
                    guard let threadID = payload["thread_id"]?.stringValue,
                          let itemID = payload["item_id"]?.stringValue else { return nil }
                    return AgentItemDeltaCoalescingIdentity.key(
                        threadID: threadID,
                        itemID: itemID,
                        turnID: payload["turn_id"]?.stringValue
                    )
                default:
                    return nil
                }
            }
        }

        func encoded(
            knownEventEncoder: (KnownConnectionEventFrame) -> Data?
        ) -> Data? {
            switch self {
            case .raw(let data): return data
            case .knownEvent(let frame): return knownEventEncoder(frame)
            }
        }
    }

    /// Buffered application frame with enqueue stamp for wait instrumentation.
    private struct QueuedApplicationFrame {
        let frame: ApplicationFrame
        let priority: ApplicationPriority
        /// Monotonic timestamp from `now` at accept time (not wall clock).
        let enqueuedAt: TimeInterval
    }

    /// Result of a backpressure degrade pass. Callers use this to account for
    /// discarded sequences (`recordFilteredEvent`) and to emit at most one
    /// in-band `baseline_required` without closing the socket.
    struct DegradeOutcome: Equatable {
        var freedBytes: Int
        var freedFrames: Int
        /// Sequences of application event frames removed from the outbound queue.
        /// These were previously accepted; the caller must recover via
        /// `baseline_required` (watermark already advanced past them).
        var droppedEventSequences: [Int64]
        var coalescedAwayFrames: Int
        var discardedBulkFrames: Int
        /// True when any kept-but-dropped content requires client rebaseline.
        var needsBaselineRequired: Bool

        static let empty = DegradeOutcome(
            freedBytes: 0,
            freedFrames: 0,
            droppedEventSequences: [],
            coalescedAwayFrames: 0,
            discardedBulkFrames: 0,
            needsBaselineRequired: false
        )
    }

    /// Target backlog duration used to size the queue from measured drain rate.
    static let targetBacklogSeconds: TimeInterval = 8
    static let minimumQueuedBytes = 64 * 1_024
    /// Hard ceiling so a fast Wi-Fi drain estimate cannot grow unbounded.
    static let maximumQueuedBytesCeiling = 4 * 1_024 * 1_024
    /// Absolute caps used when the effective budget is large enough to leave
    /// headroom. Tiny unit-test budgets scale down via fractions below.
    static let reservedControlBytesCap = 4 * 1_024
    static let reservedInteractiveBytesCap = 64 * 1_024

    private enum State: Equatable {
        case open
        case terminalReserved
        case terminalQueued
        case terminalSent
        case closed
    }

    private let queue: DispatchQueue
    /// Configured starting budget / soft ceiling floor for cold start.
    private let configuredMaxQueuedBytes: Int
    private let maxQueuedFrames: Int
    private let lock = NSLock()
    private var queuedBytes = 0
    private var queuedFrames = 0
    /// Bytes held in `pendingControlFrames` (subset of `queuedBytes`).
    private var queuedControlBytes = 0
    private var state: State = .open
    // Pending frames are buffered so the serial drain can prioritize:
    // 1) WebSocket control (pong/ping/close) over application data
    // 2) transport recovery application frames (baselineRequired/error/…) over
    //    sequenced event/snapshot FIFO
    // Sequenced event frames and bulk share one FIFO so seq order is preserved.
    // Each enqueue still dispatches exactly one drain token; only pick order changes.
    private var pendingPriorityApplicationFrames = WebSocketFrameFIFO<QueuedApplicationFrame>()
    private var pendingApplicationFrames = WebSocketFrameFIFO<QueuedApplicationFrame>()
    private var pendingControlFrames = WebSocketFrameFIFO<(opcode: UInt8, data: Data)>()
    private let applicationWriter: @Sendable (Data) -> Bool
    private let knownEventEncoder: @Sendable (KnownConnectionEventFrame) -> Data?
    private let controlWriter: @Sendable (UInt8, Data) -> Bool
    private let writeFailureClosingData: Data
    private let onTerminal: @Sendable (String) -> Void
    private let didSendTerminal: @Sendable () -> Void
    private let acceptedSubmissionHook: @Sendable () -> Void
    private let terminationAttemptHook: @Sendable () -> Void
    /// Monotonic (or injectable) clock for enqueue→dequeue wait. Default is
    /// process uptime so wall-clock jumps never skew wait samples.
    private let now: @Sendable () -> TimeInterval
    /// Optional process-scoped sink (e.g. WSConnectionTracker). Never receives payloads.
    private let onApplicationQueueWaitRecorded: @Sendable (ApplicationPriority, Double) -> Void
    /// Per-queue aggregate wait by existing application lane (tests + diagnostics).
    private var waitMetrics = OutboundQueueWaitMetricsSnapshot.zero
    /// EMA of observed application+control drain rate (bytes/sec).
    private var measuredDrainBytesPerSecond: Double = 0
    private var lastDrainAt: TimeInterval = 0
    private var lastDrainByteSample = 0

    init(
        label: String = "rc2.ws.outbound",
        maxQueuedBytes: Int = 1024 * 1024,
        maxQueuedFrames: Int = 4_096,
        applicationWriter: @escaping @Sendable (Data) -> Bool,
        knownEventEncoder: @escaping @Sendable (KnownConnectionEventFrame) -> Data? = {
            try? $0.encoded()
        },
        controlWriter: @escaping @Sendable (UInt8, Data) -> Bool,
        writeFailureClosingData: Data,
        onTerminal: @escaping @Sendable (String) -> Void,
        didSendTerminal: @escaping @Sendable () -> Void,
        acceptedSubmissionHook: @escaping @Sendable () -> Void = {},
        terminationAttemptHook: @escaping @Sendable () -> Void = {},
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onApplicationQueueWaitRecorded: @escaping @Sendable (ApplicationPriority, Double) -> Void = { _, _ in }
    ) {
        self.queue = DispatchQueue(label: label)
        self.configuredMaxQueuedBytes = max(1, maxQueuedBytes)
        self.maxQueuedFrames = max(1, maxQueuedFrames)
        self.applicationWriter = applicationWriter
        self.knownEventEncoder = knownEventEncoder
        self.controlWriter = controlWriter
        self.writeFailureClosingData = writeFailureClosingData
        self.onTerminal = onTerminal
        self.didSendTerminal = didSendTerminal
        self.acceptedSubmissionHook = acceptedSubmissionHook
        self.terminationAttemptHook = terminationAttemptHook
        self.now = now
        self.onApplicationQueueWaitRecorded = onApplicationQueueWaitRecorded
    }

    convenience init(
        label: String = "rc2.ws.outbound",
        maxQueuedBytes: Int = 1024 * 1024,
        maxQueuedFrames: Int = 4_096,
        writer: @escaping @Sendable (Data) -> Bool,
        onClose: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            label: label,
            maxQueuedBytes: maxQueuedBytes,
            maxQueuedFrames: maxQueuedFrames,
            applicationWriter: writer,
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: onClose,
            didSendTerminal: {}
        )
    }

    var queuedByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedBytes
    }

    var queuedFrameCountForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedFrames
    }

    /// Effective byte budget: seconds of backlog at the measured drain rate,
    /// clamped to [minimumQueuedBytes, ceiling]. Cold start (no samples) uses
    /// the configured budget so unit tests with tiny ceilings stay deterministic.
    var effectiveMaxQueuedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return effectiveMaxQueuedBytesLocked()
    }

    var measuredDrainBytesPerSecondForTests: Double {
        lock.lock(); defer { lock.unlock() }
        return measuredDrainBytesPerSecond
    }

    /// Aggregate enqueue→dequeue wait by existing application lane (secret-free).
    var queueWaitMetricsSnapshot: OutboundQueueWaitMetricsSnapshot {
        lock.lock(); defer { lock.unlock() }
        return waitMetrics
    }

    func enqueue(_ data: Data) -> EnqueueResult {
        // C-04: overflow is a degrade signal, never an implicit close.
        enqueueApplication(data)
    }

    func enqueueApplication(_ data: Data) -> EnqueueResult {
        guard !data.isEmpty else { return .accepted }
        return enqueueApplicationFrame(.raw(data))
    }

    func enqueueEvent(_ frame: KnownConnectionEventFrame) -> EnqueueResult {
        enqueueApplicationFrame(.knownEvent(frame))
    }

    private func enqueueApplicationFrame(_ frame: ApplicationFrame) -> EnqueueResult {
        let byteCount = frame.byteCount
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return .closed
        }
        let budget = effectiveMaxQueuedBytesLocked()
        let controlReserve = reservedControlBytesLocked(budget: budget)
        let interactiveReserve = reservedInteractiveBytesLocked(budget: budget)
        let softAppCeiling = max(0, budget - controlReserve)
        let softBulkCeiling = max(0, softAppCeiling - interactiveReserve)
        let applicationQueued = max(0, queuedBytes - queuedControlBytes)
        let priority = frame.priority
        // Hard bound: never exceed the total byte/frame budget.
        guard queuedFrames < maxQueuedFrames,
              byteCount <= budget - queuedBytes else {
            lock.unlock()
            return .queueFull
        }
        let afterApp = applicationQueued + byteCount
        // Soft reservations: small frames must leave room for control and
        // interactive/priority traffic. A single large frame that cannot leave
        // those slices (cold start / oversized payload) still uses the hard budget.
        switch priority {
        case .bulk:
            if afterApp > softBulkCeiling, byteCount <= interactiveReserve + controlReserve {
                lock.unlock()
                return .queueFull
            }
        case .priority, .normal:
            if afterApp > softAppCeiling, byteCount <= controlReserve {
                lock.unlock()
                return .queueFull
            }
        }
        let queued = QueuedApplicationFrame(
            frame: frame,
            priority: priority,
            enqueuedAt: now()
        )
        queuedBytes += byteCount
        queuedFrames += 1
        switch priority {
        case .priority:
            pendingPriorityApplicationFrames.append(queued)
        case .normal, .bulk:
            pendingApplicationFrames.append(queued)
        }
        acceptedSubmissionHook()
        queue.async { [weak self] in self?.writeNextPendingFrame() }
        lock.unlock()
        return .accepted
    }

    func enqueueControl(opcode: UInt8, data: Data) -> EnqueueResult {
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return .closed
        }
        let budget = effectiveMaxQueuedBytesLocked()
        let controlReserve = reservedControlBytesLocked(budget: budget)
        let applicationQueued = max(0, queuedBytes - queuedControlBytes)
        let appCeiling = max(0, budget - controlReserve)
        // Accept when total budget has room, or when applications already hold
        // their ceiling and this control still fits the reserved control slice.
        // Frame count still hard-caps pathological ping floods.
        let controlAccepted =
            queuedFrames < maxQueuedFrames
            && (
                data.count <= budget - queuedBytes
                || (
                    applicationQueued >= appCeiling
                    && queuedControlBytes + data.count <= controlReserve
                )
            )
        guard controlAccepted else {
            // Control overflow used to terminate; that killed healthy 3G sessions
            // under event load. Application backlog must never force a close when
            // only the control reserve is temporarily full — degrade owns recovery.
            lock.unlock()
            return .queueFull
        }
        queuedBytes += data.count
        queuedControlBytes += data.count
        queuedFrames += 1
        pendingControlFrames.append((opcode: opcode, data: data))
        acceptedSubmissionHook()
        queue.async { [weak self] in self?.writeNextPendingFrame() }
        lock.unlock()
        return .accepted
    }

    /// Backpressure ladder (C-04): coalesce by key → discard bulk/diagnostic
    /// application frames → report that a focused `baseline_required` is needed.
    /// Never closes the socket. Control frames are preserved.
    ///
    /// Degrade re-staging is not send admission: wait stamps are preserved for
    /// kept frames and only recorded when the drain actually dequeues them.
    @discardableResult
    func degrade() -> DegradeOutcome {
        lock.lock()
        guard state == .open else {
            lock.unlock()
            return .empty
        }

        var queued: [QueuedApplicationFrame] = []
        while let frame = pendingPriorityApplicationFrames.popFirst() {
            queued.append(frame)
        }
        while let frame = pendingApplicationFrames.popFirst() {
            queued.append(frame)
        }
        guard !queued.isEmpty else {
            lock.unlock()
            return .empty
        }

        let beforeBytes = queued.reduce(0) { $0 + $1.frame.byteCount }
        let beforeCount = queued.count
        let coalesced = Self.coalesceQueuedApplicationFrames(queued)
        let coalescedAway = beforeCount - coalesced.frames.count

        var kept: [QueuedApplicationFrame] = []
        var droppedSequences = coalesced.droppedEventSequences
        var discardedBulk = 0
        kept.reserveCapacity(coalesced.frames.count)
        for queuedFrame in coalesced.frames {
            // Snapshots and sheddable event kinds are bulk under pressure.
            let priority = queuedFrame.frame.priority
            if priority == .bulk || queuedFrame.frame.isSheddable {
                discardedBulk += 1
                if let sequence = queuedFrame.frame.reportableDroppedSequence {
                    droppedSequences.append(sequence)
                }
                continue
            }
            kept.append(QueuedApplicationFrame(
                frame: queuedFrame.frame,
                priority: priority,
                enqueuedAt: queuedFrame.enqueuedAt
            ))
        }

        let afterBytes = kept.reduce(0) { $0 + $1.frame.byteCount }
        let controlBytes = queuedControlBytes
        let controlFrames = queuedFrames - beforeCount
        queuedBytes = max(0, controlBytes) + afterBytes
        queuedFrames = max(0, controlFrames) + kept.count
        for frame in kept {
            if frame.priority == .priority {
                pendingPriorityApplicationFrames.append(frame)
            } else {
                pendingApplicationFrames.append(frame)
            }
        }

        let freedBytes = max(0, beforeBytes - afterBytes)
        let freedFrames = max(0, beforeCount - kept.count)
        let outcome = DegradeOutcome(
            freedBytes: freedBytes,
            freedFrames: freedFrames,
            droppedEventSequences: droppedSequences,
            coalescedAwayFrames: max(0, coalescedAway),
            discardedBulkFrames: discardedBulk,
            needsBaselineRequired: freedFrames > 0
        )
        lock.unlock()
        return outcome
    }

    private struct CoalescedQueuedFrames {
        var frames: [QueuedApplicationFrame]
        var droppedEventSequences: [Int64]
    }

    /// Typed known events coalesce from metadata. Raw parsing is confined to
    /// the opaque/replay adapter represented by `ApplicationFrame.raw`.
    private static func coalesceQueuedApplicationFrames(
        _ queued: [QueuedApplicationFrame],
        onRawParse: (() -> Void)? = nil,
        onRawEncode: (() -> Void)? = nil
    ) -> CoalescedQueuedFrames {
        var result: [QueuedApplicationFrame] = []
        var keySlots: [String: Int] = [:]
        var deltaFramesBySlot: [Int: [QueuedApplicationFrame]] = [:]
        var dropped: [Int64] = []
        result.reserveCapacity(queued.count)

        for queuedFrame in queued {
            let key: String?
            switch queuedFrame.frame {
            case .raw(let data):
                onRawParse?()
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                key = coalescingKey(object: object)
            case .knownEvent:
                key = queuedFrame.frame.knownCoalescingKey
            }
            guard let key else {
                result.append(queuedFrame)
                continue
            }
            guard let index = keySlots[key] else {
                keySlots[key] = result.count
                result.append(queuedFrame)
                continue
            }

            if key.hasPrefix("agent.item.delta:") {
                if deltaFramesBySlot[index] == nil {
                    deltaFramesBySlot[index] = [result[index]]
                }
                deltaFramesBySlot[index]?.append(queuedFrame)
                continue
            }
            let previous = result[index]
            if let sequence = previous.frame.eventSequence { dropped.append(sequence) }
            result[index] = QueuedApplicationFrame(
                frame: queuedFrame.frame,
                priority: queuedFrame.frame.priority,
                enqueuedAt: min(previous.enqueuedAt, queuedFrame.enqueuedAt)
            )
        }

        for (index, frames) in deltaFramesBySlot {
            dropped.append(contentsOf: frames.dropLast().compactMap(\.frame.eventSequence))
            let earliest = frames.map(\.enqueuedAt).min() ?? frames[0].enqueuedAt
            let mergedFrame: ApplicationFrame
            if frames.allSatisfy({ if case .raw = $0.frame { true } else { false } }) {
                let raw = frames.compactMap { queued -> Data? in
                    guard case .raw(let data) = queued.frame else { return nil }
                    return data
                }
                let linear = WebSocketEventBatcher.mergeAgentItemDeltasInOrder(
                    raw,
                    onParse: onRawParse,
                    onEncode: onRawEncode
                )
                mergedFrame = .raw(linear.merged.last ?? raw.last!)
            } else if frames.allSatisfy({ if case .knownEvent = $0.frame { true } else { false } }) {
                let known = frames.compactMap { queued -> KnownConnectionEventFrame? in
                    guard case .knownEvent(let frame) = queued.frame else { return nil }
                    return frame
                }
                mergedFrame = .knownEvent(known.dropFirst().reduce(known[0]) { accumulated, frame in
                    WebSocketEventBatcher.mergeKnownAgentItemDeltaFrames(accumulated, frame)
                        ?? frame
                })
            } else {
                mergedFrame = frames.last!.frame
            }
            result[index] = QueuedApplicationFrame(
                frame: mergedFrame,
                priority: mergedFrame.priority,
                enqueuedAt: earliest
            )
        }
        return CoalescedQueuedFrames(frames: result, droppedEventSequences: dropped)
    }

    /// Classify using only existing protocol `type` / sheddable `kind` fields
    /// (plus the existing Wave-4 JSON-RPC success envelope that wraps a
    /// `result.type == "snapshot"` transport frame — not a new command class).
    ///
    /// PERF: one `JSONSerialization` per frame. The previous path parsed once
    /// for `type`, again for sheddable `kind` / snapshot-RPC checks — 2–3 full
    /// parses on every enqueue, including high-frequency `agent.item.delta`.
    static func applicationPriority(of data: Data) -> ApplicationPriority {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return applicationPriority(object: object)
    }

    static func applicationPriority(object: [String: Any]?) -> ApplicationPriority {
        guard let object else {
            // Opaque / test blobs stay on the normal FIFO lane.
            return .normal
        }
        if let type = object["type"] as? String {
            switch type {
            case "error", "closing", "baselineRequired", "heartbeat":
                return .priority
            case "snapshot":
                return .bulk
            case "event":
                if let kind = object["kind"] as? String, isSheddableKind(kind) {
                    return .bulk
                }
                return .normal
            default:
                return .normal
            }
        }
        // Large `sync.snapshot` RPC replies are multiplexed on the same WS
        // as stop/input. Treat the existing nested snapshot result as bulk
        // so they cannot monopolize the control drain path.
        if isSnapshotRPCSuccessEnvelope(object: object) {
            return .bulk
        }
        return .normal
    }

    /// Whether an encoded application frame is safe to shed under pressure.
    ///
    /// PERF: single JSON parse (same contract as before).
    static func isSheddableApplicationFrame(_ data: Data) -> Bool {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return isSheddableApplicationFrame(object: object)
    }

    static func isSheddableApplicationFrame(object: [String: Any]?) -> Bool {
        guard let object else { return false }
        if object["type"] as? String == "snapshot" { return true }
        // Nested snapshot RPC bodies are the same bulk baseline as bare
        // `type:snapshot` frames; shed under pressure so recovery/control can
        // reclaim capacity without inventing a new wire field.
        if isSnapshotRPCSuccessEnvelope(object: object) { return true }
        guard object["type"] as? String == "event",
              let kind = object["kind"] as? String else {
            return false
        }
        return isSheddableKind(kind)
    }

    /// Existing Wave-4 WebSocket JSON-RPC success envelope whose `result` is a
    /// `ConnectionSnapshotFrame` (`type == "snapshot"`). Detected only from
    /// those wire keys — no new priority vocabulary.
    static func isSnapshotRPCSuccessEnvelope(_ data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return isSnapshotRPCSuccessEnvelope(object: object)
    }

    private static func isSnapshotRPCSuccessEnvelope(object: [String: Any]) -> Bool {
        guard object["jsonrpc"] as? String == "2.0",
              object["method"] == nil,
              let result = object["result"] as? [String: Any],
              result["type"] as? String == "snapshot" else {
            return false
        }
        return true
    }

    static func isSheddableKind(_ kind: String) -> Bool {
        if kind.hasPrefix("diagnostic.") || kind.hasPrefix("metrics.") {
            return true
        }
        switch kind {
        case "surface.output", "surface.output.summary", "agent.item.delta":
            return true
        default:
            return false
        }
    }

    static func frameType(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["type"] as? String
    }

    static func eventSequence(in data: Data) -> Int64? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return eventSequence(object: object)
    }

    static func eventSequence(object: [String: Any]?) -> Int64? {
        guard let object, (object["type"] as? String) == "event" else { return nil }
        return int64Field(object["sequence"])
    }

    static func snapshotSequence(in data: Data) -> Int64? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return snapshotSequence(object: object)
    }

    static func snapshotSequence(object: [String: Any]?) -> Int64? {
        guard let object, (object["type"] as? String) == "snapshot" else { return nil }
        return int64Field(object["sequence"])
    }

    /// Sequence to report when a frame is shed under degrade (event or bare snapshot).
    private static func reportableDroppedSequence(object: [String: Any]?) -> Int64? {
        if let sequence = eventSequence(object: object) { return sequence }
        return snapshotSequence(object: object)
    }

    static func eventKind(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "event" else { return nil }
        return object["kind"] as? String
    }

    private static func int64Field(_ value: Any?) -> Int64? {
        if let n = value as? Int64 { return n }
        if let n = value as? Int { return Int64(n) }
        if let n = value as? Double { return Int64(n) }
        return nil
    }

    static func coalescingKey(for data: Data) -> String? {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return coalescingKey(object: object)
    }

    static func coalescingKey(object: [String: Any]?) -> String? {
        guard let object,
              (object["type"] as? String) == "event",
              let kind = object["kind"] as? String else { return nil }
        let payload = object["payload"] as? [String: Any]
        switch kind {
        case "surface.output", "surface.output.summary", "surface.browser":
            if let sid = payload?["surface_id"] as? String {
                return "\(kind):\(sid)"
            }
        case "agent.item.delta":
            if let thread = payload?["thread_id"] as? String,
               let item = payload?["item_id"] as? String {
                return AgentItemDeltaCoalescingIdentity.key(
                    threadID: thread,
                    itemID: item,
                    turnID: payload?["turn_id"] as? String
                )
            }
        default:
            break
        }
        return nil
    }

    /// Coalesce per key: LWW for summaries/geometry; **concatenate** for
    /// `agent.item.delta` (C-16 — LWW would drop tokens and corrupt text).
    /// Non-keyed frames keep arrival order.
    static func coalesceApplicationFrames(
        _ frames: [Data],
        onParse: (() -> Void)? = nil,
        onEncode: (() -> Void)? = nil
    ) -> [Data] {
        let queued = frames.map {
            QueuedApplicationFrame(frame: .raw($0), priority: .normal, enqueuedAt: 0)
        }
        return coalesceQueuedApplicationFrames(
            queued,
            onRawParse: onParse,
            onRawEncode: onEncode
        ).frames.compactMap { queued in
            guard case .raw(let data) = queued.frame else { return nil }
            return data
        }
    }

    private func effectiveMaxQueuedBytesLocked() -> Int {
        let ceiling = min(
            Self.maximumQueuedBytesCeiling,
            max(configuredMaxQueuedBytes, Self.minimumQueuedBytes)
        )
        // No drain samples yet: honor the configured budget (keeps unit tests
        // with tiny maxQueuedBytes deterministic).
        guard measuredDrainBytesPerSecond >= 1_000 else {
            return max(1, configuredMaxQueuedBytes)
        }
        let dynamic = Int(measuredDrainBytesPerSecond * Self.targetBacklogSeconds)
        return min(ceiling, max(Self.minimumQueuedBytes, dynamic))
    }

    /// Bytes reserved exclusively for WebSocket control frames under app load.
    /// Scales down for tiny test budgets so existing overflow tests stay valid.
    private func reservedControlBytesLocked(budget: Int) -> Int {
        min(Self.reservedControlBytesCap, max(0, budget / 8))
    }

    /// Bytes applications leave free so bulk snapshot/replay cannot starve
    /// interactive/error/completion frames. Scales with budget.
    private func reservedInteractiveBytesLocked(budget: Int) -> Int {
        let control = reservedControlBytesLocked(budget: budget)
        let applicationCeiling = max(0, budget - control)
        return min(Self.reservedInteractiveBytesCap, max(0, applicationCeiling / 4))
    }

    @discardableResult
    func terminate(errorData: Data?, closingData: Data?, reason: String) -> Bool {
        terminationAttemptHook()
        lock.lock()
        guard state == .open || state == .terminalReserved else {
            lock.unlock()
            return false
        }
        state = .terminalQueued
        lock.unlock()

        onTerminal(reason)
        queue.async { [weak self] in
            guard let self, self.beginQueuedTerminalSend() else { return }
            if let errorData { _ = self.controlWriter(0x1, errorData) }
            if let closingData { _ = self.controlWriter(0x1, closingData) }
            _ = self.controlWriter(0x8, Data())
            self.didSendTerminal()
        }
        return true
    }

    func close() {
        lock.lock()
        if state == .open || state == .terminalReserved { state = .closed }
        lock.unlock()
    }

    func drain() {
        finish()
    }

    func finish() {
        queue.sync {}
    }

    /// Runs once per enqueued frame on the serial queue. Drain order:
    /// WebSocket control → transport priority application → sequenced/bulk FIFO.
    /// An application frame whose write already started is never preempted
    /// (RFC 6455 frames must not interleave).
    private func writeNextPendingFrame() {
        enum Admission {
            case control(opcode: UInt8, data: Data)
            case application(QueuedApplicationFrame, waitMilliseconds: Double)
        }

        let admission: Admission?
        lock.lock()
        if let control = pendingControlFrames.popFirst() {
            admission = .control(opcode: control.opcode, data: control.data)
            lock.unlock()
        } else if let frame = pendingPriorityApplicationFrames.popFirst() {
            let waitMs = recordApplicationQueueWaitLocked(frame)
            admission = .application(frame, waitMilliseconds: waitMs)
            lock.unlock()
            onApplicationQueueWaitRecorded(frame.priority, waitMs)
        } else if let frame = pendingApplicationFrames.popFirst() {
            let waitMs = recordApplicationQueueWaitLocked(frame)
            admission = .application(frame, waitMilliseconds: waitMs)
            lock.unlock()
            onApplicationQueueWaitRecorded(frame.priority, waitMs)
        } else {
            lock.unlock()
            admission = nil
        }

        switch admission {
        case .control(let opcode, let data):
            writeControl(opcode: opcode, data: data)
        case .application(let frame, _):
            writeApplication(frame.frame)
        case nil:
            return
        }
    }

    /// Attribute enqueue→dequeue wait to the lane classified at accept time.
    /// Call only while holding `lock`. Returns non-negative milliseconds.
    @discardableResult
    private func recordApplicationQueueWaitLocked(_ frame: QueuedApplicationFrame) -> Double {
        let waitMs = max(0, (now() - frame.enqueuedAt) * 1_000)
        switch frame.priority {
        case .priority:
            waitMetrics.priority.record(waitMilliseconds: waitMs)
        case .normal:
            waitMetrics.normal.record(waitMilliseconds: waitMs)
        case .bulk:
            waitMetrics.bulk.record(waitMilliseconds: waitMs)
        }
        return waitMs
    }

    private func writeApplication(_ frame: ApplicationFrame) {
        let byteCount = frame.byteCount
        guard shouldWriteQueuedItem() else {
            removeQueuedItem(byteCount: byteCount, isControl: false)
            return
        }
        guard let data = frame.encoded(knownEventEncoder: knownEventEncoder) else {
            removeQueuedItem(byteCount: byteCount, isControl: false)
            terminateImmediatelyAfterWriteFailure()
            return
        }
        let succeeded = applicationWriter(data)
        removeQueuedItem(byteCount: byteCount, isControl: false, countAsDrain: succeeded)
        if !succeeded { terminateImmediatelyAfterWriteFailure() }
    }

    private func writeControl(opcode: UInt8, data: Data) {
        guard shouldWriteQueuedItem() else {
            removeQueuedItem(byteCount: data.count, isControl: true)
            return
        }
        let succeeded = controlWriter(opcode, data)
        removeQueuedItem(byteCount: data.count, isControl: true, countAsDrain: succeeded)
        if !succeeded { terminateImmediatelyAfterWriteFailure() }
    }

    private func shouldWriteQueuedItem() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return state != .terminalSent && state != .closed
    }

    private func beginQueuedTerminalSend() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard state == .terminalQueued else { return false }
        state = .terminalSent
        return true
    }

    private func removeQueuedItem(byteCount: Int, isControl: Bool, countAsDrain: Bool = false) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - byteCount)
        queuedFrames = max(0, queuedFrames - 1)
        if isControl {
            queuedControlBytes = max(0, queuedControlBytes - byteCount)
        }
        if countAsDrain, byteCount > 0 {
            noteDrainLocked(bytes: byteCount)
        }
        lock.unlock()
    }

    private func noteDrainLocked(bytes: Int) {
        let now = Date().timeIntervalSinceReferenceDate
        if lastDrainAt > 0 {
            let dt = now - lastDrainAt
            if dt > 0.000_5 {
                // Attribute the previous sample's bytes over the inter-write gap.
                let instant = Double(lastDrainByteSample) / dt
                if measuredDrainBytesPerSecond <= 0 {
                    measuredDrainBytesPerSecond = instant
                } else {
                    measuredDrainBytesPerSecond =
                        measuredDrainBytesPerSecond * 0.8 + instant * 0.2
                }
            }
        }
        lastDrainAt = now
        lastDrainByteSample = bytes
    }

    private func terminateImmediatelyAfterWriteFailure() {
        lock.lock()
        guard state != .terminalSent && state != .closed else {
            lock.unlock()
            return
        }
        state = .terminalSent
        lock.unlock()
        onTerminal("write_failed")
        _ = controlWriter(0x1, writeFailureClosingData)
        _ = controlWriter(0x8, Data())
        didSendTerminal()
    }
}

final class LockedSubscriberID: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: UUID?

    var value: UUID? {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); storage = newValue; lock.unlock()
        }
    }
}

/// Per-connection last outbound queue-byte sample for /v1/health gauges.
final class LockedQueuedBytesSample: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    /// Atomically replace the sample and return the previous value.
    func swap(_ newValue: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let previous = storage
        storage = max(0, newValue)
        return previous
    }
}

/// Rate-limits in-band `baseline_required` emissions under outbound pressure
/// so a busy agent cannot flood the client (acceptance: ≤1/s).
///
/// Sticky recovery (S10): generation-aware pending + single-flight flush so a
/// success cannot clear a newer recovery request, and flood paths cannot spawn
/// unbounded retry tasks.
final class OutboundPressureBaselineGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastEmitAt: TimeInterval = 0
    private let minInterval: TimeInterval
    private var pendingGeneration: UInt64 = 0
    private var issuedGeneration: UInt64 = 0
    private var flushScheduled = false
    private var closed = false

    init(minInterval: TimeInterval = 1.0) {
        self.minInterval = max(0, minInterval)
    }

    /// True when a recovery emission is still owed and the connection is open.
    var hasPendingRecovery: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && pendingGeneration > issuedGeneration
    }

    /// Terminal: stop sticky recovery for this connection.
    func markClosed() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        flushScheduled = false
        pendingGeneration = issuedGeneration
    }

    /// Coalesce a recovery request (bumps generation so later success cannot
    /// clear a newer overflow).
    func markPending() {
        lock.lock(); defer { lock.unlock() }
        pendingGeneration &+= 1
    }

    /// Attempt to open the rate gate. Returns the generation acquired, or nil.
    func tryAcquireGeneration(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        if closed { return nil }
        if lastEmitAt > 0, now - lastEmitAt < minInterval {
            if pendingGeneration == issuedGeneration {
                pendingGeneration &+= 1
            }
            return nil
        }
        lastEmitAt = now
        // Capture the generation being served so a concurrent markPending
        // after acquire keeps recovery sticky.
        if pendingGeneration == 0 { pendingGeneration = 1 }
        return pendingGeneration
    }

    /// Convenience for callers that only need a Bool (legacy tests).
    func tryAcquire(now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Bool {
        tryAcquireGeneration(now: now) != nil
    }

    /// Clear pending only when this success covers the current generation.
    func recordSuccess(forGeneration generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if generation >= pendingGeneration {
            issuedGeneration = pendingGeneration
        } else {
            // A newer request arrived during emission — keep pending.
            issuedGeneration = min(issuedGeneration, generation)
        }
    }

    /// Legacy success without generation (covers all outstanding if no race).
    func recordSuccess() {
        lock.lock(); defer { lock.unlock() }
        issuedGeneration = pendingGeneration
    }

    /// Single-flight trailing flush arm. Returns true only for the first
    /// concurrent scheduler so floods do not enqueue unbounded tasks.
    func armFlushIfNeeded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        guard pendingGeneration > issuedGeneration else { return false }
        guard !flushScheduled else { return false }
        flushScheduled = true
        return true
    }

    func clearFlushArm() {
        lock.lock(); defer { lock.unlock() }
        flushScheduled = false
    }
}

enum ConnectionSequenceRecordResult: Equatable {
    case advanced
    case bufferedForSnapshot
    case coveredBySnapshot
    case gap(expected: Int64, received: Int64)
}

enum ConnectionSnapshotAdoptionResult: Equatable {
    case adopted(sequence: Int64)
    case gap(expected: Int64, received: Int64)
}

final class ConnectionSequenceWatermark: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: Int64
    private var snapshotCoveredThrough: Int64 = 0
    private var snapshotInFlight = false
    /// Kept events recorded out of order while a snapshot is in flight. Kept
    /// events cross one serial batcher in seq order, so a hole below a member
    /// of this set proves a genuinely lost event.
    private var pendingSequences = Set<Int64>()
    /// Filter-dropped seqs recorded ahead of the kept event below them. These
    /// are recorded synchronously on the EventBus delivery queue while kept
    /// events add batcher latency, so a hole below a member of this set only
    /// means a kept event still in flight — never a lost event.
    private var filteredPendingSequences = Set<Int64>()

    init(initialSequence: Int64) {
        self.sequence = max(0, initialSequence)
    }

    var value: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sequence
    }

    func beginSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !snapshotInFlight else { return false }
        snapshotInFlight = true
        // Kept seqs only buffer while a snapshot is in flight and every exit
        // path clears them, so this starts the lifecycle from a clean set.
        // filteredPendingSequences intentionally survives: a filter hole is a
        // fact about the live stream, not the snapshot lifecycle. Clearing it
        // would lose the account of a never-sent seq, and the first kept
        // event after the hole would re-report it as a gap.
        pendingSequences.removeAll(keepingCapacity: true)
        return true
    }

    /// Re-anchors the gap expectation when replay expiry re-anchors the
    /// delivery cursor to the live head. Advance-only, so a snapshot adopted
    /// concurrently (or live events recorded meanwhile) is never rolled back.
    func reanchorForExpiredReplay(sequence next: Int64) {
        lock.lock()
        if next > sequence {
            sequence = next
            drainPendingLocked()
        }
        lock.unlock()
    }

    func recordEnqueuedEvent(sequence next: Int64) -> ConnectionSequenceRecordResult {
        lock.lock(); defer { lock.unlock() }
        if next == sequence + 1 {
            sequence = next
            drainPendingLocked()
            return .advanced
        }
        if next <= snapshotCoveredThrough {
            return .coveredBySnapshot
        }
        if snapshotInFlight, next > sequence + 1 {
            pendingSequences.insert(next)
            return .bufferedForSnapshot
        }
        return .gap(expected: sequence + 1, received: next)
    }

    /// Accounts for a seq the connection's negotiated filter dropped: the
    /// event was never sent, so the gap expectation must advance past it
    /// without a frame. A filtered seq can be recorded ahead of an earlier
    /// kept event still crossing the batcher, so out-of-order seqs are
    /// buffered and drained once the kept event advances the watermark. A
    /// hole the filter cannot account for is left for the next enqueued
    /// event to report as a gap.
    func recordFilteredEvent(sequence next: Int64) {
        lock.lock()
        if next == sequence + 1 {
            sequence = next
            drainPendingLocked()
        } else if next > sequence, next > snapshotCoveredThrough {
            filteredPendingSequences.insert(next)
        }
        lock.unlock()
    }

    func adoptSnapshot(sequence next: Int64) -> ConnectionSnapshotAdoptionResult {
        lock.lock(); defer { lock.unlock() }
        guard snapshotInFlight else {
            return .gap(expected: sequence + 1, received: next)
        }
        var candidateSequence = max(sequence, next)
        var remainingKept = pendingSequences.filter { $0 > candidateSequence }
        var remainingFiltered = filteredPendingSequences.filter { $0 > candidateSequence }
        while remainingKept.remove(candidateSequence + 1) != nil
            || remainingFiltered.remove(candidateSequence + 1) != nil {
            candidateSequence += 1
        }
        snapshotInFlight = false
        if let received = remainingKept.min() {
            pendingSequences.removeAll(keepingCapacity: true)
            filteredPendingSequences.removeAll(keepingCapacity: true)
            return .gap(expected: candidateSequence + 1, received: received)
        }
        sequence = candidateSequence
        snapshotCoveredThrough = max(snapshotCoveredThrough, next)
        pendingSequences.removeAll(keepingCapacity: true)
        // Remaining filtered seqs above the adopted head are NOT a gap: the
        // hole below them is a kept event still crossing the batcher, and its
        // recordEnqueuedEvent will drain them. They must be retained, or that
        // kept event would re-report the filter hole as a gap.
        filteredPendingSequences = remainingFiltered
        return .adopted(sequence: sequence)
    }

    func cancelSnapshot() {
        lock.lock()
        snapshotInFlight = false
        // Kept seqs buffered for the abandoned snapshot are dropped: without
        // an adopted snapshot the hole below them stays uncovered, and the
        // next kept event fails loud as a gap.
        // filteredPendingSequences survives: it accounts for seqs that were
        // never sent, independent of any snapshot; dropping it would turn the
        // filter hole into a spurious gap once the in-flight kept event lands.
        pendingSequences.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func drainPendingLocked() {
        while pendingSequences.remove(sequence + 1) != nil
            || filteredPendingSequences.remove(sequence + 1) != nil {
            sequence += 1
        }
    }
}

final class ActiveWebSocketConnectionRegistry: @unchecked Sendable {
    private struct Entry {
        let ownerFingerprint: String
        let watermark: ConnectionSequenceWatermark
        /// Current hybrid authority for this owner. Physically live predecessors
        /// keep an entry after same-owner replace but lose authority so
        /// `ownerFingerprint(for:)` fails closed while `hasConnection` stays true.
        var isHybridAuthority: Bool
        /// Accepted TCP descriptor. Revoke must `SHUT_RDWR` this fd; the
        /// session owner still performs the final `Darwin.close`.
        let socketFD: Int32
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    func insert(
        _ connectionID: String,
        ownerFingerprint: String,
        watermark: ConnectionSequenceWatermark,
        socketFD: Int32 = -1
    ) {
        lock.lock()
        // One hybrid-authority connection per owner. A replacement WS supersedes
        // half-closed predecessors for hybrid registration without erasing their
        // physical liveness: removing the successor alone must not open the
        // WS-absent HTTP fallback while a predecessor TCP socket is still draining.
        for (key, var entry) in entries {
            guard entry.ownerFingerprint == ownerFingerprint, key != connectionID else {
                continue
            }
            entry.isHybridAuthority = false
            entries[key] = entry
        }
        entries[connectionID] = Entry(
            ownerFingerprint: ownerFingerprint,
            watermark: watermark,
            isHybridAuthority: true,
            socketFD: socketFD
        )
        lock.unlock()
    }

    func watermark(
        for connectionID: String,
        ownerFingerprint: String
    ) -> ConnectionSequenceWatermark? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[connectionID],
              entry.ownerFingerprint == ownerFingerprint,
              entry.isHybridAuthority else {
            return nil
        }
        return entry.watermark
    }

    /// Owner fingerprint for the *current hybrid authority* connection_id only.
    /// Demoted physically live predecessors return nil. Used by WS resume and
    /// sequence watermark lookup — not by HTTP mutation/snapshot admission.
    func ownerFingerprint(for connectionID: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[connectionID], entry.isHybridAuthority else {
            return nil
        }
        return entry.ownerFingerprint
    }

    /// True when this owner currently holds at least one *physically live*
    /// WebSocket entry (including demoted same-owner predecessors).
    /// WS lifecycle only — HTTP mutations/snapshots do not consult this.
    func hasConnection(ownedBy ownerFingerprint: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return entries.values.contains { $0.ownerFingerprint == ownerFingerprint }
    }

    func remove(_ connectionID: String) {
        lock.lock(); entries.removeValue(forKey: connectionID); lock.unlock()
    }

    func ownerFingerprints() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(entries.values.map(\.ownerFingerprint))
    }

    /// Shut down one connection's socket and drop its registry entry.
    /// Returns the fd so the session owner can `Darwin.close` it. Does not
    /// `close(2)` here: another thread may still hold the descriptor.
    @discardableResult
    func close(_ connectionID: String) -> Int32? {
        lock.lock()
        let entry = entries.removeValue(forKey: connectionID)
        lock.unlock()
        guard let entry else { return nil }
        Self.shutdownSocket(entry.socketFD)
        return entry.socketFD >= 0 ? entry.socketFD : nil
    }

    /// Shut down every physically live socket for `ownerFingerprint`,
    /// including demoted same-owner predecessors. Skips `except` so a
    /// revoke request can still write its 200. Returns shutdown fds.
    @discardableResult
    func close(ownedBy ownerFingerprint: String, except descriptor: Int32 = -1) -> [Int32] {
        lock.lock()
        let matching = entries.filter { _, entry in
            guard entry.ownerFingerprint == ownerFingerprint else { return false }
            if descriptor >= 0, entry.socketFD == descriptor { return false }
            return true
        }
        for key in matching.keys {
            entries.removeValue(forKey: key)
        }
        lock.unlock()
        var fds: [Int32] = []
        fds.reserveCapacity(matching.count)
        for entry in matching.values {
            Self.shutdownSocket(entry.socketFD)
            if entry.socketFD >= 0 {
                fds.append(entry.socketFD)
            }
        }
        return fds
    }

    private static func shutdownSocket(_ fd: Int32) {
        guard fd >= 0 else { return }
        _ = Darwin.shutdown(fd, SHUT_RDWR)
    }
}

/// HTTP keep-alive sessions keyed by accepted fd and durable owner fingerprint.
/// Revoke shuts these down so a revoked bearer cannot send or receive on the
/// still-open TCP connection after credential invalidation.
final class ActiveHTTPOwnerConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var ownerByDescriptor: [Int32: String] = [:]

    func bind(_ descriptor: Int32, ownerFingerprint: String) {
        guard descriptor >= 0, !ownerFingerprint.isEmpty else { return }
        lock.lock()
        ownerByDescriptor[descriptor] = ownerFingerprint
        lock.unlock()
    }

    func unbind(_ descriptor: Int32) {
        lock.lock()
        ownerByDescriptor.removeValue(forKey: descriptor)
        lock.unlock()
    }

    func ownerFingerprint(for descriptor: Int32) -> String? {
        lock.lock(); defer { lock.unlock() }
        return ownerByDescriptor[descriptor]
    }

    func ownerFingerprints() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(ownerByDescriptor.values)
    }

    func descriptors(ownedBy ownerFingerprint: String) -> [Int32] {
        lock.lock(); defer { lock.unlock() }
        return ownerByDescriptor.compactMap { fd, owner in
            owner == ownerFingerprint ? fd : nil
        }
    }

    /// Shut down every HTTP socket bound to `ownerFingerprint` except the
    /// revoke request's own fd. Session defer still `Darwin.close`s.
    @discardableResult
    func close(ownedBy ownerFingerprint: String, except descriptor: Int32 = -1) -> [Int32] {
        lock.lock()
        let fds = ownerByDescriptor.compactMap { fd, owner -> Int32? in
            guard owner == ownerFingerprint, fd != descriptor else { return nil }
            return fd
        }
        for fd in fds {
            ownerByDescriptor.removeValue(forKey: fd)
        }
        lock.unlock()
        for fd in fds {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
        }
        return fds
    }
}
