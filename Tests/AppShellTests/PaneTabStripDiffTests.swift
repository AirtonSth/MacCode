import XCTest
import CoreModel
import DesignSystemKit
@testable import AppShell

/// In-place tab-strip reconcile diff. The tab strip used to rebuild its
/// whole container on every mutation, flashing at resize-end. `diffTabs`
/// is the seam that lets the strip patch buttons in place instead: a
/// wrong diff here would either rebuild needlessly (the bug we are
/// killing) or drop/duplicate a tab. These tests pin the contract:
///
///  - same id set + same order  -> updates only, no structural change
///  - inserted / removed ids     -> exactly those ops, nothing spurious
///  - reordered surviving ids    -> `reordered == true`, set unchanged
///
/// WHY each assertion matters is called out inline; an implementation
/// that hardcoded empty ops or always-rebuild would fail these.
@MainActor
final class PaneTabStripDiffTests: XCTestCase {

    private func ids(_ n: Int) -> [SurfaceID] {
        (0..<n).map { _ in SurfaceID() }
    }

    func test_sameSetSameOrder_isUpdatesOnly_noStructuralChange() {
        let a = SurfaceID(); let b = SurfaceID(); let c = SurfaceID()
        let diff = PaneTabsView.diffTabs(old: [a, b, c], new: [a, b, c])

        XCTAssertTrue(diff.inserts.isEmpty, "identical strip must not insert -- that would rebuild and flash")
        XCTAssertTrue(diff.removes.isEmpty, "identical strip must not remove any button")
        XCTAssertFalse(diff.reordered, "identical order is not a reorder")
        XCTAssertEqual(diff.updates, [a, b, c],
                       "every surviving tab is updated in place, in display order")
    }

    func test_insertedID_producesSingleInsertAtNewIndex() {
        let a = SurfaceID(); let b = SurfaceID(); let inserted = SurfaceID()
        // `inserted` lands between a and b.
        let diff = PaneTabsView.diffTabs(old: [a, b], new: [a, inserted, b])

        XCTAssertEqual(diff.removes, [])
        XCTAssertEqual(diff.inserts.count, 1, "exactly one new button is added")
        XCTAssertEqual(diff.inserts.first?.id, inserted)
        XCTAssertEqual(diff.inserts.first?.index, 1,
                       "insert index is the position in the NEW order, so the button slots between a and b")
        XCTAssertEqual(diff.updates, [a, b],
                       "pre-existing tabs keep their identity and are merely updated")
        XCTAssertFalse(diff.reordered, "a and b keep their relative order, so no reorder")
    }

    func test_removedID_producesSingleRemove_survivorsUpdated() {
        let a = SurfaceID(); let removed = SurfaceID(); let c = SurfaceID()
        let diff = PaneTabsView.diffTabs(old: [a, removed, c], new: [a, c])

        XCTAssertEqual(diff.removes, [removed], "the closed tab is the only structural removal")
        XCTAssertTrue(diff.inserts.isEmpty)
        XCTAssertEqual(diff.updates, [a, c], "survivors stay, in order, updated in place")
        XCTAssertFalse(diff.reordered, "removing a middle tab does not reorder the survivors")
    }

    func test_reorderedSurvivors_flagsReordered_withoutInsertOrRemove() {
        let a = SurfaceID(); let b = SurfaceID(); let c = SurfaceID()
        // Same set, drag b to the front.
        let diff = PaneTabsView.diffTabs(old: [a, b, c], new: [b, a, c])

        XCTAssertTrue(diff.inserts.isEmpty, "drag-reorder adds no buttons")
        XCTAssertTrue(diff.removes.isEmpty, "drag-reorder removes no buttons")
        XCTAssertTrue(diff.reordered,
                      "the surviving ids changed relative order, so buttons must be moved, not just updated")
        XCTAssertEqual(diff.updates, [b, a, c], "updates follow the NEW display order")
    }

    func test_fullReplacement_removesAll_insertsAll_notReordered() {
        let old = ids(2)
        let new = ids(3)
        let diff = PaneTabsView.diffTabs(old: old, new: new)

        XCTAssertEqual(diff.removes, old, "no id survives, so every old button is removed")
        XCTAssertEqual(diff.inserts.map(\.id), new, "every new id is inserted, in order")
        XCTAssertEqual(diff.inserts.map(\.index), [0, 1, 2], "insert indices are the new positions")
        XCTAssertTrue(diff.updates.isEmpty, "no survivors means nothing to update in place")
        XCTAssertFalse(diff.reordered, "with zero survivors there is no relative order to reorder")
    }

    func test_emptyToEmpty_isNoOp() {
        let diff = PaneTabsView.diffTabs(old: [], new: [])
        XCTAssertEqual(diff, PaneTabsView.TabStripDiff(removes: [], inserts: [], updates: [], reordered: false),
                       "empty -> empty is a total no-op; reconcile must do nothing")
    }

