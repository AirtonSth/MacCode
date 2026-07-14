import Foundation
import CoreModel
import Persistence
import os

public struct PrivateAccountUser: Codable, Equatable, Sendable {
    // Backend spelling: the API ships a misspelled `daysRemaing` key alongside
    // the correct `daysRemaining`. Keep this property name exactly as-is — it
    // must match the wire format until the backend is renamed.
    public let daysRemaing: Int?
    public let daysRemaining: Int
    public let email: String
    public let id: String
    public let subscribed: Bool
}

public struct PrivateAccountSession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let user: PrivateAccountUser
}

public struct PrivateSubscriptionSnapshot: Codable, Equatable, Sendable {
    public let daysRemaing: Int?
    public let daysRemaining: Int
    public let email: String
    public let endsAt: String?
    public let portalUrl: String?
    public let renewsAt: String?
    public let status: String
    public let subscribed: Bool
    public let trialEndsAt: String?
}

public struct PrivateBillingOverview: Codable, Equatable, Sendable {
    public struct Plan: Codable, Equatable, Sendable {
        public let billingPeriod: String
        public let priceUsd: Double
        public let provider: String
        public let trialDays: Int
    }

    public let plan: Plan
    public let subscription: PrivateSubscriptionSnapshot
}

public struct PrivatePushDeliveryResult: Codable, Equatable, Sendable {
    public let delivered: Bool
    public let errorCode: String?
    public let shouldDropSubscription: Bool
}

// MARK: - Live Activity push content-state contract (host <-> iOS)
//
// CONTRACT PIN: an APNs Live Activity push carries a `content-state` dictionary
// that the iOS ActivityKit runtime decodes DIRECTLY into the on-device
// `RemoteCodeActivityAttributes.ContentState` via that struct's synthesized
// `Codable`. The keys below MUST therefore match that struct's stored-property
// names exactly (title, statusLine, preview, phase, activeThreadCount,
// updatedAt, runStartDate?, workspaceId?, threadId?). `phase` is the raw
// ThreadLiveActivityPhase string ("running" / "completed" / "failed"). This is
// the single schema both platforms agree on; the older chatId/chatTitle/
// elapsedSeconds shape (T025) is retired in favour of this one.
public struct PrivateLiveActivityContentState: Codable, Equatable, Sendable {
    public let title: String
    public let statusLine: String
    public let preview: String
    /// "running" | "completed" | "failed" -- the ThreadLiveActivityPhase raw value.
    public let phase: String
    public let activeThreadCount: Int
    /// Seconds since 1970 (UNIX epoch) so JS/native backends and the iOS decode
    /// agree on a single absolute time base regardless of JSONEncoder defaults.
    public let updatedAt: Double
    /// Run start (seconds since 1970) when a single thread is active; nil otherwise.
    public let runStartDate: Double?
    public let workspaceId: String?
    public let threadId: String?

    public init(
        title: String,
        statusLine: String,
        preview: String,
        phase: String,
        activeThreadCount: Int,
        updatedAt: Double,
        runStartDate: Double? = nil,
        workspaceId: String? = nil,
        threadId: String? = nil
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
    }
}

/// Host-side equivalent of the iOS `ThreadLiveActivitySnapshot`: the minimal,
/// pure input the host has at a run-lifecycle boundary, from which the
/// Live Activity push payload (`PrivateLiveActivityContentState`) is built.
public struct PrivateLiveActivitySnapshot: Equatable, Sendable {
    public let title: String
    public let statusLine: String
    public let preview: String
    public let phase: String
    public let activeThreadCount: Int
    public let updatedAt: Date
    public let runStartDate: Date?
    public let workspaceId: String?
    public let threadId: String?

    public init(
        title: String,
        statusLine: String,
        preview: String,
        phase: String,
        activeThreadCount: Int,
        updatedAt: Date,
        runStartDate: Date? = nil,
        workspaceId: String? = nil,
        threadId: String? = nil
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
    }

    /// Pure payload builder (the host-side seam unit-tested in isolation):
    /// projects this snapshot into the wire content-state both platforms decode.
    public func contentState() -> PrivateLiveActivityContentState {
        PrivateLiveActivityContentState(
            title: title,
            statusLine: statusLine,
            preview: preview,
            phase: phase,
            activeThreadCount: activeThreadCount,
            updatedAt: updatedAt.timeIntervalSince1970,
            runStartDate: runStartDate?.timeIntervalSince1970,
            workspaceId: workspaceId,
            threadId: threadId
        )
    }

