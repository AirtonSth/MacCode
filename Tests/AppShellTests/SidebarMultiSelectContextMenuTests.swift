import XCTest
@testable import AppShell
import CoreModel

// Pure helper tests - no AppKit/SwiftUI involved; no @MainActor required.
// Rule 8: every assertion encodes WHY the business rule matters, not just
// what the value is.
final class SidebarMultiSelectContextMenuTests: XCTestCase {

    // MARK: - Helpers

    private func makeID() -> WorkspaceID {
        WorkspaceID(UUID())
    }

    // MARK: - clicked row IS in a multi-item selection

    func test_clickedRowInSelectionOfTwo_returnsMultiModeWithCount2() {
        let a = makeID()
        let b = makeID()
        let result = SidebarViewModel.sidebarContextMenuMode(
            clickedID: a,
            selectedIDs: [a, b]
        )
        XCTAssertTrue(result.isMulti,
                      "right-clicking a row that is part of a 2-item selection must show the batch menu, " +
                      "not a single-row menu, so that users can act on all selected workspaces at once")
        XCTAssertEqual(result.count, 2,
                       "the batch menu label must reflect the number of selected workspaces (2), " +
                       "not a hardcoded value, so the user knows how many items will be affected")
    }

    func test_clickedRowInSelectionOfFive_returnsMultiModeWithCount5() {
        let ids = (0..<5).map { _ in makeID() }
        let clicked = ids[2]
        let result = SidebarViewModel.sidebarContextMenuMode(
            clickedID: clicked,
            selectedIDs: Set(ids)
        )
        XCTAssertTrue(result.isMulti,
                      "right-clicking any row in a large multi-selection must trigger the batch menu")
        XCTAssertEqual(result.count, 5,
                       "count must equal the full selection size so the destructive confirmation warns correctly")
    }

    // MARK: - clicked row is OUTSIDE the current selection

    func test_clickedRowOutsideSelection_returnsSingleMode() {
        let outside = makeID()
        let a = makeID()
        let b = makeID()
        let result = SidebarViewModel.sidebarContextMenuMode(
            clickedID: outside,
            selectedIDs: [a, b]
        )
        XCTAssertFalse(result.isMulti,
                       "right-clicking a row that is not in the current selection must show the single-row menu, " +
                       "consistent with standard macOS list behavior where the context menu acts on the row under the cursor")
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - empty selection

    func test_emptySelection_returnsSingleMode() {
        let id = makeID()
        let result = SidebarViewModel.sidebarContextMenuMode(
            clickedID: id,
            selectedIDs: []
        )
        XCTAssertFalse(result.isMulti,
                       "with nothing explicitly multi-selected the context menu must always show single-row actions; " +
                       "the batch menu should never appear when there is no active multi-selection to act on")
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - single-item selection (edge: not considered multi)

    func test_singleItemSelectionContainingClickedRow_returnsSingleMode() {
        let id = makeID()
        let result = SidebarViewModel.sidebarContextMenuMode(
            clickedID: id,
            selectedIDs: [id]
        )
        XCTAssertFalse(result.isMulti,
                       "a selection of exactly one row must not show the multi-select menu because " +
                       "there is no batch to perform; the threshold for batch mode is >= 2 selected rows")
        XCTAssertEqual(result.count, 1)
    }
}
