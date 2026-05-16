import Foundation

/// A small fixed swatch palette shared by workspaces, surface tabs, and
/// agent threads. Stored as the raw string (e.g. "blue"); empty/absent
/// means "no color" (use the default chrome tint). CoreModel stays
/// SwiftUI-free — views map `.hex` through DesignSystemKit's Color(hex:).
public enum TabColor: String, CaseIterable, Codable, Sendable {
    case blue, green, orange, red, purple, pink, teal, gray

    public var hex: UInt32 {
        switch self {
        case .blue:   return 0x7CC7FF
        case .green:  return 0x8EE6A8
        case .orange: return 0xFFB774
        case .red:    return 0xFF8F8F
        case .purple: return 0xC7A6FF
        case .pink:   return 0xFF9ECF
        case .teal:   return 0x6FE0D4
        case .gray:   return 0x9DA9B5
        }
    }

    public var label: String { rawValue.capitalized }

    /// Parse a stored value; nil for empty/unknown ("no color").
    public static func from(_ raw: String?) -> TabColor? {
        guard let raw, !raw.isEmpty else { return nil }
        return TabColor(rawValue: raw)
    }
}
