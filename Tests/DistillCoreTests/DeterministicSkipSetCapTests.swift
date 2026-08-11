import XCTest
@testable import DistillCore

/// PERF: bounds the Token Saver deterministic skip-set so unique non-compressible
/// inputs cannot pin unbounded (sha → turn) rows after TTL, and caps live keys.
///
/// WHY: `recordIfDeterministic` previously only inserted — expired SHAs stayed in
/// the map forever. Long agent sessions with many tool outputs below the gain
/// floor grew the dictionary without bound. Misses only re-evaluate the router
/// (same as cold start / TTL expiry).
final class DeterministicSkipSetCapTests: XCTestCase {

    func test_builtInCountLimit() {
        XCTAssertEqual(DeterministicSkipSet.defaultCountLimit, 128)
    }

    func test_prunedEntries_dropsExpiredOnInsert() {
        var entries: [String: Int] = [
            "old-sha": 0,
            "mid-sha": 50,
        ]
        // ttl=10, now=100 → both expired; insert fresh
        entries = DeterministicSkipSet.prunedEntries(
            entries,
            inserting: 100,
            for: "new-sha",
            now: 100,
            ttlTurns: 10,
            countLimit: 256
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries["new-sha"], 100)
        XCTAssertNil(entries["old-sha"])
        XCTAssertNil(entries["mid-sha"])
    }

    func test_prunedEntries_capsDistinctKeys_evictsOldest() {
        var entries: [String: Int] = [:]
        let limit = 8
        for i in 0..<(limit + 20) {
            entries = DeterministicSkipSet.prunedEntries(
                entries,
                inserting: i,
                for: "sha-\(i)",
                now: i,
                ttlTurns: 10_000,
                countLimit: limit
            )
        }
        XCTAssertEqual(entries.count, limit)
        XCTAssertEqual(entries["sha-\(limit + 19)"], limit + 19)
        // Oldest must be gone
        XCTAssertNil(entries["sha-0"])
    }

    func test_recordIfDeterministic_enforcesCapOnLiveSet() {
        var skip = DeterministicSkipSet(ttlTurns: 10_000, countLimit: 4)
        for i in 0..<20 {
            skip.recordIfDeterministic(
                input: "payload-\(i)",
                routerReturnedNil: true,
                belowGainFloor: true,
                now: i
            )
        }
        XCTAssertEqual(skip.count, 4)
        // Newest still skippable
        XCTAssertTrue(skip.shouldSkip(input: "payload-19", now: 19))
    }

    func test_existingSemantics_ttlAndTransientUnchanged() {
        // Regression guard for I4.3 contract used by NLIAndCacheInfraTests.
        var skip = DeterministicSkipSet(ttlTurns: 10, countLimit: 256)
        skip.recordIfDeterministic(input: "abc", routerReturnedNil: true, belowGainFloor: true, now: 0)
        XCTAssertTrue(skip.shouldSkip(input: "abc", now: 1))
        skip.recordIfDeterministic(input: "json", routerReturnedNil: false, belowGainFloor: true, now: 0)
        XCTAssertFalse(skip.shouldSkip(input: "json", now: 1))
        skip.recordTransientError(input: "timed-out")
        XCTAssertFalse(skip.shouldSkip(input: "timed-out", now: 1))
        XCTAssertFalse(skip.shouldSkip(input: "abc", now: 100))
    }

    func test_retentionEstimate_256KeysTo128Window() {
        let uncapped = 256 // prior defaultCountLimit
        let limit = DeterministicSkipSet.defaultCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: ~80 B/entry (64-hex sha + Int + dict overhead) →
        // 256 ≈ 20.5 KB; 128 ≈ 10.2 KB (−50%).
        let perKey = 80
        let before = uncapped * perKey
        let after = limit * perKey
        XCTAssertEqual(before, 20_480)
        XCTAssertEqual(after, 10_240)
        XCTAssertLessThan(Double(after) / Double(before), 0.51)
    }
}
