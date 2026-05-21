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

    func test_colonSeparatedTrueColorSGR_isRenderedLikeModernTerminals() {
        let r = ANSIRenderer(rows: 1, cols: 10)
        r.showCursor = false

        r.feed("\u{1B}[38:2::255:128:64mR\u{1B}[0mX".data(using: .utf8)!)

        XCTAssertEqual(r.grid[0][0].ch, "R")
        assertColor(r.grid[0][0].fg, red: 255, green: 128, blue: 64)
        XCTAssertEqual(r.grid[0][1].ch, "X")
        XCTAssertEqual(r.grid[0][1].fg, ANSIRenderer.Cell.defaultFG)
    }

    func test_snapshotPreservesForegroundAndBackgroundColors() {
        let r = ANSIRenderer(rows: 1, cols: 10)
        r.showCursor = false

        r.feed("\u{1B}[38;5;208;48;2;32;36;48mA".data(using: .utf8)!)

        let attrs = r.snapshot().attributes(at: 0, effectiveRange: nil)
        let fg = attrs[.foregroundColor] as? NSColor
        let bg = attrs[.backgroundColor] as? NSColor
        XCTAssertNotNil(fg)
        XCTAssertNotNil(bg)
        XCTAssertNotEqual(fg, ANSIRenderer.Cell.defaultFG,
                          "ANSI foreground must survive into NSTextView attributes, not collapse to plain text")
        assertColor(bg, red: 32, green: 36, blue: 48)
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

    func test_snapshotKeepsScrollableHistoryWithColorsAfterOverflow() {
        let r = ANSIRenderer(rows: 2, cols: 12)
        r.showCursor = false

        r.feed("\u{1B}[31mold-red\u{1B}[0m\nplain\nlive".data(using: .utf8)!)

        let snap = r.snapshot()
        XCTAssertTrue(snap.string.hasPrefix("old-red\nplain\nlive"),
                      "terminal scrollback must keep older output instead of dropping it when the visible grid overflows")
        let attrs = snap.attributes(at: 0, effectiveRange: nil)
        let fg = attrs[.foregroundColor] as? NSColor
        XCTAssertNotEqual(fg, ANSIRenderer.Cell.defaultFG,
                          "ANSI colors in scrollback must survive into the NSTextView attributes")
    }

    func test_alternateScreenHidesShellScrollbackWhileTUIIsActive() {
        let r = ANSIRenderer(rows: 8, cols: 20)
        r.showCursor = false

        r.feed("shell-history\n\u{1B}[?1049h\u{1B}[HClaude Code\n> ".data(using: .utf8)!)

        let snap = r.snapshot()
        XCTAssertTrue(r.usesAlternateScreen,
                      "full-screen TUIs should switch the terminal renderer into alternate-screen mode")
        XCTAssertTrue(snap.string.hasPrefix("Claude Code\n>"),
                      "TUI content must own the viewport like cmux/Ghostty instead of rendering below prior shell output. Got: \(snap.string.debugDescription)")
        XCTAssertFalse(snap.string.contains("shell-history"),
                       "alternate-screen content must be isolated from shell scrollback while the TUI is active")
    }

    func test_alternateScreenExitRestoresShellAndCursorPosition() {
        let r = ANSIRenderer(rows: 5, cols: 20)
        r.showCursor = false

        r.feed("shell\u{1B}[?1049h\u{1B}[HTUI\u{1B}[?1049l-after".data(using: .utf8)!)

        XCTAssertFalse(r.usesAlternateScreen)
        XCTAssertTrue(r.snapshot().string.hasPrefix("shell-after"),
                      "exiting a full-screen TUI must restore the shell screen and continue output at the saved cursor")
    }

    func test_privateCursorVisibilityModeHidesRenderedCursorCell() {
        let r = ANSIRenderer(rows: 2, cols: 10)

        r.feed("ab\u{1B}[?25l".data(using: .utf8)!)

        XCTAssertEqual(r.snapshot().string.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init), "ab",
                       "private cursor hide mode must remove the synthetic cursor block from rendered output")
    }

    func test_resizeDoesNotRecordInitialBlankRowsAsScrollback() {
        let r = ANSIRenderer(rows: 40, cols: 120)
        r.showCursor = false

        r.resize(rows: 1, cols: 120)

        XCTAssertEqual(r.scrollback.count, 0,
                       "first-layout resize must not create fake blank scrollback above the initial shell prompt")
    }

    func test_cursorOffset_usesCursorRowNotTrailingBlankRows() {
        let r = ANSIRenderer(rows: 5, cols: 20)
        r.feed("prompt".data(using: .utf8)!)

        let snap = r.snapshot()
        let cursorOffset = r.cursorOffset(in: snap.string)

        XCTAssertLessThan(cursorOffset, (snap.string as NSString).length - 3,
                          "terminal panes must scroll the cursor into view, not scroll to trailing blank rows")
    }

    private func assertColor(_ color: NSColor?, red: CGFloat, green: CGFloat, blue: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        guard let srgb = color?.usingColorSpace(.sRGB) else {
            XCTFail("expected sRGB color", file: file, line: line)
            return
        }
        XCTAssertEqual(srgb.redComponent, red / 255.0, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(srgb.greenComponent, green / 255.0, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(srgb.blueComponent, blue / 255.0, accuracy: 0.01, file: file, line: line)
    }
}
