import XCTest
@testable import Persistence

/// Tests for CCRRetentionJob and ReversibleContentStore.storeSizeBytes().
///
/// WHY each test matters:
///   - pruneUnreferenced is the only growth-limiting mechanism on rc_reversible_content;
///     without it the table grows unboundedly. These tests prove the job prunes the right
///     rows (old unreferenced), keeps the right rows (recent OR referenced), and that
///     storeSizeBytes() correctly reflects remaining content so a diagnostics view can
///     show real numbers.
///   - olderThanMs is a pure math helper; a bug there silently misfires the cutoff for
///     every caller, so it is verified against known arithmetic.
final class CCRRetentionJobTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore() throws -> ReversibleContentStore {
        let db = try SQLiteDB(path: ":memory:")
        try Schema.migrate(db)
        return ReversibleContentStore(db: db)
    }

    // MARK: - olderThanMs pure helper

    func test_olderThanMs_30dayDefault() {
        // WHY: verifies the cutoff math produces exactly 30 days before `now` in ms.
        // A wrong multiplier (e.g. 60 instead of 86400) would silently prune-all or prune-nothing.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cutoff = CCRRetentionJob.olderThanMs(now: now)
        let expected = Int64((now.timeIntervalSince1970 - 30 * 86_400) * 1000)
        XCTAssertEqual(cutoff, expected, "default 30-day cutoff must equal now - 30*86400 seconds in ms")
    }

    func test_olderThanMs_customRetentionDays() {
        // WHY: callers can override retentionDays; the helper must use the supplied value, not
        // a hardcoded 30, so a 7-day retention does not silently fall back to 30 days.
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cutoff7 = CCRRetentionJob.olderThanMs(now: now, retentionDays: 7)
        let expected = Int64((now.timeIntervalSince1970 - 7 * 86_400) * 1000)
        XCTAssertEqual(cutoff7, expected, "7-day cutoff must equal now - 7*86400 seconds in ms")
    }

    func test_olderThanMs_zeroDays() {
        // WHY: zero days means prune everything older than `now` (immediate cutoff).
        // The helper must not clamp or special-case zero.
        let now = Date(timeIntervalSince1970: 500_000)
        let cutoff = CCRRetentionJob.olderThanMs(now: now, retentionDays: 0)
        let expected = Int64(now.timeIntervalSince1970 * 1000)
        XCTAssertEqual(cutoff, expected, "zero retention days must produce a cutoff equal to now in ms")
    }

    // MARK: - storeSizeBytes

    func test_storeSizeBytes_emptyStore() throws {
        // WHY: an empty store must report 0 bytes, not nil/crash; the diagnostics view
        // must be able to display "0 B" on first launch before any content is stored.
        let store = try makeStore()
        XCTAssertEqual(try store.storeSizeBytes(), 0, "empty store must report 0 bytes")
    }

    func test_storeSizeBytes_reflectsStoredContent() throws {
        // WHY: byte_count is inserted at store-time; SUM(byte_count) must match the
        // actual UTF-8 byte sizes of the stored strings so the diagnostics number is accurate.
        let store = try makeStore()
        let a = "hello"      // 5 bytes UTF-8
        let b = "world!"     // 6 bytes UTF-8
        try store.store(a)
        try store.store(b)
        let expected = Int64(Data(a.utf8).count + Data(b.utf8).count)
        XCTAssertEqual(try store.storeSizeBytes(), expected,
                       "storeSizeBytes must sum byte_count of all rows (diagnostics accuracy)")
    }

    func test_storeSizeBytes_dedupDoesNotDoubleCount() throws {
        // WHY: content-addressed dedup means storing identical bytes twice must not
        // double the reported size; the upsert keeps one row, so SUM is unchanged.
        let store = try makeStore()
        let payload = "identical"
        try store.store(payload)
        try store.store(payload) // second store = upsert, single row
        let expected = Int64(Data(payload.utf8).count)
        XCTAssertEqual(try store.storeSizeBytes(), expected,
                       "dedup upsert must not double the size reported by storeSizeBytes")
    }

    func test_storeSizeBytes_decreasesAfterPrune() throws {
        // WHY: after pruning stale rows, storeSizeBytes must reflect the remaining
        // content so the diagnostics view shows reclaimed space correctly.
        let store = try makeStore()
        let t0 = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let stale = "stale data"
        let fresh = "fresh data"
        try store.store(stale, at: t0)       // old, unreferenced -> prunable
        try store.store(fresh, at: now)      // recent -> kept

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 1)
        try CCRRetentionJob.runRetention(store: store, now: now, cutoffMs: cutoffMs)

        let remaining = try store.storeSizeBytes()
        let expectedRemaining = Int64(Data(fresh.utf8).count)
        XCTAssertEqual(remaining, expectedRemaining,
                       "storeSizeBytes must drop the pruned row's byte_count after retention runs")
    }

    // MARK: - runRetention

    func test_runRetention_prunesOldUnreferenced_keepsRecent() throws {
        // WHY: the core contract — rows older than cutoff with ref_count<=0 are removed;
        // rows newer than cutoff survive, maintaining a usable recovery window.
        let store = try makeStore()
        let epoch = Date(timeIntervalSince1970: 1_000_000)

        // Stored 31 days ago (before cutoff)
        let staleDate = epoch.addingTimeInterval(-31 * 86_400)
        try store.store("stale block A", at: staleDate)
        try store.store("stale block B", at: staleDate)

        // Stored 1 day ago (after cutoff)
        let recentDate = epoch.addingTimeInterval(-1 * 86_400)
        try store.store("fresh block C", at: recentDate)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: epoch, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(store: store, now: epoch, cutoffMs: cutoffMs)

        XCTAssertEqual(removed, 2, "two stale unreferenced blocks must be pruned")
        XCTAssertEqual(try store.count(), 1, "one recent block must remain after retention")
    }

    func test_runRetention_neverPrunesReferencedRows_regardlessOfAge() throws {
        // WHY: ref_count > 0 means a live transcript holds this block; evicting it
        // would corrupt the transcript's recovery path. Age must not override ref_count.
        let store = try makeStore()
        let ancient = Date(timeIntervalSince1970: 0)  // year 1970 — far older than any cutoff
        let now = Date(timeIntervalSince1970: 1_000_000)

        let handle = try store.store("ancient but live block", at: ancient)
        try store.retain(handle)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(store: store, now: now, cutoffMs: cutoffMs)

        XCTAssertEqual(removed, 0, "referenced blocks must never be pruned regardless of age")
        XCTAssertNotNil(try store.retrieve(handle), "referenced block must still be recoverable after retention")
    }

    func test_runRetention_emptyStoreIsNoop() throws {
        // WHY: running retention on an empty store must not throw or return a negative
        // count; the daily job must be safe to fire unconditionally.
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(store: store, now: now, cutoffMs: cutoffMs)
        XCTAssertEqual(removed, 0, "retention on empty store must be a no-op (removed=0)")
    }

    func test_runRetention_allRecentIsNoop() throws {
        // WHY: if every row is newer than the cutoff, nothing should be removed;
        // a bug in the cutoff comparison could silently wipe recent data.
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentDate = now.addingTimeInterval(-1 * 86_400) // 1 day ago, within 30-day window

        try store.store("block 1", at: recentDate)
        try store.store("block 2", at: recentDate)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(store: store, now: now, cutoffMs: cutoffMs)

        XCTAssertEqual(removed, 0, "recent unreferenced blocks must not be pruned before the cutoff")
        XCTAssertEqual(try store.count(), 2, "all rows must survive when all are within the retention window")
    }

    func test_runRetention_mixedReferencedAndStale() throws {
        // WHY: validates the intersection of two independent criteria (age AND ref_count).
        // Stale+unreferenced -> pruned. Stale+referenced -> kept. Recent+unreferenced -> kept.
        // A bug that ignores either dimension silently deletes the wrong rows.
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleDate = now.addingTimeInterval(-60 * 86_400) // 60 days ago
        let recentDate = now.addingTimeInterval(-1 * 86_400) // 1 day ago

        let staleUnref  = try store.store("stale unreferenced",  at: staleDate)
        let staleRef    = try store.store("stale but referenced", at: staleDate)
        let recentUnref = try store.store("recent unreferenced", at: recentDate)

        try store.retain(staleRef)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(store: store, now: now, cutoffMs: cutoffMs)

        XCTAssertEqual(removed, 1, "only stale+unreferenced must be pruned")
        XCTAssertNil(try store.retrieve(staleUnref),   "stale unreferenced block must be gone")
        XCTAssertNotNil(try store.retrieve(staleRef),  "stale referenced block must survive")
        XCTAssertNotNil(try store.retrieve(recentUnref), "recent unreferenced block must survive")
    }
}
