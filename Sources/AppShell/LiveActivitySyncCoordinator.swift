import Foundation
import AgentRuntime
import CoreModel
import Persistence

public struct LiveActivityHostIdentity: Equatable, Sendable {
    public let serverId: String
    public let bootEpoch: UInt64
    public let activityGeneration: UInt64
}

public enum LiveActivityIdentityStore {
    private static let bootEpochKey = "live_activity.boot_epoch"
    private static let activityGenerationKey = "live_activity.activity_generation"

    public static func beginBoot(settings: SettingsRepository) throws -> LiveActivityHostIdentity {
        let serverId: String
        if let stored = try settings.get("server_id"), !stored.isEmpty {
            serverId = stored
        } else {
            serverId = UUID().uuidString
            try settings.set("server_id", serverId)
        }
        let previousBoot = UInt64(try settings.get(bootEpochKey) ?? "") ?? 0
        let bootEpoch = previousBoot &+ 1
        try settings.set(bootEpochKey, String(bootEpoch))
        let generation = UInt64(try settings.get(activityGenerationKey) ?? "") ?? 0
        return LiveActivityHostIdentity(
            serverId: serverId,
            bootEpoch: bootEpoch,
            activityGeneration: generation
        )
    }

    public static func persistActivityGeneration(
        _ generation: UInt64,
        settings: SettingsRepository
    ) throws {
        try settings.set(activityGenerationKey, String(generation))
    }
}

public enum PrivateLiveActivityProjectionPhase: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
}

/// Versioned ActivityKit content-state shared by the Mac host, backend, and iOS.
/// Dates stay integer Unix seconds on the wire; clients construct `Date` locally.
public struct PrivateLiveActivityProjectionV2: Codable, Equatable, Sendable {
    public let title: String
    public let statusLine: String
    public let preview: String
    public let phase: PrivateLiveActivityProjectionPhase
    public let activeThreadCount: Int
    public let updatedAt: Double
    public let runStartDate: Double?
    public let workspaceId: String?
    public let threadId: String?
    public let protocolVersion: Int
    public let activityKey: String
    public let sessionId: String
    public let hostId: String
    public let epoch: String
    public let revision: Int64

    public init(
        title: String = "RemoteCode",
        statusLine: String,
        preview: String = "RemoteCode",
        phase: PrivateLiveActivityProjectionPhase,
        activeThreadCount: Int,
        updatedAt: Double,
        runStartDate: Double? = nil,
        workspaceId: String? = nil,
        threadId: String? = nil,
        protocolVersion: Int = 2,
        activityKey: String = "active-threads",
        sessionId: String,
        hostId: String,
        epoch: String,
        revision: Int64
    ) {
        self.title = title
        self.statusLine = statusLine
        self.preview = preview
        self.phase = phase
        self.activeThreadCount = activeThreadCount
        self.updatedAt = updatedAt
        self.runStartDate = runStartDate
        self.workspaceId = workspaceId
        self.threadId = threadId
        self.protocolVersion = protocolVersion
        self.activityKey = activityKey
        self.sessionId = sessionId
        self.hostId = hostId
        self.epoch = epoch
        self.revision = revision
    }

    public var legacyContentState: PrivateLiveActivityContentState {
        PrivateLiveActivityContentState(
            title: title,
            statusLine: statusLine,
            preview: preview,
            phase: phase.rawValue,
            activeThreadCount: activeThreadCount,
            updatedAt: updatedAt,
            runStartDate: runStartDate,
            workspaceId: workspaceId,
            threadId: threadId
        )
    }
}

public struct LiveActivitySyncDelivery: Codable, Equatable, Sendable {
    public let event: PrivateLiveActivityEvent
    public let projection: PrivateLiveActivityProjectionV2
    public let activityGeneration: UInt64
    public let idempotencyKey: String
}

public enum LiveActivitySyncCause: Equatable, Sendable {
    case started
    case changed
    case finished(AgentRunStatus)
    case launchReconciliation
}

public enum LiveActivityTokenBindingError: Error, Equatable {
    case missingActivityID
    case unknownAuthoritativeScope
}

private final class LiveActivityTokenScopeBinder: @unchecked Sendable {
    private let lock = NSLock()
    private let serverId: String
    private let bootEpoch: UInt64
    private var currentGeneration: UInt64
    private var knownScopes: Set<LiveActivityTokenOwnership>
    private var ownershipByTargetActivity: [String: LiveActivityTokenOwnership]