    /// Builds a mid-run "running" snapshot for a Live Activity `.update` heartbeat.
    /// Extracted (like `terminal`) so the title fallback, preview selection and
    /// 140-char clamp are unit-testable without driving the coordinator. `finalMessage`
    /// is the latest assistant turn text, shown as the card preview when present.
    public static func running(
        threadId: String,
        workspaceId: String?,
        title: String?,
        finalMessage: String?,
        runStartDate: Date?,
        now: Date = Date()
    ) -> PrivateLiveActivitySnapshot {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (normalizedTitle?.isEmpty == false) ? normalizedTitle! : "Thread"
        let finalText = finalMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (finalText?.isEmpty == false) ? String(finalText!.prefix(140)) : displayTitle
        return PrivateLiveActivitySnapshot(
            title: displayTitle,
            statusLine: "Working…",
            preview: preview,
            phase: "running",
            activeThreadCount: 1,
            updatedAt: now,
            runStartDate: runStartDate,
            workspaceId: workspaceId,
            threadId: threadId
        )
    }

    /// Maps a terminal `AgentRunStatus` to a running/terminal Live Activity
    /// snapshot, reusing the same English copy the alert path ships. Returns nil
    /// for non-terminal phases (pending/running) so only real lifecycle ends
    /// fire a terminal Live Activity push.
    public static func terminal(
        threadId: String,
        title: String?,
        phase: AgentRunStatus,
        now: Date = Date()
    ) -> PrivateLiveActivitySnapshot? {
        let normalizedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = (normalizedTitle?.isEmpty == false) ? normalizedTitle! : "Thread"
        let mappedPhase: String
        let statusLine: String
        let previewSuffix: String
        switch phase {
        case .completed:
            mappedPhase = "completed"
            statusLine = "Finished"
            previewSuffix = "response is ready."
        case .cancelled:
            mappedPhase = "failed"
            statusLine = "Stopped"
            previewSuffix = "was stopped."
        case .interrupted:
            mappedPhase = "failed"
            statusLine = "Interrupted"
            previewSuffix = "was interrupted."
        case .failed:
            mappedPhase = "failed"
            statusLine = "Failed"
            previewSuffix = "ended with an error."
        case .pending, .running:
            return nil
        }
        return PrivateLiveActivitySnapshot(
            title: displayTitle,
            statusLine: statusLine,
            preview: "\(displayTitle) \(previewSuffix)",
            phase: mappedPhase,
            activeThreadCount: 0,
            updatedAt: now,
            workspaceId: nil,
            threadId: threadId
        )
    }
}

/// Idempotency-key namespace for Live Activity pushes, parallel to the
/// `thread.<id>.<outcome>` keys the alert path uses. Kept distinct so a Live
/// Activity update and an alert for the same run never collide on the backend.
public enum PrivateLiveActivityEvent: String, Codable, Equatable, Sendable {
    case start
    case update
    case end
}

struct PrivateLiveActivityDeliveryRequestBody<ContentState: Encodable>: Encodable {
    let contentState: ContentState
    let event: String
    let liveActivityToken: String
    let pushToken: String
    let pushTokenType: String
    let timestampSeconds: Int64
}

public enum PrivateLiveActivityV2TokenKind: String, Codable, Equatable, Sendable {
    case pushToStart
    case update
}

public struct PrivateLiveActivityV2TokenRegistration: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let activityKey: String
    public let deviceId: String
    public let environment: PrivatePushEnvironment
    public let token: String
    public let tokenKind: PrivateLiveActivityV2TokenKind
    public let hostId: String?
    public let bootEpoch: UInt64?
    public let activityGeneration: UInt64?
    public let activitySessionId: String?
    public let activityId: String?

    public init(
        protocolVersion: Int = 2,
        activityKey: String = "active-threads",
        deviceId: String,
        environment: PrivatePushEnvironment,
        token: String,
        tokenKind: PrivateLiveActivityV2TokenKind,
        hostId: String? = nil,
        bootEpoch: UInt64? = nil,
        activityGeneration: UInt64? = nil,
        activitySessionId: String? = nil,
        activityId: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.activityKey = activityKey
        self.deviceId = deviceId
        self.environment = environment
        self.token = token
        self.tokenKind = tokenKind
        self.hostId = hostId
        self.bootEpoch = bootEpoch
        self.activityGeneration = activityGeneration
        self.activitySessionId = activitySessionId
        self.activityId = activityId
    }
}

