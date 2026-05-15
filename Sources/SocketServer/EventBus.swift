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
    }

    private let lock = NSLock()
    private var lastSeq: Int64 = 0
    private var subscribers: [UUID: (Event) -> Void] = [:]
    private var recent: [Event] = []
    private let recentLimit = 512

    public func publish(kind: String, payload: JSONValue) {
        lock.lock()
        lastSeq += 1
        let ev = Event(seq: lastSeq, kind: kind, payload: payload, ts: Date().timeIntervalSince1970)
        recent.append(ev)
        if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
        let subs = Array(subscribers.values)
        lock.unlock()
        for s in subs { s(ev) }
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