    init(
        serverId: String,
        bootEpoch: UInt64,
        initialGeneration: UInt64,
        initialTargets: [PrivatePushTargetRecord]
    ) {
        self.serverId = serverId
        self.bootEpoch = bootEpoch
        self.currentGeneration = initialGeneration
        let current = Self.ownership(
            activityId: "",
            serverId: serverId,
            bootEpoch: bootEpoch,
            generation: initialGeneration
        )
        var known = Set<LiveActivityTokenOwnership>()
        known.insert(current)
        var mappings: [String: LiveActivityTokenOwnership] = [:]
        for target in initialTargets {
            guard let ownership = target.ownership else { continue }
            known.insert(ownership)
            mappings[Self.mappingKey(target: target, activityId: ownership.activityId)] = ownership
        }
        self.knownScopes = known
        self.ownershipByTargetActivity = mappings
    }

    func recordGeneration(_ generation: UInt64) {
        lock.withLock {
            currentGeneration = generation
            knownScopes.insert(Self.ownership(
                activityId: "",
                serverId: serverId,
                bootEpoch: bootEpoch,
                generation: generation
            ))
        }
    }

    func bind(_ target: PrivatePushTargetRecord) throws -> PrivatePushTargetRecord {
        guard target.purpose == .activityUpdate else { return target }
        guard let activityId = target.activityId, !activityId.isEmpty else {
            throw LiveActivityTokenBindingError.missingActivityID
        }
        return try lock.withLock {
            let mappingKey = Self.mappingKey(target: target, activityId: activityId)
            if let existing = ownershipByTargetActivity[mappingKey] {
                return target.bound(to: existing)
            }
            let ownership: LiveActivityTokenOwnership
            if let proposed = target.ownership {
                let scopeMarker = Self.ownership(
                    activityId: "",
                    serverId: proposed.hostId,
                    bootEpoch: proposed.bootEpoch,
                    generation: proposed.activityGeneration
                )
                guard knownScopes.contains(scopeMarker),
                      proposed.activitySessionId == scopeMarker.activitySessionId else {
                    throw LiveActivityTokenBindingError.unknownAuthoritativeScope
                }
                ownership = proposed
            } else if target.bootEpoch != nil || target.activitySessionId != nil {
                throw LiveActivityTokenBindingError.unknownAuthoritativeScope
            } else {
                ownership = Self.ownership(
                    activityId: activityId,
                    serverId: serverId,
                    bootEpoch: bootEpoch,
                    generation: currentGeneration
                )
            }
            ownershipByTargetActivity[mappingKey] = ownership
            return target.bound(to: ownership)
        }
    }

    private static func ownership(
        activityId: String,
        serverId: String,
        bootEpoch: UInt64,
        generation: UInt64
    ) -> LiveActivityTokenOwnership {
        LiveActivityTokenOwnership(
            activityId: activityId,
            hostId: serverId,
            bootEpoch: bootEpoch,
            activityGeneration: generation,
            activitySessionId: "\(serverId):\(bootEpoch):\(generation)"
        )
    }

    private static func mappingKey(target: PrivatePushTargetRecord, activityId: String) -> String {
        "\(target.deviceId)|\(target.environment.rawValue)|\(activityId)"
    }
}

/// One long-lived mailbox serializes lifecycle transitions and network delivery.
/// Callers submit synchronously from coordinator callbacks; no per-event
/// unstructured Task can reorder start/update/end.
public final class LiveActivitySyncCoordinator: @unchecked Sendable {
    public typealias Delivery = @Sendable (LiveActivitySyncDelivery) async throws -> Void
    public typealias DeliveryError = @Sendable (Error, LiveActivitySyncDelivery) -> Void
    public typealias TokenRegistration = @Sendable (PrivatePushTargetRecord) async throws -> Void
    public typealias TokenRegistrationError = @Sendable (Error, PrivatePushTargetRecord) -> Void