    func test_stableIdentity_survivingIDsAreNeverInInsertsOrRemoves() {
        // Mixed mutation: remove one, add one, reorder the rest. The two
        // survivors must appear ONLY in updates -- never re-created.
        let keepA = SurfaceID(); let keepB = SurfaceID()
        let gone = SurfaceID(); let added = SurfaceID()
        let diff = PaneTabsView.diffTabs(old: [keepA, gone, keepB], new: [keepB, added, keepA])

        XCTAssertEqual(diff.removes, [gone])
        XCTAssertEqual(diff.inserts.map(\.id), [added])
        XCTAssertEqual(Set(diff.updates), [keepA, keepB],
                       "survivors are updated in place, preserving button identity")
        XCTAssertFalse(diff.removes.contains(keepA) || diff.removes.contains(keepB),
                       "a surviving tab must never be torn down")
        XCTAssertFalse(diff.inserts.contains { $0.id == keepA || $0.id == keepB },
                       "a surviving tab must never be re-created")
        XCTAssertTrue(diff.reordered, "keepA/keepB swapped order, so a reorder is required")
    }

    // MARK: - Live reconcile (diffTabs wired into the render/update path)

    private func surface(_ id: SurfaceID, title: String, color: String? = nil) -> SurfaceDescriptor {
        var meta: [String: String] = [:]
        if let color { meta["color"] = color }
        return SurfaceDescriptor(id: id, type: .terminal, title: title, metadata: meta)
    }

    /// WHY: a focus/rename with the SAME id set+order must NOT rebuild the
    /// strip. reconcile must return true (patched in place) and the SAME
    /// button instance must carry the new selection + title -- proving the
    /// resize-end flash (full rebuild) is gone for cosmetic changes.
    func test_reconcile_cosmeticOnly_patchesInPlace_preservingButtonIdentity() {
        let a = SurfaceID(); let b = SurfaceID()
        let pane = PaneNode(surfaces: [surface(a, title: "A"), surface(b, title: "B")],
                            selectedSurfaceID: a)
        let view = PaneTabsView(pane: pane, router: nil)

        let buttonA = view.tabButtonForTesting(a)
        let buttonB = view.tabButtonForTesting(b)
        XCTAssertNotNil(buttonA); XCTAssertNotNil(buttonB)
        XCTAssertTrue(buttonA?.selectedForTesting == true, "A starts selected")
        XCTAssertTrue(buttonB?.selectedForTesting == false)

        // Same ids/order, but selection moves to B and B is renamed.
        let next = PaneNode(surfaces: [surface(a, title: "A"), surface(b, title: "B renamed")],
                            selectedSurfaceID: b)
        let patched = view.reconcile(to: next)

        XCTAssertTrue(patched, "unchanged id set+order must reconcile in place, not rebuild")
        XCTAssertTrue(view.tabButtonForTesting(a) === buttonA,
                      "button identity is preserved -- no teardown")
        XCTAssertTrue(view.tabButtonForTesting(b) === buttonB,
                      "button identity is preserved -- no teardown")
        XCTAssertEqual(buttonB?.selectedForTesting, true, "selection moved to B in place")
        XCTAssertEqual(buttonA?.selectedForTesting, false, "A deselected in place")
        XCTAssertEqual(buttonB?.titleForTesting, "B renamed", "title patched in place")
    }

    /// WHY (H3): a terminal title change patches only its tab label -- no
    /// reconcile or window refresh -- and keeps the pane copy in sync so a
    /// later in-place reconcile does not flash the old title back.
    func test_setTabTitle_patchesOnlyThatLabelInPlace() {
        let a = SurfaceID(); let b = SurfaceID()
        let pane = PaneNode(surfaces: [surface(a, title: "A"), surface(b, title: "B")],
                            selectedSurfaceID: a)
        let view = PaneTabsView(pane: pane, router: nil)
        let buttonB = view.tabButtonForTesting(b)

        view.setTabTitle(b, title: "B live")
        view.setTabTitle(SurfaceID(), title: "ignored")

        XCTAssertTrue(view.tabButtonForTesting(b) === buttonB, "no rebuild for a title change")
        XCTAssertEqual(buttonB?.titleForTesting, "B live")
        XCTAssertEqual(view.tabButtonForTesting(a)?.titleForTesting, "A")
        XCTAssertEqual(view.pane.surfaces.first { $0.id == b }?.title, "B live")
    }

    /// WHY: adding a surface changes the id SET, which is the one case that
    /// MUST restructure. reconcile must report it did NOT patch in place so
    /// the strip is rebuilt, and the new id must be present.
    func test_reconcile_structuralChange_rebuilds_andReportsNotInPlace() {
        let a = SurfaceID(); let b = SurfaceID(); let added = SurfaceID()
        let pane = PaneNode(surfaces: [surface(a, title: "A"), surface(b, title: "B")],
                            selectedSurfaceID: a)
        let view = PaneTabsView(pane: pane, router: nil)

        let next = PaneNode(surfaces: [surface(a, title: "A"), surface(added, title: "C"), surface(b, title: "B")],
                            selectedSurfaceID: added)
        let patched = view.reconcile(to: next)

        XCTAssertFalse(patched, "an id-set change is structural, not an in-place patch")
        XCTAssertEqual(view.currentSurfaceIDsForTesting, [a, added, b],
                       "the strip now renders the new id set, in new order")
        XCTAssertNotNil(view.tabButtonForTesting(added), "the inserted tab exists")
        XCTAssertEqual(view.tabButtonForTesting(added)?.selectedForTesting, true,
                       "the newly selected surface is selected after rebuild")
    }
}
