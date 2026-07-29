import Foundation

/// Pure, stateless helper that decides whether a cached model list must be
/// refetched. Extracted from CodexAppServerAdapter so it can be unit-tested
/// without any async infrastructure or @MainActor isolation.
public enum ModelListTTLDecision {
    /// Shared freshness window for provider catalog / model-list caches.
    /// Matches `CodexAppServerAdapter`'s default `modelCacheTTL` so snapshot
    /// re-probes and adapter `listModels` agree on when a catalog is still good.
    public static let defaultCatalogTTL: TimeInterval = 300

    /// Returns `true` when the cache is absent or older than `ttl` seconds.
    ///
    /// - Parameters:
    ///   - lastFetchedAt: The timestamp of the last successful fetch, or `nil`
    ///     if the cache has never been populated.
    ///   - ttl: Maximum age (in seconds) before a refetch is required.
    ///   - now: The current timestamp (injectable for deterministic tests).
    public static func shouldRefetch(
        lastFetchedAt: Date?,
        ttl: TimeInterval,
        now: Date
    ) -> Bool {
        guard let lastFetchedAt else { return true }
        return now.timeIntervalSince(lastFetchedAt) >= ttl
    }
}
