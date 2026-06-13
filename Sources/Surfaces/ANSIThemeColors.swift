import AppKit

/// A set of up to 16 named ANSI terminal colors sourced from an active Ghostty theme.
///
/// Keys 0-7 are the normal (dim) palette; keys 8-15 are the bright variants.
/// Any missing key causes `ANSIPaletteMapper` to substitute the built-in default.
public struct ANSIThemeColors: Sendable {
    public let colors: [Int: NSColor]

    public init(_ colors: [Int: NSColor]) {
        self.colors = colors
    }
}

/// Maps an optional `ANSIThemeColors` value to the concrete 8+8 palette arrays
/// used by `ANSIRenderer`.
///
/// This is a pure, nonisolated helper with no side effects so it can be tested
/// without AppKit runloop or actor context.
public enum ANSIPaletteMapper {

    // MARK: Built-in defaults (mirrors the original ANSIRenderer hardcoded literals)

    public static let defaultBasic: [NSColor] = [
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),  // 0 black
        NSColor(srgbRed: 0.80, green: 0.20, blue: 0.20, alpha: 1),  // 1 red
        NSColor(srgbRed: 0.18, green: 0.60, blue: 0.18, alpha: 1),  // 2 green
        NSColor(srgbRed: 0.80, green: 0.60, blue: 0.20, alpha: 1),  // 3 yellow
        NSColor(srgbRed: 0.20, green: 0.40, blue: 0.80, alpha: 1),  // 4 blue
        NSColor(srgbRed: 0.70, green: 0.30, blue: 0.70, alpha: 1),  // 5 magenta
        NSColor(srgbRed: 0.20, green: 0.60, blue: 0.60, alpha: 1),  // 6 cyan
        NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1),  // 7 white
    ]

    public static let defaultBright: [NSColor] = defaultBasic.map { c in
        let r = (c.redComponent + 1.0) / 2.0
        let g = (c.greenComponent + 1.0) / 2.0
        let b = (c.blueComponent + 1.0) / 2.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    // MARK: Public mapper

    /// Returns `(basic, bright)` — each array has exactly 8 entries.
    ///
    /// For each index, the theme color is used when present; otherwise the
    /// corresponding default is used so the palette is always complete.
    public static func palette(from theme: ANSIThemeColors?) -> (basic: [NSColor], bright: [NSColor]) {
        guard let theme else {
            return (defaultBasic, defaultBright)
        }
        let basic: [NSColor] = (0..<8).map { i in
            theme.colors[i] ?? defaultBasic[i]
        }
        let bright: [NSColor] = (0..<8).map { i in
            theme.colors[i + 8] ?? defaultBright[i]
        }
        return (basic, bright)
    }

    // MARK: - Wire encoding (mirror palette serialization)

    /// Encode a single NSColor as a lowercase `#rrggbb` hex string from its
    /// sRGB channels. Pure; no AppKit runloop needed.
    static func hex(_ color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255.0).rounded())
        let g = Int((c.greenComponent * 255.0).rounded())
        let b = Int((c.blueComponent * 255.0).rounded())
        func clamp(_ v: Int) -> Int { max(0, min(255, v)) }
        return String(format: "#%02x%02x%02x", clamp(r), clamp(g), clamp(b))
    }

    /// The default 16-entry palette (basic 0-7 then bright 8-15) as `#rrggbb`.
    /// Used as the omission baseline: a resolved palette equal to this is the
    /// built-in default, so the wire payload omits `ansi_palette` entirely.
    public static let defaultPaletteHex: [String] =
        (defaultBasic + defaultBright).map(hex)

    /// Resolve `theme` into a complete 16-entry `#rrggbb` palette and return it
    /// ONLY when it differs from the built-in default. Returns `nil` for a nil
    /// theme or for a theme whose resolved 16 colors equal the default palette,
    /// so default themes serialize no `ansi_palette` (back-compat: a nil here
    /// renders byte-identical to before this seam existed).
    ///
    /// WHY: the iOS mirror keeps its own hardcoded default palette. Sending the
    /// default would be redundant bytes and would force iOS down the
    /// custom-palette path for users who never changed their theme. We only
    /// transmit a palette when it is genuinely custom.
    public static func customPaletteHex(from theme: ANSIThemeColors?) -> [String]? {
        guard let theme else { return nil }
        let (basic, bright) = palette(from: theme)
        let resolved = (basic + bright).map(hex)
        return resolved == defaultPaletteHex ? nil : resolved
    }
}
