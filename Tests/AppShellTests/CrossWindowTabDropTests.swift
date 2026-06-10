import XCTest
@testable import AppShell
import CoreModel

/// Tests for the cross-window drop hit-test helper.
///
/// WHY: `performManualDrop` previously only searched `window?.contentView`,
/// making it impossible to drop a tab into a detached workspace window.
/// The pure helper `PaneTabsView.windowTarget(forScreenPoint:in:)` resolves
/// a screen-coordinate drop point against a set of window frames so the
/// live drop path can iterate NSApp.windows and pick the right target
/// without AppKit hitTest calls.
///
/// Pure helper -> no MainActor annotation needed on the class.
final class CrossWindowTabDropTests: XCTestCase {

    // Stable UUIDs used across tests.
    private let idA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
    private let idB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!
    private let idC = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!

    // MARK: - Basic containment

    func test_pointInsideWindowA_returnsWindowA() {
        // WHY: a drop point that falls inside window A's frame must resolve
        // to window A so the tab is moved into that window, not ignored.
        let windows: [(id: UUID, frame: NSRect)] = [
            (id: idA, frame: NSRect(x: 0,   y: 0, width: 800, height: 600)),
            (id: idB, frame: NSRect(x: 900, y: 0, width: 800, height: 600))
        ]
        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 400, y: 300),
            in: windows
        )
        XCTAssertEqual(result, idA,
                       "a point inside window A must resolve to A, enabling cross-window drop")
    }

    func test_pointInsideWindowB_returnsWindowB() {
        // WHY: validates that B is also reachable — cross-window drop is
        // bidirectional, not just A->B.
        let windows: [(id: UUID, frame: NSRect)] = [
            (id: idA, frame: NSRect(x: 0,   y: 0, width: 800, height: 600)),
            (id: idB, frame: NSRect(x: 900, y: 0, width: 800, height: 600))
        ]
        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 1200, y: 300),
            in: windows
        )
        XCTAssertEqual(result, idB,
                       "a point inside window B must resolve to B")
    }

    func test_pointOutsideAllWindows_returnsNil() {
        // WHY: a drop outside every window frame must return nil so the
        // caller can discard the drop instead of routing it to a random window.
        let windows: [(id: UUID, frame: NSRect)] = [
            (id: idA, frame: NSRect(x: 0,   y: 0, width: 800, height: 600)),
            (id: idB, frame: NSRect(x: 900, y: 0, width: 800, height: 600))
        ]
        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 2000, y: 300),
            in: windows
        )
        XCTAssertNil(result,
                     "a drop outside all window frames must return nil — never route a stray drop")
    }

    func test_emptyWindowList_returnsNil() {
        // WHY: guard against crash/undefined behavior when no windows are open.
        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 100, y: 100),
            in: []
        )
        XCTAssertNil(result, "with no windows registered, every drop must return nil")
    }

    // MARK: - Topmost-window (z-order) disambiguation

    func test_overlappingWindows_topmostWins() {
        // WHY: when two windows overlap, the one visually on top (last in the
        // ordered-front list, highest index) must receive the drop — matching
        // what the user sees and expects.
        //
        // NSApp.windows is ordered back-to-front: index 0 is the backmost
        // window. The helper receives windows in the same order so the last
        // match is the topmost.
        let overlap = NSRect(x: 100, y: 100, width: 400, height: 300)
        let windows: [(id: UUID, frame: NSRect)] = [
            (id: idA, frame: overlap),  // index 0 = behind
            (id: idB, frame: overlap)   // index 1 = in front
        ]
        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 200, y: 200),
            in: windows
        )
        XCTAssertEqual(result, idB,
                       "when two windows overlap, the topmost (last in ordered-front list) must win")
    }

    func test_overlappingThreeWindows_topmostWins() {
        // WHY: same invariant with three stacked windows — topmost (index 2) wins.
        let overlap = NSRect(x: 50, y: 50, width: 300, height: 200)
        let windows: [(id: UUID, frame: NSRect)] = [
            (id: idA, frame: overlap),
            (id: idB, frame: overlap),
            (id: idC, frame: overlap)
        ]
        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 150, y: 100),
            in: windows
        )
        XCTAssertEqual(result, idC,
                       "with three overlapping windows the topmost (last index) must always win")
    }

    // MARK: - Edge / boundary cases

    func test_pointOnWindowEdge_isContained() {
        // WHY: NSRect.contains uses half-open intervals; a point exactly on
        // the leading/bottom edge is inside. The helper must match NSRect's
        // own containment semantics so behavior is predictable.
        let frame = NSRect(x: 100, y: 100, width: 400, height: 300)
        let windows: [(id: UUID, frame: NSRect)] = [(id: idA, frame: frame)]

        // NSRect contains the origin corner.
        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 100, y: 100),
            in: windows
        )
        XCTAssertEqual(result, idA,
                       "the frame's origin corner must be treated as inside by NSRect.contains")
    }

    func test_pointOnMaxEdge_isNotContained() {
        // WHY: NSRect.contains is exclusive of the maxX/maxY edges. Verifying
        // this prevents a subtle off-by-one where a cursor exactly on the
        // right/top edge of window A is misrouted to A instead of nil (or B).
        let frame = NSRect(x: 100, y: 100, width: 400, height: 300)
        let windows: [(id: UUID, frame: NSRect)] = [(id: idA, frame: frame)]

        let result = PaneTabsView.windowTarget(
            forScreenPoint: NSPoint(x: 500, y: 400),  // maxX=500, maxY=400 — outside
            in: windows
        )
        XCTAssertNil(result,
                     "a point exactly on maxX/maxY is outside by NSRect.contains semantics")
    }
}
