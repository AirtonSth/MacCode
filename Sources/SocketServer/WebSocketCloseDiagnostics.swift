import Foundation
import RemoteCodeTreaty

/// What one `/v1/ws` connection looked like when it closed. Secret-free: no
/// owner, token, connection id, host or payload.
struct WebSocketCloseSummary: Equatable, Sendable {
    let reason: String
    /// WebSocket close code the host sent, or 1006 when the socket ended without
    /// a close frame. Nil when the peer sent the close frame (code not parsed).
    let code: Int?
    let durationMilliseconds: Int64
    let sinceSequence: Int64
    let replayExpired: Bool
    let framesShed: Int
}

/// Per-connection close facts. The first recorded reason wins, so the read loop
/// noticing EOF after a host-initiated close cannot overwrite the real cause.
final class WebSocketCloseRecord: @unchecked Sendable {
    private let lock = NSLock()
    private let openedAt: TimeInterval
    private let sinceSequence: Int64
    private var reason: String?
    private var code: Int?
    private var replayExpired = false
    private var framesShed = 0

    init(sinceSequence: Int64, openedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.sinceSequence = sinceSequence
        self.openedAt = openedAt
    }

    func recordClose(reason: String, code: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard self.reason == nil else { return }
        self.reason = reason
        self.code = code
    }

    /// Maps a `WebSocketOutboundQueue.terminate` reason to a stable diagnostic
    /// reason and the close code the host puts in its closing frame.
    func recordTerminal(_ terminalReason: String) {
        switch terminalReason {
        case "event_gap": recordClose(reason: "eventGap", code: 1012)
        case "heartbeatTimeout": recordClose(reason: "heartbeatTimeout", code: 1012)
        case "invalidEvent": recordClose(reason: "invalidEvent", code: 1011)
        case "write_failed": recordClose(reason: "writeFailed", code: 1011)
        case "protocolError": recordClose(reason: "protocolError", code: 1002)
        case "peerClose": recordClose(reason: "peerClose", code: nil)
        default: recordClose(reason: "other", code: nil)
        }
    }

    func markReplayExpired() {
        lock.lock(); replayExpired = true; lock.unlock()
    }

    func recordFramesShed(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); framesShed += count; lock.unlock()
    }

    func summary(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> WebSocketCloseSummary {
        lock.lock(); defer { lock.unlock() }
        return WebSocketCloseSummary(
            reason: reason ?? "other",
            code: reason == nil ? 1006 : code,
            durationMilliseconds: Int64(max(0, (now - openedAt) * 1_000).rounded()),
            sinceSequence: sinceSequence,
            replayExpired: replayExpired,
            framesShed: framesShed
        )
    }
}

/// Process-scoped close accounting for `/v1/health` plus a rate-limited
/// `diagnostic.ws_connection_closed` event. Counters count every close; the
/// event is emitted at most once per reason per `minimumInterval`, and the next
/// emitted event for that reason carries how many were suppressed in between,
/// so a reconnect storm stays attributable without flooding the event log.
public final class WebSocketCloseDiagnostics: @unchecked Sendable {
    public static let defaultMinimumInterval: TimeInterval = 10

    private let lock = NSLock()
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let publish: @Sendable (JSONValue) -> Void
    private var countsByReason: [String: Int] = [:]
    private var lastEmittedAt: [String: TimeInterval] = [:]
    private var suppressedSinceLast: [String: Int] = [:]
    private var emittedTotal = 0
    private var suppressedTotal = 0

    public init(
        minimumInterval: TimeInterval = WebSocketCloseDiagnostics.defaultMinimumInterval,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        publish: @escaping @Sendable (JSONValue) -> Void = { payload in
            EventBus.shared.publish(kind: .diagnosticWSConnectionClosed, payload: payload)
        }
    ) {
        self.minimumInterval = minimumInterval
        self.now = now
        self.publish = publish
    }

    /// Counts the close and emits the diagnostic event unless this reason
    /// already emitted one inside the window. Returns whether it emitted.
    @discardableResult
    func record(_ summary: WebSocketCloseSummary) -> Bool {
        let current = now()
        lock.lock()
        countsByReason[summary.reason, default: 0] += 1
        if let last = lastEmittedAt[summary.reason], current - last < minimumInterval {
            suppressedSinceLast[summary.reason, default: 0] += 1
            suppressedTotal += 1
            lock.unlock()
            return false
        }
        let suppressed = suppressedSinceLast.removeValue(forKey: summary.reason) ?? 0
        lastEmittedAt[summary.reason] = current
        emittedTotal += 1
        lock.unlock()
        publish(.object([
            "reason": .string(summary.reason),
            "code": summary.code.map { .number(Double($0)) } ?? .null,
            "duration_ms": .number(Double(summary.durationMilliseconds)),
            "since_seq": .number(Double(summary.sinceSequence)),
            "replay_expired": .bool(summary.replayExpired),
            "frames_shed": .number(Double(summary.framesShed)),
            "suppressed_since_last": .number(Double(suppressed))
        ]))
        return true
    }

    /// `/v1/health` `connection_closes` block.
    public func healthJSON() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "by_reason": countsByReason,
            "events_emitted_total": emittedTotal,
            "events_suppressed_total": suppressedTotal
        ]
    }

    /// Jittered reconnect hint for eventGap closes (250–1000 ms). Zero let every
    /// client that lost the same burst reconnect at once.
    static func eventGapRetryAfterMilliseconds(
        randomUnit: Double = Double.random(in: 0..<1)
    ) -> Int64 {
        let unit = min(max(randomUnit.isFinite ? randomUnit : 0, 0), 1)
        return 250 + Int64((unit * 750).rounded(.down))
    }
}
