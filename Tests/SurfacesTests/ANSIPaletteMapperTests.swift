import XCTest
import AppKit
@testable import Surfaces

// Tests that ANSIPaletteMapper correctly derives the 16-entry ANSI palette from
// an active Ghostty theme, so iOS mirror sessions see the same colors as the Mac.
final class ANSIPaletteMapperTests: XCTestCase {

    // MARK: - Default palette (no theme)

    // When no theme is supplied the palette must equal the documented defaults so
    // existing sessions that predate theme support are unaffected.
    func test_noTheme_returnsDocumentedDefaults() {
        let (basic, bright) = ANSIPaletteMapper.palette(from: nil)

        XCTAssertEqual(basic.count, 8, "basic palette must always have exactly 8 entries")
        XCTAssertEqual(bright.count, 8, "bright palette must always have exactly 8 entries")

        // Spot-check index 0 (black) matches the hardcoded default.
        assertColorComponents(basic[0], r: 0.10, g: 0.10, b: 0.10,
                              message: "default black must match original ANSIRenderer literal")
        // Spot-check index 1 (red).
        assertColorComponents(basic[1], r: 0.80, g: 0.20, b: 0.20,
                              message: "default red must match original ANSIRenderer literal")
    }

    // Bright defaults are derived from basic defaults by midpoint-lightening.
    // If the derivation changes, iOS mirroring will drift for sessions without themes.
    func test_noTheme_brightColorsAreLighterThanBasic() {
        let (basic, bright) = ANSIPaletteMapper.palette(from: nil)

        for i in 0..<8 {
            let b = bright[i]
            let n = basic[i]
            // At least one channel must be brighter (or equal when already at 1.0).
            let brighter = b.redComponent >= n.redComponent &&
                           b.greenComponent >= n.greenComponent &&
                           b.blueComponent >= n.blueComponent
            XCTAssertTrue(brighter,
                "bright[\(i)] must be >= basic[\(i)] in all channels so dim/bright ANSI pairs remain visually distinct")
        }
    }

    // MARK: - Theme override

    // When all 16 colors are present, the palette must use only the theme colors so
    // iOS mirrors render the same Ghostty theme the user configured on Mac.
    func test_fullTheme_allIndexesUseThemeColors() {
        var map: [Int: NSColor] = [:]
        for i in 0..<16 {
            let v = CGFloat(i) / 15.0
            map[i] = NSColor(srgbRed: v, green: 0.0, blue: 0.0, alpha: 1)
        }
        let theme = ANSIThemeColors(map)
        let (basic, bright) = ANSIPaletteMapper.palette(from: theme)

        for i in 0..<8 {
            let expected = CGFloat(i) / 15.0
            assertColorComponents(basic[i], r: expected, g: 0.0, b: 0.0,
                message: "basic[\(i)] must use the theme color, not the built-in default")
        }
        for i in 0..<8 {
            let expected = CGFloat(i + 8) / 15.0
            assertColorComponents(bright[i], r: expected, g: 0.0, b: 0.0,
                message: "bright[\(i)] must use theme color at key \(i + 8)")
        }
    }

    // Partially-specified themes must fall back only for missing entries, not clobber
    // everything — a partial theme file (e.g. overriding only red) must still produce
    // correct defaults for the untouched slots.
    func test_partialTheme_missingIndexesFallBackToDefaults() {
        // Override only index 1 (red).
        let customRed = NSColor(srgbRed: 0.99, green: 0.11, blue: 0.11, alpha: 1)
        let theme = ANSIThemeColors([1: customRed])
        let (basic, bright) = ANSIPaletteMapper.palette(from: theme)

        // Index 1 must use the theme value.
        assertColorComponents(basic[1], r: 0.99, g: 0.11, b: 0.11,
            message: "when theme supplies index 1, the custom red must be used")

        // Index 0 must use the default.
        assertColorComponents(basic[0], r: 0.10, g: 0.10, b: 0.10,
            message: "when theme omits index 0, the default black must be used")

        // Bright 0 (index 8 in theme) not in theme — must be default bright.
        XCTAssertEqual(bright[0], ANSIPaletteMapper.defaultBright[0],
            "bright[0] must use the default when theme does not supply key 8")
    }

