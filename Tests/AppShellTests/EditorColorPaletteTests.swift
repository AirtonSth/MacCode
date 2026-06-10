import XCTest
import AppKit
@testable import AppShell

/// Tests for the pure `EditorColorPalette.resolve(isDark:)` helper that chooses
/// the correct editor color set based on system appearance.
///
/// WHY these tests matter:
///  - In dark mode the editor must use a dark background so text is readable; using
///    a light background in dark mode would make the editor look broken and clash with
///    every surrounding panel.
///  - In light mode the editor must use a light background; using the hardcoded dark
///    values in light mode was the bug this feature fixes: light-mode users see a near-
///    black editor inside a white/grey macOS window.
///  - The `text` color must contrast with `background` so code is legible. A palette
///    that returns dark text on dark background or light text on light background is
///    unusable regardless of correctness on the other axis.
///  - The helpers are pure (no AppKit environment needed) so they can be exercised in a
///    unit test without a running NSApp or display.
final class EditorColorPaletteTests: XCTestCase {

    // MARK: Dark palette

    func test_resolve_dark_backgroundIsDark() {
        // The dark palette background must be perceptually dark (luminance < 0.25).
        // If it isn't, the dark editor will look washed-out or identical to a light theme.
        let palette = EditorColorPalette.resolve(isDark: true)
        XCTAssertLessThan(
            palette.background.relativeLuminance, 0.25,
            "dark palette background must be perceptually dark (luminance < 0.25)")
    }

    func test_resolve_dark_textIsLight() {
        // Text on the dark background must be light so it's readable.
        let palette = EditorColorPalette.resolve(isDark: true)
        XCTAssertGreaterThan(
            palette.text.relativeLuminance, 0.5,
            "dark palette text must be perceptually light (luminance > 0.5) for readability")
    }

    func test_resolve_dark_lineNumberBackgroundMatchesEditorBackground() {
        // The line-number gutter should visually recede next to the editor; it must be
        // at most as bright as the editor background (slightly darker or equal).
        let palette = EditorColorPalette.resolve(isDark: true)
        XCTAssertLessThanOrEqual(
            palette.lineNumberBackground.relativeLuminance,
            palette.background.relativeLuminance + 0.05,
            "dark palette line-number background must not be brighter than the editor background")
    }

    // MARK: Light palette

    func test_resolve_light_backgroundIsLight() {
        // The light palette background must be perceptually light (luminance > 0.75).
        // This is the primary fix: previously the editor was always dark even in light mode.
        let palette = EditorColorPalette.resolve(isDark: false)
        XCTAssertGreaterThan(
            palette.background.relativeLuminance, 0.75,
            "light palette background must be perceptually light (luminance > 0.75)")
    }

    func test_resolve_light_textIsDark() {
        // Text on a light background must be dark to maintain readability.
        let palette = EditorColorPalette.resolve(isDark: false)
        XCTAssertLessThan(
            palette.text.relativeLuminance, 0.25,
            "light palette text must be perceptually dark (luminance < 0.25) for readability")
    }

    func test_resolve_light_lineNumberBackgroundIsLight() {
        // Line-number gutter in light mode must also be light so it doesn't appear as a dark
        // stripe in an otherwise light window.
        let palette = EditorColorPalette.resolve(isDark: false)
        XCTAssertGreaterThan(
            palette.lineNumberBackground.relativeLuminance, 0.6,
            "light palette line-number background must be light")
    }

    // MARK: Dark vs light are different

    func test_resolve_darkAndLight_palettesNotEqual() {
        // The two resolved palettes must be unequal; if resolve() returned the same palette
        // for both modes, the appearance-switch check in updateNSView would never re-apply
        // colors and the bug (dark editor in light mode) would persist.
        let dark = EditorColorPalette.resolve(isDark: true)
        let light = EditorColorPalette.resolve(isDark: false)
        XCTAssertNotEqual(dark, light,
            "dark and light palettes must be unequal so the appearance-change guard triggers")
    }

    func test_resolve_sameMode_palettesEqual() {
        // Two resolves for the same mode must be equal so the guard in updateNSView correctly
        // skips redundant re-application on unrelated @Published changes.
        let a = EditorColorPalette.resolve(isDark: true)
        let b = EditorColorPalette.resolve(isDark: true)
        XCTAssertEqual(a, b,
            "two palettes resolved for the same mode must be equal to allow the no-op guard")
    }
}

// MARK: - NSColor luminance helper (test-only)

private extension NSColor {
    /// WCAG relative luminance: linearised sRGB -> Y component.
    /// Used only to make palette assertions perceptual rather than comparing raw hex values,
    /// so the test doesn't break if exact shades are tweaked while staying accessible.
    var relativeLuminance: CGFloat {
        guard let rgb = usingColorSpace(.sRGB) else { return 0 }
        func lin(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(rgb.redComponent)
             + 0.7152 * lin(rgb.greenComponent)
             + 0.0722 * lin(rgb.blueComponent)
    }
}