public struct LiveActivityTokenOwnership: Codable, Equatable, Hashable, Sendable {
    public let activityId: String
    public let hostId: String
    public let bootEpoch: UInt64
    public let activityGeneration: UInt64
    public let activitySessionId: String

    public init(activityId: String, hostId: String, bootEpoch: UInt64, activityGeneration: UInt64, activitySessionId: String) {
        self.activityId = activityId
        self.hostId = hostId
        self.bootEpoch = bootEpoch
        self.activityGeneration = activityGeneration
        self.activitySessionId = activitySessionId
    }
}

public struct PrivateLiveActivityV2TokenRegistrationAck: Codable, Equatable, Sendable {
    public struct Token: Codable, Equatable, Sendable {
        public let activityKey: String
        public let deviceId: String
        public let environment: PrivatePushEnvironment
        public let tokenKind: PrivateLiveActivityV2TokenKind
        public let hostId: String?
        public let bootEpoch: UInt64?
        public let activityGeneration: UInt64?
        public let activitySessionId: String?
        public let activityId: String?

        public var ownership: LiveActivityTokenOwnership? {
            guard let activityId, let hostId, let bootEpoch, let activityGeneration, let activitySessionId else { return nil }
            return LiveActivityTokenOwnership(
                activityId: activityId, hostId: hostId, bootEpoch: bootEpoch,
                activityGeneration: activityGeneration, activitySessionId: activitySessionId
            )
        }
    }

    public let token: Token
}

/// Flat backend v2 request. This is the single adapter between the internal
/// host projection and `/live-activities/deliver`; ActivityKit content-state
/// nesting remains a backend responsibility.
public struct PrivateLiveActivityV2DeliveryRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let activityKey: String
    public let activitySessionId: String
    public let hostId: String
    public let bootEpoch: UInt64
    public let activityGeneration: UInt64
    public let revision: Int64
    public let event: PrivateLiveActivityEvent
    public let deviceId: String
    public let environment: PrivatePushEnvironment
    public let phase: PrivateLiveActivityProjectionPhase
    public let activeThreadCount: Int
    public let title: String
    public let statusLine: String
    public let preview: String
    public let updatedAtEpochSeconds: Int64
    public let runStartEpochSeconds: Int64?
    public let workspaceId: String?
    public let threadId: String?

    public init(delivery: LiveActivitySyncDelivery, target: PrivatePushTargetRecord) {
        protocolVersion = 2
        activityKey = "active-threads"
        activitySessionId = delivery.projection.sessionId
        hostId = delivery.projection.hostId
        bootEpoch = UInt64(delivery.projection.epoch) ?? 0
        activityGeneration = delivery.activityGeneration
        revision = delivery.projection.revision
        event = delivery.event
        deviceId = target.deviceId
        environment = target.environment
        phase = delivery.projection.phase
        activeThreadCount = delivery.projection.activeThreadCount
        title = delivery.projection.title
        statusLine = delivery.projection.statusLine
        preview = delivery.projection.preview
        updatedAtEpochSeconds = Int64(delivery.projection.updatedAt)
        runStartEpochSeconds = delivery.projection.runStartDate.map(Int64.init)
        workspaceId = delivery.projection.workspaceId
        threadId = delivery.projection.threadId
    }
}

public protocol PrivateAccountAPI: Sendable {
    func login(email: String, password: String) async throws -> PrivateAccountSession
    func currentUser(accessToken: String) async throws -> PrivateAccountUser
    func refresh(refreshToken: String) async throws -> PrivateAccountSession
    func logout(refreshToken: String) async throws
    func billingOverview(accessToken: String) async throws -> PrivateBillingOverview
    func createPortal(accessToken: String) async throws -> URL
    func deliverAlert(accessToken: String, title: String, body: String, data: [String: String], pushToken: String, pushTokenType: String, idempotencyKey: String) async throws -> PrivatePushDeliveryResult
    func deliverLiveActivity(accessToken: String, event: String, contentState: PrivateLiveActivityContentState, timestampSeconds: Int64, liveActivityToken: String, pushToken: String, pushTokenType: String, idempotencyKey: String) async throws -> PrivatePushDeliveryResult
    func registerLiveActivityTokenV2(accessToken: String, registration: PrivateLiveActivityV2TokenRegistration) async throws -> PrivateLiveActivityV2TokenRegistrationAck
    func deliverLiveActivityV2(accessToken: String, request: PrivateLiveActivityV2DeliveryRequest, idempotencyKey: String) async throws -> PrivateLiveActivityV2DeliveryAck
}

