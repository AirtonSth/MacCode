import XCTest
@testable import AppShell

/// QA-cross:36 -- the mac same-pane tab-reorder position rule
/// (PaneTabsView.adjustedSamePanePosition) must share semantics with the iOS
/// TabReorderPlan.plan offset rule, which iOS already covers in TabReorderPlanTests.
/// These cases mirror the iOS fixtures so a divergence in either repo fails a test:
///   - rightward same-pane move offsets the target by its own removal (-1)
///   - leftward move (sourceIndex >= target) keeps the target slot (no offset)
/// WHY: the two platforms drive the same `surface.reorder` host RPC; if their
/// position math drifts, a drag reorders to a different slot per device.
final class TabReorderParityTests: XCTestCase {

    func test_rightwardSamePaneMoveOffsetsForOwnRemoval() {
        // iOS parity: TabReorderPlanTests.test_samePane_dragRightward... expects
        // position 1 for source 0 dropped at slot 2 (a,b,c -> drag a onto c).
        XCTAssertEqual(PaneTabsView.adjustedSamePanePosition(sourceIndex: 0, targetPosition: 2), 1,
                       "a rightward same-pane move must offset its target by its own removal")
    }

    func test_leftwardSamePaneMoveKeepsTargetSlot() {
        // iOS parity: leftward move inserts at the neighbor's slot, no offset.
        XCTAssertEqual(PaneTabsView.adjustedSamePanePosition(sourceIndex: 2, targetPosition: 0), 0,
                       "a leftward same-pane move must keep the target slot (no removal offset)")
    }

    func test_sourceEqualsTargetIsANoOpPosition() {
        XCTAssertEqual(PaneTabsView.adjustedSamePanePosition(sourceIndex: 1, targetPosition: 1), 1,
                       "dropping at the source's own slot must not shift the position")
    }

    func test_unresolvableSourceKeepsTarget() {
        XCTAssertEqual(PaneTabsView.adjustedSamePanePosition(sourceIndex: nil, targetPosition: 3), 3,
                       "a drop whose source surface is not in the pane (cross-pane) keeps the raw target")
    }

    func test_rightwardToZeroClampsNonNegative() {
        // Degenerate guard: target 0 with a source before it cannot underflow.
        XCTAssertEqual(PaneTabsView.adjustedSamePanePosition(sourceIndex: 0, targetPosition: 0), 0,
                       "the offset must never produce a negative position")
    }
}
