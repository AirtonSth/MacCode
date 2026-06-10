import XCTest
@testable import AppShell
@testable import CoreModel

/// Tests for `SidebarViewModel.pinnedSeparatorIndex(in:)`.
///
/// The helper is `nonisolated static`, so no `@MainActor` annotation is needed.
/// Each test encodes a business rule that would fail if the separator-index
/// computation changed incorrectly.
final class SidebarPinnedSeparatorTests: XCTestCase {

    // MARK: - Helpers

    private func ws(pinned: Bool, name: String = "ws") -> Workspace {
        Workspace(
            name: name,
            cwd: "/tmp/\(name)",
            layout: .pane(PaneNode(surfaces: [])),
            metadata: pinned ? ["pinned": "true"] : [:]
        )
    }

    // MARK: - Empty list

    func test_emptyList_returnsNil() {
        // No separator when there are no rows at all.
        XCTAssertNil(SidebarViewModel.pinnedSeparatorIndex(in: []))
    }

    // MARK: - None pinned

    func test_nonePinned_returnsNil() {
        // All unpinned: no boundary exists so no divider should appear.
        let rows = [ws(pinned: false, name: "a"), ws(pinned: false, name: "b")]
        XCTAssertNil(SidebarViewModel.pinnedSeparatorIndex(in: rows))
    }

    // MARK: - All pinned

    func test_allPinned_returnsNil() {
        // All pinned: no transition to an unpinned row, so no divider.
        let rows = [ws(pinned: true, name: "a"), ws(pinned: true, name: "b")]
        XCTAssertNil(SidebarViewModel.pinnedSeparatorIndex(in: rows))
    }

    // MARK: - Mixed: separator index == count of leading pinned rows

    func test_onePinnedThenUnpinned_returnsOne() {
        // One pinned row leading: separator belongs at index 1 (before first unpinned).
        let rows = [ws(pinned: true, name: "p"), ws(pinned: false, name: "u")]
        XCTAssertEqual(SidebarViewModel.pinnedSeparatorIndex(in: rows), 1)
    }

    func test_twoPinnedThenUnpinned_returnsTwo() {
        // Two pinned rows leading: separator at index 2.
        let rows = [
            ws(pinned: true, name: "p1"),
            ws(pinned: true, name: "p2"),
            ws(pinned: false, name: "u1"),
            ws(pinned: false, name: "u2")
        ]
        XCTAssertEqual(SidebarViewModel.pinnedSeparatorIndex(in: rows), 2)
    }

    func test_threePinnedOneUnpinned_returnsThree() {
        // Three pinned rows + one unpinned: separator at index 3.
        let rows = [
            ws(pinned: true, name: "p1"),
            ws(pinned: true, name: "p2"),
            ws(pinned: true, name: "p3"),
            ws(pinned: false, name: "u")
        ]
        XCTAssertEqual(SidebarViewModel.pinnedSeparatorIndex(in: rows), 3)
    }

    func test_singlePinnedAmongMany_returnsOne() {
        // One pinned at head, several unpinned: separator still at index 1.
        let rows = [
            ws(pinned: true, name: "p"),
            ws(pinned: false, name: "u1"),
            ws(pinned: false, name: "u2"),
            ws(pinned: false, name: "u3")
        ]
        XCTAssertEqual(SidebarViewModel.pinnedSeparatorIndex(in: rows), 1)
    }

    // MARK: - Pinned rows only at non-leading positions are not counted

    func test_unpinnedThenPinned_returnsNil() {
        // If the leading rows are NOT pinned, there is no leading pinned group.
        // The separator exists only between a pinned prefix and an unpinned suffix.
        let rows = [ws(pinned: false, name: "u"), ws(pinned: true, name: "p")]
        // Leading pinned count = 0 => no separator.
        XCTAssertNil(SidebarViewModel.pinnedSeparatorIndex(in: rows))
    }
}
