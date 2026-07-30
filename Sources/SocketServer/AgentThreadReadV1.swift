import Foundation
import CoreModel

/// Opt-in `agent.thread.read` response_version=1 for weak-network mobile recovery.
///
/// WHY: legacy watermark reads load/decode the entire stream then suffix in the
/// Dispatcher. A long thread or one oversized event can exceed the 1 MiB WebSocket
/// or 8 MiB HTTP ceiling. v1:
/// 1. Pushes event + byte limits into SQLite metadata (`LENGTH(payload_json)`)
///    so oversized rows are never transferred/decoded.
/// 2. Keeps only the newest contiguous suffix whose **full JSON-RPC envelope**
///    (keys, separators, escaping, id) fits `max_bytes`.
///
/// Legacy callers omit `response_version` and keep the previous shapes exactly.
public enum AgentThreadReadV1: Sendable {
    public static let version = 1
    public static let defaultEventLimit = 500
    public static let minEventLimit = 1
    public static let maxEventLimit = 500
    public static let minMaxBytes = 32 * 1_024
    public static let maxMaxBytes = 512 * 1_024
    public static let defaultMaxBytes = maxMaxBytes

    public enum TruncationReason: String, Sendable, Equatable {
        case countLimit = "count_limit"
        case byteLimit = "byte_limit"
    }

    public struct Caps: Sendable, Equatable {
        public let threadId: AgentThreadID
        public let eventLimit: Int
        public let maxBytes: Int

        public init(threadId: AgentThreadID, eventLimit: Int, maxBytes: Int) {
            self.threadId = threadId
            self.eventLimit = eventLimit
            self.maxBytes = maxBytes
        }
    }

    public struct BlockedEvent: Sendable, Equatable {
        public let id: Int64
        public let payloadBytes: Int64
        public let reason: String

        public init(id: Int64, payloadBytes: Int64, reason: String) {
            self.id = id
            self.payloadBytes = payloadBytes
            self.reason = reason
        }
    }

    public struct Window: Sendable, Equatable {
        public let events: [AssistantEvent]
        public let encodedEvents: [JSONValue]
        public let eventsTruncated: Bool
        public let responseTruncated: Bool
        public let truncationReason: TruncationReason?
        public let hasMore: Bool
        public let blockedEvent: BlockedEvent?

        public init(
            events: [AssistantEvent],
            encodedEvents: [JSONValue],
            eventsTruncated: Bool,
            responseTruncated: Bool,
            truncationReason: TruncationReason?,
            hasMore: Bool,
            blockedEvent: BlockedEvent?
        ) {
            self.events = events
            self.encodedEvents = encodedEvents
            self.eventsTruncated = eventsTruncated
            self.responseTruncated = responseTruncated
            self.truncationReason = truncationReason
            self.hasMore = hasMore
            self.blockedEvent = blockedEvent
        }
    }

    private static let allowedKeys: Set<String> = [
        "thread_id",
        "include_event_watermark",
        "response_version",
        "event_limit",
        "max_bytes",
    ]

    /// Parse opt-in v1 caps. Returns `nil` when `response_version` is absent (legacy).
    /// Throws `invalidParams` before any repository/coordinator work when present
    /// but not a valid integral-1 request. Never silently downgrades to legacy.
    public static func parseCaps(_ params: [String: JSONValue]) throws -> Caps? {
        guard params["response_version"] != nil else { return nil }

        guard Set(params.keys).isSubset(of: allowedKeys) else {
            throw JSONRPCError.invalidParams
        }
        guard case .number(let rawVersion) = params["response_version"],
              rawVersion.isFinite,
              let version = Int(exactly: rawVersion),
              version == Self.version else {
            throw JSONRPCError.invalidParams
        }
        guard params["include_event_watermark"]?.boolValue == true else {
            throw JSONRPCError.invalidParams
        }
        guard let threadRaw = params["thread_id"]?.stringValue,
              let uuid = UUID(uuidString: threadRaw) else {
            throw JSONRPCError.invalidParams
        }

        let eventLimit: Int
        if let value = params["event_limit"] {
            guard case .number(let rawNumber) = value,
                  rawNumber.isFinite,
                  let raw = Int(exactly: rawNumber),
                  (minEventLimit...maxEventLimit).contains(raw) else {
                throw JSONRPCError.invalidParams
            }
            eventLimit = raw
        } else {
            eventLimit = defaultEventLimit
        }

        let maxBytes: Int
        if let value = params["max_bytes"] {
            guard case .number(let rawNumber) = value,
                  rawNumber.isFinite,
                  let raw = Int(exactly: rawNumber),
                  (minMaxBytes...maxMaxBytes).contains(raw) else {
                throw JSONRPCError.invalidParams
            }
            maxBytes = raw
        } else {
            maxBytes = defaultMaxBytes
        }

        return Caps(
            threadId: AgentThreadID(uuid),
            eventLimit: eventLimit,
            maxBytes: maxBytes
        )
    }

