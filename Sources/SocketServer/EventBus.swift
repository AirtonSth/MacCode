import Foundation

/// In-process event bus that the dispatcher writes to when mutations
/// succeed. Each subscriber gets a per-connection async stream so JSON-RPC
/// `events.subscribe` notifications can be pushed back over the same
/// socket as line-delimited frames.
public final class EventBus: @unchecked Sendable {
    public static let shared = EventBus()

    public struct Event: Codable, Sendable {
        public let seq: Int64
        public let kind: String
        public let payload: JSONValue
        public let ts: Double

        public init(seq: Int64, kind: String, payload: JSONValue, ts: Double) {
            self.seq = seq; self.kind = kind; self.payload = payload; self.ts = ts
        }
    }

    private let lock = NSLock()
    private var lastSeq: Int64 = 0
    private struct Subscriber {
        let filter: EventStreamFilter
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
    private let encoder = JSONEncoder()
    /// One-encode-per-event cache keyed by seq. Entries are evicted when the
    /// corresponding event is removed from the recent ring, bounding memory to
    /// at most recentLimit entries.
    private var encodedCache: [Int64: Data] = [:]

    // QA-002: injectable clock so event timestamps (ts field) are deterministic
    // in tests. Default is real wall time. Protected by `lock` so the closure
    // swap in setClockForTests is visible to concurrent publish() calls.
    // publish() reads clock directly while holding lock (no re-entry issue).
    private var clock: @Sendable () -> Date

    public var persister: ((Event) -> Void)?
    public var shouldRetainRecentEvent: ((Event) -> Bool)?

    public struct RecentEventsResult: Sendable {
        public let lastSeq: Int64
        public let events: [Event]
        public let truncated: Bool
        public let requiresBaseline: Bool
    }

