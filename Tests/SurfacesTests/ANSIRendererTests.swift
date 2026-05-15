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

    func test_sgrColors_applied() {
        let r = ANSIRenderer(rows: 1, cols: 10)
        r.feed("\u{1B}[31mR\u{1B}[0mX".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "R")
        XCTAssertNotEqual(r.grid[0][0].fg, NSColor.white)
        XCTAssertEqual(r.grid[0][1].ch, "X")
        XCTAssertEqual(r.grid[0][1].fg, NSColor.white)
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
