import SwiftUI
import AppKit

/// RemoteCode design tokens.
///
/// Aesthetic: dense, dark, developer-grade — the cmux / T3 Code lineage.
/// One semantic palette (no raw hex in views), a 4/8 spacing rhythm, a
/// constrained type scale, hairline 1px borders, and shadows reserved
/// for transient surfaces (popovers/modals) only — never on content.
public enum DS {

    // MARK: Color primitives (sRGB, dark theme is the only V1 theme)

    public enum Palette {
        // Backgrounds, low → high elevation
        public static let bg          = Color(hex: 0x0F1419)
        public static let surface     = Color(hex: 0x171D24)
        public static let sidebar     = surface
        public static let surfaceRaised = Color(hex: 0x1B222B)
        public static let surfaceOverlay = Color(hex: 0x212A34)

        // Hairlines
        public static let line        = Color(hex: 0x2A3440)
        public static let lineStrong  = Color(hex: 0x394654)

        // Text
        public static let text        = Color(hex: 0xE7EDF3)
        public static let textSecondary = Color(hex: 0x9DA9B5)
        public static let textTertiary  = Color(hex: 0x6B7785)

        // Brand / semantic accents
        public static let accent      = Color(hex: 0x7CC7FF)
        public static let onAccent    = Color(hex: 0x0A0E13)
        public static let splitPreviewFill = Color(hex: 0x0099FB).opacity(0.34)
        public static let splitPreviewStroke = Color(hex: 0x0099FB)
        public static let success     = Color(hex: 0x8EE6A8)
        public static let warning     = Color(hex: 0xFFD37A)
        public static let danger      = Color(hex: 0xFF8F8F)

        // Interaction layers (composited over surface)
        public static let hover       = Color.white.opacity(0.05)
        public static let pressed     = Color.white.opacity(0.09)
        public static let selection   = Color(hex: 0x7CC7FF).opacity(0.16)
        public static let focusRing   = Color(hex: 0x7CC7FF).opacity(0.65)
    }

    // MARK: AppKit mirror (for NSView-based surfaces)

    public enum NS {
        public static let bg            = NSColor(hex: 0x0F1419)
        public static let surface       = NSColor(hex: 0x171D24)
        public static let sidebar       = surface
        public static let surfaceRaised = NSColor(hex: 0x1B222B)
        public static let line          = NSColor(hex: 0x2A3440)
        public static let lineStrong    = NSColor(hex: 0x394654)
        public static let text          = NSColor(hex: 0xE7EDF3)
        public static let textSecondary = NSColor(hex: 0x9DA9B5)
        public static let textTertiary  = NSColor(hex: 0x6B7785)
        public static let accent        = NSColor(hex: 0x7CC7FF)
        public static let onAccent      = NSColor(hex: 0x0A0E13)
        public static let splitPreviewFill = NSColor(hex: 0x0099FB).withAlphaComponent(0.34)
        public static let splitPreviewStroke = NSColor(hex: 0x0099FB)
        public static let success       = NSColor(hex: 0x8EE6A8)
        public static let warning       = NSColor(hex: 0xFFD37A)
        public static let danger        = NSColor(hex: 0xFF8F8F)
        // Terminal palette: closer to Terminal.app's dark profile than app chrome.
        public static let terminalBG    = NSColor(hex: 0x20242E)
        public static let terminalFG    = NSColor(hex: 0xF2F2F2)

        public static func terminalFont(weight: NSFont.Weight = .regular) -> NSFont {
            if weight == .bold, let font = NSFont(name: "Menlo-Bold", size: 12) {
                return font
            }
            if let font = NSFont(name: "Menlo-Regular", size: 12) {
                return font
            }
            if let font = NSFont(name: "Menlo", size: 12) {
                return font
            }
            return NSFont.monospacedSystemFont(ofSize: 12, weight: weight)
        }
    }

    // MARK: Spacing — 4/8 rhythm

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs:  CGFloat = 4
        public static let sm:  CGFloat = 6
        public static let md:  CGFloat = 8
        public static let lg:  CGFloat = 12
        public static let xl:  CGFloat = 16
        public static let xxl: CGFloat = 20
        public static let xxxl: CGFloat = 24
        public static let huge: CGFloat = 32
    }

    // MARK: Radius

    public enum Radius {
        public static let control: CGFloat = 5
        public static let card:    CGFloat = 7
        public static let panel:   CGFloat = 9
        public static let modal:   CGFloat = 12
        public static let pill:    CGFloat = 999
    }

    // MARK: Border

    public enum Border {
        public static let hairline: CGFloat = 1
    }

    // MARK: Resize dividers

    public enum ResizeDivider {
        public static let thickness: CGFloat = 5
        public static let gripThickness: CGFloat = 2
        public static let gripLength: CGFloat = 28
    }

    // MARK: Typography — constrained developer-tool scale

    public enum Font {
        public static let caption2 = SwiftUI.Font.system(size: 10, weight: .regular)
        public static let caption  = SwiftUI.Font.system(size: 11, weight: .regular)
        public static let captionStrong = SwiftUI.Font.system(size: 11, weight: .semibold)
        public static let bodyDense = SwiftUI.Font.system(size: 12, weight: .regular)
        public static let body      = SwiftUI.Font.system(size: 13, weight: .regular)
        public static let bodyStrong = SwiftUI.Font.system(size: 13, weight: .semibold)
        public static let title3   = SwiftUI.Font.system(size: 15, weight: .semibold)
        public static let title2   = SwiftUI.Font.system(size: 18, weight: .semibold)
        public static let title    = SwiftUI.Font.system(size: 22, weight: .bold)
        public static let mono     = SwiftUI.Font.system(size: 12, weight: .regular, design: .monospaced)
        public static let monoSmall = SwiftUI.Font.system(size: 11, weight: .regular, design: .monospaced)
        public static let monoStrong = SwiftUI.Font.system(size: 12, weight: .semibold, design: .monospaced)
    }

    // MARK: Motion (rule §7: 150–300ms, ease-out enter)

    public enum Motion {
        public static let micro = Animation.easeOut(duration: 0.16)
        public static let standard = Animation.easeOut(duration: 0.22)
        public static let emphasized = Animation.spring(response: 0.34, dampingFraction: 0.86)
    }
}

// MARK: - Color hex helpers

public extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

public extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}
