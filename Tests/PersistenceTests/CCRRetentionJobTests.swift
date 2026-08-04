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
        // Safe path requires protectedHandles (plan-final W3). Empty set = none protected.
        try CCRRetentionJob.runRetention(
            store: store, now: now, cutoffMs: cutoffMs, protectedHandles: []
        )

        let remaining = try store.storeSizeBytes()
        let expectedRemaining = Int64(Data(fresh.utf8).count)
        XCTAssertEqual(remaining, expectedRemaining,
                       "storeSizeBytes must drop the pruned row's byte_count after retention runs")
    }

    // MARK: - runRetention

    func test_runRetention_withoutProtectedHandles_isNoOp() throws {
        // WHY: production must fail closed when no durable handle set is supplied.
        let store = try makeStore()
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        let staleDate = epoch.addingTimeInterval(-31 * 86_400)
        try store.store("stale", at: staleDate)
        let cutoffMs = CCRRetentionJob.olderThanMs(now: epoch, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(store: store, now: epoch, cutoffMs: cutoffMs)
        XCTAssertEqual(removed, 0)
        XCTAssertEqual(try store.count(), 1)
    }

    func test_runRetention_prunesOldUnreferenced_keepsRecent() throws {
        // WHY: rows older than cutoff and not in protectedHandles are removed;
        // rows newer than cutoff survive, maintaining a usable recovery window.
        let store = try makeStore()
        let epoch = Date(timeIntervalSince1970: 1_000_000)

        let staleDate = epoch.addingTimeInterval(-31 * 86_400)
        try store.store("stale block A", at: staleDate)
        try store.store("stale block B", at: staleDate)

        let recentDate = epoch.addingTimeInterval(-1 * 86_400)
        try store.store("fresh block C", at: recentDate)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: epoch, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(
            store: store, now: epoch, cutoffMs: cutoffMs, protectedHandles: []
        )

        XCTAssertEqual(removed, 2, "two stale unprotected blocks must be pruned")
        XCTAssertEqual(try store.count(), 1, "one recent block must remain after retention")
    }

    func test_runRetention_neverPrunesProtectedRows_regardlessOfAge() throws {
        // WHY: protectedHandles models marker-reachable originals; age must not override.
        let store = try makeStore()
        let ancient = Date(timeIntervalSince1970: 0)
        let now = Date(timeIntervalSince1970: 1_000_000)

        let handle = try store.store("ancient but live block", at: ancient)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(
            store: store, now: now, cutoffMs: cutoffMs, protectedHandles: [handle]
        )

        XCTAssertEqual(removed, 0, "protected blocks must never be pruned regardless of age")
        XCTAssertNotNil(try store.retrieve(handle), "protected block must still be recoverable after retention")
    }

    func test_runRetention_emptyStoreIsNoop() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(
            store: store, now: now, cutoffMs: cutoffMs, protectedHandles: []
        )
        XCTAssertEqual(removed, 0, "retention on empty store must be a no-op (removed=0)")
    }

    func test_runRetention_allRecentIsNoop() throws {
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let recentDate = now.addingTimeInterval(-1 * 86_400)

        try store.store("block 1", at: recentDate)
        try store.store("block 2", at: recentDate)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(
            store: store, now: now, cutoffMs: cutoffMs, protectedHandles: []
        )

        XCTAssertEqual(removed, 0, "recent blocks must not be pruned before the cutoff")
        XCTAssertEqual(try store.count(), 2, "all rows must survive when all are within the retention window")
    }

    func test_runRetention_mixedProtectedAndStale() throws {
        // Stale+unprotected -> pruned. Stale+protected -> kept. Recent -> kept.
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 2_000_000)
        let staleDate = now.addingTimeInterval(-60 * 86_400)
        let recentDate = now.addingTimeInterval(-1 * 86_400)

        let staleUnref  = try store.store("stale unreferenced",  at: staleDate)
        let staleRef    = try store.store("stale but referenced", at: staleDate)
        let recentUnref = try store.store("recent unreferenced", at: recentDate)

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(
            store: store, now: now, cutoffMs: cutoffMs, protectedHandles: [staleRef]
        )

        XCTAssertEqual(removed, 1, "only stale+unprotected must be pruned")
        XCTAssertNil(try store.retrieve(staleUnref),   "stale unprotected block must be gone")
        XCTAssertNotNil(try store.retrieve(staleRef),  "stale protected block must survive")
        XCTAssertNotNil(try store.retrieve(recentUnref), "recent block must survive")
    }

    // MARK: - Wiring contract: retention actually bounds the store

    func test_retentionBoundsStore_beyondWindowIsRemoved_withinWindowSurvives() throws {
        // WHY: wiring runRetention/pruneUnreferenced to app launch + a daily timer is
        // only meaningful if calling runRetention actually removes rows that have grown
        // beyond the retention window. This test seeds content that exceeds the default
        // 30-day window, calls runRetention (the production call path), and asserts the
        // store is bounded: stale rows gone, recent rows intact. A defined-but-uncalled
        // retention method means unbounded growth; this test fails if the call is removed.
        let store = try makeStore()
        let now = Date(timeIntervalSince1970: 5_000_000)

        // Five blocks beyond the 30-day window (35 days old, unreferenced).
        let staleDate = now.addingTimeInterval(-35 * 86_400)
        var staleHandles: [String] = []
        for i in 0..<5 {
            let h = try store.store("old block \(i) -- should be pruned", at: staleDate)
            staleHandles.append(h)
        }

        // Two blocks inside the window (10 days old, unreferenced -- must survive).
        let recentDate = now.addingTimeInterval(-10 * 86_400)
        let recentA = try store.store("recent block A -- must survive", at: recentDate)
        let recentB = try store.store("recent block B -- must survive", at: recentDate)

        XCTAssertEqual(try store.count(), 7, "precondition: 7 rows before retention")

        let cutoffMs = CCRRetentionJob.olderThanMs(now: now, retentionDays: 30)
        let removed = try CCRRetentionJob.runRetention(
            store: store, now: now, cutoffMs: cutoffMs, protectedHandles: []
        )

        XCTAssertEqual(removed, 5,
            "all 5 stale unprotected rows must be pruned -- store is bounded after retention runs")
        XCTAssertEqual(try store.count(), 2,
            "only the 2 recent rows must remain -- unbounded growth is prevented")
        for h in staleHandles {
            XCTAssertNil(try store.retrieve(h),
                "stale block must be unrecoverable after retention -- it exceeded the 30-day window")
        }
        XCTAssertNotNil(try store.retrieve(recentA), "recent block A must still be recoverable")
        XCTAssertNotNil(try store.retrieve(recentB), "recent block B must still be recoverable")
    }
}
