import Foundation
import RemoteCodeTreaty

/// In-process event bus that the dispatcher writes to when mutations
/// succeed. Each subscriber gets a per-connection async stream so JSON-RPC
/// `events.subscribe` notifications can be pushed back over the same
/// socket as line-delimited frames.
public final class EventBus: @unchecked Sendable {
    public static let shared = EventBus()

    /// Posted on the main queue after a new live subscriber is installed so
    /// AppShell can re-emit sticky glanceable state (Token Saver digest) to
    /// late remote clients whose replay cursor missed the last publish.
    public static let subscriberAddedNotification = Notification.Name(
        "io.remotecode.eventbus.subscriberAdded"
    )

    public struct MutationEventIntent: Sendable, Equatable {
        public let kind: RemoteCodeEventKind
        public let payload: JSONValue
        public let createdAt: Date

        public init(kind: RemoteCodeEventKind, payload: JSONValue, createdAt: Date) {
            self.kind = kind
            self.payload = payload
            self.createdAt = createdAt
        }
    }

    public final class MutationEventSink: @unchecked Sendable {
        fileprivate enum AppendResult {
            case captured
            case suppressed
            case sealed
        }

        private let lock = NSLock()
        private var intents: [MutationEventIntent] = []
        private var sealed = false

        public init() {}

        fileprivate func append(
            _ intent: MutationEventIntent,
            captureEnabled: Bool
        ) -> AppendResult {
            lock.lock()
            defer { lock.unlock() }
            guard !sealed else { return .sealed }
            guard captureEnabled else { return .suppressed }
            intents.append(intent)
            return .captured
        }

        public func seal() throws -> [MutationEventIntent] {
            lock.lock()
            defer { lock.unlock() }
            sealed = true
            return intents
        }
    }

    @TaskLocal public static var activeMutationEventSink: MutationEventSink?
    @TaskLocal public static var suppressMutationEventCapture = false

    /// Starts work whose events belong to the runtime lifecycle after the
    /// admitting mutation, not to that mutation's durable receipt range.
    /// Unstructured Tasks inherit TaskLocal values at creation, so callers
    /// must cross this boundary before creating work that can outlive a reply.
    public static func outsideMutationCapture<Value>(
        _ operation: () throws -> Value
    ) rethrows -> Value {
        try $activeMutationEventSink.withValue(nil) {
            try $suppressMutationEventCapture.withValue(false) {
                try operation()
            }
        }
    }

    public struct Event: Codable, Sendable {
        public let seq: Int64
        public let kind: String
        public let payload: JSONValue
        public let ts: Double

        public var knownKind: RemoteCodeEventKind? {
            RemoteCodeEventKind(rawValue: kind)
        }

        public var knownEvent: KnownEvent? {
            guard let kind = knownKind,
                  case .object(let payload) = payload else { return nil }
            return KnownEvent(seq: seq, kind: kind, payload: payload, ts: ts)
        }

        public init(seq: Int64, kind: String, payload: JSONValue, ts: Double) {
            self.seq = seq; self.kind = kind; self.payload = payload; self.ts = ts
        }
    }

    /// Compile-time object-payload carrier for every productive event after the
    /// EventBus publication boundary. Persisted future events remain `Event`
    /// because their kind and payload shape are intentionally forward-raw.
    public struct KnownEvent: Equatable, Sendable {
        public let seq: Int64
        public let kind: RemoteCodeEventKind
        public let payload: [String: JSONValue]
        public let ts: Double

        public init(
            seq: Int64,
            kind: RemoteCodeEventKind,
            payload: [String: JSONValue],
            ts: Double
        ) {
            self.seq = seq
            self.kind = kind
            self.payload = payload
            self.ts = ts
        }

        public var rawEvent: Event {
            Event(seq: seq, kind: kind.rawValue, payload: .object(payload), ts: ts)
        }
    }

    private let lock = NSLock()
    private let snapshotBarrierLock = NSLock()
    private let deliveryQueue = DispatchQueue(label: "com.remotecode.eventbus.delivery")
    private let deliveryQueueKey = DispatchSpecificKey<UInt8>()
    private var lastSeq: Int64 = 0
    private var domainRevisions = ConnectionDomainRevisions(
        shell: 0, surfaces: 0, agentThreads: 0, browser: 0, files: 0
    )
    private struct Subscriber {
        var filter: EventStreamFilter
        /// Called with the seq of an event this subscriber's filter dropped,
        /// so per-connection gap detection can account for the hole.
        let onFilteredEvent: (Int64) -> Void
        let handler: (Event) -> Void
    }

    private var subscribers: [UUID: Subscriber] = [:]
    /// Cached flat array rebuilt only when subscribers are added or removed.
    /// publish() reads this instead of copying subscribers.values every call.
    private var subscribersSnapshot: [Subscriber] = []
    private var recent: [Event] = []
    private var recentBytes: Int = 0
    private let recentLimit: Int
    private let recentByteLimit: Int
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    /// Lazy encode cache for `encodedData(for:)`. Publish no longer fills this —
    /// ring accounting uses `retainedJSONByteCount` so token-rate deltas do not
    /// allocate `JSONEncoder` `Data` under `lock`.
    private var encodedCache: [Int64: Data] = [:]
    /// Byte-cost cache keyed by seq. Evicted with the recent ring.
    private var encodedSizeCache: [Int64: Int] = [:]
#if DEBUG
    /// Test seam: increments only when `encodedData(for:)` actually encodes.
    private(set) var encodeCountForTesting = 0
#endif

