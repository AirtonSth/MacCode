import XCTest
import AppKit
@testable import Surfaces

/// QA-cross:24 (mac half) -- comprehensive ANSI palette golden for ANSIRenderer.
///
/// Pairs with the iOS AnsiTextPaletteTests golden grid: every basic (SGR 30-37)
/// and bright (SGR 90-97) foreground code must render its EXACT default-palette
/// slot, so a drift in ANY single color (the UX-gap-12 palette-drift class) fails
/// here. The expected values are the same cross-device contract the iOS renderer
/// asserts -- both platforms map SGR <code> to the same logical palette index.
final class ANSIPaletteGoldenTests: XCTestCase {

    // Feed an SGR foreground sequence + a marker glyph and return the marker's fg.
    private func renderedFG(sgr: Int, themeColors: ANSIThemeColors? = nil) -> NSColor {
        let renderer = ANSIRenderer(rows: 2, cols: 8, themeColors: themeColors)
        renderer.feed(Data("\u{1B}[\(sgr)mX".utf8))
        return renderer.grid[0][0].fg
    }

    func test_goldenPalette_everyBasicForegroundMatchesDefaultSlot() {
        for index in 0..<8 {
            let sgr = 30 + index
            XCTAssertEqual(renderedFG(sgr: sgr), ANSIPaletteMapper.defaultBasic[index],
                "SGR \(sgr) (basic color \(index)) must render ANSIPaletteMapper.defaultBasic[\(index)] -- any drift is a palette regression")
        }
    }

    func test_goldenPalette_everyBrightForegroundMatchesDefaultSlot() {
        for index in 0..<8 {
            let sgr = 90 + index
            XCTAssertEqual(renderedFG(sgr: sgr), ANSIPaletteMapper.defaultBright[index],
                "SGR \(sgr) (bright color \(index)) must render ANSIPaletteMapper.defaultBright[\(index)]")
        }
    }

    func test_goldenPalette_hostThemeThreadsEveryBasicSlot() {
        // Under a full host theme, every SGR 30-37 must resolve to the host slot,
        // proving the palette threads through all colors, not just one. This is the
        // mac analogue of the iOS host-palette golden -- cross-device fidelity.
        var map: [Int: NSColor] = [:]
        for i in 0..<16 {
            map[i] = NSColor(red: CGFloat(i) / 16.0, green: 0.04, blue: 0.04, alpha: 1.0)
        }
        let theme = ANSIThemeColors(map)
        let (basic, _) = ANSIPaletteMapper.palette(from: theme)
        for index in 0..<8 {
            let sgr = 30 + index
            let fg = renderedFG(sgr: sgr, themeColors: theme)
            XCTAssertEqual(fg, basic[index],
                "under a host theme, SGR \(sgr) must render the host basic[\(index)] -- proves all slots thread, not just one")
        }
    }
}
