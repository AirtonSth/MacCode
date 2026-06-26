import XCTest
@testable import AppShell
@testable import Surfaces
import SocketServer

/// Tests for the mirror ANSI-palette serialization seam.
///
/// WHY: the iOS mirror re-renders the Mac terminal's ANSI bytes through its own
/// renderer. When a user picks a non-default Ghostty theme, the Mac surface and
/// the iOS mirror render the SAME bytes with DIFFERENT colors (drift). The fix
/// transmits the resolved 16-entry palette alongside the snapshot. Default-theme
/// snapshots send an explicit null so iOS clears any cached custom palette for
/// the same surface.
///
/// Two layers are covered:
///  1. The pure encoder `ANSIPaletteMapper.customPaletteHex(from:)` (round-trip
///     + omit-for-default).
///  2. The wire serializer `terminalSnapshotJSON` (custom palette array, default
///     palette null).
final class TerminalSnapshotPaletteTests: XCTestCase {

    // MARK: - Encoder round-trip (P4: mac round-trip)

    // A custom theme must round-trip into exactly 16 lowercase #rrggbb strings,
    // basic indices 0-7 then bright 8-15, with channel values matching the source
    // NSColor. This is the value the wire carries; if it drifts, the mirror colors
    // drift.
    func test_customPalette_roundTripsTo16HexStrings() {
        // Distinctive per-index colors so a mis-ordered or dropped entry fails.
        var map: [Int: NSColor] = [:]
        for i in 0..<16 {
            map[i] = NSColor(srgbRed: CGFloat(i) / 15.0,
                             green: CGFloat(15 - i) / 15.0,
                             blue: 0.5, alpha: 1)
        }
        let theme = ANSIThemeColors(map)

        guard let hex = ANSIPaletteMapper.customPaletteHex(from: theme) else {
            return XCTFail("a fully-custom theme must produce a palette, not nil")
        }
        XCTAssertEqual(hex.count, 16, "palette must always be the full 16-entry array")
        // index 0 red channel 0 -> #00..; index 15 red channel 255 -> #ff..
        XCTAssertTrue(hex[0].hasPrefix("#00"), "index 0 red channel must encode as 00, got \(hex[0])")
        XCTAssertTrue(hex[15].hasPrefix("#ff"), "index 15 red channel must encode as ff, got \(hex[15])")
        // blue channel is 0.5 everywhere -> 0x80 (128) in the last 2 hex digits.
        for entry in hex {
            XCTAssertTrue(entry.hasSuffix("80"),
                "blue channel 0.5 must encode as 80 for every entry, got \(entry)")
            XCTAssertEqual(entry.count, 7, "each entry must be #rrggbb (7 chars), got \(entry)")
            XCTAssertEqual(entry, entry.lowercased(), "hex must be lowercase, got \(entry)")
        }
    }

    // The default palette (the exact literals the mirror also hardcodes) must
    // encode to nil so the wire sends ansi_palette=null.
    func test_defaultPalette_encodesToNil() {
        // Build a theme that resolves to exactly the default palette.
        let basic = ANSIPaletteMapper.defaultBasic
        let bright = ANSIPaletteMapper.defaultBright
        var map: [Int: NSColor] = [:]
        for i in 0..<8 { map[i] = basic[i]; map[i + 8] = bright[i] }
        let theme = ANSIThemeColors(map)

        XCTAssertNil(ANSIPaletteMapper.customPaletteHex(from: theme),
            "a theme equal to the default palette must encode to nil so ansi_palette is serialized as null")
    }

    // A nil theme (no Ghostty config) must also encode to nil.
    func test_nilTheme_encodesToNil() {
        XCTAssertNil(ANSIPaletteMapper.customPaletteHex(from: nil),
            "a nil theme must produce nil so the snapshot carries no palette")
    }

    // MARK: - Wire serializer includes/clears (P4: snapshot-includes/clears)

    private func snapshot(palette: [String]?) -> TerminalTextSnapshot {
        TerminalTextSnapshot(
            text: "x",
            ansiText: nil,
            ansiPalette: palette,
            complete: true,
            source: "test",
            timestamp: Date(timeIntervalSince1970: 0),
            partialReason: nil,
            pendingBytes: 0,
            rows: 1,
            cols: 1,
            renderDiagnostics: nil
        )
    }

    // A snapshot with a custom palette must serialize an `ansi_palette` array of
    // the exact hex strings, in order.
    func test_snapshotJSON_includesPaletteWhenCustom() {
        let hex = ["#112233", "#445566"] + Array(repeating: "#000000", count: 14)
        guard let obj = terminalSnapshotJSON(snapshot(palette: hex)).objectValue else {
            return XCTFail("snapshot JSON must be an object")
        }
        guard let arr = obj["ansi_palette"]?.arrayValue else {
            return XCTFail("custom palette must emit an ansi_palette array")
        }
        XCTAssertEqual(arr.compactMap { $0.stringValue }, hex,
            "ansi_palette must be the exact hex strings in order")
    }

    // A snapshot with nil palette (default theme) must include explicit null so
    // iOS clears any previous custom palette cached for the same surface.
    func test_snapshotJSON_clearsPaletteWhenNil() {
        guard let obj = terminalSnapshotJSON(snapshot(palette: nil)).objectValue else {
            return XCTFail("snapshot JSON must be an object")
        }
        guard case .null? = obj["ansi_palette"] else {
            return XCTFail("a nil palette must serialize ansi_palette=null so mirrors clear stale custom colors")
        }
        // Sanity: the rest of the payload still serializes.
        XCTAssertEqual(obj["text"]?.stringValue, "x")
    }
}
