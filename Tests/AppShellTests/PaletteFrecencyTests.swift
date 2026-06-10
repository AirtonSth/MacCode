import XCTest
@testable import AppShell

// MARK: - In-memory repository double

/// Thread-unsafe in-memory kv store for testing — no SQLite required.
private final class FakeKVRepo: PaletteFrecencyRepository {
    var store: [String: String] = [:]
    func get(_ key: String) throws -> String? { store[key] }
    func set(_ key: String, _ value: String) throws { store[key] = value }
}

// MARK: - Scorer tests

/// Verifies PaletteFrecencyScorer: frecency formula correctness + relative ordering.
///
/// WHY: the scorer is the business-critical function that determines whether
/// \"New Terminal\" beats \"New Browser\" for query \"n\" after the user has
/// opened more terminals than browsers.  Tests must break if the formula is
/// accidentally removed or inverted.
final class PaletteFrecencyScorerTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: - Monotonicity: more uses -> higher score

    func test_score_moreUsesYieldsHigherScore() {
        // WHY: a command used 10 times must outscore one used once, same recency.
        let s1 = PaletteFrecencyScorer.score(uses: 1, lastUsedAt: now, now: now)
        let s10 = PaletteFrecencyScorer.score(uses: 10, lastUsedAt: now, now: now)
        XCTAssertGreaterThan(s10, s1, "10 uses must score higher than 1 use at equal recency")
    }

    func test_score_moreRecentYieldsHigherScore() {
        // WHY: a command used 1 minute ago must outscore one used 30 days ago
        // for the same use count.
        let recentDate = now.addingTimeInterval(-60)   // 1 minute ago
        let oldDate    = now.addingTimeInterval(-60 * 60 * 24 * 30)  // 30 days ago
        let sRecent = PaletteFrecencyScorer.score(uses: 5, lastUsedAt: recentDate, now: now)
        let sOld    = PaletteFrecencyScorer.score(uses: 5, lastUsedAt: oldDate,    now: now)
        XCTAssertGreaterThan(sRecent, sOld, "recent use must score higher than old use at equal count")
    }

    func test_score_neverUsedIsPositive() {
        // WHY: uses=0 must still produce a positive score (count+1 floor) so
        // new commands are not completely buried under used ones.
        let s = PaletteFrecencyScorer.score(uses: 0, lastUsedAt: .distantPast, now: now)
        XCTAssertGreaterThan(s, 0, "even an unused command must have a positive floor score")
    }

    func test_score_neverUsedScoredBelow_usedOnce() {
        // WHY: a command used once recently must outrank one never used.
        let sUsed  = PaletteFrecencyScorer.score(uses: 1, lastUsedAt: now, now: now)
        let sNever = PaletteFrecencyScorer.score(uses: 0, lastUsedAt: .distantPast, now: now)
        XCTAssertGreaterThan(sUsed, sNever,
            "a recently used command must beat a never-used command")
    }

    func test_score_halfLifeDecay_atHalfLifeIsHalf() {
        // WHY: validates the decay formula: at exactly one half-life the decay
        // factor must be 0.5.  If someone changes the formula the test breaks.
        let halfLifeAgo = now.addingTimeInterval(-PaletteFrecencyScorer.halfLifeSeconds)
        let sNow  = PaletteFrecencyScorer.score(uses: 1, lastUsedAt: now,         now: now)
        let sHalf = PaletteFrecencyScorer.score(uses: 1, lastUsedAt: halfLifeAgo, now: now)
        XCTAssertEqual(sHalf, sNow * 0.5, accuracy: 0.001,
            "score at one half-life ago must be exactly half the current score")
    }
}

// MARK: - Merger tests

