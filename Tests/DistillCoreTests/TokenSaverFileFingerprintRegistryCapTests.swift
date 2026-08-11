import XCTest
@testable import DistillCore

/// PERF: bounds TokenSaverFileFingerprintRegistry so multi-file agent
/// sessions cannot pin unbounded path/scope → sha maps process-wide.
///
/// WHY: every unique path+scope registration previously left a fingerprint
/// and recency key forever. Long Read/Edit storms grew both maps without
/// bound. Evicted keys re-send full content on next touch (cold-start parity).
final class TokenSaverFileFingerprintRegistryCapTests: XCTestCase {

    private let scope = TokenSaverRecoveryScope(
        workspaceID: "w",
        projectID: "p",
        threadID: "t",
        provider: "claude",
        attemptID: "a"
    )

    func test_builtInCountLimit_matchesSkipSetOrder() {
        XCTAssertEqual(TokenSaverFileFingerprintRegistry.defaultCountLimit, 128)
    }

    func test_prunedMaps_capsDistinctKeys_evictsOldest() {
        var fingerprints: [String: String] = [:]
        var recentKeys: [String] = []
        let limit = 4
        for i in 0..<(limit + 10) {
            let result = TokenSaverFileFingerprintRegistry.prunedMaps(
                fingerprints: fingerprints,
                recentKeys: recentKeys,
                inserting: "k-\(i)",
                fingerprint: "fp-\(i)",
                countLimit: limit
            )
            fingerprints = result.fingerprints
            recentKeys = result.recentKeys
        }
        XCTAssertEqual(fingerprints.count, limit)
        XCTAssertEqual(recentKeys.count, limit)
        XCTAssertEqual(fingerprints["k-\(limit + 9)"], "fp-\(limit + 9)")
        XCTAssertNil(fingerprints["k-0"])
        XCTAssertFalse(recentKeys.contains("k-0"))
    }

    func test_prunedMaps_updatesExistingWithoutGrowth() {
        var fingerprints: [String: String] = [:]
        var recentKeys: [String] = []
        let first = TokenSaverFileFingerprintRegistry.prunedMaps(
            fingerprints: fingerprints,
            recentKeys: recentKeys,
            inserting: "same",
            fingerprint: "v1",
            countLimit: 3
        )
        let second = TokenSaverFileFingerprintRegistry.prunedMaps(
            fingerprints: first.fingerprints,
            recentKeys: first.recentKeys,
            inserting: "same",
            fingerprint: "v2",
            countLimit: 3
        )
        XCTAssertEqual(second.fingerprints.count, 1)
        XCTAssertEqual(second.recentKeys, ["same"])
        XCTAssertEqual(second.fingerprints["same"], "v2")
    }

    func test_prunedMaps_keepsNewestWhenAtCap() {
        let seedPrints = ["a": "1", "b": "2", "c": "3"]
        let seedRecent = ["a", "b", "c"]
        let result = TokenSaverFileFingerprintRegistry.prunedMaps(
            fingerprints: seedPrints,
            recentKeys: seedRecent,
            inserting: "d",
            fingerprint: "4",
            countLimit: 3
        )
        XCTAssertEqual(result.fingerprints.count, 3)
        XCTAssertEqual(Set(result.recentKeys), Set(["b", "c", "d"]))
        XCTAssertNil(result.fingerprints["a"])
        XCTAssertEqual(result.fingerprints["d"], "4")
    }

    func test_register_enforcesCapOnLiveSet() {
        var registry = TokenSaverFileFingerprintRegistry(
            protectedRecentCount: 0,
            countLimit: 5
        )
        for i in 0..<18 {
            _ = registry.register(
                path: "/repo/file-\(i).swift",
                bytes: Data("body-\(i)".utf8),
                scope: scope
            )
        }
        XCTAssertEqual(registry.count, 5)
        // Newest still registered as known/unchanged
        let again = registry.register(
            path: "/repo/file-17.swift",
            bytes: Data("body-17".utf8),
            scope: scope
        )
        // protectedRecentCount=0 → re-touch of identical content is unchanged
        guard case .unchanged = again else {
            return XCTFail("expected unchanged for newest identical re-register")
        }
        // Evicted oldest re-sends full
        XCTAssertEqual(
            registry.register(
                path: "/repo/file-0.swift",
                bytes: Data("body-0".utf8),
                scope: scope
            ),
            .sendFull
        )
    }

    func test_register_preservesProtectedRecentWorkingSetSemantics() {
        // Regression: existing T003 test — latest working set stays verbatim.
        var registry = TokenSaverFileFingerprintRegistry(protectedRecentCount: 1, countLimit: 256)
        XCTAssertEqual(registry.register(path: "/repo/A.swift", bytes: Data("same".utf8), scope: scope), .sendFull)
        XCTAssertEqual(
            registry.register(path: "/repo/A.swift", bytes: Data("same".utf8), scope: scope),
            .sendFull,
            "latest working set stays verbatim"
        )
        _ = registry.register(path: "/repo/B.swift", bytes: Data("other".utf8), scope: scope)
        let unchanged = registry.register(path: "/repo/A.swift", bytes: Data("same".utf8), scope: scope)
        guard case .unchanged(let fingerprint) = unchanged else {
            return XCTFail("expected unchanged marker")
        }
        XCTAssertFalse(fingerprint.isEmpty)
    }

    func test_retentionEstimate_256KeysTo128Window() {
        let uncapped = 256 // prior defaultCountLimit
        let limit = TokenSaverFileFingerprintRegistry.defaultCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: scope+path key (~200B) + 64-hex fingerprint (~64B) + recency
        // slot ≈ ~300B. 256 × 300B ≈ 76.8KB → 128 × 300B ≈ 38.4KB (−50%).
        let perKey = 300
        XCTAssertEqual(uncapped * perKey, 76_800)
        XCTAssertEqual(limit * perKey, 38_400)
    }
}
