import Foundation

/// C8: durable replay of state-bearing events for a resuming client.
///
/// Opt-in only. A client sends `X-RC2-Durable-Replay: v1` on the `/v1/ws`
/// upgrade. Without it the socket behaves exactly as before: an expired
/// cursor gets `baselineRequired`. With it:
/// - the welcome carries `replayFromSequence` (the cursor this socket replays
///   from; equal to `currentSequence` when a `baselineRequired` follows);
/// - a cursor the in-memory ring no longer covers is served from the event
///   log (state-bearing kinds), then the ring, in byte-budget slices;
/// - live-only events that were lost (agent deltas, terminal output) are
///   reported per stream with `streamGap` frames instead of a global baseline;
/// - `replayComplete {throughSequence}` (= the welcome `currentSequence`)
///   ends the catch-up; everything after it is live. A `baselineRequired`
///   replaces it when the cursor cannot be served, and can still follow it
///   (live buffer overflow, outbound pressure) like on any socket;
/// - a cursor from the previous boot epoch is accepted after a clean,
///   flushed shutdown (the new boot's sequence continues above it).
/// `events.recent` takes `durable: true` for the same replay over HTTP.
public enum DurableReplayContract {
    public static let capability = "events.durable_replay_v1"
    static let header = "x-rc2-durable-replay"
    static let headerValue = "v1"
    /// Welcome key present only on durable-replay sockets.
    static let welcomeKey = "replayFromSequence"
    /// A replay that needs the event log and is estimated above this many
    /// wire bytes gets a baseline instead. The C8 receipts: a 1 h gap
    /// replayed 1800 events (819 KB, 290 ms) where the baseline snapshot of
    /// 180 threads was 129 KB in 88 ms; a 5 min gap replayed 150 events
    /// (69 KB, 23 ms). The live 177-thread snapshot is about 270 KB.
    public static let maximumReplayBytes = 256 * 1_024

    static func isRequested(header value: String?) -> Bool {
        guard let value else { return false }
        return value.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).lowercased() == headerValue
        }
    }

    /// Which cursor a durable-replay socket replays from. A same-boot (or
    /// legacy envelope-less) cursor works as before. A previous-boot cursor
    /// is kept only when that boot left a clean resume record and the cursor
    /// is not past what it published.
    ///
    /// `eventLog` is true only when the envelope proves which boot the cursor
    /// came from (this boot, or the clean previous one). An envelope-less
    /// cursor may come from a boot that crashed: its unpersisted events are
    /// holes in the log and its lost deltas are in no ledger, so it gets the
    /// ring or a baseline, as before C8.
    static func acceptedResume(
        requestedSinceSequence: Int64,
        requestedResumeHost: String?,
        requestedResumeBootEpoch: Int64?,
        serverId: String,
        bootEpoch: Int64,
        currentSequence: Int64,
        previousBoot: EventBus.PreviousBootReplay?
    ) -> (since: Int64, previousBoot: Bool, eventLog: Bool) {
        let sameBoot = DirectHTTPServer.acceptedResumeSequence(
            requestedSinceSequence: requestedSinceSequence,
            requestedResumeHost: requestedResumeHost,
            requestedResumeBootEpoch: requestedResumeBootEpoch,
            serverId: serverId,
            bootEpoch: bootEpoch,
            currentSequence: currentSequence
        )
        let hasEnvelope = requestedResumeHost != nil || requestedResumeBootEpoch != nil
        guard hasEnvelope else { return (sameBoot, false, false) }
        let matchesCurrentBoot = requestedResumeHost == serverId
            && requestedResumeBootEpoch == bootEpoch
        if matchesCurrentBoot { return (sameBoot, false, true) }
        guard let previousBoot,
              requestedResumeHost == serverId,
              let epoch = requestedResumeBootEpoch,
              epoch >= 0, UInt64(epoch) == previousBoot.bootEpoch,
              requestedSinceSequence > 0,
              requestedSinceSequence <= previousBoot.highWater else {
            return (0, false, false)
        }
        return (requestedSinceSequence, true, true)
    }
}

/// `streamGap`: replay-only events of one stream were lost after the
/// client's cursor. Exactly one of `threadId` (refetch the thread tail with
/// `agent.thread.read` v1) or `surfaceId` (refetch the terminal) is present.
struct ConnectionStreamGapFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    var threadId: String? = nil
    var surfaceId: String? = nil
    let sinceSequence: Int64
    let throughSequence: Int64
}

/// `replayComplete`: the durable backlog (events and stream gaps) through
/// `throughSequence` has been sent; later frames are live.
struct ConnectionReplayCompleteFrame: Codable, Equatable, Sendable {
    let protocolVersion: Int
    let type: String
    let connectionId: String
    let hostId: String
    let bootEpoch: UInt64
    let throughSequence: Int64
}

/// Live events for a durable-replay subscriber wait here until the backlog
/// has been streamed; `goLive` then delivers them in order and switches to
/// direct delivery. Bounded: past the budget the buffer is dropped and the
/// switch reports an overflow so the caller can fall back to a baseline.
public final class DurableReplaySubscription: @unchecked Sendable {
    public enum Item: Sendable {
        case event(EventBus.Event)
        case filtered(Int64)