public extension PrivateAccountAPI {
    func registerLiveActivityTokenV2(
        accessToken: String,
        registration: PrivateLiveActivityV2TokenRegistration
    ) async throws -> PrivateLiveActivityV2TokenRegistrationAck {
        throw PrivateAccountAPIError.invalidResponse
    }

    func deliverLiveActivityV2(
        accessToken: String,
        request: PrivateLiveActivityV2DeliveryRequest,
        idempotencyKey: String
    ) async throws -> PrivateLiveActivityV2DeliveryAck {
        throw PrivateAccountAPIError.invalidResponse
    }
}

public enum PrivateAccountAPIError: Error, Equatable {
    case invalidResponse
    case http(Int)
}

public final class URLSessionPrivateAccountAPI: PrivateAccountAPI, @unchecked Sendable {
    static let liveActivityV2DeliveryPath = "/v1/private/push-notification/live-activities/deliver"
    static let liveActivityV2TokensPath = "/v1/private/push-notification/live-activities/tokens"

    private let baseURL: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(baseURL: URL = URL(string: "https://private.remotecode.io")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func login(email: String, password: String) async throws -> PrivateAccountSession {
        struct Body: Encodable { let email: String; let password: String }
        return try await request(path: "/v1/private/auth/login", method: "POST", body: Body(email: email, password: password))
    }

    public func currentUser(accessToken: String) async throws -> PrivateAccountUser {
        struct Response: Decodable { let user: PrivateAccountUser }
        let response: Response = try await request(path: "/v1/private/me", method: "GET", accessToken: accessToken)
        return response.user
    }

    public func refresh(refreshToken: String) async throws -> PrivateAccountSession {
        struct Body: Encodable { let refreshToken: String }
        return try await request(path: "/v1/private/auth/refresh", method: "POST", body: Body(refreshToken: refreshToken))
    }

    public func logout(refreshToken: String) async throws {
        struct Body: Encodable { let refreshToken: String }
        try await requestEmpty(path: "/v1/private/auth/logout", method: "POST", body: Body(refreshToken: refreshToken))
    }

    public func billingOverview(accessToken: String) async throws -> PrivateBillingOverview {
        struct Response: Decodable { let billing: PrivateBillingOverview }
        let response: Response = try await request(path: "/v1/private/billing", method: "GET", accessToken: accessToken)
        return response.billing
    }

    public func createPortal(accessToken: String) async throws -> URL {
        struct Response: Decodable { let portalUrl: URL }
        let response: Response = try await request(path: "/v1/private/billing/portal", method: "POST", accessToken: accessToken)
        return response.portalUrl
    }

    public func deliverAlert(accessToken: String, title: String, body: String, data: [String: String], pushToken: String, pushTokenType: String, idempotencyKey: String) async throws -> PrivatePushDeliveryResult {
        struct Body: Encodable {
            let body: String
            let data: [String: String]?
            let pushToken: String
            let pushTokenType: String
            let title: String
        }
        return try await request(
            path: "/v1/private/push-notification/alert",
            method: "POST",
            accessToken: accessToken,
            body: Body(
                body: body,
                data: data.isEmpty ? nil : data,
                pushToken: pushToken,
                pushTokenType: pushTokenType,
                title: title
            ),
            idempotencyKey: idempotencyKey
        )
    }

    public func deliverLiveActivity(
        accessToken: String,
        event: String,
        contentState: PrivateLiveActivityContentState,
        timestampSeconds: Int64,
        liveActivityToken: String,
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String
    ) async throws -> PrivatePushDeliveryResult {
        return try await request(
            path: "/v1/private/push-notification/deliver",
            method: "POST",
            accessToken: accessToken,
            body: PrivateLiveActivityDeliveryRequestBody(
                contentState: contentState,
                event: event,
                liveActivityToken: liveActivityToken,
                pushToken: pushToken,
                pushTokenType: pushTokenType,
                timestampSeconds: timestampSeconds
            ),
            idempotencyKey: idempotencyKey
        )
    }

    public func deliverLiveActivityV2(
        accessToken: String,
        request deliveryRequest: PrivateLiveActivityV2DeliveryRequest,
        idempotencyKey: String
    ) async throws -> PrivateLiveActivityV2DeliveryAck {
        try await request(
            path: Self.liveActivityV2DeliveryPath,
            method: "POST",
            accessToken: accessToken,
            body: deliveryRequest,
            idempotencyKey: idempotencyKey
        )
    }

    public func registerLiveActivityTokenV2(
        accessToken: String,
        registration: PrivateLiveActivityV2TokenRegistration
    ) async throws -> PrivateLiveActivityV2TokenRegistrationAck {
        try await request(
            path: Self.liveActivityV2TokensPath,
            method: "POST",
            accessToken: accessToken,
            body: registration
        )
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        accessToken: String? = nil,
        body: (any Encodable)? = nil,
        idempotencyKey: String? = nil
    ) async throws -> Response {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let idempotencyKey {
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrivateAccountAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PrivateAccountAPIError.http(http.statusCode) }
        return try decoder.decode(Response.self, from: data)
    }

    private func requestEmpty(
        path: String,
        method: String,
        accessToken: String? = nil,
        body: (any Encodable)? = nil
    ) async throws {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(AnyEncodable(body))
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PrivateAccountAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw PrivateAccountAPIError.http(http.statusCode) }
    }
}

