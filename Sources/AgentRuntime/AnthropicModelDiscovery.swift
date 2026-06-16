import Foundation
import CoreModel

// MARK: - Pure helpers (no MainActor; fully testable)

/// Immutable cache entry for model list results.
public struct ModelDiscoveryCacheEntry: Sendable {
    public let models: [AgentModelDescriptor]
    public let fetchedAt: Date

    public init(models: [AgentModelDescriptor], fetchedAt: Date) {
        self.models = models
        self.fetchedAt = fetchedAt
    }

    /// Returns true when `ttl` seconds have NOT elapsed since `fetchedAt`.
    public func isValid(ttl: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(fetchedAt) < ttl
    }
}

/// Builds a URLRequest for the Anthropic models endpoint.
/// OAuth token takes priority; falls back to API key.
public enum AnthropicDiscoveryRequestBuilder {
    public static let defaultTimeoutSeconds: TimeInterval = 10

    /// Returns nil if neither credential is available or the URL is invalid.
    public static func build(
        environment: [String: String],
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds
    ) -> URLRequest? {
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds

        let oauthToken = environment["ANTHROPIC_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let token = oauthToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return request
        }
        if let key = apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            return request
        }
        return nil
    }
}

// MARK: - Discovery result carrying source signal

/// Result of a model-list attempt.
/// `isFallback == true` means no live data was obtained and the static alias
/// list is being used instead. The picker must surface this to the user.
public struct ModelListResult: Sendable {
    public let models: [AgentModelDescriptor]
    /// True when `models` is the static built-in alias list, not a live API response.
    public let isFallback: Bool

    public init(models: [AgentModelDescriptor], isFallback: Bool) {
        self.models = models
        self.isFallback = isFallback
    }
}

// MARK: - Discovery with 1-hour TTL cache

public enum AnthropicModelDiscovery {
    // TTL = 3600 s (1 hour).
    static let cacheTTL: TimeInterval = 3_600
    // Actor-isolated mutable cache; avoids data races under Swift 6 strict concurrency.
    private static let _cache = ModelDiscoveryCache()

    // For testing only: clears the static in-process cache so each test starts clean.
    static func _resetCacheForTesting() async {
        await _cache.reset()
    }

    /// Returns live models or empty on failure. Callers that need the
    /// fallback signal should use `listModelsResult` instead.
    public static func listModels(
        environment: [String: String] = [:],
        session: URLSession = .shared
    ) async -> [AgentModelDescriptor] {
        await listModelsResult(environment: environment, session: session).models
    }

    /// Returns a `ModelListResult` that carries both the model list and an
    /// `isFallback` flag. `isFallback` is true when the live fetch failed
    /// (no credential, network error, non-200) and the static alias list was
    /// substituted; false when live API data was obtained.
    public static func listModelsResult(
        environment: [String: String] = [:],
        session: URLSession = .shared
    ) async -> ModelListResult {
        let env = CodexRunner.processEnvironment(overrides: environment)

        // Cache hit? Cache stores only live data, so a hit is never a fallback.
        if let cached = await _cache.entry, cached.isValid(ttl: cacheTTL) {
            return ModelListResult(models: cached.models, isFallback: false)
        }

        guard let request = AnthropicDiscoveryRequestBuilder.build(environment: env) else {
            return ModelListResult(models: [], isFallback: true)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ModelListResult(models: [], isFallback: true)
            }
            let models = modelDescriptors(fromListResponse: object)
            await _cache.store(ModelDiscoveryCacheEntry(models: models, fetchedAt: Date()))
            return ModelListResult(models: models, isFallback: false)
        } catch {
            return ModelListResult(models: [], isFallback: true)
        }
    }

    /// Forces a fresh live fetch by clearing the cache first, then delegates
    /// to `listModelsResult`. Use this when the user explicitly requests a
    /// refresh from the model picker.
    public static func refresh(
        environment: [String: String] = [:],
        session: URLSession = .shared
    ) async -> ModelListResult {
        await _cache.reset()
        return await listModelsResult(environment: environment, session: session)
    }

    public static func modelDescriptors(fromListResponse response: [String: Any]) -> [AgentModelDescriptor] {
        let rawModels = response["data"] as? [[String: Any]]
            ?? response["models"] as? [[String: Any]]
            ?? []
        return rawModels.compactMap { raw -> AgentModelDescriptor? in
            guard let id = string(raw, "id") ?? string(raw, "model"),
                  id.hasPrefix("claude-") else { return nil }
            let label = string(raw, "display_name") ?? string(raw, "displayName") ?? displayName(for: id)
            return descriptor(id: id, label: label)
        }
    }

    public static func latestAliasModels() -> [AgentModelDescriptor] {
        [
            descriptor(id: "opus", label: "Opus (latest)"),
            descriptor(id: "sonnet", label: "Sonnet (latest)"),
            descriptor(id: "haiku", label: "Haiku (latest)")
        ]
    }

    private static func descriptor(id: String, label: String) -> AgentModelDescriptor {
        let lower = "\(id) \(label)".lowercased()
        let supportsReasoning = lower.contains("opus") || lower.contains("sonnet")
        return AgentModelDescriptor(
            id: id,
            label: label,
            provider: .claude,
            supportsReasoning: supportsReasoning,
            supportedReasoningEfforts: supportsReasoning ? AgentReasoningEffort.claudeSupportedCases : [],
            supportsCustomModel: true,
            contextWindowTokens: 200_000
        )
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        object[key] as? String
    }

    private static func displayName(for id: String) -> String {
        id.split(separator: "-")
            .filter { Int($0) == nil && $0.count != 8 }
            .map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }
            .joined(separator: " ")
    }
}

// MARK: - Actor-isolated cache storage

actor ModelDiscoveryCache {
    var entry: ModelDiscoveryCacheEntry?

    func store(_ e: ModelDiscoveryCacheEntry) {
        entry = e
    }

    func reset() {
        entry = nil
    }
}
