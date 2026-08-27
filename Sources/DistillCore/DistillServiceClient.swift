import Foundation

public enum DistillClientError: Error, Sendable, CustomStringConvertible {
    case invalidBaseURL(String)
    case transport(String)
    case badStatus(Int, String)
    case decode(String)
    /// The request exceeded the explicit transport budget (item 218): the local
    /// optimizer did not answer within `DistillServiceClient.requestTimeoutSeconds`.
    /// Surfaced as a distinct case so callers can degrade gracefully and fall
    /// back to the raw, untruncated payload instead of blocking ~a minute.
    case timedOut(TimeInterval)

    public var description: String {
        switch self {
        case .invalidBaseURL(let url): return "invalid distill base url \(url)"
        case .transport(let m): return "distill transport error: \(m)"
        case .badStatus(let code, let body): return "distill service returned HTTP \(code): \(body)"
        case .decode(let m): return "distill response decode failed: \(m)"
        case .timedOut(let s): return "distill request exceeded \(s)s transport budget"
        }
    }
}

/// HTTP client for the local RemoteCodeDistillService. Stateless and
/// concurrency-safe: URLSession serves overlapping `compress(...)` calls in
/// parallel while the service's own bounded scheduler caps real model work, so
/// many threads/agents can share one client. Optimized for the loopback
/// sidecar: ephemeral config, no cookies/cache, short timeouts.
public final class DistillServiceClient: @unchecked Sendable {
    private let baseURL: URL
    private let authToken: String
    private let session: URLSession
    // PERF: distill() used to allocate a sortedKeys JSONEncoder per request for
    // wire body + recovery operation IDs while post()/decode also hit instance
    // codecs without serialization. JSONEncoder/Decoder are not thread-safe —
    // share one sortedKeys encoder + decoder under a short lock (key order is
    // still valid JSON for rank/embed; distill recovery digests stay stable).
    private let codecLock = NSLock()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
    private let decoder = JSONDecoder()

    /// Explicit request timeout for the optimizer round-trip (item 218). Kept in
    /// the 5-10s band so a slow/hung sidecar never blocks the calling agent's
    /// shell for ~a minute; 8s gives the local model room to answer normal
    /// payloads while still failing fast. Used as the default for both inits and
    /// applied per-request below so the budget holds even if a caller passes a
    /// larger session timeout.
    public static let requestTimeoutSeconds: TimeInterval = 8

    /// Upper bound on bytes we hand to the optimizer (item 218). Inputs above
    /// this limit fail open before request construction because a partial wire
    /// copy cannot back a capability that promises the complete original. ~32MB.
    public static let stdinByteCap: Int = 32 * 1024 * 1024

