import XCTest
import CoreModel
@testable import AppShell

/// Drop-position math for drag-to-reorder tabs. The returned index is
/// fed straight to `reorderSurface(..., position:)`, so an off-by-one
/// here silently drops a dragged tab into the wrong slot — the whole
/// point of the gesture. These pin the contract: the index is the
/// count of tab midpoints strictly left of the drop x, clamped to a
/// valid insertion range.
@MainActor
final class TabDragTests: XCTestCase {

    func test_dropIndex_emptyStrip_isZero() {
        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: [], dropX: 0), 0)
        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: [], dropX: 999), 0,
                       "no tabs means the only valid insertion point is 0")
    }

    func test_dropIndex_buckets_byMidpoint() {
        let mids: [CGFloat] = [10, 30, 50]   // three tabs, centers at these x

        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: mids, dropX: 5), 0,
                       "left of every tab → before the first")
        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: mids, dropX: 20), 1,
                       "past tab 0's center, before tab 1's → between them")
        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: mids, dropX: 40), 2)
    }

    func test_dropIndex_pastLastTab_clampsToCount() {
        let mids: [CGFloat] = [10, 30, 50]
        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: mids, dropX: 1000), 3,
                       "dropping beyond the last tab appends, never overflows count")
    }

    func test_dropIndex_exactlyOnMidpoint_staysLeft() {
        // `dropX > mid` is strict, so a drop exactly on a center does
        // not jump past that tab — stable, predictable behavior.
        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: [10, 30], dropX: 10), 0)
        XCTAssertEqual(PaneTabsView.dropInsertionIndex(tabMidXs: [10, 30], dropX: 30), 1)
    }
}
