import Foundation

public enum DistillClientError: Error, Sendable, CustomStringConvertible {
    case invalidBaseURL(String)
    case transport(String)
    case badStatus(Int, String)
    case decode(String)

    public var description: String {
        switch self {
        case .invalidBaseURL(let url): return "invalid distill base url \(url)"
        case .transport(let m): return "distill transport error: \(m)"
        case .badStatus(let code, let body): return "distill service returned HTTP \(code): \(body)"
        case .decode(let m): return "distill response decode failed: \(m)"
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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        baseURL: URL,
        authToken: String,
        timeout: TimeInterval = 20,
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
        timeout: TimeInterval = 20
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
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent("v1/distill"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            httpRequest.httpBody = try encoder.encode(request)
        } catch {
            throw DistillClientError.transport("encode request: \(error)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: httpRequest)
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
            return try decoder.decode(DistillResponse.self, from: data)
        } catch {
            throw DistillClientError.decode(String(describing: error))
        }
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
}