/// Verifies PaletteFrecencyMerger: more-frecent commands are ranked first.
///
/// WHY: this is the integration seam that CommandPalette calls to reorder the
/// default view.  Tests must break if the comparator is inverted or entries
/// with no data are accidentally placed before scored ones.
final class PaletteFrecencyMergerTests: XCTestCase {

    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    func test_ranked_moreFrecentCommandComesFirst() {
        // WHY: \"surface.new.terminal\" used 5x recently must appear before
        // \"surface.new.browser\" used 1x older — this is exactly the stated
        // P2 requirement (\"New Terminal beats New Browser for query n over time\").
        let terminal = PaletteFrecencyEntry(
            id: "surface.new.terminal",
            useCount: 5,
            lastUsedAt: now.addingTimeInterval(-3600)   // 1 hour ago
        )
        let browser = PaletteFrecencyEntry(
            id: "surface.new.browser",
            useCount: 1,
            lastUsedAt: now.addingTimeInterval(-7 * 24 * 3600)  // 7 days ago
        )
        let ids = ["surface.new.terminal", "surface.new.browser"]
        let ranked = PaletteFrecencyMerger.ranked(candidateIDs: ids, entries: [terminal, browser], now: now)
        XCTAssertEqual(ranked.first, "surface.new.terminal",
            "more-frecent terminal must rank before less-frecent browser")
    }

    func test_ranked_lessFrecentBrowserComesBefore_terminal_whenUsedMore() {
        // WHY: if the user runs the browser more often, it should rank first.
        let terminal = PaletteFrecencyEntry(
            id: "surface.new.terminal",
            useCount: 1,
            lastUsedAt: now.addingTimeInterval(-7 * 24 * 3600)
        )
        let browser = PaletteFrecencyEntry(
            id: "surface.new.browser",
            useCount: 10,
            lastUsedAt: now.addingTimeInterval(-3600)
        )
        let ids = ["surface.new.terminal", "surface.new.browser"]
        let ranked = PaletteFrecencyMerger.ranked(candidateIDs: ids, entries: [terminal, browser], now: now)
        XCTAssertEqual(ranked.first, "surface.new.browser",
            "frequently used browser must rank above rarely used terminal")
    }

    func test_ranked_unscoredCommandsAppendedAfterScored() {
        // WHY: commands with no usage history must not push scored commands down;
        // they must all land after all commands that have frecency data.
        let terminal = PaletteFrecencyEntry(
            id: "surface.new.terminal",
            useCount: 3,
            lastUsedAt: now.addingTimeInterval(-600)
        )
        let ids = ["session.save", "surface.new.terminal", "app.quit"]
        let ranked = PaletteFrecencyMerger.ranked(candidateIDs: ids, entries: [terminal], now: now)
        XCTAssertEqual(ranked.first, "surface.new.terminal",
            "scored command must appear before unscored commands regardless of insertion order")
        // Unscored commands preserve relative insertion order.
        let unscoredPart = ranked.filter { $0 != "surface.new.terminal" }
        XCTAssertEqual(unscoredPart, ["session.save", "app.quit"],
            "unscored commands keep their original relative order")
    }

    func test_ranked_emptyEntriesReturnsOriginalOrder() {
        // WHY: when no frecency data exists the default view must not change —
        // regression guard for pre-P2 behavior.
        let ids = ["a", "b", "c"]
        let ranked = PaletteFrecencyMerger.ranked(candidateIDs: ids, entries: [], now: now)
        XCTAssertEqual(ranked, ids, "empty entries must preserve original insertion order")
    }

    func test_ranked_tieBrokenByOriginalInsertionOrder() {
        // WHY: two commands with identical frecency score must keep the
        // original catalog insertion order (deterministic, no flakiness).
        let t = now.addingTimeInterval(-100)
        let a = PaletteFrecencyEntry(id: "cmd.a", useCount: 3, lastUsedAt: t)
        let b = PaletteFrecencyEntry(id: "cmd.b", useCount: 3, lastUsedAt: t)
        let ids = ["cmd.a", "cmd.b"]
        let ranked = PaletteFrecencyMerger.ranked(candidateIDs: ids, entries: [a, b], now: now)
        XCTAssertEqual(ranked, ["cmd.a", "cmd.b"],
            "equal-score commands must be stable (insertion order)")
    }
}

// MARK: - Store persistence tests

/// Verifies PaletteFrecencyStore: load/save round-trip + use count increments.
///
/// WHY: the store is the only cross-launch durability path.  If it silently
/// fails to persist, frecency would reset on every launch and the ranking
/// would never improve — the entire P2 value proposition collapses.
final class PaletteFrecencyStoreTests: XCTestCase {

    // MARK: - Round-trip