public final class PrivateAccountSessionStore: @unchecked Sendable {
    private let repo: SettingsRepository
    private let key = "private.account.session"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(repo: SettingsRepository) {
        self.repo = repo
    }

    public func load() -> PrivateAccountSession? {
        guard let json = try? repo.get(key),
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(PrivateAccountSession.self, from: data)
    }

    public func save(_ session: PrivateAccountSession) {
        guard let data = try? encoder.encode(session),
              let json = String(data: data, encoding: .utf8) else { return }
        try? repo.set(key, json)
    }

    public func clear() {
        try? repo.set(key, "")
    }
}

public struct PrivatePushTarget: Codable, Equatable, Sendable {
    public let deviceId: String?
    public let liveActivityToken: String?
    public let pushToken: String
    public let pushTokenType: String
    public let updatedAt: Date
}

public enum PrivatePushTokenPurpose: String, Codable, Equatable, Sendable {
    case alert
    case pushToStart = "push_to_start"
    case activityUpdate = "activity_update"
}

public enum PrivatePushEnvironment: String, Codable, Equatable, Sendable {
    case sandbox
    case production
}

public struct PrivatePushTargetRecord: Codable, Equatable, Sendable {
    public let deviceId: String
    public let serverId: String
    public let purpose: PrivatePushTokenPurpose
    public let environment: PrivatePushEnvironment
    public let token: String
    public let activityGeneration: UInt64?
    public let activityId: String?
    public let bootEpoch: UInt64?
    public let activitySessionId: String?
    public let contractVersion: Int
    public let capabilities: [String]?
    public let updatedAt: Date

    public init(
        deviceId: String,
        serverId: String,
        purpose: PrivatePushTokenPurpose,
        environment: PrivatePushEnvironment,
        token: String,
        activityGeneration: UInt64? = nil,
        activityId: String? = nil,
        bootEpoch: UInt64? = nil,
        activitySessionId: String? = nil,
        contractVersion: Int = 1,
        capabilities: [String]? = nil,
        updatedAt: Date = Date()
    ) {
        self.deviceId = deviceId
        self.serverId = serverId
        self.purpose = purpose
        self.environment = environment
        self.token = token
        self.activityGeneration = activityGeneration
        self.activityId = activityId
        self.bootEpoch = bootEpoch
        self.activitySessionId = activitySessionId
        self.contractVersion = contractVersion
        self.capabilities = capabilities
        self.updatedAt = updatedAt
    }

    public var supportsLiveActivityV2: Bool {
        contractVersion >= 2 && (capabilities ?? []).contains("live_activity_v2")
    }

    public var ownership: LiveActivityTokenOwnership? {
        guard purpose == .activityUpdate,
              let activityId,
              let bootEpoch,
              let activityGeneration,
              let activitySessionId else { return nil }
        return LiveActivityTokenOwnership(
            activityId: activityId,
            hostId: serverId,
            bootEpoch: bootEpoch,
            activityGeneration: activityGeneration,
            activitySessionId: activitySessionId
        )
    }

