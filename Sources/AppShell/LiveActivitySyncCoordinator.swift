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

public struct LiveActivitySyncDelivery: Equatable, Sendable {
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

/// One long-lived mailbox serializes lifecycle transitions and network delivery.
/// Callers submit synchronously from coordinator callbacks; no per-event
/// unstructured Task can reorder start/update/end.
public final class LiveActivitySyncCoordinator: @unchecked Sendable {
    public typealias Delivery = @Sendable (LiveActivitySyncDelivery) async -> Void
    public typealias TokenRegistration = @Sendable (PrivatePushTargetRecord) async -> Void

    private enum Command: @unchecked Sendable {
        case registerToken(PrivatePushTargetRecord)
        case projection(ActiveRunProjection, LiveActivitySyncCause, Date)
        case heartbeat(Date)
        case flush(CheckedContinuation<Void, Never>)
    }

    private let continuation: AsyncStream<Command>.Continuation
    private var worker: Task<Void, Never>?

    public init(
        serverId: String,
        bootEpoch: UInt64,
        initialActivityGeneration: UInt64 = 0,
        registerToken: @escaping TokenRegistration = { _ in },
        deliver: @escaping Delivery
    ) {
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
                    await registerToken(target)
                case .projection(let projection, let cause, let now):
                    let previousCount = latest.activeRunCount
                    latest = projection
                    let event: PrivateLiveActivityEvent
                    if cause == .launchReconciliation {
                        event = .end
                    } else if previousCount == 0, projection.activeRunCount > 0 {
                        activityGeneration &+= 1
                        stateRevision = 0
                        event = .start
                    } else if projection.activeRunCount == 0 {
                        event = .end
                    } else {
                        event = .update
                    }
                    stateRevision &+= 1
                    await deliver(Self.delivery(
                        projection: projection,
                        cause: cause,
                        event: event,
                        serverId: serverId,
                        bootEpoch: bootEpoch,
                        activityGeneration: activityGeneration,
                        stateRevision: stateRevision,
                        now: now
                    ))
                case .heartbeat(let now):
                    guard latest.activeRunCount > 0 else { continue }
                    stateRevision &+= 1
                    await deliver(Self.delivery(
                        projection: latest,
                        cause: .changed,
                        event: .update,
                        serverId: serverId,
                        bootEpoch: bootEpoch,
                        activityGeneration: activityGeneration,
                        stateRevision: stateRevision,
                        now: now
                    ))
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

    public func submitTokenRegistration(_ target: PrivatePushTargetRecord) {
        continuation.yield(.registerToken(target))
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
        let primaryThreadId = projection.activeRunCount == 1
            ? projection.runs.first?.threadId.value.uuidString
            : nil
        let sessionId = "\(serverId):\(bootEpoch):\(activityGeneration)"
        let contentState = PrivateLiveActivityProjectionV2(
            statusLine: projection.activeRunCount == 1
                ? "1 active run"
                : "\(projection.activeRunCount) active runs",
            phase: phase,
            activeThreadCount: projection.activeRunCount,
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
