import XCTest
import CoreModel
@testable import AgentRuntime

// Tests for the TTL-cache decision helper and the wired listModels/refreshModels
// paths on CodexAppServerAdapter.
//
// WHY: The adapter previously returned a hardcoded model list. It now calls the
// real Codex app-server discovery, caches results for `modelCacheTTL` seconds,
// and falls back to the hardcoded list on failure. These tests verify every
// branch without network I/O or spawning a real process.

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

final class CodexAppServerModelCacheTests: XCTestCase {

    // -------------------------------------------------------------------------
    // MARK: - ModelListTTLDecision (pure, no async)
    // -------------------------------------------------------------------------

    func test_ttl_returnsTrue_whenNoCachedDate() {
        // WHY: a never-populated cache must always refetch so the picker
        // is not empty on first open.
        XCTAssertTrue(
            ModelListTTLDecision.shouldRefetch(
                lastFetchedAt: nil,
                ttl: 300,
                now: Date()
            )
        )
    }

    func test_ttl_returnsFalse_withinTTL() {
        // WHY: within the TTL window the adapter must serve the cache to avoid
        // spawning a new codex process on every picker render.
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000 + 299)   // 299s later < 300s TTL
        XCTAssertFalse(
            ModelListTTLDecision.shouldRefetch(
                lastFetchedAt: fetchedAt,
                ttl: 300,
                now: now
            )
        )
    }

    func test_ttl_returnsTrue_exactlyAtTTLBoundary() {
        // WHY: >= boundary means the cache is stale; strictly-less-than would
        // leave a stale entry for one extra second with "> ttl" semantics.
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000 + 300)   // exactly 300s
        XCTAssertTrue(
            ModelListTTLDecision.shouldRefetch(
                lastFetchedAt: fetchedAt,
                ttl: 300,
                now: now
            )
        )
    }

    func test_ttl_returnsTrue_pastTTL() {
        // WHY: once stale the adapter must fetch fresh data so new server-side
        // models surface in the picker.
        let fetchedAt = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000 + 301)
        XCTAssertTrue(
            ModelListTTLDecision.shouldRefetch(
                lastFetchedAt: fetchedAt,
                ttl: 300,
                now: now
            )
        )
    }

    // -------------------------------------------------------------------------
    // MARK: - CodexAppServerAdapter.listModels (with discovery stub)
    // -------------------------------------------------------------------------

    // Convenience: build an adapter whose "discovery" is fully stubbed via the
    // modelListDiscovery closure parameter. We set modelCacheTTL to 60s so we
    // can control staleness explicitly.

    private func makeAdapter(
        discoveredModels: @escaping @Sendable () async -> [AgentModelDescriptor]
    ) -> CodexAppServerAdapter {
        CodexAppServerAdapter(
            modelCacheTTL: 60,
            modelListDiscovery: discoveredModels
        )
    }

    func test_listModels_returnsDiscoveredModels_whenDiscoverySucceeds() async {
        // WHY: when the live server returns models the picker must show them,
        // not the hardcoded fallback list.
        let live = [
            AgentModelDescriptor(id: "live-model-1", label: "Live 1", provider: .codex,
                                 supportsReasoning: false, supportsServiceTier: false, supportsCustomModel: true),
            AgentModelDescriptor(id: "gpt-6-astra", label: "Live Astra", provider: .codex,
                                 supportsReasoning: false, supportsServiceTier: false, supportsCustomModel: true)
        ]
        let adapter = makeAdapter(discoveredModels: { live })

        let result = await adapter.listModels()
        XCTAssertEqual(result.map(\.id), ["live-model-1", "gpt-6-astra"],
                       "listModels must preserve live models without duplicating Astra")
        XCTAssertEqual(result.last?.label, "Live Astra")
        XCTAssertFalse(result.last?.supportsReasoning ?? true)
    }

    func test_listModels_returnsFallback_whenDiscoveryReturnsEmpty() async {
        // WHY: if the codex binary is absent or returns nothing, the adapter
        // must still populate the picker with the hardcoded baseline so the
        // user can run a session.
        let adapter = makeAdapter(discoveredModels: { [] })

        let result = await adapter.listModels()
        XCTAssertFalse(result.isEmpty, "listModels must fall back to hardcoded list on empty discovery")
        // The fallback list always contains at least the \"default\" entry.
        XCTAssertTrue(result.contains { $0.provider == .codex },
                      "fallback models must still be tagged as .codex provider")
    }

    func test_listModels_returnsCachedResult_withinTTL() async {
        // WHY: within the TTL the adapter must not call discovery again so we
        // do not spawn extra processes on every UI render.
        let counter = Counter()
        let live = [
            AgentModelDescriptor(id: "cached-model", label: "Cached", provider: .codex,
                                 supportsReasoning: false, supportsServiceTier: false, supportsCustomModel: true)
        ]
        let adapter = CodexAppServerAdapter(
            modelCacheTTL: 60,
            modelListDiscovery: {
                counter.increment()
                return live
            }
        )

        _ = await adapter.listModels()        // populates cache
        _ = await adapter.listModels()        // should hit cache
        XCTAssertEqual(counter.current, 1,
                       "discovery must only be called once within the TTL window")
    }

    func test_listModels_refetches_afterTTLExpired() async {
        // WHY: once the TTL has elapsed the adapter must call discovery again
        // so new models surface automatically without user interaction.
        let counter = Counter()
        let live = [
            AgentModelDescriptor(id: "ttl-model", label: "TTL", provider: .codex,
                                 supportsReasoning: false, supportsServiceTier: false, supportsCustomModel: true)
        ]
        // TTL = 0 seconds so every call is stale.
        let adapter = CodexAppServerAdapter(
            modelCacheTTL: 0,
            modelListDiscovery: {
                counter.increment()
                return live
            }
        )

        _ = await adapter.listModels()
        _ = await adapter.listModels()
        XCTAssertEqual(counter.current, 2,
                       "discovery must be called again once the TTL has expired")
    }

    func test_refreshModels_forcesRefetch_regardlessOfTTL() async {
        // WHY: the model picker has an explicit refresh button; tapping it must
        // bypass the cache even when the TTL has not elapsed.
        let counter = Counter()
        let live = [
            AgentModelDescriptor(id: "fresh-model", label: "Fresh", provider: .codex,
                                 supportsReasoning: false, supportsServiceTier: false, supportsCustomModel: true)
        ]
        let adapter = CodexAppServerAdapter(
            modelCacheTTL: 3600,          // very long TTL -- would normally serve cache
            modelListDiscovery: {
                counter.increment()
                return live
            }
        )

        _ = await adapter.listModels()    // primes cache (call 1)
        _ = await adapter.refreshModels() // manual refresh must bypass TTL (call 2)
        XCTAssertEqual(counter.current, 2,
                       "refreshModels must bypass TTL and call discovery even when cache is fresh")
    }

    // -------------------------------------------------------------------------
    // MARK: - listModelsResult fallback signal
    // -------------------------------------------------------------------------

    func test_listModelsResult_isFallback_true_whenDiscoveryReturnsEmpty() async {
        // WHY: a broken codex binary/app-server must not present the hardcoded
        // list as live data — callers need this signal to surface "model list
        // unavailable" instead of silently serving the static list as if the
        // user's account really offered exactly those models.
        let adapter = makeAdapter(discoveredModels: { [] })

        let result = await adapter.listModelsResult()
        XCTAssertTrue(result.isFallback,
                      "empty live discovery must be flagged as a fallback, not presented as live data")
        XCTAssertFalse(result.models.isEmpty,
                       "the fallback result must still carry the hardcoded baseline so the picker stays usable")
    }

    func test_listModelsResult_keepsAstraSelectableWhenLiveCatalogOmitsIt_andCachesResult() async {
        // A successful catalog keeps Astra selectable even when omitted upstream;
        // a cache hit must preserve that option without a fallback warning.
        let live = [
            AgentModelDescriptor(id: "live-model-1", label: "Live 1", provider: .codex,
                                 supportsReasoning: false, supportsServiceTier: false, supportsCustomModel: true)
        ]
        let adapter = makeAdapter(discoveredModels: { live })

        let first = await adapter.listModelsResult()
        XCTAssertFalse(first.isFallback,
                       "successful live discovery must not be flagged as a fallback")
        let cached = await adapter.listModelsResult()
        XCTAssertFalse(cached.isFallback,
                       "a cache hit serves previously fetched live data and is never a fallback")
        XCTAssertEqual(first.models.map(\.id), ["live-model-1", "gpt-6-astra"])
        XCTAssertEqual(cached.models.map(\.id), first.models.map(\.id))
    }
}