        var sequence: Int64 {
            switch self {
            case .event(let event): return event.seq
            case .filtered(let seq): return seq
            }
        }
    }

    public enum GoLiveOutcome: Equatable, Sendable {
        case live
        /// The buffer overflowed; the live stream continues after this seq.
        case overflowed(lastSequence: Int64)
    }

    public let id: UUID
    public let plan: EventBus.DurableReplayPlan
    private weak var bus: EventBus?
    private let lock = NSLock()
    private var isLive = false
    private var buffered: [Item] = []
    private var bufferedBytes = 0
    private var overflowedThrough: Int64?
    private var deliver: ((Item) -> Void)?

    static let maximumBufferedItems = 16_384
    static let maximumBufferedBytes = 4 * 1_024 * 1_024

    init(id: UUID, plan: EventBus.DurableReplayPlan, bus: EventBus) {
        self.id = id
        self.plan = plan
        self.bus = bus
    }

    /// Called on the EventBus delivery queue.
    func receive(_ item: Item) {
        lock.lock()
        if isLive, let deliver {
            lock.unlock()
            deliver(item)
            return
        }
        if let through = overflowedThrough {
            overflowedThrough = max(through, item.sequence)
            lock.unlock()
            return
        }
        buffered.append(item)
        if case .event(let event) = item {
            bufferedBytes += EventBus.retainedJSONByteCount(event)
        }
        if buffered.count > Self.maximumBufferedItems || bufferedBytes > Self.maximumBufferedBytes {
            overflowedThrough = item.sequence
            buffered.removeAll()
            bufferedBytes = 0
        }
        lock.unlock()
    }

    /// Maps a replayed event through this subscriber's current filter.
    public func map(_ event: EventBus.Event) -> EventBus.Event? {
        // A nil from the subscriber's filter is a drop, not a missing bus:
        // `bus?.map(...) ?? full` would resend every event the filter dropped.
        guard let bus else { return EventStreamFilter.full.map(event) }
        return bus.mapForSubscriber(id, event)
    }

    /// True when this subscriber's current filter carries the stream's
    /// live-only events, so its gap means something to the client.
    public func admits(_ gap: EventBus.StreamGap) -> Bool {
        map(gap.representativeEvent) != nil
    }

    /// Delivers the buffered live events, then switches to direct delivery.
    /// On overflow, `onOverflow` runs before any later live event is
    /// delivered, with the newest dropped seq.
    ///
    /// No closure runs under `lock`: `receive` takes it on the EventBus
    /// delivery queue, and `onOverflow` / `deliver` can publish to the bus
    /// (pressure diagnostics), which waits on that queue.
    @discardableResult
    public func goLive(
        deliver: @escaping (Item) -> Void,
        onOverflow: (Int64) -> Void
    ) -> GoLiveOutcome {
        var overflowedAt: Int64?
        while true {
            lock.lock()
            if let through = overflowedThrough {
                // Events received from here on are all after `through`; they
                // buffer and drain below once the overflow is reported.
                overflowedThrough = nil
                lock.unlock()
                onOverflow(through)
                overflowedAt = through
                continue
            }
            if buffered.isEmpty {
                self.deliver = deliver
                isLive = true
                lock.unlock()
                return overflowedAt.map { .overflowed(lastSequence: $0) } ?? .live
            }
            let items = buffered
            buffered.removeAll()
            bufferedBytes = 0
            lock.unlock()
            for item in items { deliver(item) }
        }
    }

#if DEBUG
    var bufferedCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return buffered.count
    }
#endif
}

/// Streams a durable plan to one socket off the delivery queue: event-log
/// pages, then the ring backlog, then stream gaps, then live delivery. Each
/// slice waits until the outbound queue is back under `sliceBytes`, so a
/// long backlog never fills the queue or sheds frames. A socket that does
/// not drain a slice within `stallTimeout` gets a baseline instead.
struct DurableReplayDriver {
    enum Room: Equatable {
        case ready
        case closed
        case stalled
    }

    /// A slice the socket cannot drain in this long ends the replay.
    static let defaultStallTimeout: TimeInterval = 10

    var sliceBytes: Int
    /// First event-log page, read before the welcome (proves the log still
    /// reaches the cursor).
    var firstPage: EventBus.DurableReplayPage?
    var readPage: (_ after: Int64, _ through: Int64, _ maxBytes: Int) -> EventBus.DurableReplayPage?
    /// Delivers one mapped replay event like a live one.
    var deliverEvent: (EventBus.Event) -> Void
    /// Accounts for a seq the filter dropped or that the replay skips.
    var deliverFiltered: (Int64) -> Void
    /// Flushes coalesced frames and moves the gap watermark past `seq`.
    var advanceWatermark: (_ seq: Int64) -> Void
    var isOpen: () -> Bool
    /// Blocks until at most `limit` bytes are queued (signalled by the
    /// outbound queue, not polled), the socket closes, or `timeout` passes.
    var waitForRoom: (_ limit: Int, _ timeout: TimeInterval) -> Room
    var stallTimeout: TimeInterval = DurableReplayDriver.defaultStallTimeout
    /// Enqueues one stream gap; false when it could not be queued.
    var sendGap: (EventBus.StreamGap) -> Bool
    /// Falls back to a baseline from `head` (log pruned mid-replay, overflow).
    var requireBaseline: (_ head: Int64) -> Void

