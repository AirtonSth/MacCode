import XCTest
import AppKit
@testable import Surfaces

// Tests for the ANSIRenderer.ansiThemeColors(from:) pure static seam that converts
// raw RGB palette entries (as read from Ghostty config) into ANSIThemeColors.
//
// WHY these tests exist: the Mac renders ANSI colors from the Ghostty theme palette,
// while the iOS mirror re-renders ANSI snapshot bytes through ANSIRenderer using its
// own palette. Without exporting the resolved Mac palette alongside the snapshot, the
// same terminal output renders with different colors per device. This seam is the
// single conversion point where a Vec of (index, r, g, b) entries becomes the
// ANSIThemeColors value that ANSIRenderer uses — it must round-trip exactly.
final class ANSIThemeColorExportTests: XCTestCase {

    // MARK: - Round-trip correctness

    // All 16 entries supplied -> all 16 must appear in the result with exact sRGB
    // channel values. Proves the index-to-NSColor mapping is lossless for the
    // 8-bit precision of the Ghostty C struct.
    func test_full16Entries_roundTripExact() {
        let entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)] = (0..<16).map { i in
            (index: i, r: UInt8(i * 16), g: UInt8(255 - i * 16), b: UInt8(128))
        }
        let theme = ANSIRenderer.ansiThemeColors(from: entries)

        for i in 0..<16 {
            guard let color = theme.colors[i] else {
                XCTFail("index \(i) must be present — all 16 entries were supplied")
                continue
            }
            let expectedR = CGFloat(i * 16) / 255.0
            let expectedG = CGFloat(255 - i * 16) / 255.0
            let expectedB = CGFloat(128) / 255.0
            XCTAssertEqual(color.redComponent,   expectedR, accuracy: 1.0 / 255.0,
                "index \(i): red channel must match the raw UInt8 value / 255.0")
            XCTAssertEqual(color.greenComponent, expectedG, accuracy: 1.0 / 255.0,
                "index \(i): green channel must match the raw UInt8 value / 255.0")
            XCTAssertEqual(color.blueComponent,  expectedB, accuracy: 1.0 / 255.0,
                "index \(i): blue channel must match the raw UInt8 value / 255.0")
        }
    }

    // Empty input -> empty colors dict. ANSIPaletteMapper will then use its full
    // built-in defaults — no partial override occurs.
    func test_emptyEntries_producesEmptyDict() {
        let theme = ANSIRenderer.ansiThemeColors(from: [])
        XCTAssertTrue(theme.colors.isEmpty,
            "empty entry list must produce an empty colors dict so ANSIPaletteMapper uses defaults")
    }

    // Entries with index outside 0...15 must be silently dropped — the Ghostty palette
    // struct has 256 slots but ANSIRenderer only uses indices 0-15 for SGR colors.
    // Passing them through would pollute the dict with keys ANSIRenderer never reads.
    func test_outOfRangeIndexes_areSilentlyDropped() {
        let entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)] = [
            (index: -1,  r: 255, g: 0,   b: 0),   // below range
            (index: 5,   r: 10,  g: 20,  b: 30),   // valid
            (index: 16,  r: 200, g: 200, b: 200),  // above 15
            (index: 255, r: 100, g: 100, b: 100),  // way above
        ]
        let theme = ANSIRenderer.ansiThemeColors(from: entries)

        XCTAssertEqual(theme.colors.count, 1,
            "only index 5 is in 0...15; the others must be dropped")
        XCTAssertNotNil(theme.colors[5],
            "the single valid index (5) must be present in the result")
        XCTAssertNil(theme.colors[-1],
            "index -1 is out of range and must not appear in the result")
        XCTAssertNil(theme.colors[16],
            "index 16 is out of range and must not appear in the result")
    }

    // Duplicate entries: when the same index appears more than once (e.g. if the
    // caller iterates a C array that has sparse data), the last writer wins.
    // This is acceptable behavior — it matches Swift Dictionary semantics.
    func test_duplicateIndex_lastEntryWins() {
        let entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)] = [
            (index: 2, r: 10, g: 20, b: 30),
            (index: 2, r: 99, g: 88, b: 77),
        ]
        let theme = ANSIRenderer.ansiThemeColors(from: entries)

        XCTAssertEqual(theme.colors.count, 1, "duplicate index must not create two entries")
        XCTAssertEqual(theme.colors[2]?.redComponent ?? 0, CGFloat(99) / 255.0, accuracy: 1.0 / 255.0,
            "when index 2 appears twice, the last entry's red value must be used")
    }

    // MARK: - Integration with ANSIPaletteMapper

    // A theme produced by ansiThemeColors(from:) must flow correctly through
    // ANSIPaletteMapper — the mapper must use the theme values and not fall back to
    // defaults for supplied indices. This proves the seam connects to the full
    // palette-resolution pipeline that ANSIRenderer uses at init time.
    func test_seam_feedsCorrectlyIntoANSIPaletteMapper() {
        // Supply a distinctive green for index 2 (SGR 32 = basic green).
        let distinctiveGreen = (r: UInt8(11), g: UInt8(222), b: UInt8(33))
        let entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)] = [
            (index: 2, r: distinctiveGreen.r, g: distinctiveGreen.g, b: distinctiveGreen.b)
        ]
        let theme = ANSIRenderer.ansiThemeColors(from: entries)
        let (basic, _) = ANSIPaletteMapper.palette(from: theme)

        // basic[2] must be the supplied green — if it were the default the test fails,
        // proving color drift is eliminated when the theme palette is correctly threaded.
        XCTAssertEqual(basic[2].redComponent,   CGFloat(distinctiveGreen.r) / 255.0, accuracy: 1.0 / 255.0,
            "basic[2] must use the theme green's red channel, not the default green's red")
        XCTAssertEqual(basic[2].greenComponent, CGFloat(distinctiveGreen.g) / 255.0, accuracy: 1.0 / 255.0,
            "basic[2] must use the theme green's green channel, not the default green's green")
        XCTAssertEqual(basic[2].blueComponent,  CGFloat(distinctiveGreen.b) / 255.0, accuracy: 1.0 / 255.0,
            "basic[2] must use the theme green's blue channel, not the default green's blue")
    }

    // MARK: - ANSIRenderer init integration

    // When ANSIRenderer is built with the theme colors returned by the seam, SGR 32
    // (green text) must store the theme green in grid cells — proving the full chain
    // from raw C RGB -> ANSIThemeColors -> ANSIRenderer init -> cell color is correct.
    func test_seam_rendererCellUsesThemePaletteColor() {
        let themeGreen = (r: UInt8(0), g: UInt8(200), b: UInt8(50))
        let entries: [(index: Int, r: UInt8, g: UInt8, b: UInt8)] = [
            (index: 2, r: themeGreen.r, g: themeGreen.g, b: themeGreen.b)
        ]
        let theme = ANSIRenderer.ansiThemeColors(from: entries)
        let renderer = ANSIRenderer(rows: 1, cols: 20, themeColors: theme)

        // SGR 32 selects basicColors[2] (green).
        renderer.feed("\u{1B}[32mG".data(using: .utf8)!)

        let cell = renderer.grid[0][0]
        XCTAssertEqual(cell.ch, "G")
        XCTAssertEqual(cell.fg.redComponent,   CGFloat(themeGreen.r) / 255.0, accuracy: 1.0 / 255.0,
            "grid cell fg red must match the theme green from ansiThemeColors(from:) — not the hardcoded default")
        XCTAssertEqual(cell.fg.greenComponent, CGFloat(themeGreen.g) / 255.0, accuracy: 1.0 / 255.0,
            "grid cell fg green must match the theme green from ansiThemeColors(from:)")
        XCTAssertEqual(cell.fg.blueComponent,  CGFloat(themeGreen.b) / 255.0, accuracy: 1.0 / 255.0,
            "grid cell fg blue must match the theme green from ansiThemeColors(from:)")
    }
}