    public init(
        baseURL: URL,
        authToken: String,
        timeout: TimeInterval = DistillServiceClient.requestTimeoutSeconds,
        maxConcurrentConnections: Int = 8
    ) {
        self.baseURL = baseURL
        self.authToken = authToken
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = max(1, maxConcurrentConnections)
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    public convenience init?(
        ready: DistillServiceReadyEvent,
        authToken: String,
        timeout: TimeInterval = DistillServiceClient.requestTimeoutSeconds
    ) {
        guard let url = URL(string: ready.baseURL) else { return nil }
        self.init(
            baseURL: url,
            authToken: authToken,
            timeout: timeout,
            maxConcurrentConnections: max(1, ready.maxConcurrentRequests)
        )
    }

    /// Compress `request` through the local model and return the distilled
    /// output plus measured token deltas. Throws on any non-200 so callers can
    /// fail loud or fall back to the raw text deliberately.
    public func distill(_ request: DistillRequest) async throws -> DistillResponse {
        try await distill(request, recoveryContext: nil)
    }

    /// Scoped store-before-loss transport. Callers provide the five stable runtime
    /// scope fields; an empty operation ID is derived from the exact canonical wire
    /// request so retries are idempotent and distinct calls do not share outbox state.
    public func distill(
        _ request: DistillRequest,
        recoveryContext: TokenSaverRecoveryRequestContext
    ) async throws -> DistillResponse {
        try await distill(request, recoveryContext: Optional(recoveryContext))
    }

    private func distill(
        _ request: DistillRequest,
        recoveryContext: TokenSaverRecoveryRequestContext?
    ) async throws -> DistillResponse {
        guard request.input.utf8.count <= Self.stdinByteCap else {
            let tokens = TokenEstimator.estimate(request.input)
            return DistillResponse(
                requestID: request.id,
                output: request.input,
                inputCharacters: request.input.count,
                inputTokens: tokens,
                outputTokens: tokens,
                originalHandle: nil,
                runMode: request.effectiveRunMode,
                routeStage: .verbatim
            )
        }
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent("v1/distill"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Enforce the transport budget per-request so the 5-10s cap holds even if
        // the URLSession was configured with a larger timeout (item 218).
        httpRequest.timeoutInterval = Self.requestTimeoutSeconds
        let wireRequest = request
        do {
            let body = try encode(wireRequest)
            httpRequest.httpBody = body
            if let recoveryContext {
                recoveryContext.applyIdentityHeaders(to: &httpRequest)
                if recoveryContext.hasCompleteScope {
                    let derivedOperationID = ManagedDistillCLI.recoveryOperationID(kind: "distill", canonicalPayload: body)
                    let operationID = recoveryContext.operationID.isEmpty
                        ? derivedOperationID
                        : recoveryContext.operationID + ":" + derivedOperationID
                    httpRequest.setValue(request.id.uuidString.lowercased(), forHTTPHeaderField: "X-RemoteCode-Invocation-ID")
                    httpRequest.setValue(operationID, forHTTPHeaderField: "X-RemoteCode-Operation-ID")
                }
            }
        } catch {
            throw DistillClientError.transport("encode request: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: httpRequest)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw DistillClientError.timedOut(Self.requestTimeoutSeconds)
        } catch {
            throw DistillClientError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw DistillClientError.transport("non-http response")
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            throw DistillClientError.badStatus(http.statusCode, body)
        }
        do {
            return try decode(DistillResponse.self, from: data)
        } catch {
            throw DistillClientError.decode(String(describing: error))
        }
    }

    public func rank(_ request: DistillRankRequest) async throws -> DistillRankResponse {
        try await post(path: "v1/rank", body: request, responseType: DistillRankResponse.self)
    }

    public func embed(_ request: DistillEmbedRequest) async throws -> DistillEmbedResponse {
        try await post(path: "v1/embed", body: request, responseType: DistillEmbedResponse.self)
    }

    /// Release the underlying URLSession, allowing in-flight requests to
    /// complete before the session is torn down. Call this before discarding
    /// a client so the OS can reclaim socket/thread resources promptly.
    public func invalidate() {
        session.finishTasksAndInvalidate()
    }

    /// Liveness probe against the unauthenticated `/healthz` endpoint.
    public func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("healthz"))
        request.httpMethod = "GET"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else {
            return false
        }
        return http.statusCode == 200
    }

    private func post<Request: Encodable, Response: Decodable>(
        path: String,
        body: Request,
        responseType: Response.Type
    ) async throws -> Response {
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent(path))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.timeoutInterval = Self.requestTimeoutSeconds
        do {
            httpRequest.httpBody = try encode(body)
        } catch {
            throw DistillClientError.transport("encode request: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: httpRequest)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw DistillClientError.timedOut(Self.requestTimeoutSeconds)
        } catch {
            throw DistillClientError.transport(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw DistillClientError.transport("non-http response")
        }
        guard http.statusCode == 200 else {
            let body = String(decoding: data, as: UTF8.self)
            throw DistillClientError.badStatus(http.statusCode, body)
        }
        do {
            return try decode(responseType, from: data)
        } catch {
            throw DistillClientError.decode(String(describing: error))
        }
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        codecLock.lock()
        defer { codecLock.unlock() }
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        codecLock.lock()
        defer { codecLock.unlock() }
        return try decoder.decode(type, from: data)
    }
}
