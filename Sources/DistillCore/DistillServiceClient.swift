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
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Explicit request timeout for the optimizer round-trip (item 218). Kept in
    /// the 5-10s band so a slow/hung sidecar never blocks the calling agent's
    /// shell for ~a minute; 8s gives the local model room to answer normal
    /// payloads while still failing fast. Used as the default for both inits and
    /// applied per-request below so the budget holds even if a caller passes a
    /// larger session timeout.
    public static let requestTimeoutSeconds: TimeInterval = 8

    /// Upper bound on bytes we hand to the optimizer (item 218). The optimizer is
    /// a best-effort summarizer, so over-cap input is head/tail truncated for the
    /// wire only -- the caller's original payload is never lost. ~32MB.
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
        var httpRequest = URLRequest(url: baseURL.appendingPathComponent("v1/distill"))
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Enforce the transport budget per-request so the 5-10s cap holds even if
        // the URLSession was configured with a larger timeout (item 218).
        httpRequest.timeoutInterval = Self.requestTimeoutSeconds
        // Cap only the copy sent over the wire. The caller still holds the
        // original `request.input` untouched (value type), so an over-cap payload
        // degrades to best-effort optimization, never data loss.
        let wireRequest = Self.cappedForWire(request)
        do {
            httpRequest.httpBody = try encoder.encode(wireRequest)
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
            return try decoder.decode(DistillResponse.self, from: data)
        } catch {
            throw DistillClientError.decode(String(describing: error))
        }
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

    /// Marker inserted between the preserved head and tail when an over-cap
    /// payload is truncated for the wire. Byte length is bounded and accounted
    /// for in the budget so the result stays <= cap.
    public static let truncationMarker =
        "\n...[distill: input truncated for optimizer; original preserved by caller]...\n"

    /// Pure helper: build the request copy actually sent to the optimizer. Under
    /// cap it is the same request (success path unchanged). Over cap, only the
    /// `input` is head/tail truncated; every other field is preserved.
    nonisolated static func cappedForWire(_ request: DistillRequest) -> DistillRequest {
        let capped = headTailTruncate(request.input, cap: stdinByteCap)
        guard capped != request.input else { return request }
        return DistillRequest(
            id: request.id,
            mode: request.mode,
            priority: request.priority,
            input: capped,
            question: request.question,
            provider: request.provider,
            recordSavings: request.recordSavings ?? false,
            maxOutputCharacters: request.maxOutputCharacters
        )
    }

    /// Pure helper: clamp `input` to at most `cap` UTF-8 bytes, preserving the
    /// head and tail around `truncationMarker`. Returns the input unchanged when
    /// already within budget. Splits only on `Character` boundaries so the result
    /// is always valid UTF-8 and never exceeds `cap` bytes. Stateless and
    /// service-free so it is unit-testable in isolation (item 218).
    nonisolated static func headTailTruncate(_ input: String, cap: Int) -> String {
        let totalBytes = input.utf8.count
        guard totalBytes > cap else { return input }

        let markerBytes = truncationMarker.utf8.count
        // Degenerate cap that cannot even hold the marker: keep a byte-bounded
        // head so the result still never exceeds cap.
        guard cap > markerBytes else {
            return headPrefix(of: input, maxBytes: cap)
        }

        let budget = cap - markerBytes
        let headBudget = budget - budget / 2 // head gets the rounding remainder
        let tailBudget = budget / 2
        let head = headPrefix(of: input, maxBytes: headBudget)
        let tail = tailSuffix(of: input, maxBytes: tailBudget)
        return head + truncationMarker + tail
    }

    /// Longest prefix of `s` whose UTF-8 size is <= `maxBytes`, cut on a
    /// Character boundary so no multibyte scalar is split.
    nonisolated private static func headPrefix(of s: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var used = 0
        var end = s.startIndex
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(after: i)
            let charBytes = String(s[i..<next]).utf8.count
            if used + charBytes > maxBytes { break }
            used += charBytes
            end = next
            i = next
        }
        return String(s[s.startIndex..<end])
    }

    /// Longest suffix of `s` whose UTF-8 size is <= `maxBytes`, cut on a
    /// Character boundary.
    nonisolated private static func tailSuffix(of s: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var used = 0
        var start = s.endIndex
        var i = s.endIndex
        while i > s.startIndex {
            let prev = s.index(before: i)
            let charBytes = String(s[prev..<i]).utf8.count
            if used + charBytes > maxBytes { break }
            used += charBytes
            start = prev
            i = prev
        }
        return String(s[start..<s.endIndex])
    }
}