    enum Outcome: Equatable {
        case completed(eventsReplayed: Int, gapsSent: Int)
        case baselineRequired
        case closed
    }

    /// Runs the backlog. The caller then calls `goLive` on the subscription.
    func run(subscription: DurableReplaySubscription) -> Outcome {
        let plan = subscription.plan
        var expectedNext = plan.since + 1
        var replayed = 0
        var budgetUsed = 0

        func emit(_ event: EventBus.Event) -> Room {
            if event.seq <= expectedNext - 1 { return .ready }
            if event.seq > expectedNext {
                // Live-only seqs are not in the event log: skip over them.
                advanceWatermark(event.seq - 1)
            }
            if let mapped = subscription.map(event) {
                deliverEvent(mapped)
                budgetUsed += EventBus.retainedJSONByteCount(mapped)
            } else {
                deliverFiltered(event.seq)
            }
            expectedNext = event.seq + 1
            replayed += 1
            if budgetUsed >= sliceBytes {
                budgetUsed = 0
                return waitForRoom(sliceBytes, stallTimeout)
            }
            return isOpen() ? .ready : .closed
        }
        func stop(_ room: Room) -> Outcome {
            guard room == .stalled else { return .closed }
            requireBaseline(plan.head)
            return .baselineRequired
        }

        if plan.durableThrough > plan.since {
            var page = firstPage
            var after = plan.since
            while after < plan.durableThrough {
                guard let current = page ?? readPage(after, plan.durableThrough, sliceBytes) else {
                    guard isOpen() else { return .closed }
                    requireBaseline(plan.head)
                    return .baselineRequired
                }
                page = nil
                for event in current.events {
                    let room = emit(event)
                    guard room == .ready else { return stop(room) }
                }
                guard current.coveredThrough > after else {
                    requireBaseline(plan.head)
                    return .baselineRequired
                }
                after = current.coveredThrough
            }
        }
        for event in plan.ringBacklog {
            let room = emit(event)
            guard room == .ready else { return stop(room) }
        }
        // Trailing live-only seqs up to the head were lost or filtered.
        advanceWatermark(plan.head)
        var gaps = 0
        for gap in plan.streamGaps {
            guard isOpen() else { return .closed }
            // A stream this socket's filter never carries (a thread outside a
            // cellular interest set, a kind outside its prefixes) has nothing
            // for the client to refetch.
            guard subscription.admits(gap) else { continue }
            guard sendGap(gap) else {
                requireBaseline(plan.head)
                return .baselineRequired
            }
            gaps += 1
        }
        return .completed(eventsReplayed: replayed, gapsSent: gaps)
    }
}

extension DurableReplayContract {
    static func streamGapData(
        connectionId: String,
        hostId: String,
        bootEpoch: UInt64,
        gap: EventBus.StreamGap
    ) -> Data? {
        var frame = ConnectionStreamGapFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "streamGap",
            connectionId: connectionId,
            hostId: hostId,
            bootEpoch: bootEpoch,
            sinceSequence: gap.sinceSequence,
            throughSequence: gap.throughSequence
        )
        switch gap.stream {
        case .thread(let id): frame.threadId = id
        case .surface(let id): frame.surfaceId = id
        }
        return try? ConnectionTransportFrame.streamGap(frame).encoded()
    }

    static func replayCompleteData(
        connectionId: String,
        hostId: String,
        bootEpoch: UInt64,
        throughSequence: Int64
    ) -> Data? {
        try? ConnectionTransportFrame.replayComplete(ConnectionReplayCompleteFrame(
            protocolVersion: ConnectionTransportFrame.protocolVersion,
            type: "replayComplete",
            connectionId: connectionId,
            hostId: hostId,
            bootEpoch: bootEpoch,
            throughSequence: throughSequence
        )).encoded()
    }
}

/// Secret-free counters for `/v1/health` `durable_replay`.
public final class DurableReplayMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var served = 0
    private var baselines = 0
    private var closed = 0
    private var overflows = 0
    private var eventsReplayed = 0
    private var gapsSent = 0

    public init() {}

    func record(_ outcome: DurableReplayDriver.Outcome) {
        lock.lock(); defer { lock.unlock() }
        switch outcome {
        case .completed(let events, let gaps):
            served += 1
            eventsReplayed += events
            gapsSent += gaps
        case .baselineRequired:
            baselines += 1
        case .closed:
            closed += 1
        }
    }

    func recordOverflow() {
        lock.lock(); overflows += 1; lock.unlock()
    }

    public func healthJSON() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "served_total": served,
            "baseline_required_total": baselines,
            "closed_total": closed,
            "live_buffer_overflows_total": overflows,
            "events_replayed_total": eventsReplayed,
            "stream_gaps_sent_total": gapsSent,
        ]
    }
}
