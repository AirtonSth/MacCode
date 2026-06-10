import XCTest
import AppKit
import CoreModel
@testable import AppShell

/// Tests for the `extraWindowsRemoving(_:from:)` pure helper.
///
/// WHY these tests matter:
///   - Leak prevention: extraWindows is the sole strong reference to each
///     extra NSWindow; failing to remove on close keeps the window alive for
///     the entire app lifetime, wasting memory proportional to how many
///     windows the user has opened and closed.
///   - Correctness: removing the wrong entry or clearing the whole map would
///     hide live windows from openAdditionalWindow, causing duplicate windows
///     to open instead of raising the existing one.
///   - Absent-key safety: receiving windowWillClose for an NSWindow not in the
///     map (e.g. a workspace window) must be a silent no-op.
final class ExtraWindowsRemovingTests: XCTestCase {

    // MARK: - Helpers

    private func makeID() -> WindowID {
        WindowID(UUID())
    }

    // MARK: - Removal

    func test_removesMatchingEntry() {
        let id = makeID()
        let win = NSWindow()
        let other = makeID()
        let otherWin = NSWindow()
        let dict: [WindowID: NSWindow] = [id: win, other: otherWin]

        let result = extraWindowsRemoving(win, from: dict)

        XCTAssertNil(result[id],
            "closed window entry must be removed so ARC can deallocate it")
        XCTAssertEqual(result[other], otherWin,
            "sibling entries must be preserved: removing one window must not affect others")
    }

    func test_removesOnlyMatchingEntry_multipleWindows() {
        let ids = (0..<4).map { _ in makeID() }
        let windows = ids.map { _ in NSWindow() }
        var dict: [WindowID: NSWindow] = [:]
        for (id, win) in zip(ids, windows) { dict[id] = win }

        let targetIndex = 2
        let result = extraWindowsRemoving(windows[targetIndex], from: dict)

        XCTAssertEqual(result.count, 3,
            "only the closed window entry must be removed; all others must remain")
        XCTAssertNil(result[ids[targetIndex]],
            "the exact closed-window key must be absent after removal")
        for i in [0, 1, 3] {
            XCTAssertEqual(result[ids[i]], windows[i],
                "entry at index \(i) must be intact after removing index \(targetIndex)")
        }
    }

    // MARK: - Absent-key no-op

    func test_absentWindow_returnsUnchangedMap() {
        let id = makeID()
        let win = NSWindow()
        let dict: [WindowID: NSWindow] = [id: win]
        let stranger = NSWindow()

        let result = extraWindowsRemoving(stranger, from: dict)

        XCTAssertEqual(result.count, 1,
            "removing an NSWindow not in the map must be a no-op; map size must not change")
        XCTAssertEqual(result[id], win,
            "existing entry must be unchanged when the removed window is absent from the map")
    }

    func test_emptyMap_returnsEmptyMap() {
        let result = extraWindowsRemoving(NSWindow(), from: [:])

        XCTAssertTrue(result.isEmpty,
            "removing from an empty map must return an empty map, not crash or add entries")
    }

    // MARK: - Identity (pointer equality)

    func test_removesBy_objectIdentity_notEquality() {
        // Two distinct NSWindow instances cannot be compared by ==; the helper
        // must use === so that a coincidentally equal object does not trigger
        // removal of the wrong entry.
        let id = makeID()
        let win = NSWindow()
        let dict: [WindowID: NSWindow] = [id: win]
        let differentInstance = NSWindow()

        let result = extraWindowsRemoving(differentInstance, from: dict)

        XCTAssertEqual(result[id], win,
            "removal must use object identity (===), not value equality, " +
            "so a different NSWindow instance does not remove an unrelated entry")
    }
}