    // QA-002: injectable clock so event timestamps (ts field) are deterministic
    // in tests. Default is real wall time. Protected by `lock` so the closure
    // swap in setClockForTests is visible to concurrent publish() calls.
    // publish() reads clock directly while holding lock (no re-entry issue).
    private var clock: @Sendable () -> Date

    public var persister: ((Event) -> Void)?
    /// Optional durability fence for persisters that submit work asynchronously.
    /// `commitPersistedEvents` invokes it from the serialized delivery lane so a
    /// receipt cannot physically overtake an earlier normal event.
    public var persistenceCommitFence: (() -> Void)?
    public var shouldRetainRecentEvent: ((Event) -> Bool)?

    // PERF: EventLog persisters encode payload on every retained publish.
    // Share one encoder under a short lock (JSONEncoder is not thread-safe)
    // and a static `null` Data for encode failures.
    private static let persistencePayloadEncodeLock = NSLock()
    private static let persistencePayloadEncoder = JSONEncoder()
    private static let nullJSONData = Data([0x6e, 0x75, 0x6c, 0x6c]) // "null"

    /// Encode an event payload for EventLog storage. Used by AppDelegate /
    /// AppContext persisters so each publish does not allocate a JSONEncoder.
    public static func encodePayloadForPersistence(_ payload: JSONValue) -> String {
        persistencePayloadEncodeLock.lock()
        let data = (try? persistencePayloadEncoder.encode(payload)) ?? nullJSONData
        persistencePayloadEncodeLock.unlock()
        return String(data: data, encoding: .utf8) ?? "null"
    }

    public struct RecentEventsResult: Sendable {
        public let lastSeq: Int64
        public let events: [Event]
        public let truncated: Bool
        public let requiresBaseline: Bool
    }

    public struct SnapshotMetadata: Sendable, Equatable {
        public let sequence: Int64
        public let oldestReplaySequence: Int64
        public let domainRevisions: ConnectionDomainRevisions
    }

    public struct SnapshotBarrierResult<Value> {
        public let state: Value
        public let metadata: SnapshotMetadata
    }

    /// Peak events retained in the in-process recent ring (and encode cache).
    /// Bounds reconnect catch-up / agent host-state flood memory. 128 matches
    /// other agent surface caps — was 512, then 256.
    public static let defaultRecentLimit = 128
    /// Peak payload bytes retained alongside `defaultRecentLimit`.
    /// Must cover several client replay pages: a DERP/cellular round trip can
    /// otherwise evict the required prefix between baselineRequired and
    /// events.recent, forcing an endless full-snapshot loop under host churn.
    public static let defaultRecentByteLimit = 2 * 1_024 * 1_024

    public init(
        recentLimit: Int = EventBus.defaultRecentLimit,
        recentByteLimit: Int = EventBus.defaultRecentByteLimit,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recentLimit = max(0, recentLimit)
        self.recentByteLimit = max(0, recentByteLimit)
        self.clock = clock
        deliveryQueue.setSpecific(key: deliveryQueueKey, value: 1)
    }

    /// QA-002: inject a fixed or advancing clock so event timestamps are
    /// deterministic. Must not be called in production code.
    public func setClockForTests(_ clock: @escaping @Sendable () -> Date) {
        lock.lock(); defer { lock.unlock() }
        self.clock = clock
    }

    /// The highest seq published so far. A reconnecting client (or a test) can
    /// subscribe with `since: currentSeq` / the `x-rc2-since-seq` header to receive
    /// only future events, skipping the retained backlog deterministically.
    public var currentSeq: Int64 {
        lock.lock(); defer { lock.unlock() }
        return lastSeq
    }

    public func publish(kind: RemoteCodeEventKind, payload: JSONValue) {
        // Every catalogued event payload is an object. Keep the legacy call
        // spelling for the existing producers, but make the productive carrier
        // object-typed immediately at the narrow publication boundary.
        guard case .object(let objectPayload) = payload else {
#if DEBUG
            // Legacy tests that intentionally exercise raw ring accounting use
            // this debug-only adapter. Productive release builds fail closed.
            if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
                deliveryQueue.async { [self] in
                    publishRawSerialized(kind: kind.rawValue, payload: payload)
                }
            } else {
                deliveryQueue.sync {
                    publishRawSerialized(kind: kind.rawValue, payload: payload)
                }
            }
            return
#else
            preconditionFailure("Known event payload must be a JSON object: \(kind.rawValue)")
#endif
        }
        if let sink = Self.activeMutationEventSink {
            lock.lock()
            let createdAt = clock()
            lock.unlock()
            switch sink.append(
                MutationEventIntent(kind: kind, payload: .object(objectPayload), createdAt: createdAt),
                captureEnabled: !Self.suppressMutationEventCapture
            ) {
            case .captured, .suppressed:
                return
            case .sealed:
                NSLog(
                    "[RC2.EventBus] late mutation event escaped sealed receipt sink: %@",
                    kind.rawValue
                )
            }
        }
        if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
            deliveryQueue.async { [self] in
                publishSerialized(kind: kind, payload: objectPayload)
            }
        } else {
            deliveryQueue.sync { publishSerialized(kind: kind, payload: objectPayload) }
        }
    }

