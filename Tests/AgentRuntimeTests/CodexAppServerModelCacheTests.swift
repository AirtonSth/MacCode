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

final class CodexAppServerModelCacheTests: ProviderProcessTestCase {

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

    func test_listModelsResult_keepsLiveCatalogWithoutInventingAstra_andCachesResult() async {
        // An injected live catalog is already the source under test. The adapter
        // must not invent a special model that the source did not return.
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
        XCTAssertEqual(first.models.map(\.id), ["live-model-1"])
        XCTAssertEqual(cached.models.map(\.id), first.models.map(\.id))
    }

    func test_modelDiscoveryAddsAstraFromSameAccountHarnessCacheWhenModelListOmitsIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-harness-models-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cache: [String: Any] = [
            "models": [
                [
                    "slug": "gpt-6-astra",
                    "display_name": "GPT-6-Astra",
                    "visibility": "list",
                    "supported_in_api": true,
                    "supported_reasoning_levels": [
                        ["effort": "low"], ["effort": "medium"], ["effort": "high"],
                        ["effort": "xhigh"], ["effort": "max"], ["effort": "ultra"]
                    ],
                    "additional_speed_tiers": ["fast"],
                    "service_tiers": [["id": "priority"]],
                    "context_window": 272_000
                ],
                ["slug": "gpt-hidden", "display_name": "Hidden", "visibility": "hide", "supported_in_api": true],
                ["slug": "gpt-disabled", "display_name": "Disabled", "visibility": "list", "supported_in_api": false]
            ]
        ]
        let cacheData = try JSONSerialization.data(withJSONObject: cache)
        try cacheData.write(to: home.appendingPathComponent("models_cache.json"))

        let binary = root.appendingPathComponent("codex")
        try """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get("method")
            if method == "initialize":
                print(json.dumps({"id": request["id"], "result": {"userAgent": "fake-codex"}}), flush=True)
            elif method == "model/list":
                print(json.dumps({"id": request["id"], "result": {"data": [{
                    "model": "gpt-5.6-luna",
                    "displayName": "Live Luna",
                    "supportedReasoningEfforts": [{"reasoningEffort": "high"}],
                    "modelContextWindow": 999
                }]}}), flush=True)
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let result = await CodexAppServerModelDiscovery.listModelsResult(
            binary: binary.path,
            cwd: root.path,
            environment: ["CODEX_HOME": home.path]
        )

        XCTAssertFalse(result.isFallback,
                       "a live model/list response plus the selected account cache is current harness discovery")
        XCTAssertEqual(result.models.first?.label, "Live Luna",
                       "live model/list metadata must win for duplicate IDs")
        let astra = try XCTUnwrap(result.models.first { $0.id == "gpt-6-astra" })
        XCTAssertEqual(astra.supportedReasoningEfforts, [.low, .medium, .high, .xhigh, .max, .ultra])
        XCTAssertTrue(astra.supportsServiceTier)
        XCTAssertEqual(astra.contextWindowTokens, 272_000)
        XCTAssertFalse(result.models.contains { $0.id == "gpt-hidden" })
        XCTAssertFalse(result.models.contains { $0.id == "gpt-disabled" })
    }

    func test_modelDiscoveryRetainsSameAccountCacheAsFallbackWhenLiveDiscoveryFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-harness-fallback-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("codex-home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheData = try JSONSerialization.data(withJSONObject: [
            "models": [[
                "slug": "cached-luna",
                "display_name": "Cached Luna",
                "visibility": "list",
                "supported_in_api": true
            ]]
        ])
        try cacheData.write(to: home.appendingPathComponent("models_cache.json"))

        let binary = root.appendingPathComponent("codex")
        try """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if request.get("method") == "initialize":
                print(json.dumps({"id": request["id"], "error": {"code": -32000, "message": "offline"}}), flush=True)
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let result = await CodexAppServerModelDiscovery.listModelsResult(
            binary: binary.path,
            cwd: root.path,
            environment: ["CODEX_HOME": home.path]
        )

        XCTAssertTrue(result.isFallback,
                      "same-account cache after failed live discovery must remain fallback data")
        XCTAssertEqual(result.models.map(\.id), ["cached-luna"])
    }

    func test_harnessCatalogUsesConfiguredAccountHomeWithoutLeakingAnotherCache() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-harness-account-scope-\(UUID().uuidString)", isDirectory: true)
        let homeA = root.appendingPathComponent("account-a", isDirectory: true)
        let homeB = root.appendingPathComponent("account-b", isDirectory: true)
        try FileManager.default.createDirectory(at: homeA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeB, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func writeCache(_ id: String, to home: URL) throws {
            let data = try JSONSerialization.data(withJSONObject: [
                "models": [[
                    "slug": id,
                    "display_name": id,
                    "visibility": "list",
                    "supported_in_api": true
                ]]
            ])
            try data.write(to: home.appendingPathComponent("models_cache.json"))
        }
        try writeCache("account-a-model", to: homeA)
        try writeCache("account-b-model", to: homeB)

        let accountA = CodexHarnessModelCatalog.models(environment: ["CODEX_HOME": homeA.path])
        let accountB = CodexHarnessModelCatalog.models(environment: ["CODEX_HOME": homeB.path])
        XCTAssertEqual(accountA.map(\.id), ["account-a-model"])
        XCTAssertEqual(accountB.map(\.id), ["account-b-model"])
        XCTAssertFalse(accountA.contains { $0.id == "account-b-model" })
        XCTAssertFalse(accountB.contains { $0.id == "account-a-model" })
    }

    func test_discoveryEnvironmentDoesNotInheritParentCodexHomeWhenHomeChanges() {
        let parentHome = "/tmp/codex-parent-home"
        let accountHome = "/tmp/codex-selected-account"
        let base = ["HOME": parentHome, "CODEX_HOME": "\(parentHome)/.codex"]

        let selected = CodexAppServerModelDiscovery.environmentForDiscovery(
            environment: ["HOME": accountHome],
            runAsUser: nil,
            baseEnvironment: base
        )
        XCTAssertEqual(selected["HOME"], accountHome)
        XCTAssertEqual(selected["CODEX_HOME"], "\(accountHome)/.codex")

        let sameAccount = CodexAppServerModelDiscovery.environmentForDiscovery(
            environment: ["HOME": parentHome],
            runAsUser: nil,
            baseEnvironment: base
        )
        XCTAssertEqual(sameAccount["CODEX_HOME"], "\(parentHome)/.codex")

        let explicit = CodexAppServerModelDiscovery.environmentForDiscovery(
            environment: ["HOME": accountHome, "CODEX_HOME": "/tmp/explicit-codex-home"],
            runAsUser: nil,
            baseEnvironment: base
        )
        XCTAssertEqual(explicit["CODEX_HOME"], "/tmp/explicit-codex-home")
    }
}
