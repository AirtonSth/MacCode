import XCTest
@testable import Surfaces

/// Pins R6 residual agent-surface memory ceilings (memory-loop tip values).
///
/// WHY: StreamEventBatch, full-load body budget, markdown parse caches, and
/// assistant-text dedupe NSCaches dominate multi-thread stream working set.
/// Keep defaults aligned with progressive lowers from origin/agent-perf/memory-loop.
final class AgentAppMemoryR6CapTests: XCTestCase {

    func test_streamEventBatchDefaults() {
        let limits = StreamEventBatch.Limits()
        XCTAssertEqual(limits.maxBufferedCount, 4_096)
        XCTAssertEqual(limits.maxBufferedBytes, 2 * 1_024 * 1_024)
    }

    func test_fullLoadBodyBudget_is128KiB() {
        XCTAssertEqual(AgentAppViewModel.fullLoadBodyBudgetBytes, 128 * 1024)
    }

    func test_markdownCacheCostLimits_are2MiB() {
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheCostLimit, 2 * 1_024 * 1_024)
        XCTAssertEqual(AgentMessageMarkdown.inlineCacheCostLimit, 2 * 1_024 * 1_024)
    }

    func test_assistantTextDedupeCacheCostLimit_is128KiB() {
        XCTAssertEqual(AgentAppView.assistantTextDedupeCacheCostLimit, 128 * 1024)
        XCTAssertEqual(AgentAppView.assistantTextDedupeCacheCountLimit, 128)
    }

    func test_assistantTextDedupeCache_keysAreFingerprintsNotFullBodies() throws {
        // WHY: costLimit bounds values, not keys. Full-body NSString keys
        // duplicated up to 2×128 KiB of source text. Markdown cacheKey is
        // `"utf8Count:hash"` (~20–40 B × 128 × 2 ≈ 10 KiB).
        let body = String(repeating: "x", count: 4_096)
        let key = AgentMessageMarkdown.cacheKey(for: body)
        XCTAssertEqual(key as String, "\(body.utf8.count):\(AgentMessageMarkdown.sourceFingerprint(for: body))")
        XCTAssertLessThan((key as String).utf8.count, 80)
        let beforeKeyBytes = 2 * AgentAppView.assistantTextDedupeCacheCostLimit
        let afterKeyBytes = 2 * AgentAppView.assistantTextDedupeCacheCountLimit * (key as String).utf8.count
        XCTAssertEqual(beforeKeyBytes, 256 * 1024)
        XCTAssertLessThan(afterKeyBytes, 20 * 1024)

        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("let key = AgentMessageMarkdown.cacheKey(for: text)"))
        XCTAssertFalse(
            source.contains("let key = text as NSString"),
            "normalized/compact caches must not key by the full body NSString"
        )
    }

    func test_retentionEstimate_streamBatch_32MiBTo2MiB() {
        let prior = 32 * 1_024 * 1_024
        let limit = StreamEventBatch.Limits().maxBufferedBytes
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertGreaterThan(reduction, 0.93)
        XCTAssertEqual(limit, 2 * 1_024 * 1_024)
    }

    func test_retentionEstimate_fullLoad_400KiBTo128KiB() {
        let prior = 400 * 1024
        let limit = AgentAppViewModel.fullLoadBodyBudgetBytes
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertEqual(reduction, 0.68, accuracy: 0.01)
        XCTAssertEqual(limit, 128 * 1024)
    }

    func test_retentionEstimate_dedupeCache_8MiBTo128KiB() {
        let prior = 8 * 1024 * 1024
        let limit = AgentAppView.assistantTextDedupeCacheCostLimit
        let reduction = Double(prior - limit) / Double(prior)
        XCTAssertGreaterThan(reduction, 0.98)
        XCTAssertEqual(limit, 128 * 1024)
    }
}
