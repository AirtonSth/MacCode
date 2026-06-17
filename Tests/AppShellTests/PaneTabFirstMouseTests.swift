import XCTest
@testable import AppShell
import CoreModel

@MainActor
final class PaneTabFirstMouseTests: XCTestCase {
    private func makeTab() -> PaneTabButton {
        PaneTabButton(
            surfaceID: SurfaceID(),
            title: "Agent App",
            symbol: "sparkles",
            selected: false,
            onSelect: {},
            onClose: {}
        )
    }

    func test_tabAcceptsFirstMouseSoInactiveDetachedWindowClickSelectsTab() {
        let tab = makeTab()

        XCTAssertTrue(
            tab.acceptsFirstMouse(for: nil),
            "tabs must accept first mouse so a single click into an inactive detached workspace window both activates the window and selects the tab"
        )
    }

    func test_tabBodyHitTestReturnsTabSoLabelClickSelectsInDetachedWindow() {
        let tab = makeTab()
        tab.frame = NSRect(x: 0, y: 0, width: 180, height: 34)
        tab.layoutSubtreeIfNeeded()

        let hit = tab.hitTest(NSPoint(x: 70, y: 17))

        XCTAssertTrue(
            hit === tab,
            "clicks on tab label/icon body must route to PaneTabButton; otherwise detached-window tab clicks hit child views and require a retry"
        )
    }
}