    public func bound(to ownership: LiveActivityTokenOwnership) -> PrivatePushTargetRecord {
        PrivatePushTargetRecord(
            deviceId: deviceId,
            serverId: ownership.hostId,
            purpose: purpose,
            environment: environment,
            token: token,
            activityGeneration: ownership.activityGeneration,
            activityId: ownership.activityId,
            bootEpoch: ownership.bootEpoch,
            activitySessionId: ownership.activitySessionId,
            contractVersion: contractVersion,
            capabilities: capabilities,
            updatedAt: updatedAt
        )
    }
}

public final class PrivatePushTargetStore: @unchecked Sendable {
    private let repo: SettingsRepository
    private let key = "private.push.target"
    private let recordsKey = "private.push.targets.v2"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    public init(repo: SettingsRepository) {
        self.repo = repo
    }

    public func load() -> PrivatePushTarget? {
        guard let json = try? repo.get(key),
              let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(PrivatePushTarget.self, from: data)
    }

    public func save(pushToken: String, pushTokenType: String, liveActivityToken: String?, deviceId: String?) {
        let target = PrivatePushTarget(
            deviceId: deviceId,
            liveActivityToken: liveActivityToken,
            pushToken: pushToken,
            pushTokenType: pushTokenType,
            updatedAt: Date()
        )
        guard let data = try? encoder.encode(target),
              let json = String(data: data, encoding: .utf8) else { return }
        try? repo.set(key, json)
    }

    public func clear() {
        try? repo.set(key, "")
    }

    public func records() throws -> [PrivatePushTargetRecord] {
        try lock.withLock { try loadRecordsUnlocked() }
    }

    public func upsert(_ record: PrivatePushTargetRecord) throws {
        try lock.withLock {
            var values = try loadRecordsUnlocked()
            values.removeAll { Self.sameIdentity($0, record) }
            values.append(record)
            try saveRecordsUnlocked(values)
        }
    }

    public func invalidate(
        deviceId: String,
        serverId: String,
        purpose: PrivatePushTokenPurpose,
        environment: PrivatePushEnvironment,
        activityGeneration: UInt64? = nil,
        activityId: String? = nil
    ) throws {
        try lock.withLock {
            var values = try loadRecordsUnlocked()
            values.removeAll {
                $0.deviceId == deviceId &&
                $0.serverId == serverId &&
                $0.purpose == purpose &&
                $0.environment == environment &&
                $0.activityGeneration == activityGeneration &&
                $0.activityId == activityId
            }
            try saveRecordsUnlocked(values)
        }
    }

    private func loadRecordsUnlocked() throws -> [PrivatePushTargetRecord] {
        guard let json = try repo.get(recordsKey),
              let data = json.data(using: .utf8),
              !data.isEmpty else { return [] }
        return try decoder.decode([PrivatePushTargetRecord].self, from: data)
    }

    private func saveRecordsUnlocked(_ records: [PrivatePushTargetRecord]) throws {
        let data = try encoder.encode(records)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try repo.set(recordsKey, json)
    }

    private static func sameIdentity(_ lhs: PrivatePushTargetRecord, _ rhs: PrivatePushTargetRecord) -> Bool {
        lhs.deviceId == rhs.deviceId &&
        lhs.serverId == rhs.serverId &&
        lhs.purpose == rhs.purpose &&
        lhs.environment == rhs.environment &&
        lhs.activityGeneration == rhs.activityGeneration &&
        lhs.activityId == rhs.activityId &&
        lhs.bootEpoch == rhs.bootEpoch &&
        lhs.activitySessionId == rhs.activitySessionId
    }
}

private actor PrivatePushSessionRefresher {
    private let accountStore: PrivateAccountSessionStore
    private let api: PrivateAccountAPI
    private var refreshTask: Task<PrivateAccountSession, Error>?

    init(accountStore: PrivateAccountSessionStore, api: PrivateAccountAPI) {
        self.accountStore = accountStore
        self.api = api
    }

    func perform<Response: Sendable>(
        session fallbackSession: PrivateAccountSession,
        operation: @escaping @Sendable (String) async throws -> Response
    ) async throws -> Response {
        let session = accountStore.load() ?? fallbackSession
        do {
            return try await operation(session.accessToken)
        } catch let error as PrivateAccountAPIError where error == .http(401) {
            let refreshed = try await refreshedSession(replacing: session)
            do {
                return try await operation(refreshed.accessToken)
            } catch let retryError as PrivateAccountAPIError where retryError == .http(401) {
                accountStore.clear()
                throw retryError
            }
        }
    }

    private func refreshedSession(
        replacing staleSession: PrivateAccountSession
    ) async throws -> PrivateAccountSession {
        if let current = accountStore.load(), current.accessToken != staleSession.accessToken {
            return current
        }
        if let refreshTask {
            return try await refreshTask.value
        }

        let api = self.api
        let refreshToken = staleSession.refreshToken
        let task = Task {
            try await api.refresh(refreshToken: refreshToken)
        }
        refreshTask = task
        do {
            let session = try await task.value
            accountStore.save(session)
            refreshTask = nil
            return session
        } catch {
            refreshTask = nil
            accountStore.clear()
            throw error
        }
    }
}