    public init(
        recentLimit: Int = 512,
        recentByteLimit: Int = 2 * 1024 * 1024,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.recentLimit = max(0, recentLimit)
        self.recentByteLimit = max(0, recentByteLimit)
        self.clock = clock
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

    public func publish(kind: String, payload: JSONValue) {
        lock.lock()
        lastSeq += 1
        let ev = Event(seq: lastSeq, kind: kind, payload: payload, ts: clock().timeIntervalSince1970)
        if shouldRetainRecentEvent?(ev) ?? true {
            retainRecent(ev)
        }
        let subs = subscribersSnapshot
        let p = persister
        lock.unlock()
        p?(ev)
        for s in subs {
            guard let mapped = s.filter.map(ev) else { continue }
            s.handler(mapped)
        }
    }

    public func reloadFromPersistence(lastSeq: Int64, recent: [Event]) {
        // --- snapshot under lock (cheap: set + closure capture) ---
        lock.lock()
        let knownSeqs = Set(self.recent.map(\.seq))
        let retain = shouldRetainRecentEvent  // capture while holding lock, same as publish()
        lock.unlock()

        // --- precompute off the lock (expensive: filter + encode) ---
        // `recent` is the caller-provided immutable parameter (no lock needed).
        // `knownSeqs` and `retain` are immutable snapshots captured under the lock above.
        // We encode only the events that are new relative to the snapshot; events that
        // arrive via publish() between the two lock regions are not in `recent` at all
        // and are handled correctly by the per-event path in publish().
        var newEncoded: [Int64: Data] = [:]
        let candidates = recent.filter { ev in
            guard !knownSeqs.contains(ev.seq) else { return false }
            guard retain?(ev) ?? true else { return false }
            let d = (try? encoder.encode(ev)) ?? Data()
            newEncoded[ev.seq] = d
            return true
        }

        // --- assign under lock (cheap: dedup check, append, sort, byte-count, trim) ---
        // Re-check against the live self.recent to handle events that publish() may have
        // added between the two lock regions; encoding is already done via newEncoded.
        lock.lock()
        self.lastSeq = max(self.lastSeq, lastSeq)
        let liveKnown = Set(self.recent.map(\.seq))
        for ev in candidates where !liveKnown.contains(ev.seq) {
            let bytes = newEncoded[ev.seq]?.count ?? 0
            guard recentLimit > 0, recentByteLimit > 0, bytes <= recentByteLimit else { continue }
            // populate cache before appending so trimRecent's encodedSize hits the cache
            if let d = newEncoded[ev.seq] { encodedCache[ev.seq] = d }
            self.recent.append(ev)
            self.recentBytes += bytes
        }
        self.recent.sort { $0.seq < $1.seq }
        trimRecent()
        lock.unlock()
    }

    @discardableResult
    public func subscribe(since: Int64?, filter: EventStreamFilter = .full, _ handler: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = Subscriber(filter: filter, handler: handler)
        subscribersSnapshot = Array(subscribers.values)
        let backlog = recent.compactMap { event -> Event? in
            guard event.seq > (since ?? 0) else { return nil }
            return filter.map(event)
        }
        lock.unlock()
        for ev in backlog { handler(ev) }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        subscribersSnapshot = Array(subscribers.values)
        lock.unlock()
    }

    public func snapshot() -> (lastSeq: Int64, recent: [Event]) {
        lock.lock(); defer { lock.unlock() }
        return (lastSeq, recent)
    }

    public func recentEvents(since: Int64, maxBytes: Int?) -> RecentEventsResult {
        lock.lock()
        let currentLastSeq = lastSeq
        let candidates = recent.filter { $0.seq > since }
        lock.unlock()

        guard let maxBytes, maxBytes > 0 else {
            return RecentEventsResult(lastSeq: currentLastSeq,
                                      events: candidates,
                                      truncated: false,
                                      requiresBaseline: false)
        }

        var selected: [Event] = []
        var used = 0
        var truncated = false
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

    private func retainRecent(_ ev: Event) {
        let bytes = encodedSize(ev)
        guard recentLimit > 0, recentByteLimit > 0, bytes <= recentByteLimit else {
            trimRecent()
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
    func encodedData(for ev: Event) -> Data {
        if let cached = encodedCache[ev.seq] { return cached }
        let data = (try? encoder.encode(ev)) ?? Data()
        encodedCache[ev.seq] = data
        return data
    }

    private func encodedSize(_ ev: Event) -> Int {
        encodedData(for: ev).count
    }
}

public enum EventStreamFilter: Sendable, Equatable {
    case full
    case cellularSafe

    public static func parse(_ raw: String?) -> EventStreamFilter {
        guard raw?.lowercased().contains("cellular-safe") == true else { return .full }
        return .cellularSafe
    }

    public func allows(_ event: EventBus.Event) -> Bool {
        map(event) != nil
    }

    public func coalescingKey(for event: EventBus.Event) -> String? {
        guard self == .cellularSafe else { return nil }
        guard case .object(let payload) = event.payload else { return nil }
        guard event.kind == "surface.output.summary",
              let surfaceID = payload["surface_id"]?.stringValue else { return nil }
        return "\(event.kind):\(surfaceID)"
    }

    public func map(_ event: EventBus.Event) -> EventBus.Event? {
        switch self {
        case .full:
            return event
        case .cellularSafe:
            let classification = EventStreamClassification.classify(kind: event.kind)
            if event.kind == "surface.output" {
                return Self.terminalOutputSummary(from: event)
            }
            guard classification.reducerRequired || classification.priority == .critical else { return nil }
            return event
        }
    }

    private static func terminalOutputSummary(from event: EventBus.Event) -> EventBus.Event? {
        guard case .object(let payload) = event.payload,
              let surfaceID = payload["surface_id"] else { return nil }
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
        return EventBus.Event(seq: event.seq,
                              kind: "surface.output.summary",
                              payload: .object(summary),
                              ts: event.ts)
    }
}

private struct EventStreamClassification {
    enum Priority { case critical, interactive, state, bulk, diagnostic }

    let priority: Priority
    let reducerRequired: Bool

    static func classify(kind: String) -> EventStreamClassification {
        switch kind {
        case let k where k.hasPrefix("diagnostic.") || k.hasPrefix("metrics."):
            return EventStreamClassification(priority: .diagnostic, reducerRequired: false)
        case "surface.output", "agent.item.delta":
            return EventStreamClassification(priority: .bulk, reducerRequired: true)
        case "surface.browser":
            return EventStreamClassification(priority: .interactive, reducerRequired: true)
        case "settings.updated":
            return EventStreamClassification(priority: .state, reducerRequired: true)
        default:
            return EventStreamClassification(priority: .critical, reducerRequired: true)
        }
    }
}
