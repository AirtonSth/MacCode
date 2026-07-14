import Foundation
import Persistence

public struct PrivateLiveActivityV2DeliveryAck: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let attempts: Int
    public let nextAttemptAt: String?
    public let accepted: Bool?

    public init(id: String, status: String, attempts: Int, nextAttemptAt: String?, accepted: Bool? = nil) {
        self.id = id
        self.status = status
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
        self.accepted = accepted
    }

    public var isAccepted: Bool {
        ["pending", "queued", "processing", "delivered"].contains(status)
    }

    private enum CodingKeys: String, CodingKey { case id, status, attempts, nextAttemptAt, accepted }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        status = try values.decode(String.self, forKey: .status)
        attempts = try values.decode(Int.self, forKey: .attempts)
        accepted = try values.decodeIfPresent(Bool.self, forKey: .accepted)
        if let string = try? values.decodeIfPresent(String.self, forKey: .nextAttemptAt) {
            nextAttemptAt = string
        } else if let number = try? values.decode(Double.self, forKey: .nextAttemptAt) {
            nextAttemptAt = String(number)
        } else {
            nextAttemptAt = nil
        }
    }
}

public enum LiveActivityAcceptanceTarget: Codable, Equatable, Sendable {
    case v2(PrivatePushTargetRecord)
    case legacy(PrivatePushTarget)

    var unitIdentity: String {
        switch self {
        case .v2(let target):
            return "v2|\(target.serverId)|\(target.deviceId)|\(target.environment.rawValue)|\(target.purpose.rawValue)"
        case .legacy(let target):
            return "legacy|\(target.deviceId ?? "unknown")|\(target.pushTokenType)"
        }
    }

    var deviceIdentity: String {
        switch self {
        case .v2(let target):
            return "v2|\(target.serverId)|\(target.deviceId)|\(target.environment.rawValue)"
        case .legacy(let target):
            return "legacy|\(target.deviceId ?? "unknown")|\(target.pushTokenType)"
        }
    }
}

public struct LiveActivityAcceptanceRecord: Codable, Equatable, Sendable {
    public let delivery: LiveActivitySyncDelivery
    public let target: LiveActivityAcceptanceTarget
    public let attempts: Int
    public let nextAttemptAt: Date?

    public init(
        delivery: LiveActivitySyncDelivery,
        target: LiveActivityAcceptanceTarget,
        attempts: Int = 0,
        nextAttemptAt: Date? = nil
    ) {
        self.delivery = delivery
        self.target = target
        self.attempts = attempts
        self.nextAttemptAt = nextAttemptAt
    }

    var recordID: String { delivery.idempotencyKey + "|" + target.unitIdentity }
}

public final class LiveActivityAcceptanceOutboxStore: @unchecked Sendable {
    private static let key = "live_activity.acceptance_outbox.v1"

    private let settings: SettingsRepository
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(settings: SettingsRepository) {
        self.settings = settings
    }

    public func enqueue(
        _ delivery: LiveActivitySyncDelivery,
        targets: [LiveActivityAcceptanceTarget]
    ) throws {
        try lock.withLock {
            var records = try loadUnlocked()
            for target in targets {
                let incoming = LiveActivityAcceptanceRecord(delivery: delivery, target: target)
                guard !records.contains(where: { $0.recordID == incoming.recordID }) else { continue }
                if delivery.event == .update {
                    records.removeAll {
                        $0.target.unitIdentity == target.unitIdentity &&
                        $0.delivery.event == .update &&
                        Self.isSameSession($0.delivery, delivery)
                    }
                }
                records.append(incoming)
            }
            try saveUnlocked(records)
        }
    }

    public func pending() throws -> [LiveActivityAcceptanceRecord] {
        try lock.withLock { try loadUnlocked() }
    }

    func candidates() throws -> [LiveActivityAcceptanceRecord] {
        try lock.withLock {
            let records = try loadUnlocked()
            let groups = Dictionary(grouping: records, by: { $0.target.unitIdentity })
            let perUnit: [LiveActivityAcceptanceRecord] = groups.values.compactMap { unit -> LiveActivityAcceptanceRecord? in
                guard let oldestSession = unit.min(by: {
                    Self.isOrderedBefore($0.delivery, $1.delivery)
                }) else { return nil }
                let session = unit.filter {
                    Self.isSameSession($0.delivery, oldestSession.delivery)
                }
                if let terminal = session
                    .filter({ $0.delivery.event == .end })
                    .max(by: { $0.delivery.projection.revision < $1.delivery.projection.revision }) {
                    return terminal
                }
                if let start = session
                    .filter({ $0.delivery.event == .start })
                    .min(by: { $0.delivery.projection.revision < $1.delivery.projection.revision }) {
                    return start
                }
                return session.max(by: {
                    $0.delivery.projection.revision < $1.delivery.projection.revision
                })
            }
            let oldestByDevice = Dictionary(grouping: records, by: { $0.target.deviceIdentity })
                .compactMapValues { values in
                    values.min(by: { Self.isOrderedBefore($0.delivery, $1.delivery) })
                }
            return perUnit.filter { candidate in
                guard let oldest = oldestByDevice[candidate.target.deviceIdentity] else { return false }
                return Self.isSameSession(candidate.delivery, oldest.delivery)
            }
        }
    }

