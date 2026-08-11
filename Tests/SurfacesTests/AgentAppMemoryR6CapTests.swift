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

    func test_markdownCacheCostLimits_are128KiB() {
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheCostLimit, 128 * 1_024)
        XCTAssertEqual(AgentMessageMarkdown.inlineCacheCostLimit, 128 * 1_024)
    }

    func test_assistantTextDedupeCacheCostLimit_is128KiB() {
        XCTAssertEqual(AgentAppView.assistantTextDedupeCacheCostLimit, 128 * 1024)
        XCTAssertEqual(AgentAppView.assistantTextDedupeCacheCountLimit, 128)
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