#if DEBUG
    /// Test-only escape hatch for forward-unknown and synthetic replay cases.
    /// Productive callers must use `publish(kind: RemoteCodeEventKind, ...)`.
    public func publishRawForTesting(kind: String, payload: JSONValue) {
        if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
            deliveryQueue.async { [self] in publishRawSerialized(kind: kind, payload: payload) }
        } else {
            deliveryQueue.sync { publishRawSerialized(kind: kind, payload: payload) }
        }
    }
#endif

    /// Wait until every publish accepted before this call has submitted its
    /// persistence work. Lifecycle code follows this barrier by draining the
    /// persistence queue, so a concurrent publisher cannot be stranded between
    /// the EventBus delivery queue and durable storage during a graceful exit.
    public func flushPersistenceSubmissions() {
        precondition(DispatchQueue.getSpecific(key: deliveryQueueKey) == nil)
        deliveryQueue.sync {}
    }

    /// Serializes durable sequence allocation against every normal publisher.
    /// The closure commits receipt/outcome/events while the EventBus sequence is
    /// reserved; fanout and replay retention happen only after it returns.
    public func commitPersistedEvents(
        _ commit: (Int64) throws -> [Event]
    ) throws -> [Event] {
        precondition(DispatchQueue.getSpecific(key: deliveryQueueKey) == nil)
        return try deliveryQueue.sync {
            let fence: (() -> Void)?
            lock.lock()
            fence = persistenceCommitFence
            lock.unlock()
            fence?()
            snapshotBarrierLock.lock()
            let floor: Int64
            lock.lock()
            floor = lastSeq
            lock.unlock()
            do {
                let events = try commit(floor)
                var deliveries: [(Event, [Subscriber])] = []
                lock.lock()
                for event in events {
                    precondition(event.seq > lastSeq)
                    lastSeq = event.seq
                    domainRevisions = Self.revisions(after: event, current: domainRevisions)
                    if shouldRetainRecentEvent?(event) ?? true {
                        retainRecent(event)
                    }
                    deliveries.append((event, subscribersSnapshot))
                }
                lock.unlock()
                snapshotBarrierLock.unlock()
                for (event, subscribers) in deliveries {
                    for subscriber in subscribers {
                        guard let mapped = subscriber.filter.map(event) else {
                            subscriber.onFilteredEvent(event.seq)
                            continue
                        }
                        subscriber.handler(mapped)
                    }
                }
                return events
            } catch {
                snapshotBarrierLock.unlock()
                throw error
            }
        }
    }

    private func publishSerialized(
        kind: RemoteCodeEventKind,
        payload: [String: JSONValue]
    ) {
        publishRawSerialized(kind: kind.rawValue, payload: .object(payload))
    }

    private func publishRawSerialized(kind: String, payload: JSONValue) {
        snapshotBarrierLock.lock()
        lock.lock()
        lastSeq += 1
        let ev = Event(seq: lastSeq, kind: kind, payload: payload, ts: clock().timeIntervalSince1970)
        domainRevisions = Self.revisions(after: ev, current: domainRevisions)
        if shouldRetainRecentEvent?(ev) ?? true {
            retainRecent(ev)
        }
        let subs = subscribersSnapshot
        let p = persister
        lock.unlock()
        snapshotBarrierLock.unlock()
        for s in subs {
            guard let mapped = s.filter.map(ev) else {
                s.onFilteredEvent(ev.seq)
                continue
            }
            s.handler(mapped)
        }
        p?(ev)
    }

    public func reloadFromPersistence(lastSeq: Int64, recent: [Event]) {
        // --- snapshot under lock (cheap: set + closure capture) ---
        lock.lock()
        let knownSeqs = Set(self.recent.map(\.seq))
        let retain = shouldRetainRecentEvent  // capture while holding lock, same as publish()
        lock.unlock()

        // --- precompute off the lock (filter + byte-cost walk, no JSONEncoder) ---
        // `recent` is the caller-provided immutable parameter (no lock needed).
        // `knownSeqs` and `retain` are immutable snapshots captured under the lock above.
        // Events that arrive via publish() between the two lock regions are not in
        // `recent` at all and are handled correctly by the per-event path in publish().
        var newSizes: [Int64: Int] = [:]
        let candidates = recent.filter { ev in
            guard !knownSeqs.contains(ev.seq) else { return false }
            guard retain?(ev) ?? true else { return false }
            newSizes[ev.seq] = Self.retainedJSONByteCount(ev)
            return true
        }

        // --- assign under lock (cheap: dedup check, append, sort, byte-count, trim) ---
        // Re-check against the live self.recent to handle events that publish() may have
        // added between the two lock regions; sizes are already walked via newSizes.
        lock.lock()
        self.lastSeq = max(self.lastSeq, lastSeq)
        let liveKnown = Set(self.recent.map(\.seq))
        for ev in candidates where !liveKnown.contains(ev.seq) {
            let bytes = newSizes[ev.seq] ?? 0
            guard recentLimit > 0, recentByteLimit > 0, bytes <= recentByteLimit else { continue }
            encodedSizeCache[ev.seq] = bytes
            self.recent.append(ev)
            self.recentBytes += bytes
        }
        self.recent.sort { $0.seq < $1.seq }
        for event in self.recent {
            domainRevisions = Self.revisions(after: event, current: domainRevisions)
        }
        trimRecent()
        lock.unlock()
    }

    @discardableResult
    public func subscribe(since: Int64?, filter: EventStreamFilter = .full, _ handler: @escaping (Event) -> Void) -> UUID {
        if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
            return subscribeSerialized(since: since, filter: filter, handler)
        }
        return deliveryQueue.sync {
            subscribeSerialized(since: since, filter: filter, handler)
        }
    }

    /// Installs a subscriber and reports an expired replay cursor before any
    /// future event can be delivered. The callback runs on the delivery queue,
    /// so callers can enqueue baselineRequired ahead of the live stream.
    @discardableResult
    public func subscribeDetectingReplayExpiry(
        since: Int64,
        filter: EventStreamFilter = .full,
        onReplayExpired: @escaping (SnapshotMetadata) -> Void,
        onFilteredEvent: @escaping (Int64) -> Void = { _ in },
        _ handler: @escaping (Event) -> Void
    ) -> UUID {
        let register = { [self] in
            lock.lock()
            let metadata = snapshotMetadataLocked()
            let replayFloor = replayFloorLocked()
            let replayExpired = since < replayFloor
            let subscriptionCursor = replayExpired ? lastSeq : since
            let id = UUID()
            subscribers[id] = Subscriber(
                filter: filter, onFilteredEvent: onFilteredEvent, handler: handler
            )
            subscribersSnapshot = Array(subscribers.values)
            let backlog = recent.filter { $0.seq > subscriptionCursor }
            lock.unlock()
            if replayExpired { onReplayExpired(metadata) }
            for event in backlog {
                guard let mapped = filter.map(event) else {
                    onFilteredEvent(event.seq)
                    continue
                }
                handler(mapped)
            }
            Self.notifySubscriberAdded()
            return id
        }
        if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
            return register()
        }
        return deliveryQueue.sync(execute: register)
    }

    /// Atomically captures the current sequence and installs a live subscriber.
    /// Callers that must recover durable state through the captured cursor can do
    /// that work after registration without relying on the bounded recent ring to
    /// bridge a cursor-to-subscribe race.
    public func subscribeFromCurrent(
        filter: EventStreamFilter = .full,
        _ handler: @escaping (Event) -> Void
    ) -> (id: UUID, cursor: Int64) {
        let register = { [self] in
            let cursor = currentSeq
            let id = subscribeSerialized(since: cursor, filter: filter, handler)
            return (id: id, cursor: cursor)
        }
        if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
            return register()
        }
        return deliveryQueue.sync(execute: register)
    }

    private func subscribeSerialized(
        since: Int64?,
        filter: EventStreamFilter,
        _ handler: @escaping (Event) -> Void
    ) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = Subscriber(
            filter: filter, onFilteredEvent: { _ in }, handler: handler
        )
        subscribersSnapshot = Array(subscribers.values)
        let backlog = recent.compactMap { event -> Event? in
            guard event.seq > (since ?? 0) else { return nil }
            return filter.map(event)
        }
        lock.unlock()
        for ev in backlog { handler(ev) }
        Self.notifySubscriberAdded()
        return id
    }

    private static func notifySubscriberAdded() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: subscriberAddedNotification, object: nil)
        }
    }

    public func unsubscribe(_ id: UUID) {
        if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
            unsubscribeSerialized(id)
        } else {
            deliveryQueue.sync { unsubscribeSerialized(id) }
        }
    }

    /// Mid-session interest update: replace the subscriber filter without
    /// reconnecting. No-op when the id is unknown (fail open).
    public func updateSubscriberFilter(_ id: UUID, filter: EventStreamFilter) {
        if DispatchQueue.getSpecific(key: deliveryQueueKey) != nil {
            updateSubscriberFilterSerialized(id, filter: filter)
        } else {
            deliveryQueue.sync { updateSubscriberFilterSerialized(id, filter: filter) }
        }
    }

    private func updateSubscriberFilterSerialized(_ id: UUID, filter: EventStreamFilter) {
        lock.lock()
        guard var sub = subscribers[id] else {
            lock.unlock()
            return
        }
        sub.filter = filter
        subscribers[id] = sub
        subscribersSnapshot = Array(subscribers.values)
        lock.unlock()
    }

    private func unsubscribeSerialized(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        subscribersSnapshot = Array(subscribers.values)
        lock.unlock()
    }

    public func snapshot() -> (lastSeq: Int64, recent: [Event]) {
        lock.lock(); defer { lock.unlock() }
        return (lastSeq, recent)
    }

    /// Cheap counters for `/v1/health` and readiness probes.
    ///
    /// Avoids re-encoding every retained event on the health path (which used
    /// to allocate under concurrent HTTP load). Uses the same `recentBytes`
    /// ring accounting publish already maintains.
    public func healthCounters() -> (
        lastSeq: Int64,
        retainedCount: Int,
        retainedBytes: Int,
        oldestRetainedSeq: Int64
    ) {
        lock.lock(); defer { lock.unlock() }
        return (
            lastSeq,
            recent.count,
            recentBytes,
            recent.first?.seq ?? 0
        )
    }

    public func snapshotMetadata() -> SnapshotMetadata {
        lock.lock(); defer { lock.unlock() }
        return snapshotMetadataLocked()
    }

    public func withSnapshotBarrier<Value>(
        _ readState: () throws -> Value
    ) rethrows -> SnapshotBarrierResult<Value> {
        snapshotBarrierLock.lock()
        defer { snapshotBarrierLock.unlock() }
        let state = try readState()
        lock.lock()
        let metadata = snapshotMetadataLocked()
        lock.unlock()
        return SnapshotBarrierResult(state: state, metadata: metadata)
    }

    public func recentEvents(since: Int64, maxBytes: Int?) -> RecentEventsResult {
        lock.lock()
        let currentLastSeq = lastSeq
        let candidates = recent.filter { $0.seq > since }
        let replayFloor = replayFloorLocked()
        let replayExpired = since < replayFloor
        lock.unlock()

        guard let maxBytes, maxBytes > 0 else {
            return RecentEventsResult(lastSeq: currentLastSeq,
                                      events: candidates,
                                      truncated: replayExpired,
                                      requiresBaseline: replayExpired)
        }

        var selected: [Event] = []
        var used = 0
        var truncated = replayExpired
        for event in candidates {
            let size = encodedSize(event)
            if used + size > maxBytes {
                truncated = true
                break
            }
            selected.append(event)
            used += size
        }
        return RecentEventsResult(lastSeq: currentLastSeq,
                                  events: selected,
                                  truncated: truncated,
                                  requiresBaseline: truncated)
    }

    private func snapshotMetadataLocked() -> SnapshotMetadata {
        let replayFloor = replayFloorLocked()
        return SnapshotMetadata(
            sequence: lastSeq,
            oldestReplaySequence: replayFloor < lastSeq ? replayFloor + 1 : lastSeq,
            domainRevisions: domainRevisions
        )
    }

    /// Returns the oldest cursor that can reach `lastSeq` using only a
    /// contiguous suffix of retained events. A filtered or missing tail leaves
    /// only `lastSeq` itself replayable.
    private func replayFloorLocked() -> Int64 {
        var floor = lastSeq
        for event in recent.reversed() {
            if event.seq > floor { continue }
            guard event.seq == floor else { break }
            guard floor > 0 else { break }
            floor -= 1
        }
        return floor
    }

    private static func revisions(
        after event: Event,
        current: ConnectionDomainRevisions
    ) -> ConnectionDomainRevisions {
        let kind = event.kind
        let shell = kind.hasPrefix("workspace.")
            || kind.hasPrefix("window.")
            || kind.hasPrefix("pane.")
            || kind == "settings.updated"
        let surfaces = kind.hasPrefix("surface.") || kind.hasPrefix("pane.")
        let agentThreads = kind.hasPrefix("agent.")
        let browser = kind.hasPrefix("browser.") || kind == "surface.browser"
        let files = kind.hasPrefix("files.") || kind.hasPrefix("fs.")
        return ConnectionDomainRevisions(
            shell: shell ? max(current.shell, event.seq) : current.shell,
            surfaces: surfaces ? max(current.surfaces, event.seq) : current.surfaces,
            agentThreads: agentThreads ? max(current.agentThreads, event.seq) : current.agentThreads,
            browser: browser ? max(current.browser, event.seq) : current.browser,
            files: files ? max(current.files, event.seq) : current.files
        )
    }

    private func retainRecent(_ ev: Event) {
        let bytes = encodedSize(ev)
        guard recentLimit > 0, recentByteLimit > 0 else { return }
        // Single frame larger than the whole recent window: reclaim everything
        // older and still admit the newest event so replay keeps progressing.
        if bytes > recentByteLimit {
            recent.removeAll(keepingCapacity: true)
            recentBytes = 0
            encodedCache.removeAll(keepingCapacity: true)
            encodedSizeCache.removeAll(keepingCapacity: true)
            recent.append(ev)
            recentBytes = bytes
            return
        }
        recent.append(ev)
        recentBytes += bytes
        trimRecent()
    }

    private func trimRecent() {
        while recent.count > recentLimit || recentBytes > recentByteLimit {
            guard !recent.isEmpty else {
                recentBytes = 0
                return
            }
            let removed = recent.removeFirst()
            recentBytes = max(0, recentBytes - encodedSize(removed))
            encodedCache.removeValue(forKey: removed.seq)
            encodedSizeCache.removeValue(forKey: removed.seq)
        }
    }

    // MARK: - Test-visible accessors (read-only; no production callers)

    /// WHY: flood stress tests must assert that recent buffer count stays <= recentLimit
    /// without accessing private state. Read-only; zero production impact.
    public var subscriberCountForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }

    /// WHY: flood stress tests must assert that recent buffer count stays <= recentLimit.
    /// Read-only; zero production impact.
    public var recentCountForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return recent.count
    }

    /// WHY: flood stress tests must assert that accumulated bytes stay <= recentByteLimit.
    /// Read-only; zero production impact.
    public var recentBytesForTests: Int {
        lock.lock(); defer { lock.unlock() }
        return recentBytes
    }

    /// Returns the JSON-encoded bytes for `ev`, encoding at most once per event.
    /// Callers inside the lock may call this freely; the cache is also lock-protected.
    /// Production publish/retain uses `retainedJSONByteCount` instead so the
    /// token-rate path does not allocate encoder `Data`.
    func encodedData(for ev: Event) -> Data {
        if let cached = encodedCache[ev.seq] { return cached }
#if DEBUG
        encodeCountForTesting += 1
#endif
        let data = (try? encoder.encode(ev)) ?? Data()
        encodedCache[ev.seq] = data
        return data
    }

    private func encodedSize(_ ev: Event) -> Int {
        if let cached = encodedSizeCache[ev.seq] { return cached }
        let size = Self.retainedJSONByteCount(ev)
        encodedSizeCache[ev.seq] = size
        return size
    }

    /// Byte cost of `JSONEncoder` + `.sortedKeys` for a retained event, without
    /// allocating `Data`. Must stay equal to `encoder.encode(ev).count` so ring
    /// eviction and `recentEvents` truncation match the previous encode path.
    nonisolated static func retainedJSONByteCount(_ ev: Event) -> Int {
        // Auto-synthesized Codable keys, sorted: kind, payload, seq, ts.
        var count = 2 // {}
        count += 7 // "kind":
        count += jsonStringByteCount(ev.kind)
        count += 1 // ,
        count += 10 // "payload":
        count += jsonValueByteCount(ev.payload)
        count += 1 // ,
        count += 6 // "seq":
        count += jsonInt64ByteCount(ev.seq)
        count += 1 // ,
        count += 5 // "ts":
        count += jsonNumberByteCount(ev.ts)
        return count
    }

    /// Byte cost of a success `JSONRPCResponse` (jsonrpc + optional id + result)
    /// without allocating encoder `Data`. Length-equal to default `JSONEncoder`
    /// (key order does not change size). Used by agent.message list/get fit.
    nonisolated static func jsonRPCResponseByteCount(id: JSONRPCID?, result: JSONValue) -> Int {
        var count = 2 // {}
        count += 10 // "jsonrpc":
        count += 5 // "2.0"
        if let id {
            count += 1 // ,
            count += 5 // "id":
            count += jsonRPCIDByteCount(id)
        }
        count += 1 // ,
        count += 9 // "result":
        count += jsonValueByteCount(result)
        return count
    }

    nonisolated static func jsonRPCIDByteCount(_ id: JSONRPCID) -> Int {
        switch id {
        case .string(let string):
            return jsonStringByteCount(string)
        case .number(let number):
            return jsonInt64ByteCount(Int64(number))
        }
    }

    nonisolated static func jsonValueByteCount(_ value: JSONValue) -> Int {
        switch value {
        case .null:
            return 4
        case .bool(true):
            return 4
        case .bool(false):
            return 5
        case .number(let number):
            return jsonNumberByteCount(number)
        case .string(let string):
            return jsonStringByteCount(string)
        case .array(let items):
            var count = 2
            if !items.isEmpty {
                count += items.count - 1
                for item in items { count += jsonValueByteCount(item) }
            }
            return count
        case .object(let object):
            // Key order does not change JSON length (`"a":1,"b":2` ==
            // `"b":2,"a":1`). Skip `keys.sorted()` so token-rate retain
            // does not allocate an Array under the EventBus lock.
            var count = 2
            if !object.isEmpty {
                count += object.count - 1
                for (key, value) in object {
                    count += jsonStringByteCount(key) + 1
                    count += jsonValueByteCount(value)
                }
            }
            return count
        }
    }

    nonisolated static func jsonStringByteCount(_ string: String) -> Int {
        var count = 2
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x08, 0x09, 0x0A, 0x0C, 0x0D, 0x22, 0x2F, 0x5C:
                count += 2
            case 0x00...0x1F:
                count += 6
            case 0x20..<0x80:
                count += 1
            case 0x80..<0x800:
                count += 2
            case 0x800..<0x10000:
                count += 3
            default:
                count += 4
            }
        }
        return count
    }

    nonisolated static func jsonInt64ByteCount(_ value: Int64) -> Int {
        if value == 0 { return 1 }
        if value == Int64.min { return 20 } // -9223372036854775808
        var n = value
        var count = 0
        if n < 0 {
            count += 1
            n = -n
        }
        while n > 0 {
            count += 1
            n /= 10
        }
        return count
    }

    /// Match `JSONEncoder` + `.sortedKeys` number fragments for `ts` and
    /// `JSONValue.number`. Exact integers stay digit-count only. Fractional
    /// values use Swift's `Double` description, which matches the encoder
    /// (unlike `JSONSerialization` of `NSNumber`, which lengthens π / 1/3).
    /// Publish `ts` is `Date().timeIntervalSince1970` — almost never an
    /// integer — so the previous `JSONSerialization.data` allocated on every
    /// token-rate retain under `lock`.
    nonisolated static func jsonNumberByteCount(_ value: Double) -> Int {
        if value == 0 {
            // `Int64(exactly: -0.0)` is 0, but JSONEncoder emits `-0`.
            return value.sign == .minus ? 2 : 1
        }
        if value.isFinite, value.rounded(.towardZero) == value,
           let exact = Int64(exactly: value) {
            return jsonInt64ByteCount(exact)
        }
        guard value.isFinite else { return 24 }
        return String(value).utf8.count
    }
}

