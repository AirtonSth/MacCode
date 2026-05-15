import XCTest
import AppKit
@testable import Surfaces

final class ANSIRendererTests: XCTestCase {
    func test_plainText_placesIntoGrid() {
        let r = ANSIRenderer(rows: 3, cols: 10)
        r.feed("hello\n".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "h")
        XCTAssertEqual(r.grid[0][4].ch, "o")
        XCTAssertEqual(r.cursorRow, 1)
        XCTAssertEqual(r.cursorCol, 0)
    }

    func test_cursorBlock_isRenderedInverse() {
        let r = ANSIRenderer(rows: 2, cols: 10)
        r.feed("ab".data(using: .utf8)!)   // cursor now at row 0, col 2
        let snap = r.snapshot()
        // Row keeps a 3rd cell (the caret) even though it is blank.
        let firstLine = snap.string.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        XCTAssertTrue(firstLine.hasPrefix("ab"))
        XCTAssertGreaterThanOrEqual(firstLine.count, 3)
        // The caret cell uses an inverse (filled) background.
        let attrs = snap.attributes(at: 2, effectiveRange: nil)
        let bg = attrs[.backgroundColor] as? NSColor
        XCTAssertEqual(bg, ANSIRenderer.Cell.defaultFG)
    }

    func test_cursorHidden_whenShowCursorFalse() {
        let r = ANSIRenderer(rows: 2, cols: 10)
        r.showCursor = false
        r.feed("ab".data(using: .utf8)!)
        let snap = r.snapshot()
        let firstLine = snap.string.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        XCTAssertEqual(firstLine, "ab")  // trailing caret cell trimmed
    }

    func test_sgrColors_applied() {
        let r = ANSIRenderer(rows: 1, cols: 10)
        r.feed("\u{1B}[31mR\u{1B}[0mX".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "R")
        XCTAssertNotEqual(r.grid[0][0].fg, ANSIRenderer.Cell.defaultFG)
        XCTAssertEqual(r.grid[0][1].ch, "X")
        XCTAssertEqual(r.grid[0][1].fg, ANSIRenderer.Cell.defaultFG)
    }

    func test_carriageReturn_overwrites() {
        let r = ANSIRenderer(rows: 1, cols: 10)
        r.feed("abc\rXY".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "X")
        XCTAssertEqual(r.grid[0][1].ch, "Y")
        XCTAssertEqual(r.grid[0][2].ch, "c")
    }

    func test_eraseLine_clears() {
        let r = ANSIRenderer(rows: 1, cols: 10)
        r.feed("abcdef".data(using: .utf8)!)
        r.feed("\u{1B}[2K".data(using: .utf8)!)
        for c in 0..<10 { XCTAssertEqual(r.grid[0][c].ch, " ") }
    }

    func test_cursorPosition_H() {
        let r = ANSIRenderer(rows: 3, cols: 10)
        r.feed("\u{1B}[2;3HXY".data(using: .utf8)!)
        XCTAssertEqual(r.grid[1][2].ch, "X")
        XCTAssertEqual(r.grid[1][3].ch, "Y")
    }

    func test_scrollUp_onOverflow() {
        let r = ANSIRenderer(rows: 2, cols: 4)
        r.feed("a\nb\nc".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "b")
        XCTAssertEqual(r.grid[1][0].ch, "c")
    }
}
