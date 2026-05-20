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
    private let recentLimit = 512

    public var persister: ((Event) -> Void)?

    public func publish(kind: String, payload: JSONValue) {
        lock.lock()
        lastSeq += 1
        let ev = Event(seq: lastSeq, kind: kind, payload: payload, ts: Date().timeIntervalSince1970)
        recent.append(ev)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
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
        for ev in recent where !known.contains(ev.seq) {
            self.recent.append(ev)
        }
        self.recent.sort { $0.seq < $1.seq }
        if self.recent.count > recentLimit { self.recent.removeFirst(self.recent.count - recentLimit) }
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
}