enum AgentItemDeltaCoalescingIdentity {
    static func key(threadID: String, itemID: String, turnID: String?) -> String? {
        // Ordinary AppContext deltas do not carry a turn id. They must remain
        // in arrival-order buffering so an item-start boundary fences providers
        // that reuse the same item id in a later turn.
        guard let turnID, !turnID.isEmpty else { return nil }
        let base = "agent.item.delta:\(threadID.utf8.count):\(threadID):\(itemID.utf8.count):\(itemID)"
        return base + ":turn:\(turnID.utf8.count):\(turnID)"
    }
}

public enum EventStreamFilter: Sendable, Equatable {
    case full
    /// Cellular volume filter. Optional interest thread ids drop high-volume
    /// agent deltas for other threads (fail open when interest is empty).
    case cellularSafe(interestThreadIds: Set<String> = [])
    /// Local in-process subscribers that only care about specific kind prefixes
    /// (e.g. Agent App surfaces: `agent.thread.` / `agent.message.queue`).
    case kindPrefixes([String])

    /// True for any cellular-safe filter regardless of interest set.
    /// Prefer this over `== .cellularSafe` (associated value breaks equality).
    public var isCellularSafe: Bool {
        if case .cellularSafe = self { return true }
        return false
    }

    /// Agent App surface subscription: thread lifecycle + queue only.
    public static let agentThreadAndQueue = EventStreamFilter.kindPrefixes([
        "agent.thread.",
        "agent.message.queue",
        "agent.message.queued"
    ])