    // MARK: - Palette completeness

    // ANSIRenderer uses all 16 slots (0-7 for SGR 30-37/40-47, 8-15 for 90-97/100-107).
    // A short palette causes an out-of-bounds crash, so both arrays must be exactly 8.
    func test_paletteIsAlwaysExactly8Plus8() {
        // All three cases: nil, partial, full.
        let inputs: [ANSIThemeColors?] = [
            nil,
            ANSIThemeColors([3: NSColor.red]),
            ANSIThemeColors(Dictionary(uniqueKeysWithValues: (0..<16).map { ($0, NSColor.blue) })),
        ]
        for theme in inputs {
            let (basic, bright) = ANSIPaletteMapper.palette(from: theme)
            XCTAssertEqual(basic.count, 8,
                "basic palette must be exactly 8 — ANSIRenderer indexes with p-30 (0-7)")
            XCTAssertEqual(bright.count, 8,
                "bright palette must be exactly 8 — ANSIRenderer indexes with p-90 (0-7)")
        }
    }

    // MARK: - ANSIRenderer integration

    // ANSIRenderer must honour the theme palette when writing cells, so that the
    // NSColor stored in each cell matches the theme color rather than the default.
    // This proves the plumbing from init -> applySGR -> grid cell is wired correctly.
    func test_rendererUsesThemeColorForSGR31() {
        let customRed = NSColor(srgbRed: 0.95, green: 0.05, blue: 0.05, alpha: 1)
        let theme = ANSIThemeColors([1: customRed])  // index 1 = red (SGR 31)
        let r = ANSIRenderer(rows: 1, cols: 10, themeColors: theme)

        // SGR 31 selects basicColors[1] (red).
        r.feed("\u{1B}[31mA".data(using: .utf8)!)

        XCTAssertEqual(r.grid[0][0].ch, "A")
        assertColorComponents(r.grid[0][0].fg, r: 0.95, g: 0.05, b: 0.05,
            message: "grid cell fg must reflect the theme red, not the built-in default red")
    }

    // Same test for bright red (SGR 91 -> brightColors[1]).
    func test_rendererUsesThemeBrightColorForSGR91() {
        let customBrightRed = NSColor(srgbRed: 0.99, green: 0.50, blue: 0.50, alpha: 1)
        let theme = ANSIThemeColors([9: customBrightRed])  // index 9 = bright red (SGR 91)
        let r = ANSIRenderer(rows: 1, cols: 10, themeColors: theme)

        r.feed("\u{1B}[91mB".data(using: .utf8)!)

        XCTAssertEqual(r.grid[0][0].ch, "B")
        assertColorComponents(r.grid[0][0].fg, r: 0.99, g: 0.50, b: 0.50,
            message: "grid cell fg must reflect the theme bright red (index 9)")
    }

    // When no theme is given the renderer behavior must be identical to the
    // original hardcoded-palette behavior so existing sessions are unaffected.
    func test_rendererNoTheme_behaviorUnchanged() {
        let r = ANSIRenderer(rows: 1, cols: 10)
        r.feed("\u{1B}[31mA\u{1B}[0mX".data(using: .utf8)!)

        // Index 0 has the default red, index 1 has default fg.
        XCTAssertNotEqual(r.grid[0][0].fg, ANSIRenderer.Cell.defaultFG,
            "SGR 31 with no theme must still change fg to non-default")
        XCTAssertEqual(r.grid[0][1].fg, ANSIRenderer.Cell.defaultFG,
            "SGR 0 must reset fg to default regardless of theme")
    }

    // MARK: - Helpers

    private func assertColorComponents(
        _ color: NSColor,
        r: CGFloat, g: CGFloat, b: CGFloat,
        message: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        let eps: CGFloat = 0.01
        XCTAssertEqual(color.redComponent,   r, accuracy: eps, "\(message) [red]",   file: file, line: line)
        XCTAssertEqual(color.greenComponent, g, accuracy: eps, "\(message) [green]", file: file, line: line)
        XCTAssertEqual(color.blueComponent,  b, accuracy: eps, "\(message) [blue]",  file: file, line: line)
    }
}
