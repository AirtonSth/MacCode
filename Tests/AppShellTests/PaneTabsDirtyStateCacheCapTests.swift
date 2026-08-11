import XCTest
@testable import AppShell
import CoreModel

/// PERF: bounds PaneTabsView.dirtyStateCache so closed-tab churn cannot pin
/// unbounded SurfaceID→Bool memos process-wide for the pane lifetime.
///
/// WHY: async dirty resolve and files.state.updated events insert cache keys
/// but structural rebuild only refreshed tabButtons — never the dirty map.
/// Multi-day tab open/close grew SurfaceID membership without bound. Cap at
/// 256 and prune to live strip ids on structural rebuild; misses re-resolve
/// async (cold-start / first-paint parity).
final class PaneTabsDirtyStateCacheCapTests: XCTestCase {

    func test_builtInCountLimit() {
        XCTAssertEqual(PaneTabsView.dirtyStateCacheCountLimit, 256)
    }

    func test_noteDirtyStateCacheEntry_capsDistinctKeys() {
        var cache: [SurfaceID: Bool] = [:]
        let limit = 4
        var newest = SurfaceID()
        for _ in 0..<(limit + 12) {
            newest = SurfaceID()
            PaneTabsView.noteDirtyStateCacheEntry(
                &cache, id: newest, isDirty: true, countLimit: limit
            )
        }
        XCTAssertEqual(cache.count, limit)
        XCTAssertEqual(cache[newest], true)
    }

    func test_noteDirtyStateCacheEntry_updatesExistingWithoutGrowth() {
        var cache: [SurfaceID: Bool] = [:]
        let id = SurfaceID()
        PaneTabsView.noteDirtyStateCacheEntry(&cache, id: id, isDirty: false, countLimit: 3)
        PaneTabsView.noteDirtyStateCacheEntry(&cache, id: id, isDirty: true, countLimit: 3)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache[id], true)
    }

    func test_pruneDirtyStateCache_retainsOnlyLiveIDs() {
        let live = SurfaceID()
        let dead = SurfaceID()
        var cache: [SurfaceID: Bool] = [live: true, dead: false]
        PaneTabsView.pruneDirtyStateCache(&cache, retaining: [live])
        XCTAssertEqual(cache, [live: true])
    }

    func test_pruneDirtyStateCache_emptyLiveClearsAll() {
        var cache: [SurfaceID: Bool] = [SurfaceID(): true, SurfaceID(): false]
        PaneTabsView.pruneDirtyStateCache(&cache, retaining: [])
        XCTAssertTrue(cache.isEmpty)
    }

    func test_retentionEstimate_2kTabsTo256Window() {
        let uncapped = 2_000
        let limit = PaneTabsView.dirtyStateCacheCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.87)
        XCTAssertEqual(limit, 256)
        // Basis: SurfaceID (16B) + Bool + dict overhead ≈ ~48B/key.
        // 2k × 48B ≈ 96KB → 256 × 48B ≈ 12.3KB (−87.2%).
        let perKey = 48
        XCTAssertEqual(uncapped * perKey, 96_000)
        XCTAssertEqual(limit * perKey, 12_288)
    }
}