    func test_store_roundTrip_persistsAndLoadsEntries() {
        // WHY: verifies that an entry written via recordUse can be read back
        // by a fresh store instance sharing the same repository.
        let repo = FakeKVRepo()
        let date = Date(timeIntervalSinceReferenceDate: 500_000)
        let store1 = PaletteFrecencyStore(repo: repo)
        store1.recordUse(id: "surface.new.terminal", at: date)

        let store2 = PaletteFrecencyStore(repo: repo)
        let entries = store2.load()
        XCTAssertEqual(entries.count, 1, "one entry must survive round-trip")
        XCTAssertEqual(entries.first?.id, "surface.new.terminal")
        XCTAssertEqual(entries.first?.useCount, 1,
            "use count must be 1 after first recordUse")
        XCTAssertEqual(entries.first!.lastUsedAt.timeIntervalSinceReferenceDate,
                       date.timeIntervalSinceReferenceDate, accuracy: 0.001,
                       "lastUsedAt must survive round-trip with sub-second precision")
    }

    func test_store_recordUse_incrementsCount() {
        // WHY: calling recordUse three times must produce useCount == 3, not 1.
        // If upsert logic is wrong and inserts instead of updating, this fails.
        let repo = FakeKVRepo()
        let store = PaletteFrecencyStore(repo: repo)
        let t = Date(timeIntervalSinceReferenceDate: 300_000)
        store.recordUse(id: "cmd.a", at: t)
        store.recordUse(id: "cmd.a", at: t)
        store.recordUse(id: "cmd.a", at: t)
        let entries = store.load()
        XCTAssertEqual(entries.first(where: { $0.id == "cmd.a" })?.useCount, 3,
            "three calls to recordUse must yield useCount == 3")
    }

    func test_store_recordUse_updatesLastUsedAt() {
        // WHY: lastUsedAt must reflect the most recent call, not the first.
        // Recency ranking breaks if the timestamp is never updated.
        let repo = FakeKVRepo()
        let store = PaletteFrecencyStore(repo: repo)
        let t1 = Date(timeIntervalSinceReferenceDate: 100_000)
        let t2 = Date(timeIntervalSinceReferenceDate: 200_000)
        store.recordUse(id: "cmd.a", at: t1)
        store.recordUse(id: "cmd.a", at: t2)
        let entry = store.load().first(where: { $0.id == "cmd.a" })
        XCTAssertEqual(entry!.lastUsedAt.timeIntervalSinceReferenceDate,
                       t2.timeIntervalSinceReferenceDate, accuracy: 0.001,
                       "lastUsedAt must be updated to the most recent call")
    }

    func test_store_multipleIDs_storedIndependently() {
        // WHY: terminal and browser must each keep their own counts; a bug that
        // shares a counter or key would make both IDs appear as one entry.
        let repo = FakeKVRepo()
        let store = PaletteFrecencyStore(repo: repo)
        let t = Date(timeIntervalSinceReferenceDate: 400_000)
        store.recordUse(id: "surface.new.terminal", at: t)
        store.recordUse(id: "surface.new.terminal", at: t)
        store.recordUse(id: "surface.new.browser",  at: t)
        let entries = store.load()
        let tEntry = entries.first(where: { $0.id == "surface.new.terminal" })
        let bEntry = entries.first(where: { $0.id == "surface.new.browser"  })
        XCTAssertEqual(tEntry?.useCount, 2, "terminal count must be 2")
        XCTAssertEqual(bEntry?.useCount, 1, "browser count must be 1")
    }

    func test_store_emptyRepo_loadReturnsEmpty() {
        // WHY: a fresh repo (first launch, or cleared DB) must not crash or
        // return garbage — the absence of data must degrade to an empty list.
        let repo = FakeKVRepo()
        let store = PaletteFrecencyStore(repo: repo)
        XCTAssertEqual(store.load(), [], "empty repo must return empty entries")
    }

    func test_store_cap_trimsToCapSize() {
        // WHY: if the cap is not enforced, the stored JSON grows unboundedly.
        // After cap+1 distinct IDs the store must hold at most cap entries.
        let repo = FakeKVRepo()
        let cap = 5
        let store = PaletteFrecencyStore(repo: repo, cap: cap)
        let t = Date(timeIntervalSinceReferenceDate: 600_000)
        for i in 0..<(cap + 3) {
            store.recordUse(id: "cmd.\(i)", at: t.addingTimeInterval(Double(i)))
        }
        let entries = store.load()
        XCTAssertLessThanOrEqual(entries.count, cap,
            "store must not exceed cap after recording more than cap distinct IDs")
    }
}
