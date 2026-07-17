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
        /// Pet-surface copy (active ∪ needs-you ∪ completed). Nil ends attention-
        /// only cards; run projection can still keep the activity alive.
        case surface(PetLiveActivityCopy.Output?, Date)
        case heartbeat(Date)
        case flush(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Command>.Continuation
    private let tokenScopeBinder: LiveActivityTokenScopeBinder
    private var worker: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// Keep remote Live Activities under ActivityKit stale budget while runs are
    /// active — even when no turn.completed event arrives for a long stretch.
    public static let heartbeatIntervalNanoseconds: UInt64 = 30_000_000_000

    public init(
        serverId: String,
        bootEpoch: UInt64,
        initialActivityGeneration: UInt64 = 0,
        initialTokenTargets: [PrivatePushTargetRecord] = [],
        registerToken: @escaping TokenRegistration = { _ in },
        onTokenRegistrationError: @escaping TokenRegistrationError = { _, _ in },
        onDeliveryError: @escaping DeliveryError = { _, _ in },
        deliver: @escaping Delivery,
        heartbeatIntervalNanoseconds: UInt64 = LiveActivitySyncCoordinator.heartbeatIntervalNanoseconds
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
            var surface: PetLiveActivityCopy.Output?
            var wasPresent = false
            var activityGeneration = initialActivityGeneration
            var stateRevision: UInt64 = 0

            func presentNow() -> Bool {
                surface != nil || latest.activeRunCount > 0
            }

            func emit(
                event: PrivateLiveActivityEvent,
                cause: LiveActivitySyncCause,
                now: Date
            ) async {
                stateRevision &+= 1
                if event == .start {
                    stateRevision = 1
                }
                let delivery = Self.delivery(
                    projection: latest,
                    surface: surface,
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
            }

            for await command in stream {
                switch command {
                case .registerToken(let target):
                    do {
                        try await registerToken(target)
                    } catch {
                        onTokenRegistrationError(error, target)
                    }
                case .projection(let projection, let cause, let now):
                    latest = projection
                    if cause == .launchReconciliation {
                        surface = nil
                        wasPresent = false
                        activityGeneration &+= 1
                        tokenScopeBinder.recordGeneration(activityGeneration)
                        stateRevision = 0
                        await emit(event: .end, cause: cause, now: now)
                        continue
                    }
                    let nowPresent = presentNow()
                    let event: PrivateLiveActivityEvent
                    if !wasPresent, nowPresent {
                        activityGeneration &+= 1
                        tokenScopeBinder.recordGeneration(activityGeneration)
                        stateRevision = 0
                        event = .start
                    } else if wasPresent, !nowPresent {
                        event = .end
                    } else if nowPresent {
                        event = .update
                    } else {
                        wasPresent = nowPresent
                        continue
                    }
                    wasPresent = nowPresent
                    await emit(event: event, cause: cause, now: now)
                case .surface(let content, let now):
                    surface = content
                    let nowPresent = presentNow()
                    let event: PrivateLiveActivityEvent
                    if !wasPresent, nowPresent {
                        activityGeneration &+= 1
                        tokenScopeBinder.recordGeneration(activityGeneration)
                        stateRevision = 0
                        event = .start
                    } else if wasPresent, !nowPresent {
                        event = .end
                    } else if nowPresent {
                        event = .update
                    } else {
                        wasPresent = nowPresent
                        continue
                    }
                    wasPresent = nowPresent
                    await emit(event: event, cause: .changed, now: now)
                case .heartbeat(let now):
                    guard presentNow() else { continue }
                    await emit(event: .update, cause: .changed, now: now)
                case .flush(let barrier):
                    barrier.resume()
                }
            }
        }
        // Always-on keep-alive while any run is active (idle heartbeats are no-ops).
        self.heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: heartbeatIntervalNanoseconds)
                } catch {
                    break
                }
                self?.submitHeartbeat()
            }
        }
    }

    deinit {
        continuation.finish()
        worker?.cancel()
        heartbeatTask?.cancel()
    }

    public func submit(_ projection: ActiveRunProjection, cause: LiveActivitySyncCause, now: Date = Date()) {
        continuation.yield(.projection(projection, cause, now))
    }

    /// Publish pet-identical Live Activity copy (active + needs-you + completed).
    public func submitSurface(_ content: PetLiveActivityCopy.Output?, now: Date = Date()) {
        continuation.yield(.surface(content, now))
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
        surface: PetLiveActivityCopy.Output?,
        cause: LiveActivitySyncCause,
        event: PrivateLiveActivityEvent,
        serverId: String,
        bootEpoch: UInt64,
        activityGeneration: UInt64,
        stateRevision: UInt64,
        now: Date
    ) -> LiveActivitySyncDelivery {
        let sessionId = "\(serverId):\(bootEpoch):\(activityGeneration)"
        let title: String
        let statusLine: String
        let preview: String
        let phase: PrivateLiveActivityProjectionPhase
        let count: Int
        let threadId: String?
        let workspaceId: String?
        let runStartDate: Double?

        if let surface {
            title = surface.title
            statusLine = surface.statusLine
            preview = surface.preview
            phase = surface.phase
            count = surface.activeThreadCount
            threadId = surface.threadId
            workspaceId = surface.workspaceId
            runStartDate = surface.runStartDate.map { $0.timeIntervalSince1970 }
        } else if projection.activeRunCount > 0 {
            phase = .running
            count = projection.activeRunCount
            threadId = count == 1 ? projection.runs.first?.threadId.value.uuidString : nil
            workspaceId = nil
            runStartDate = nil
            if count == 1 {
                title = "RemoteCode"
                statusLine = "1 active run"
                preview = "RemoteCode"
            } else {
                title = "\(count) active runs"
                statusLine = "\(count) active runs"
                preview = "\(count) agents running"
            }
        } else {
            if case .finished(.completed) = cause {
                phase = .completed
            } else {
                phase = .failed
            }
            count = 0
            threadId = nil
            workspaceId = nil
            runStartDate = nil
            title = "RemoteCode"
            statusLine = phase == .completed ? "Finished" : "Failed"
            preview = "RemoteCode"
        }
        let contentState = PrivateLiveActivityProjectionV2(
            title: title,
            statusLine: statusLine,
            preview: preview,
            phase: phase,
            activeThreadCount: count,
            updatedAt: Double(Int64(now.timeIntervalSince1970)),
            runStartDate: runStartDate,
            workspaceId: workspaceId,
            threadId: threadId,
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
