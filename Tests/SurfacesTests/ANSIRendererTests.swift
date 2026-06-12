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

    func test_ansiSnapshotPreservesEnhancedTerminalStylesForIOSMirror() {
        let r = ANSIRenderer(rows: 2, cols: 20)
        r.showCursor = false

        r.feed("\u{1B}[38;2;255;128;64;48;2;32;36;48;1mTUI\u{1B}[0m".data(using: .utf8)!)

        let ansi = r.ansiSnapshot(includeScrollback: false)
        XCTAssertTrue(ansi.contains("\u{1B}[0;1;38;2;255;128;64;48;2;32;36;48mT"),
                      "iOS synchronized terminal snapshots must carry ANSI foreground, background, and bold state instead of plain text only")
        XCTAssertTrue(ansi.hasSuffix("\u{1B}[0m"),
                      "exported ANSI snapshots must reset style so later chunks do not inherit stale terminal colors")
    }

    func test_ansiSnapshotCanExportVisibleViewportWithoutOldScrollback() {
        let r = ANSIRenderer(rows: 2, cols: 20)
        r.showCursor = false

        r.feed("old\ncurrent\nprompt".data(using: .utf8)!)

        let visible = r.ansiSnapshot(includeScrollback: false)
        XCTAssertFalse(visible.contains("old"),
                       "callers that need only the current terminal frame can export ANSI without old scrollback")
        XCTAssertTrue(visible.contains("current"))
        XCTAssertTrue(visible.contains("prompt"))
    }

    func test_ansiSnapshotDoesNotExportSyntheticCursorCell() {
        let r = ANSIRenderer(rows: 1, cols: 10)

        r.feed("ab".data(using: .utf8)!)

        let ansi = r.ansiSnapshot(includeScrollback: false)
        XCTAssertFalse(ansi.hasSuffix(" \u{1B}[0m"),
                       "synchronized mobile snapshots must not encode the host renderer cursor as a stray glyph")
    }

    func test_ansiSnapshotMatchingVisibleTextKeepsViewportShapeAndStyles() {
        let r = ANSIRenderer(rows: 4, cols: 44)
        r.showCursor = false

        r.feed("""
        old line
        \u{1B}[38;2;242;242;242;48;2;87;31;24m76 - h1 {                                \u{1B}[0m
        \u{1B}[38;2;242;242;242;48;2;87;31;24m77 -   font-size: 56px;                   \u{1B}[0m
        \u{1B}[38;2;242;242;242m• Working (4m 27s • esc to interrupt)\u{1B}[0m
        """.data(using: .utf8)!)

        let visible = """
        76 - h1 {
        77 -   font-size: 56px;
        • Working (4m 27s • esc to interrupt)
        """
        let ansi = r.ansiSnapshot(matchingVisibleText: visible)

        XCTAssertEqual(ansi.components(separatedBy: "\n").count,
                       visible.components(separatedBy: "\n").count,
                       "iOS enhanced snapshots must match the macOS viewport line count instead of shipping the whole renderer scrollback")
        XCTAssertTrue(ansi.contains("48;2;87;31;24"),
                      "visible Ghostty lines should reuse the renderer's latest ANSI background when the same line exists in scrollback")
        XCTAssertTrue(ansi.contains("• Working"),
                      "the live status line must remain in the synchronized iOS snapshot")
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

    // MARK: - OSC buffer cap tests

    /// WHY: a malformed or adversarial OSC string must not grow oscBuffer beyond
    /// oscBufferCap, preventing unbounded memory growth (OOM risk on long-running
    /// terminal sessions receiving crafted input).
    func test_oscBuffer_abortsToGroundAtCap() {
        let r = ANSIRenderer(rows: 2, cols: 20)
        // Build an OSC sequence whose payload exceeds the cap: ESC ] <cap+1 bytes> BEL
        var oversized = Data([0x1B, 0x5D]) // ESC ]
        oversized += Data(repeating: UInt8(ascii: "X"), count: ANSIRenderer.oscBufferCap + 1)
        oversized += Data([0x07]) // BEL terminator
        r.feed(oversized)
        // After overflow the parser must be back in ground, not stuck in .osc.
        // Verify by feeding plain text that must land in the grid correctly.
        r.feed("A".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "A",
            "parser must return to ground after OSC overflow so subsequent text is placed")
    }

    /// WHY: legitimate short OSC sequences (e.g. title sets, <100 bytes) must
    /// continue to be consumed and not corrupt the parser state.
    func test_oscBuffer_shortSequenceDoesNotAffectSubsequentText() {
        let r = ANSIRenderer(rows: 2, cols: 20)
        // ESC ] 0 ; title BEL  (set-title, standard OSC 0)
        let osc = "\u{1B}]0;my title\u{07}"
        r.feed(osc.data(using: .utf8)!)
        r.feed("B".data(using: .utf8)!)
        XCTAssertEqual(r.grid[0][0].ch, "B",
            "normal OSC sequence must not corrupt ground state")
    }
}
