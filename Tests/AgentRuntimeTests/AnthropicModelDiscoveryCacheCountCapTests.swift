import XCTest
import CoreModel
@testable import AgentRuntime

/// PERF: bounds the process-wide Anthropic model-list discovery cache so
/// credential fingerprint churn cannot pin unbounded model arrays process-wide.
///
/// WHY: each cache key retains a full `[AgentModelDescriptor]` snapshot for one
/// OAuth/API-key fingerprint. Without a ceiling, long-lived apps that rotate
/// Anthropic credentials (or exercise many keys in tests) accumulate every
/// historical list until process exit. Misses only re-fetch within the 1h TTL.
final class AnthropicModelDiscoveryCacheCountCapTests: XCTestCase {

    func test_builtInCountLimit_matchesDiscoveryCacheOrder() {
        // 32 matches Grok ACP / catalog verification caches; enough concurrent
        // accounts without multi-hundred key growth.
        XCTAssertEqual(AnthropicModelDiscovery.modelDiscoveryCacheCountLimit, 32)
    }

    func test_noteModelDiscoveryCacheEntry_capsDistinctKeys() {
        var entries: [String: ModelDiscoveryCacheEntry] = [:]
        let limit = 8
        var newest = ""
        for i in 0..<(limit + 20) {
            newest = "apikey:fp-\(i)"
            AnthropicModelDiscovery.noteModelDiscoveryCacheEntry(
                &entries,
                key: newest,
                entry: ModelDiscoveryCacheEntry(
                    models: [
                        AgentModelDescriptor(
                            id: "claude-test-\(i)",
                            label: "T\(i)",
                            provider: .claude
                        )
                    ],
                    fetchedAt: Date(timeIntervalSince1970: Double(i))
                ),
                countLimit: limit
            )
        }
        XCTAssertEqual(entries.count, limit)
        XCTAssertNotNil(entries[newest])
        XCTAssertEqual(entries[newest]?.models.first?.id, "claude-test-\(limit + 19)")
    }

    func test_noteModelDiscoveryCacheEntry_updatesExistingWithoutGrowth() {
        var entries: [String: ModelDiscoveryCacheEntry] = [:]
        let key = "oauth:same"
        AnthropicModelDiscovery.noteModelDiscoveryCacheEntry(
            &entries,
            key: key,
            entry: ModelDiscoveryCacheEntry(
                models: [AgentModelDescriptor(id: "a", label: "A", provider: .claude)],
                fetchedAt: Date(timeIntervalSince1970: 1)
            ),
            countLimit: 5
        )
        AnthropicModelDiscovery.noteModelDiscoveryCacheEntry(
            &entries,
            key: key,
            entry: ModelDiscoveryCacheEntry(
                models: [AgentModelDescriptor(id: "b", label: "B", provider: .claude)],
                fetchedAt: Date(timeIntervalSince1970: 2)
            ),
            countLimit: 5
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[key]?.models.first?.id, "b")
    }

    func test_noteModelDiscoveryCacheEntry_keepsNewestUnderPressure() {
        var entries: [String: ModelDiscoveryCacheEntry] = [:]
        AnthropicModelDiscovery.noteModelDiscoveryCacheEntry(
            &entries,
            key: "old",
            entry: ModelDiscoveryCacheEntry(models: [], fetchedAt: Date(timeIntervalSince1970: 1)),
            countLimit: 1
        )
        AnthropicModelDiscovery.noteModelDiscoveryCacheEntry(
            &entries,
            key: "new",
            entry: ModelDiscoveryCacheEntry(
                models: [AgentModelDescriptor(id: "n", label: "N", provider: .claude)],
                fetchedAt: Date(timeIntervalSince1970: 2)
            ),
            countLimit: 1
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries["new"])
        XCTAssertNil(entries["old"])
    }

    func test_retentionEstimate_2kKeysTo32Window() {
        let uncapped = 2_000
        let limit = AnthropicModelDiscovery.modelDiscoveryCacheCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.98)
        XCTAssertEqual(limit, 32)
        // Basis: ~50 models × ~100 B ≈ 5 KB/key → 2k ≈ 10 MB; 32 ≈ 160 KB (−98.4%).
        let perKey = 5_000
        let before = uncapped * perKey
        let after = limit * perKey
        XCTAssertEqual(before, 10_000_000)
        XCTAssertEqual(after, 160_000)
        XCTAssertLessThan(Double(after) / Double(before), 0.02)
    }
}