    private enum Command: @unchecked Sendable {
        case registerToken(PrivatePushTargetRecord)
        case projection(ActiveRunProjection, LiveActivitySyncCause, Date)
        case heartbeat(Date)
        case flush(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Command>.Continuation
    private let tokenScopeBinder: LiveActivityTokenScopeBinder
    private var worker: Task<Void, Never>?

    public init(
        serverId: String,
        bootEpoch: UInt64,
        initialActivityGeneration: UInt64 = 0,
        initialTokenTargets: [PrivatePushTargetRecord] = [],
        registerToken: @escaping TokenRegistration = { _ in },
        onTokenRegistrationError: @escaping TokenRegistrationError = { _, _ in },
        onDeliveryError: @escaping DeliveryError = { _, _ in },
        deliver: @escaping Delivery
    ) {
        let tokenScopeBinder = LiveActivityTokenScopeBinder(
            serverId: serverId,
            bootEpoch: bootEpoch,
            initialGeneration: initialActivityGeneration,
            initialTargets: initialTokenTargets
        )
        self.tokenScopeBinder = tokenScopeBinder
        var capturedContinuation: AsyncStream<Command>.Continuation?
        let stream = AsyncStream<Command> { capturedContinuation = $0 }
        self.continuation = capturedContinuation!
        self.worker = Task {
            var latest = ActiveRunProjection(runs: [])
            var activityGeneration = initialActivityGeneration
            var stateRevision: UInt64 = 0

            for await command in stream {
                switch command {
                case .registerToken(let target):
                    do {
                        try await registerToken(target)
                    } catch {
                        onTokenRegistrationError(error, target)
                    }
                case .projection(let projection, let cause, let now):
                    let previousCount = latest.activeRunCount
                    latest = projection
                    let event: PrivateLiveActivityEvent
                    if cause == .launchReconciliation {
                        event = .end
                    } else if previousCount == 0, projection.activeRunCount > 0 {
                        activityGeneration &+= 1
                        tokenScopeBinder.recordGeneration(activityGeneration)
                        stateRevision = 0
                        event = .start
                    } else if projection.activeRunCount == 0 {
                        event = .end
                    } else {
                        event = .update
                    }
                    stateRevision &+= 1
                    let delivery = Self.delivery(
                        projection: projection,
                        cause: cause,
                        event: event,
                        serverId: serverId,
                        bootEpoch: bootEpoch,
                        activityGeneration: activityGeneration,
                        stateRevision: stateRevision,
                        now: now
                    )
                    do {
                        try await deliver(delivery)
                    } catch {
                        onDeliveryError(error, delivery)
                    }
                case .heartbeat(let now):
                    guard latest.activeRunCount > 0 else { continue }
                    stateRevision &+= 1
                    let delivery = Self.delivery(
                        projection: latest,
                        cause: .changed,
                        event: .update,
                        serverId: serverId,
                        bootEpoch: bootEpoch,
                        activityGeneration: activityGeneration,
                        stateRevision: stateRevision,
                        now: now
                    )
                    do {
                        try await deliver(delivery)
                    } catch {
                        onDeliveryError(error, delivery)
                    }
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

    public func submit(_ projection: ActiveRunProjection, cause: LiveActivitySyncCause, now: Date = Date()) {
        continuation.yield(.projection(projection, cause, now))
    }

    @discardableResult
    public func submitTokenRegistration(_ target: PrivatePushTargetRecord) throws -> PrivatePushTargetRecord {
        let bound = try tokenScopeBinder.bind(target)
        continuation.yield(.registerToken(bound))
        return bound
    }

    public func submitHeartbeat(now: Date = Date()) {
        continuation.yield(.heartbeat(now))
    }

    public func flush() async {
        await withCheckedContinuation { continuation in
            self.continuation.yield(.flush(continuation))
        }
    }

    private static func delivery(
        projection: ActiveRunProjection,
        cause: LiveActivitySyncCause,
        event: PrivateLiveActivityEvent,
        serverId: String,
        bootEpoch: UInt64,
        activityGeneration: UInt64,
        stateRevision: UInt64,
        now: Date
    ) -> LiveActivitySyncDelivery {
        let phase: PrivateLiveActivityProjectionPhase
        if projection.activeRunCount > 0 {
            phase = .running
        } else if case .finished(.completed) = cause {
            phase = .completed
        } else {
            phase = .failed
        }
        let count = projection.activeRunCount
        let primaryThreadId = count == 1
            ? projection.runs.first?.threadId.value.uuidString
            : nil
        let sessionId = "\(serverId):\(bootEpoch):\(activityGeneration)"
        // Text-only multi overview for push-to-device when iOS is not connected.
        // Single-run keeps a short status; multi uses count as the headline so
        // the Lock Screen card matches the iOS aggregate copy shape.
        let title: String
        let statusLine: String
        let preview: String
        if count <= 0 {
            title = "RemoteCode"
            statusLine = phase == .completed ? "Finished" : "Failed"
            preview = "RemoteCode"
        } else if count == 1 {
            title = "RemoteCode"
            statusLine = "1 active run"
            preview = "RemoteCode"
        } else {
            title = "\(count) active runs"
            statusLine = "\(count) active runs"
            preview = "\(count) agents running"
        }
        let contentState = PrivateLiveActivityProjectionV2(
            title: title,
            statusLine: statusLine,
            preview: preview,
            phase: phase,
            activeThreadCount: count,
            updatedAt: Double(Int64(now.timeIntervalSince1970)),
            threadId: primaryThreadId,
            sessionId: sessionId,
            hostId: serverId,
            epoch: String(bootEpoch),
            revision: Int64(stateRevision)
        )
        let key = "activity.\(serverId).\(bootEpoch).\(activityGeneration).\(stateRevision).\(event.rawValue)"
        return LiveActivitySyncDelivery(
            event: event,
            projection: contentState,
            activityGeneration: activityGeneration,
            idempotencyKey: key
        )
    }
}