    func recordFailure(
        recordID: String,
        nextAttemptAt: Date
    ) throws -> LiveActivityAcceptanceRecord? {
        try lock.withLock {
            var records = try loadUnlocked()
            guard let index = records.firstIndex(where: {
                $0.recordID == recordID
            }) else { return nil }
            records[index] = LiveActivityAcceptanceRecord(
                delivery: records[index].delivery,
                target: records[index].target,
                attempts: records[index].attempts + 1,
                nextAttemptAt: nextAttemptAt
            )
            try saveUnlocked(records)
            return records[index]
        }
    }

    func acknowledge(_ record: LiveActivityAcceptanceRecord) throws {
        try lock.withLock {
            var records = try loadUnlocked()
            if record.delivery.event == .end {
                records.removeAll { candidate in
                    candidate.target.deviceIdentity == record.target.deviceIdentity &&
                    Self.isSameOrOlderSession(candidate.delivery, than: record.delivery)
                }
            } else {
                records.removeAll { $0.recordID == record.recordID }
            }
            try saveUnlocked(records)
        }
    }

    private func loadUnlocked() throws -> [LiveActivityAcceptanceRecord] {
        guard let json = try settings.get(Self.key),
              !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return try decoder.decode([LiveActivityAcceptanceRecord].self, from: data)
    }

    private func saveUnlocked(_ records: [LiveActivityAcceptanceRecord]) throws {
        let data = try encoder.encode(records)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try settings.set(Self.key, json)
    }

    private static func isOrderedBefore(
        _ lhs: LiveActivitySyncDelivery,
        _ rhs: LiveActivitySyncDelivery
    ) -> Bool {
        let lhsBoot = UInt64(lhs.projection.epoch) ?? 0
        let rhsBoot = UInt64(rhs.projection.epoch) ?? 0
        if lhsBoot != rhsBoot { return lhsBoot < rhsBoot }
        if lhs.activityGeneration != rhs.activityGeneration {
            return lhs.activityGeneration < rhs.activityGeneration
        }
        if lhs.projection.revision != rhs.projection.revision {
            return lhs.projection.revision < rhs.projection.revision
        }
        return eventRank(lhs.event) < eventRank(rhs.event)
    }

    private static func isSameOrOlderSession(
        _ candidate: LiveActivitySyncDelivery,
        than terminal: LiveActivitySyncDelivery
    ) -> Bool {
        guard candidate.projection.hostId == terminal.projection.hostId else { return false }
        let candidateBoot = UInt64(candidate.projection.epoch) ?? 0
        let terminalBoot = UInt64(terminal.projection.epoch) ?? 0
        if candidateBoot != terminalBoot { return candidateBoot < terminalBoot }
        if candidate.activityGeneration != terminal.activityGeneration {
            return candidate.activityGeneration < terminal.activityGeneration
        }
        return candidate.projection.revision <= terminal.projection.revision
    }

    private static func isSameSession(
        _ lhs: LiveActivitySyncDelivery,
        _ rhs: LiveActivitySyncDelivery
    ) -> Bool {
        lhs.projection.hostId == rhs.projection.hostId &&
        lhs.projection.epoch == rhs.projection.epoch &&
        lhs.activityGeneration == rhs.activityGeneration
    }

    private static func eventRank(_ event: PrivateLiveActivityEvent) -> Int {
        switch event {
        case .start: 0
        case .update: 1
        case .end: 2
        }
    }
}

public enum LiveActivityAcceptanceOutboxError: Error, Equatable {
    case backendDidNotAccept(String)
}

public final class LiveActivityAcceptanceOutbox: @unchecked Sendable {
    public typealias Now = @Sendable () -> Date
    public typealias RetryDelay = @Sendable (Int) -> TimeInterval
    public typealias Schedule = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    public typealias Send = @Sendable (LiveActivityAcceptanceRecord) async throws -> PrivateLiveActivityV2DeliveryAck
    public typealias ErrorHandler = @Sendable (Error, LiveActivitySyncDelivery?) -> Void