public final class PrivateNotificationBridge: @unchecked Sendable {
    private static let log = Logger(subsystem: "io.remotecode.app", category: "private-push")
    private let accountStore: PrivateAccountSessionStore
    private let pushTargetStore: PrivatePushTargetStore
    private let api: PrivateAccountAPI
    private let sessionRefresher: PrivatePushSessionRefresher

    public init(accountStore: PrivateAccountSessionStore, pushTargetStore: PrivatePushTargetStore, api: PrivateAccountAPI = URLSessionPrivateAccountAPI()) {
        self.accountStore = accountStore
        self.pushTargetStore = pushTargetStore
        self.api = api
        self.sessionRefresher = PrivatePushSessionRefresher(accountStore: accountStore, api: api)
    }

    public func deliver(_ content: RemoteCodeNotificationContent) async {
        guard let session = accountStore.load(), session.user.subscribed,
              let target = pushTargetStore.load() else { return }
        do {
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverAlert(
                    accessToken: accessToken,
                    title: content.title,
                    body: content.body,
                    // Carry routing keys so a remote alert opens the exact thread.
                    data: content.userInfo,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: content.identifier
                )
            }
            if result.shouldDropSubscription {
                pushTargetStore.clear()
            }
        } catch {
            Self.log.error("Private push delivery failed: \(String(describing: error), privacy: .public)")
            return
        }
    }

    /// Delivers a Live Activity content-state push for a run-lifecycle boundary,
    /// mirroring `deliver(_:)`. Requires the paired iOS device to have registered
    /// a `liveActivityToken` (start-token) via `privatePushTokenUpdate`; without
    /// one there is no activity to address, so the push is skipped. The
    /// `idempotencyKey` namespaces the event (start/update/end) so a Live Activity
    /// push never collides with the alert for the same run.
    public func deliverLiveActivity(
        snapshot: PrivateLiveActivitySnapshot,
        event: PrivateLiveActivityEvent,
        idempotencyKey: String
    ) async {
        guard let session = accountStore.load(), session.user.subscribed,
              let target = pushTargetStore.load(),
              let liveActivityToken = target.liveActivityToken,
              !liveActivityToken.isEmpty else { return }
        do {
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverLiveActivity(
                    accessToken: accessToken,
                    event: event.rawValue,
                    contentState: snapshot.contentState(),
                    timestampSeconds: Int64(snapshot.updatedAt.timeIntervalSince1970),
                    liveActivityToken: liveActivityToken,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: idempotencyKey
                )
            }
            if result.shouldDropSubscription {
                pushTargetStore.clear()
            }
        } catch {
            Self.log.error("Private live-activity delivery failed: \(String(describing: error), privacy: .public)")
            return
        }
    }

    public func registerLiveActivityTokenV2(_ target: PrivatePushTargetRecord) async throws {
        guard target.supportsLiveActivityV2,
              let session = accountStore.load(),
              session.user.subscribed else { throw PrivateAccountAPIError.invalidResponse }

        let tokenKind: PrivateLiveActivityV2TokenKind
        switch target.purpose {
        case .pushToStart:
            tokenKind = .pushToStart
        case .activityUpdate:
            guard target.ownership != nil else { throw LiveActivityTokenBindingError.unknownAuthoritativeScope }
            tokenKind = .update
        case .alert:
            throw PrivateAccountAPIError.invalidResponse
        }

        let ack = try await sessionRefresher.perform(session: session) { accessToken in
            try await self.api.registerLiveActivityTokenV2(
                accessToken: accessToken,
                registration: PrivateLiveActivityV2TokenRegistration(
                    deviceId: target.deviceId,
                    environment: target.environment,
                    token: target.token,
                    tokenKind: tokenKind,
                    hostId: target.ownership?.hostId,
                    bootEpoch: target.ownership?.bootEpoch,
                    activityGeneration: target.ownership?.activityGeneration,
                    activitySessionId: target.ownership?.activitySessionId,
                    activityId: target.ownership?.activityId
                )
            )
        }
        if tokenKind == .update, ack.token.ownership != target.ownership {
            throw PrivateAccountAPIError.invalidResponse
        }
    }


    /// Compatibility wrapper for callers outside the durable acceptance outbox.
    public func deliverLiveActivity(_ delivery: LiveActivitySyncDelivery) async {
        do {
            for target in try acceptanceTargets(for: delivery) {
                let record = LiveActivityAcceptanceRecord(delivery: delivery, target: target)
                _ = try await sendLiveActivityAcceptance(record)
            }
        } catch {
            Self.log.error("Private live-activity acceptance failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends one durable acceptance record. V2 returns an outbox acknowledgement;
    /// legacy clients keep their existing immediate-delivery wire contract.
    public func acceptanceTargets(
        for delivery: LiveActivitySyncDelivery
    ) throws -> [LiveActivityAcceptanceTarget] {
        let records = try pushTargetStore.records()
        let purpose: PrivatePushTokenPurpose = delivery.event == .start ? .pushToStart : .activityUpdate
        let scopedRecords = records.filter {
            guard $0.supportsLiveActivityV2,
                  $0.purpose == purpose,
                  $0.serverId == delivery.projection.hostId else { return false }
            return true
        }
        let targets = scopedRecords.filter {
            if purpose == .pushToStart { return true }
            guard let ownership = $0.ownership else { return false }
            return ownership.bootEpoch == UInt64(delivery.projection.epoch) &&
                ownership.activityGeneration == delivery.activityGeneration &&
                ownership.activitySessionId == delivery.projection.sessionId
        }
        if !targets.isEmpty { return targets.map(LiveActivityAcceptanceTarget.v2) }
        guard scopedRecords.isEmpty else {
            throw LiveActivityTokenBindingError.unknownAuthoritativeScope
        }
        guard let legacy = pushTargetStore.load(),
              let token = legacy.liveActivityToken,
              !token.isEmpty else { throw PrivateAccountAPIError.invalidResponse }
        return [.legacy(legacy)]
    }

    public func sendLiveActivityAcceptance(
        _ record: LiveActivityAcceptanceRecord
    ) async throws -> PrivateLiveActivityV2DeliveryAck {
        let delivery = record.delivery
        guard let session = accountStore.load(), session.user.subscribed else {
            throw PrivateAccountAPIError.http(401)
        }
        switch record.target {
        case .legacy(let target):
            let legacyState = delivery.projection.legacyContentState
            guard let liveActivityToken = target.liveActivityToken, !liveActivityToken.isEmpty else {
                throw PrivateAccountAPIError.invalidResponse
            }
            let result = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverLiveActivity(
                    accessToken: accessToken,
                    event: delivery.event.rawValue,
                    contentState: legacyState,
                    timestampSeconds: Int64(legacyState.updatedAt),
                    liveActivityToken: liveActivityToken,
                    pushToken: target.pushToken,
                    pushTokenType: target.pushTokenType,
                    idempotencyKey: delivery.idempotencyKey
                )
            }
            if result.shouldDropSubscription { pushTargetStore.clear() }
            guard result.delivered else {
                throw LiveActivityAcceptanceOutboxError.backendDidNotAccept(
                    result.errorCode ?? "legacy_rejected"
                )
            }
            return PrivateLiveActivityV2DeliveryAck(
                id: delivery.idempotencyKey,
                status: "delivered",
                attempts: 1,
                nextAttemptAt: nil
            )
        case .v2(let target):
            let request = PrivateLiveActivityV2DeliveryRequest(delivery: delivery, target: target)
            let ack = try await sessionRefresher.perform(session: session) { accessToken in
                try await self.api.deliverLiveActivityV2(
                    accessToken: accessToken,
                    request: request,
                    idempotencyKey: delivery.idempotencyKey
                )
            }
            guard ack.isAccepted else {
                throw LiveActivityAcceptanceOutboxError.backendDidNotAccept(ack.status)
            }
            return ack
        }
    }
}

private struct AnyEncodable: Encodable {
    private let encodeBody: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encodeBody = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeBody(encoder)
    }
}
