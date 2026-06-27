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
public enum PrivateLiveActivityEvent: String, Sendable {
    case start
    case update
    case end
}

public protocol PrivateAccountAPI: Sendable {
    func login(email: String, password: String) async throws -> PrivateAccountSession
    func currentUser(accessToken: String) async throws -> PrivateAccountUser
    func refresh(refreshToken: String) async throws -> PrivateAccountSession
    func logout(refreshToken: String) async throws
    func billingOverview(accessToken: String) async throws -> PrivateBillingOverview
    func createPortal(accessToken: String) async throws -> URL
    func deliverAlert(accessToken: String, title: String, body: String, data: [String: String], pushToken: String, pushTokenType: String, idempotencyKey: String) async throws -> PrivatePushDeliveryResult
    func deliverLiveActivity(accessToken: String, event: String, contentState: PrivateLiveActivityContentState, liveActivityToken: String, pushToken: String, pushTokenType: String, idempotencyKey: String) async throws -> PrivatePushDeliveryResult
}

public enum PrivateAccountAPIError: Error, Equatable {
    case invalidResponse
    case http(Int)
}

public final class URLSessionPrivateAccountAPI: PrivateAccountAPI, @unchecked Sendable {
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
        liveActivityToken: String,
        pushToken: String,
        pushTokenType: String,
        idempotencyKey: String
    ) async throws -> PrivatePushDeliveryResult {
        struct Body: Encodable {
            let contentState: PrivateLiveActivityContentState
            let event: String
            let liveActivityToken: String
            let pushToken: String
            let pushTokenType: String
        }
        return try await request(
            path: "/v1/private/push-notification/deliver",
            method: "POST",
            accessToken: accessToken,
            body: Body(
                contentState: contentState,
                event: event,
                liveActivityToken: liveActivityToken,
                pushToken: pushToken,
                pushTokenType: pushTokenType
            ),
            idempotencyKey: idempotencyKey
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

public final class PrivatePushTargetStore: @unchecked Sendable {
    private let repo: SettingsRepository
    private let key = "private.push.target"
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

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
}

public final class PrivateNotificationBridge: @unchecked Sendable {
    private static let log = Logger(subsystem: "io.remotecode.app", category: "private-push")
    private let accountStore: PrivateAccountSessionStore
    private let pushTargetStore: PrivatePushTargetStore
    private let api: PrivateAccountAPI

    public init(accountStore: PrivateAccountSessionStore, pushTargetStore: PrivatePushTargetStore, api: PrivateAccountAPI = URLSessionPrivateAccountAPI()) {
        self.accountStore = accountStore
        self.pushTargetStore = pushTargetStore
        self.api = api
    }

    public func deliver(_ content: RemoteCodeNotificationContent) async {
        guard let session = accountStore.load(), session.user.subscribed,
              let target = pushTargetStore.load() else { return }
        do {
            let result = try await api.deliverAlert(
                accessToken: session.accessToken,
                title: content.title,
                body: content.body,
                // Carry the notification's routing keys (workspaceId/threadId/category)
                // as the push `data` so a tap on the remote alert opens the exact
                // thread, matching the local-notification path's userInfo.
                data: content.userInfo,
                pushToken: target.pushToken,
                pushTokenType: target.pushTokenType,
                idempotencyKey: content.identifier
            )
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
            let result = try await api.deliverLiveActivity(
                accessToken: session.accessToken,
                event: event.rawValue,
                contentState: snapshot.contentState(),
                liveActivityToken: liveActivityToken,
                pushToken: target.pushToken,
                pushTokenType: target.pushTokenType,
                idempotencyKey: idempotencyKey
            )
            if result.shouldDropSubscription {
                pushTargetStore.clear()
            }
        } catch {
            Self.log.error("Private live-activity delivery failed: \(String(describing: error), privacy: .public)")
            return
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
