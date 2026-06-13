import XCTest
@testable import AppShell

// Tests for the async dirty-state seam (PERF-MAC_TABS-127).
//
// WHY tested: sync RPC x tabs x rebuilds = main-thread stall on every tab
// operation (open, close, rename, reorder). The seam `dirtyStateForTab`
// encodes the synchronous decision so the live path never calls
// filesStateGet on the main thread for tab construction.
//
// All tests exercise the pure nonisolated static -- no MainActor, no window.

final class PaneTabsDirtyStateTests: XCTestCase {

    // MARK: - isDirty flag (highest priority)

    // WHY: descriptor.isDirty=true must short-circuit immediately -- no cache
    // or metadata consulted. Any regression here would hide unsaved-indicator dots.
    func test_isDirtyTrue_returnsTrue_ignoresMetadata() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: true,
            metadataDirtyCount: "0",  // would say clean if consulted
            cachedDirty: false        // would say clean if consulted
        )
        XCTAssertEqual(result, true,
                       "isDirty=true must return true regardless of metadata or cache")
    }

    func test_isDirtyTrue_returnsTrue_nilMetadataAndCache() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: true,
            metadataDirtyCount: nil,
            cachedDirty: nil
        )
        XCTAssertEqual(result, true,
                       "isDirty=true must return true even when metadata and cache are absent")
    }

    // MARK: - dirty_count metadata (second priority, no RPC)

    // WHY: dirty_count streamed via files.state.updated eliminates the sync RPC
    // for the common case. "1" -> dirty, "0" -> clean. Wrong interpretation
    // means either false negatives (missing dot) or false positives (spurious dot).
    func test_metadataDirtyCountOne_returnsTrue() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: "1",
            cachedDirty: nil
        )
        XCTAssertEqual(result, true,
                       "dirty_count=1 must report dirty without an RPC")
    }

    func test_metadataDirtyCountZero_returnsFalse() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: "0",
            cachedDirty: true  // would say dirty if consulted
        )
        XCTAssertEqual(result, false,
                       "dirty_count=0 must report clean; cache must not override explicit metadata")
    }

    func test_metadataDirtyCountNonNumeric_treatedAsZero_returnsFalse() {
        // WHY: malformed metadata must not crash or report dirty spuriously.
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: "bad",
            cachedDirty: nil
        )
        XCTAssertEqual(result, false,
                       "non-numeric dirty_count must be treated as 0 (clean), not crash")
    }

    // MARK: - cached value (third priority, async-resolved)

    // WHY: after the async RPC resolves, the cache entry is the source of truth
    // for subsequent synchronous calls. If the cache is ignored the dot would
    // disappear on the next rebuild even after the async resolve finished.
    func test_cachedDirtyTrue_returnsTrue_whenNoMetadata() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: nil,
            cachedDirty: true
        )
        XCTAssertEqual(result, true,
                       "cached true must report dirty when no metadata is present")
    }

    func test_cachedDirtyFalse_returnsFalse_whenNoMetadata() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: nil,
            cachedDirty: false
        )
        XCTAssertEqual(result, false,
                       "cached false must report clean when no metadata is present")
    }

    // MARK: - unknown state (nil return -> async resolve required)

    // WHY: nil means the caller must fire scheduleAsyncDirtyResolve and return
    // false as the cheap default. If nil were treated as clean permanently the
    // dot would never appear for files tabs whose metadata has never been set.
    func test_noMetadataNoCache_returnsNil_signallingAsyncResolveNeeded() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: nil,
            cachedDirty: nil
        )
        XCTAssertNil(result,
                     "absent metadata + absent cache must return nil so caller triggers async resolve")
    }

    // MARK: - priority ordering

    // WHY: metadata must override cache; if cache wins over metadata a stale
    // cached value could persist even after dirty_count arrives via event stream.
    func test_metadataDirtyCountZero_overrides_cachedTrue() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: "0",
            cachedDirty: true
        )
        XCTAssertEqual(result, false,
                       "metadata dirty_count=0 must override a stale cache entry that says dirty")
    }

    func test_metadataDirtyCountOne_overrides_cachedFalse() {
        let result = PaneTabsView.dirtyStateForTab(
            isDirty: false,
            metadataDirtyCount: "1",
            cachedDirty: false
        )
        XCTAssertEqual(result, true,
                       "metadata dirty_count=1 must override a stale cache entry that says clean")
    }
}