    /// Shrink the newest contiguous suffix until the **full JSON-RPC envelope**
    /// fits `maxBytes`. Never splits an event. If the newest alone does not fit
    /// (or the source already blocked it), returns zero events with honest flags.
    ///
    /// Measurement always uses the candidate's final flag/metadata payload so
    /// truncation keys and `blocked_event` cannot push a "fitting" window over
    /// the wire cap after the fact.
    public static func boundToEnvelope(
        events: [AssistantEvent],
        encodedEvents: [JSONValue],
        sourceHadOlderEvents: Bool,
        blockedEvent: BlockedEvent?,
        maxBytes: Int,
        eventWatermark: Int64,
        responseId: JSONRPCID?,
        measureEnvelope: (JSONValue) -> Int
    ) -> Window {
        precondition(events.count == encodedEvents.count)
        _ = responseId // id is embedded by measureEnvelope via the caller's closure

        // Source already refused to decode the newest oversized row.
        if let blockedEvent, events.isEmpty {
            let empty = makeWindow(
                events: [],
                encodedEvents: [],
                sourceHadOlderEvents: true,
                byteTruncated: true,
                blockedEvent: blockedEvent
            )
            // Empty honest partial must still fit; if it somehow does not (tiny
            // maxBytes), still return it — client cannot recover without metadata.
            _ = measureEnvelope(payload(window: empty, eventWatermark: eventWatermark))
            return empty
        }

        var start = 0
        while start <= events.count {
            let sliceEvents = Array(events[start...])
            let sliceEncoded = Array(encodedEvents[start...])
            let byteTruncated = start > 0 || (sliceEvents.isEmpty && !events.isEmpty)
            let candidate = makeWindow(
                events: sliceEvents,
                encodedEvents: sliceEncoded,
                sourceHadOlderEvents: sourceHadOlderEvents,
                byteTruncated: byteTruncated,
                blockedEvent: sliceEvents.isEmpty ? blockedEvent : nil
            )
            let size = measureEnvelope(payload(window: candidate, eventWatermark: eventWatermark))
            if size <= maxBytes || sliceEvents.isEmpty {
                return candidate
            }
            // Drop oldest; keep contiguous newest suffix.
            start += 1
        }

        return makeWindow(
            events: [],
            encodedEvents: [],
            sourceHadOlderEvents: true,
            byteTruncated: true,
            blockedEvent: blockedEvent
        )
    }

    private static func makeWindow(
        events: [AssistantEvent],
        encodedEvents: [JSONValue],
        sourceHadOlderEvents: Bool,
        byteTruncated: Bool,
        blockedEvent: BlockedEvent?
    ) -> Window {
        let truncated = sourceHadOlderEvents || byteTruncated || blockedEvent != nil
        let reason: TruncationReason?
        if byteTruncated || blockedEvent != nil {
            reason = .byteLimit
        } else if sourceHadOlderEvents {
            reason = .countLimit
        } else {
            reason = nil
        }
        return Window(
            events: events,
            encodedEvents: encodedEvents,
            eventsTruncated: truncated,
            responseTruncated: truncated,
            truncationReason: reason,
            hasMore: truncated,
            blockedEvent: blockedEvent
        )
    }

    public static func payload(
        window: Window,
        eventWatermark: Int64
    ) -> JSONValue {
        let blocked: JSONValue
        if let blockedEvent = window.blockedEvent {
            blocked = .object([
                "id": .number(Double(blockedEvent.id)),
                "payload_bytes": .number(Double(blockedEvent.payloadBytes)),
                "reason": .string(blockedEvent.reason),
            ])
        } else {
            blocked = .null
        }
        return .object([
            "events": .array(window.encodedEvents),
            "event_watermark": .number(Double(eventWatermark)),
            "events_truncated": .bool(window.eventsTruncated),
            "response_truncated": .bool(window.responseTruncated),
            "truncation_reason": window.truncationReason.map { .string($0.rawValue) } ?? .null,
            "has_more": .bool(window.hasMore),
            "blocked_event": blocked,
        ])
    }
}
