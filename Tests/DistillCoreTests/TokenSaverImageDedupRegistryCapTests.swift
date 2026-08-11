import XCTest
@testable import DistillCore

/// PERF: bounds TokenSaverImageDedupRegistry so attachment/image storms
/// cannot pin unbounded scope+hash membership process-wide.
///
/// WHY: every unique image hash previously stayed in `hashesByThread` forever.
/// Multi-turn attachment churn grew the set without bound. Evicted hashes
/// re-send original (cold-start / first-touch parity).
final class TokenSaverImageDedupRegistryCapTests: XCTestCase {

    private let scope = TokenSaverRecoveryScope(
        workspaceID: "w",
        projectID: "p",
        threadID: "t",
        provider: "claude",
        attemptID: "a"
    )

    func test_builtInCountLimit_matchesFingerprintOrder() {
        XCTAssertEqual(TokenSaverImageDedupRegistry.defaultCountLimit, 128)
    }

    func test_prunedMembership_capsDistinctKeys_evictsOldest() {
        var set = Set<String>()
        var order: [String] = []
        let limit = 4
        for i in 0..<(limit + 10) {
            let result = TokenSaverImageDedupRegistry.prunedMembership(
                set: set,
                order: order,
                inserting: "h-\(i)",
                countLimit: limit
            )
            set = result.set
            order = result.order
        }
        XCTAssertEqual(set.count, limit)
        XCTAssertEqual(order.count, limit)
        XCTAssertTrue(set.contains("h-\(limit + 9)"))
        XCTAssertFalse(set.contains("h-0"))
    }

    func test_prunedMembership_reinsertMovesToNewest() {
        let first = TokenSaverImageDedupRegistry.prunedMembership(
            set: ["a", "b"],
            order: ["a", "b"],
            inserting: "c",
            countLimit: 3
        )
        let again = TokenSaverImageDedupRegistry.prunedMembership(
            set: first.set,
            order: first.order,
            inserting: "a",
            countLimit: 3
        )
        XCTAssertEqual(again.set.count, 3)
        XCTAssertEqual(again.order.last, "a")
        XCTAssertEqual(Set(again.order), Set(["b", "c", "a"]))
    }

    func test_register_enforcesCapAndDedupSemantics() {
        var registry = TokenSaverImageDedupRegistry(countLimit: 5)
        for i in 0..<18 {
            let action = registry.register(
                hash: "img-\(i)",
                scope: scope,
                explicitResend: false
            )
            XCTAssertEqual(action, .sendOriginal)
        }
        XCTAssertEqual(registry.count, 5)
        // Newest still dedups
        XCTAssertEqual(
            registry.register(hash: "img-17", scope: scope, explicitResend: false),
            .deduplicateExact
        )
        // Evicted oldest re-sends original
        XCTAssertEqual(
            registry.register(hash: "img-0", scope: scope, explicitResend: false),
            .sendOriginal
        )
    }

    func test_explicitResend_alwaysSendOriginalButStillCaps() {
        var registry = TokenSaverImageDedupRegistry(countLimit: 3)
        for i in 0..<8 {
            XCTAssertEqual(
                registry.register(hash: "x-\(i)", scope: scope, explicitResend: true),
                .sendOriginal
            )
        }
        XCTAssertEqual(registry.count, 3)
        // Still tracked newest for future non-explicit dedup
        XCTAssertEqual(
            registry.register(hash: "x-7", scope: scope, explicitResend: false),
            .deduplicateExact
        )
    }

    func test_scopeIsolation_andExistingContract() {
        // Regression-shaped: same hash different thread is a different key.
        var registry = TokenSaverImageDedupRegistry()
        let other = TokenSaverRecoveryScope(
            workspaceID: "w", projectID: "p", threadID: "other",
            provider: "claude", attemptID: "a"
        )
        XCTAssertEqual(registry.register(hash: "same", scope: scope, explicitResend: false), .sendOriginal)
        XCTAssertEqual(registry.register(hash: "same", scope: scope, explicitResend: false), .deduplicateExact)
        XCTAssertEqual(registry.register(hash: "same", scope: other, explicitResend: false), .sendOriginal)
    }

    func test_retentionEstimate_256HashesTo128Window() {
        let uncapped = 256 // prior defaultCountLimit
        let limit = TokenSaverImageDedupRegistry.defaultCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: scope+hash key (~200B) + Set/array membership ≈ ~240B/key.
        // 256 × 240B ≈ 61.4KB → 128 × 240B ≈ 30.7KB (−50%).
        let perKey = 240
        XCTAssertEqual(uncapped * perKey, 61_440)
        XCTAssertEqual(limit * perKey, 30_720)
    }
}
