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
    private var subscribers: [UUID: (Event) -> Void] = [:]
    private var recent: [Event] = []
    private var recentBytes: Int = 0
    private let recentLimit: Int
    private let recentByteLimit: Int
    private let encoder = JSONEncoder()

    public var persister: ((Event) -> Void)?
    public var shouldRetainRecentEvent: ((Event) -> Bool)?

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
        for s in subs { s(ev) }
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
    public func subscribe(since: Int64?, _ handler: @escaping (Event) -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        subscribers[id] = handler
        let backlog = recent.filter { $0.seq > (since ?? 0) }
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
        }
    }

    private func rebuildRecentByteCount() {
        recentBytes = recent.reduce(0) { $0 + encodedSize($1) }
    }

    private func encodedSize(_ ev: Event) -> Int {
        (try? encoder.encode(ev).count) ?? 0
    }
}
