import XCTest
import CoreModel
@testable import AppShell

// Tests for shift-click range selection in SSH file tables.
//
// WHY: Mac users expect shift-click to select a contiguous range from the
// last-clicked anchor to the clicked row (Finder convention). Before this
// fix, shift-click and cmd-click both toggled a single row -- breaking the
// platform convention and making multi-file selection require cmd-clicking
// each row individually.
//
// Pure helper tests are decoupled from AppKit/SSHFileEntry so they can run
// without UI infrastructure. Surface integration tests verify anchor tracking
// through the SSHSurface testing hooks.

// MARK: - Pure index math

final class SSHRangeIndicesTests: XCTestCase {

    // WHY: anchor 2 to clicked 5 must select indices 2,3,4,5. If lo or hi
    // is wrong, range-extension misses rows and the user gets a partial selection.
    func test_anchorBeforeClicked_returnsForwardRange() {
        let range = sshRangeIndices(anchor: 2, clicked: 5, count: 10)
        XCTAssertEqual(range, 2...5,
                       "anchor 2 -> clicked 5 must produce range 2...5")
    }

    // WHY: shift-clicking above the anchor (reverse order) must select the same
    // rows as the forward direction. If order matters, shift-clicking upward
    // produces an empty or wrong selection.
    func test_clickedBeforeAnchor_returnsSameRange() {
        let range = sshRangeIndices(anchor: 5, clicked: 2, count: 10)
        XCTAssertEqual(range, 2...5,
                       "anchor 5 -> clicked 2 must produce the same range 2...5")
    }

    // WHY: clicking the same row as the anchor must produce a single-row range.
    // An empty result would deselect the anchor on shift-click of the same row.
    func test_anchorEqualsClicked_returnsSingleRow() {
        let range = sshRangeIndices(anchor: 3, clicked: 3, count: 10)
        XCTAssertEqual(range, 3...3)
    }

    // WHY: a clicked index beyond the list end is a programming error (the view
    // should only supply valid indices). The helper returns nil so the caller can
    // fall through to a no-op instead of crashing with an out-of-bounds subscript.
    func test_clickedOutOfBounds_returnsNil() {
        let range = sshRangeIndices(anchor: 0, clicked: 10, count: 10)
        XCTAssertNil(range,
                     "clicked index >= count must return nil to prevent OOB crash")
    }

    // WHY: a negative anchor is always invalid. Returning nil avoids subscripting
    // a negative index, which would crash.
    func test_negativeAnchor_returnsNil() {
        let range = sshRangeIndices(anchor: -1, clicked: 3, count: 10)
        XCTAssertNil(range)
    }

    // WHY: a zero-element list has no valid index. Both 0 and 0 would be out
    // of bounds for an empty array.
    func test_emptyList_returnsNil() {
        let range = sshRangeIndices(anchor: 0, clicked: 0, count: 0)
        XCTAssertNil(range)
    }
}

// MARK: - Surface integration (anchor tracking + selection IDs)

@MainActor
final class SSHRangeSelectionIntegrationTests: XCTestCase {

    private func makeSurface() throws -> SSHSurface {
        try SSHSurface(workspaceID: WorkspaceID(), cwd: "/tmp", title: "t", router: nil)
    }

    // WHY: plain-click must produce a single-item selection. If it selects
    // multiple rows, the anchor logic is broken from the start.
    func test_plainClick_selectsSingleRow() throws {
        let surface = try makeSurface()
        surface.seedLocalEntriesForTesting(["a", "b", "c", "d", "e", "f"])
        surface.plainSelectLocalAtForTesting(2)
        XCTAssertEqual(surface.selectedLocalIDsForTesting, ["c"],
                       "plain click on index 2 must select exactly that row")
    }

    // WHY: shift-click from anchor 2 to row 5 must select all four rows
    // {c,d,e,f} (indices 2,3,4,5). The previous bug would have toggled only
    // the clicked row, leaving the others unselected.
    func test_shiftClick_anchor2_to5_selectsRange() throws {
        let surface = try makeSurface()
        surface.seedLocalEntriesForTesting(["a", "b", "c", "d", "e", "f"])
        surface.plainSelectLocalAtForTesting(2)           // sets anchor at index 2
        surface.shiftSelectLocalAtForTesting(5)           // shift-click index 5
        XCTAssertEqual(surface.selectedLocalIDsForTesting, ["c", "d", "e", "f"],
                       "shift-click from anchor 2 to row 5 must select indices 2..5")
    }

    // WHY: shift-clicking ABOVE the anchor (index 5 -> shift-click 2) must
    // produce the same range {c,d,e,f}. Order-independence is the Mac convention.
    func test_shiftClick_anchor5_to2_selectsSameRange() throws {
        let surface = try makeSurface()
        surface.seedLocalEntriesForTesting(["a", "b", "c", "d", "e", "f"])
        surface.plainSelectLocalAtForTesting(5)           // sets anchor at index 5
        surface.shiftSelectLocalAtForTesting(2)           // shift-click index 2
        XCTAssertEqual(surface.selectedLocalIDsForTesting, ["c", "d", "e", "f"],
                       "shift-click above anchor must select the same contiguous range")
    }

    // WHY: a second shift-click must extend from the ORIGINAL anchor, not from
    // the last shift-click target. If the anchor moved after the first shift-click,
    // the user would lose the initial reference point and get an unexpected range.
    func test_successiveShiftClicks_anchorStaysFixed() throws {
        let surface = try makeSurface()
        surface.seedLocalEntriesForTesting(["a", "b", "c", "d", "e", "f"])
        surface.plainSelectLocalAtForTesting(2)           // anchor = 2
        surface.shiftSelectLocalAtForTesting(4)           // range 2..4
        surface.shiftSelectLocalAtForTesting(5)           // range 2..5 (anchor still 2)
        XCTAssertEqual(surface.selectedLocalIDsForTesting, ["c", "d", "e", "f"],
                       "successive shift-clicks must extend from the original anchor")
    }

    // WHY: cmd-click must toggle a single row without disturbing the shift-click
    // anchor. If anchor moved on cmd-click, the next shift-click would compute
    // range from the wrong row.
    func test_cmdClick_togglesWithoutMovingAnchor() throws {
        let surface = try makeSurface()
        surface.seedLocalEntriesForTesting(["a", "b", "c", "d", "e", "f"])
        surface.plainSelectLocalAtForTesting(2)           // anchor = 2, selection = {c}
        surface.cmdSelectLocalAtForTesting(4)             // add "e", anchor still 2
        // After cmd-click, shift-click should still use anchor=2
        surface.shiftSelectLocalAtForTesting(5)           // range 2..5 replaces selection
        XCTAssertEqual(surface.selectedLocalIDsForTesting, ["c", "d", "e", "f"],
                       "shift-click after cmd-click must still use the plain-click anchor")
    }

    // WHY: a plain click after a shift-extended selection must reset both the
    // selection and the anchor. The next shift-click should extend from the new
    // plain-click position, not from the old one.
    func test_plainClickAfterRange_resetsAnchor() throws {
        let surface = try makeSurface()
        surface.seedLocalEntriesForTesting(["a", "b", "c", "d", "e", "f"])
        surface.plainSelectLocalAtForTesting(0)
        surface.shiftSelectLocalAtForTesting(3)           // anchor was 0
        surface.plainSelectLocalAtForTesting(4)           // new anchor = 4
        surface.shiftSelectLocalAtForTesting(5)           // range 4..5
        XCTAssertEqual(surface.selectedLocalIDsForTesting, ["e", "f"],
                       "plain click after range resets anchor; next shift-click extends from new anchor")
    }
}
