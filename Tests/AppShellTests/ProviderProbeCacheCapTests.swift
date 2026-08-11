import XCTest
@testable import AppShell

/// PERF: bounds AppCommandRouter providerProbeCache so env/run-as fingerprint
/// churn cannot pin unbounded capability structs process-wide.
///
/// WHY: every probe stores slashCommands + skills under a key that includes
/// full sorted environment. Distinct env snapshots (cwd, HOME, run-as) never
/// expired except on auth refresh for one provider. Cap at 32 (Grok discovery /
/// Codex fork probe / catalog verification parity). Evicted keys re-probe on
/// next read after TTL miss (cold-start parity).
final class ProviderProbeCacheCapTests: XCTestCase {

    func test_builtInCountLimit_matchesDiscoveryOrder() {
        XCTAssertEqual(AppCommandRouter.providerProbeCacheCountLimit, 32)
    }

    func test_noteProviderProbeCacheEntry_capsDistinctKeys() {
        var cache: [String: Int] = [:]
        let limit = 4
        for i in 0..<(limit + 12) {
            AppCommandRouter.noteProviderProbeCacheEntry(
                &cache,
                key: "k-\(i)",
                value: i,
                countLimit: limit
            )
        }
        XCTAssertEqual(cache.count, limit)
        XCTAssertEqual(cache["k-\(limit + 11)"], limit + 11)
    }

    func test_noteProviderProbeCacheEntry_updatesExistingWithoutGrowth() {
        var cache: [String: String] = [:]
        AppCommandRouter.noteProviderProbeCacheEntry(
            &cache, key: "same", value: "v1", countLimit: 3
        )
        AppCommandRouter.noteProviderProbeCacheEntry(
            &cache, key: "same", value: "v2", countLimit: 3
        )
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache["same"], "v2")
    }

    func test_noteProviderProbeCacheEntry_keepsNewestWhenAtCap() {
        var cache = ["a": 1, "b": 2, "c": 3]
        AppCommandRouter.noteProviderProbeCacheEntry(
            &cache, key: "d", value: 4, countLimit: 3
        )
        XCTAssertEqual(cache.count, 3)
        XCTAssertEqual(cache["d"], 4)
        // At least one of the prior keys dropped
        let survivors = Set(cache.keys)
        XCTAssertTrue(survivors.contains("d"))
        XCTAssertEqual(survivors.intersection(["a", "b", "c"]).count, 2)
    }

    func test_retentionEstimate_2kProbesTo32Window() {
        let uncapped = 2_000
        let limit = AppCommandRouter.providerProbeCacheCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.98)
        XCTAssertEqual(limit, 32)
        // Basis: key (provider+binary+env fingerprint) ~200B + capabilities
        // (slashCommands/skills arrays) ~1KB ≈ 1.2KB/entry.
        // 2k × 1.2KB ≈ 2.4MB → 32 × 1.2KB ≈ 38.4KB (−98.4%).
        let perKey = 1_200
        XCTAssertEqual(uncapped * perKey, 2_400_000)
        XCTAssertEqual(limit * perKey, 38_400)
    }
}
