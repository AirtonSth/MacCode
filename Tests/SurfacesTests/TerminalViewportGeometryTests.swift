import XCTest
import AppKit
@testable import Surfaces

final class TerminalViewportGeometryTests: XCTestCase {
    func test_sizeUsesAvailableViewportSoTUIProgramsFillTheTerminalPane() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let cell = TerminalViewportGeometry.cellSize(for: font)
        let inset = NSSize(width: 10, height: 10)
        let viewport = NSSize(
            width: cell.width * 96 + inset.width * 2,
            height: cell.height * 28 + inset.height * 2
        )

        let size = TerminalViewportGeometry.size(for: viewport, font: font, inset: inset)

        XCTAssertEqual(size, TerminalViewportSize(rows: 28, cols: 96),
                       "full-screen TUIs depend on the PTY row/column count matching the visible terminal viewport, not a fixed fallback")
    }

    func test_sizeClampsTinyViewportToOneCellSoPTYNeverReceivesZeroRowsOrColumns() {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let size = TerminalViewportGeometry.size(for: .zero, font: font, inset: NSSize(width: 10, height: 10))

        XCTAssertEqual(size, TerminalViewportSize(rows: 1, cols: 1),
                       "blank or first-layout frames must not send a zero-sized PTY that can leave terminal output invisible")
    }
}