    /// Files tab subscription: state + edit lifecycle only.
    /// Stream kinds (`agent.item.delta` / `surface.output`) must not hop
    /// each open Files surface to the main queue.
    public static let filesSurface = EventStreamFilter.kindPrefixes([
        "files.state.",
        "files.edit."
    ])

    public static func parse(_ raw: String?) -> EventStreamFilter {
        parse(filterHeader: raw, interestThreadHeader: nil)
    }

    /// Parse filter + optional interest header (`thread-a,thread-b`).
    public static func parse(
        filterHeader: String?,
        interestThreadHeader: String?
    ) -> EventStreamFilter {
        guard filterHeader?.lowercased().contains("cellular-safe") == true else {
            return .full
        }
        let ids = Set(
            (interestThreadHeader ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        return .cellularSafe(interestThreadIds: ids)
    }

    /// Mid-session interest control wire type (client → host over live WS).
    public static let interestControlType = "rc2.interest"

    /// Parse `{"type":"rc2.interest","thread_ids":[…]}`. Returns nil when the
    /// payload is not this control (caller must not treat as protocol error).
    public static func parseInterestControl(_ data: Data) -> Set<String>? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String,
              type == interestControlType else {
            return nil
        }
        guard let raw = root["thread_ids"] as? [Any] else {
            return []
        }
        let ids = raw.compactMap { value -> String? in
            guard let s = value as? String else { return nil }
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return Set(ids)
    }

    /// Apply mid-session interest onto an existing filter. Full filters stay
    /// full (fail open — interest only gates cellular-safe admissions).
    public func applyingInterestThreadIds(_ ids: Set<String>) -> EventStreamFilter {
        switch self {
        case .full:
            return .full
        case .cellularSafe:
            return .cellularSafe(interestThreadIds: ids)
        case .kindPrefixes(let prefixes):
            return .kindPrefixes(prefixes)
        }
    }

    public func allows(_ event: EventBus.Event) -> Bool {
        map(event) != nil
    }

    public func coalescingKey(for event: EventBus.Event) -> String? {
        guard let known = event.knownEvent else { return nil }
        return coalescingKey(for: known)
    }

    public func coalescingKey(for event: EventBus.KnownEvent) -> String? {
        guard case .cellularSafe = self else { return nil }
        let payload = event.payload
        // C-14: last-write-wins for terminal summaries (seq + byte counts only).
        if event.kind == .surfaceOutputSummary,
           let surfaceID = payload["surface_id"]?.stringValue {
            return "\(event.kind.rawValue):\(surfaceID)"
        }
        // C-16: same thread_id + item_id merges by *concat* of append fields
        // (not LWW) so agent text stays byte-identical without crossing threads.
        if event.kind == .agentItemDelta,
           let threadID = payload["thread_id"]?.stringValue,
           let itemID = payload["item_id"]?.stringValue {
            return AgentItemDeltaCoalescingIdentity.key(
                threadID: threadID,
                itemID: itemID,
                turnID: payload["turn_id"]?.stringValue
            )
        }
        return nil
    }

    /// Whether a coalescing key uses concatenate-merge (C-16) instead of LWW.
    public func coalescingMergesByConcatenation(for event: EventBus.Event) -> Bool {
        event.knownKind == .agentItemDelta
    }

    public func coalescingMergesByConcatenation(for event: EventBus.KnownEvent) -> Bool {
        event.kind == .agentItemDelta
    }

    public func map(_ event: EventBus.Event) -> EventBus.Event? {
        guard let known = event.knownEvent else {
            switch self {
            case .full:
                return event
            case .kindPrefixes(let prefixes):
                return prefixes.contains { event.kind == $0 || event.kind.hasPrefix($0) }
                    ? event
                    : nil
            case .cellularSafe:
                // Future unknown events are sequence-bearing but do not alter a
                // known projection. Preserve them for forward-compatible clients.
                return event
            }
        }
        return map(known)?.rawEvent
    }

    public func map(_ event: EventBus.KnownEvent) -> EventBus.KnownEvent? {
        switch self {
        case .full:
            return event
        case .kindPrefixes(let prefixes):
            for prefix in prefixes {
                if event.kind.rawValue == prefix || event.kind.rawValue.hasPrefix(prefix) {
                    return event
                }
            }
            return nil
        case .cellularSafe(let interestThreadIds):
            // `reducerRequired` means the *content* is required on the client,
            // not that every micro-token must be its own WS frame (C-16).
            let classification = EventStreamClassification.classify(event: event)
            if event.kind == .surfaceOutput {
                if Self.isGeometryOnlyTerminalOutput(event) {
                    return event
                }
                return Self.terminalOutputSummary(from: event)
            }
            // On-screen interest: drop high-volume agent deltas for other threads.
            // Fail open when interest set is empty.
            let payload = event.payload
            if !interestThreadIds.isEmpty,
               (event.kind == .agentItemDelta || event.kind == .agentItemProgress),
               let threadId = payload["thread_id"]?.stringValue ?? payload["threadId"]?.stringValue,
               !interestThreadIds.contains(threadId) {
                return nil
            }
            guard classification.reducerRequired || classification.priority == .critical else { return nil }
            return event
        }
    }

    private static func isGeometryOnlyTerminalOutput(_ event: EventBus.KnownEvent) -> Bool {
        let payload = event.payload
        return payload["base64"] == nil && payload["rows"] != nil && payload["cols"] != nil
    }

    private static func terminalOutputSummary(
        from event: EventBus.KnownEvent
    ) -> EventBus.KnownEvent? {
        let payload = event.payload
        guard let surfaceID = payload["surface_id"] else { return nil }
        let base64Bytes = payload["base64"]?.stringValue?.utf8.count ?? 0
        var summary: [String: JSONValue] = [
            "surface_id": surfaceID,
            "partial": .bool(true),
            "encoded_bytes": .number(Double(base64Bytes))
        ]
        if let seq = payload["seq"] {
            summary["seq"] = seq
        }
        if let rows = payload["rows"] {
            summary["rows"] = rows
        }
        if let cols = payload["cols"] {
            summary["cols"] = cols
        }
        return EventBus.KnownEvent(
            seq: event.seq,
            kind: .surfaceOutputSummary,
            payload: summary,
            ts: event.ts
        )
    }
}

private struct EventStreamClassification {
    enum Priority { case critical, interactive, state, bulk, diagnostic }

    let priority: Priority
    let reducerRequired: Bool

    static func classify(event: EventBus.KnownEvent) -> EventStreamClassification {
        switch event.kind {
        case .diagnosticHTTPClOExecFailed,
             .diagnosticHTTPConnectionLimit,
             .diagnosticUnixClientLimit,
             .diagnosticUnixRequestLimit,
             .diagnosticUnixRequestTimeout,
             .diagnosticUnixSlowClient,
             .diagnosticWSOutboundPressure,
             .diagnosticWSSlowClient:
            return EventStreamClassification(priority: .diagnostic, reducerRequired: false)
        case .surfaceOutput, .agentItemDelta:
            return EventStreamClassification(priority: .bulk, reducerRequired: true)
        case .surfaceBrowser:
            return EventStreamClassification(priority: .interactive, reducerRequired: true)
        case .settingsUpdated:
            return EventStreamClassification(priority: .state, reducerRequired: true)
        default:
            return EventStreamClassification(priority: .critical, reducerRequired: true)
        }
    }
}
