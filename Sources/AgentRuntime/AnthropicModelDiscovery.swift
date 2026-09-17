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
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        afterID: String? = nil
    ) -> URLRequest? {
        guard var components = URLComponents(string: "https://api.anthropic.com/v1/models") else { return nil }
        if let afterID, !afterID.isEmpty {
            components.queryItems = [URLQueryItem(name: "after_id", value: afterID)]
        }
        guard let url = components.url else { return nil }
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

    /// Peak distinct credential fingerprints retained in the process-wide
    /// Anthropic model-list cache. Key churn (API key / OAuth rotation, multi
    /// account) would otherwise pin unbounded model arrays process-wide; 32
    /// matches Grok ACP / catalog verification cache order of magnitude.
    public static let modelDiscoveryCacheCountLimit = 32

    /// Pure insert/evict for the Anthropic model discovery cache. Keeps `key`;
    /// drops arbitrary other keys when over `countLimit`. Extracted for unit tests.
    public static func noteModelDiscoveryCacheEntry(
        _ entries: inout [String: ModelDiscoveryCacheEntry],
        key: String,
        entry: ModelDiscoveryCacheEntry,
        countLimit: Int = modelDiscoveryCacheCountLimit
    ) {
        entries[key] = entry
        let cap = max(1, countLimit)
        while entries.count > cap {
            if let victim = entries.keys.first(where: { $0 != key }) ?? entries.keys.first {
                entries.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }

    // For testing only: clears the static in-process cache so each test starts clean.
    static func _resetCacheForTesting() async {
        await _cache.reset()
    }

    /// Test-only: number of retained credential fingerprints in the shared cache.
    static func _cacheCountForTesting() async -> Int {
        await _cache.countForTesting
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
        let env = CodexRunner.processEnvironment(overrides: environment, purpose: .supportProcess)
        let cacheKey = credentialFingerprint(environment: env)

        // Cache hit? Cache stores only live data, keyed per credential so
        // switching Anthropic accounts never serves another account's list;
        // a hit is never a fallback.
        if let cached = await _cache.entry(for: cacheKey), cached.isValid(ttl: cacheTTL) {
            return ModelListResult(models: cached.models, isFallback: false)
        }

        do {
            var afterID: String?
            var seenAfterIDs = Set<String>()
            var models: [AgentModelDescriptor] = []
            while true {
                guard let request = AnthropicDiscoveryRequestBuilder.build(
                    environment: env,
                    afterID: afterID
                ) else {
                    return ModelListResult(models: [], isFallback: true)
                }
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return ModelListResult(models: [], isFallback: true)
                }
                models.append(contentsOf: modelDescriptors(fromListResponse: object))
                guard object["has_more"] as? Bool == true else { break }
                guard let nextAfterID = object["last_id"] as? String,
                      !nextAfterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      seenAfterIDs.insert(nextAfterID).inserted else {
                    // A malformed or cyclic cursor cannot prove that the
                    // catalog is complete. Preserve the honest fallback state.
                    return ModelListResult(models: [], isFallback: true)
                }
                afterID = nextAfterID
            }
            await _cache.store(ModelDiscoveryCacheEntry(models: models, fetchedAt: Date()), for: cacheKey)
            return ModelListResult(models: models, isFallback: false)
        } catch {
            return ModelListResult(models: [], isFallback: true)
        }
    }

    /// Cache key derived from the resolved credential (same precedence as
    /// `AnthropicDiscoveryRequestBuilder.build`: OAuth token over API key).
    /// Hashed so the raw secret is never held as a dictionary key; per-process
    /// hash stability is sufficient for the in-process cache.
    private static func credentialFingerprint(environment: [String: String]) -> String {
        if let token = environment["ANTHROPIC_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return "oauth:\(token.hashValue)"
        }
        if let key = environment["ANTHROPIC_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return "apikey:\(key.hashValue)"
        }
        return "none"
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
            // The CLI accepts the bare "fable" alias (and "claude-fable-5");
            // the flagship leads so it stays selectable on the fallback path.
            descriptor(id: "fable", label: "Fable (latest)"),
            descriptor(id: "opus", label: "Opus (latest)"),
            descriptor(id: "sonnet", label: "Sonnet (latest)"),
            descriptor(id: "haiku", label: "Haiku (latest)")
        ]
    }

    private static func descriptor(id: String, label: String) -> AgentModelDescriptor {
        let reasoningEfforts = ClaudeRunner.supportedReasoningEfforts(for: id)
        return AgentModelDescriptor(
            id: id,
            label: label,
            provider: .claude,
            supportsReasoning: !reasoningEfforts.isEmpty,
            supportedReasoningEfforts: reasoningEfforts,
            supportsCustomModel: true,
            contextWindowTokens: contextWindowTokens(forID: id)
        )
    }

    /// Known context windows by model-id prefix (Anthropic docs, 2026-07):
    /// Fable 5, Opus 4.6+, and Sonnet 4.6+ are 1M-context; Haiku is 200k.
    /// First match wins, so dated/legacy ids must precede their bare alias.
    private static let contextWindowsByIDPrefix: [(prefix: String, tokens: Int)] = [
        ("claude-fable", 1_000_000),
        ("fable", 1_000_000),
        ("claude-opus-5", 1_000_000),
        ("claude-opus-4-8", 1_000_000),
        ("claude-opus-4-7", 1_000_000),
        ("claude-opus-4-6", 1_000_000),
        ("opus", 1_000_000),   // bare alias resolves to the latest Opus
        ("claude-sonnet-5", 1_000_000),
        ("claude-sonnet-4-6", 1_000_000),
        ("sonnet", 1_000_000), // bare alias resolves to the latest Sonnet
        ("claude-haiku", 200_000),
        ("haiku", 200_000)
    ]

    /// Nil when the window is unknown so the picker hides the context pill
    /// instead of showing a fabricated number.
    private static func contextWindowTokens(forID id: String) -> Int? {
        let lower = id.lowercased()
        return contextWindowsByIDPrefix.first { lower.hasPrefix($0.prefix) }?.tokens
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
    // Keyed by credential fingerprint so per-account lists never cross.
    private var entries: [String: ModelDiscoveryCacheEntry] = [:]

    func entry(for key: String) -> ModelDiscoveryCacheEntry? {
        entries[key]
    }

    func store(_ e: ModelDiscoveryCacheEntry, for key: String) {
        AnthropicModelDiscovery.noteModelDiscoveryCacheEntry(
            &entries,
            key: key,
            entry: e
        )
    }

    func reset() {
        entries.removeAll()
    }

    var countForTesting: Int { entries.count }
}