    private enum Command: @unchecked Sendable {
        case wake
        case retryReady(String)
        case flush(CheckedContinuation<Void, Never>)
    }

    private let store: LiveActivityAcceptanceOutboxStore
    private let continuation: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?

    public init(
        store: LiveActivityAcceptanceOutboxStore,
        now: @escaping Now = { Date() },
        retryDelay: @escaping RetryDelay = { attempt in
            min(60, pow(2, Double(max(0, attempt - 1))))
        },
        schedule: @escaping Schedule = { delay, callback in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + max(0, delay),
                execute: callback
            )
        },
        onError: @escaping ErrorHandler = { _, _ in },
        send: @escaping Send
    ) {
        self.store = store
        var capturedContinuation: AsyncStream<Command>.Continuation?
        let stream = AsyncStream<Command> { capturedContinuation = $0 }
        let commandContinuation = capturedContinuation!
        self.continuation = commandContinuation
        self.worker = Task {
            var scheduled = Set<String>()
            for await command in stream {
                switch command {
                case .wake:
                    await Self.drain(
                        store: store,
                        now: now,
                        retryDelay: retryDelay,
                        schedule: schedule,
                        send: send,
                        onError: onError,
                        continuation: commandContinuation,
                        scheduled: &scheduled
                    )
                case .retryReady(let key):
                    scheduled.remove(key)
                    await Self.drain(
                        store: store,
                        now: now,
                        retryDelay: retryDelay,
                        schedule: schedule,
                        send: send,
                        onError: onError,
                        continuation: commandContinuation,
                        scheduled: &scheduled
                    )
                case .flush(let barrier):
                    barrier.resume()
                }
            }
        }
    }

    deinit {
        continuation.finish()
        worker?.cancel()
    }

    public func accept(
        _ delivery: LiveActivitySyncDelivery,
        targets: [LiveActivityAcceptanceTarget]
    ) throws {
        try store.enqueue(delivery, targets: targets)
        continuation.yield(.wake)
    }

    public func resumePending() {
        continuation.yield(.wake)
    }

    public func flush() async {
        await withCheckedContinuation { barrier in
            continuation.yield(.flush(barrier))
        }
    }

    private static func drain(
        store: LiveActivityAcceptanceOutboxStore,
        now: Now,
        retryDelay: RetryDelay,
        schedule: Schedule,
        send: Send,
        onError: ErrorHandler,
        continuation: AsyncStream<Command>.Continuation,
        scheduled: inout Set<String>
    ) async {
        while true {
            let record: LiveActivityAcceptanceRecord
            do {
                let candidates = try store.candidates()
                guard !candidates.isEmpty else { return }
                let ready = candidates.filter { ($0.nextAttemptAt ?? .distantPast) <= now() }
                guard let next = ready.sorted(by: Self.isPreferred).first else {
                    for candidate in candidates {
                        guard let retryAt = candidate.nextAttemptAt else { continue }
                        let candidateKey = candidate.recordID
                        if scheduled.insert(candidateKey).inserted {
                            schedule(max(0, retryAt.timeIntervalSince(now()))) {
                                continuation.yield(.retryReady(candidateKey))
                            }
                        }
                    }
                    return
                }
                record = next
            } catch {
                onError(error, nil)
                return
            }
            let key = record.recordID
            do {
                let ack = try await send(record)
                guard ack.isAccepted else {
                    throw LiveActivityAcceptanceOutboxError.backendDidNotAccept(ack.status)
                }
                try store.acknowledge(record)
                scheduled.remove(key)
            } catch {
                onError(error, record.delivery)
                let delay = retryDelay(record.attempts + 1)
                let failed: LiveActivityAcceptanceRecord?
                do {
                    failed = try store.recordFailure(
                        recordID: key,
                        nextAttemptAt: now().addingTimeInterval(delay)
                    )
                } catch {
                    onError(error, record.delivery)
                    return
                }
                if failed != nil, scheduled.insert(key).inserted {
                    schedule(delay) {
                        continuation.yield(.retryReady(key))
                    }
                }
                continue
            }
        }
    }

    private static func isPreferred(
        _ lhs: LiveActivityAcceptanceRecord,
        _ rhs: LiveActivityAcceptanceRecord
    ) -> Bool {
        if lhs.delivery.event != rhs.delivery.event {
            if lhs.delivery.event == .end { return true }
            if rhs.delivery.event == .end { return false }
        }
        if lhs.delivery.activityGeneration != rhs.delivery.activityGeneration {
            return lhs.delivery.activityGeneration < rhs.delivery.activityGeneration
        }
        return lhs.delivery.projection.revision < rhs.delivery.projection.revision
    }
}
