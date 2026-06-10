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
    private var recent: [Event] = []
    private var recentBytes: Int = 0
    private let recentLimit: Int
    private let recentByteLimit: Int
    private let encoder = JSONEncoder()
    /// One-encode-per-event cache keyed by seq. Entries are evicted when the
    /// corresponding event is removed from the recent ring, bounding memory to
    /// at most recentLimit entries.
    private var encodedCache: [Int64: Data] = [:]

    public var persister: ((Event) -> Void)?
    public var shouldRetainRecentEvent: ((Event) -> Bool)?

    public struct RecentEventsResult: Sendable {
        public let lastSeq: Int64
        public let events: [Event]
        public let truncated: Bool
        public let requiresBaseline: Bool
    }

    public init(recentLimit: Int = 512, recentByteLimit: Int = 2 * 1024 * 1024) {
        self.recentLimit = max(0, recentLimit)
        self.recentByteLimit = max(0, recentByteLimit)
    }

    public func publish(kind: String, payload: JSONValue) {
        lock.lock()
        lastSeq += 1
        let ev = Event(seq: lastSeq, kind: kind, payload: payload, ts: Date().timeIntervalSince1970)
        if shouldRetainRecentEvent?(ev) ?? true {
            retainRecent(ev)
        }
        let subs = Array(subscribers.values)
        let p = persister
        lock.unlock()
        p?(ev)
        for s in subs {
            guard let mapped = s.filter.map(ev) else { continue }
            s.handler(mapped)
        }
    }

    public func reloadFromPersistence(lastSeq: Int64, recent: [Event]) {
        lock.lock()
        self.lastSeq = max(self.lastSeq, lastSeq)
        // append unique events
        let known = Set(self.recent.map(\.seq))
        for ev in recent where !known.contains(ev.seq) && (shouldRetainRecentEvent?(ev) ?? true) {
            retainRecent(ev)
        }
        self.recent.sort { $0.seq < $1.seq }
        rebuildRecentByteCount()
        trimRecent()
        lock.unlock()
    }

    @discardableResult
    public func subscribe(since: Int64?, filter: EventStreamFilter = .full, _ handler: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = Subscriber(filter: filter, handler: handler)
        let backlog = recent.compactMap { event -> Event? in
            guard event.seq > (since ?? 0) else { return nil }
            return filter.map(event)
        }
        lock.unlock()
        for ev in backlog { handler(ev) }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        lock.lock(); subscribers.removeValue(forKey: id); lock.unlock()
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

    private func rebuildRecentByteCount() {
        recentBytes = recent.reduce(0) { $0 + encodedSize($1) }
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
