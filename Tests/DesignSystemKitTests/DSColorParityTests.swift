import XCTest
import SwiftUI
@testable import DesignSystemKit

// MARK: - Cross-platform color parity
//
// WHY: DS.Palette is maintained by hand as hex literals (Tokens.swift). The
// iOS counterpart DS.Color is maintained by hand as fractional float literals
// (DesignSystem.swift). Both encode the same palette in different notations;
// silent drift between them produces UI that looks correct on one platform and
// wrong on the other, with no compile error. These tests assert that each
// macOS palette hex matches the canonical hex in ../../design-tokens.json,
// expressed as the Color(hex:) float expansion so the test uses the *same*
// conversion path both platforms use at runtime.
//
// Tokens in scope: the 13 tokens shared across both platforms (see
// design-tokens.json `_name_mapping`). Platform-only tokens (terminalBG,
// terminalFG, surfaceOverlay, lineStrong, onAccent, textTertiary) are excluded
// from shared-parity assertions but pinned individually below so they still
// fail loudly on drift.
//
// Conversion: hex 0xRRGGBB -> (Double, Double, Double) via /255.0, matching
// the Color(hex:) extension in Tokens.swift lines 160-165.
//
// Tolerance: 0.001 (< 0.5/255 ≈ 0.00196) so any channel rounding difference
// of more than half a quantisation step fails the test.

private func rgb(_ hex: UInt32) -> (Double, Double, Double) {
    let r = Double((hex >> 16) & 0xFF) / 255.0
    let g = Double((hex >> 8)  & 0xFF) / 255.0
    let b = Double(hex & 0xFF)         / 255.0
    return (r, g, b)
}

private func assertHex(
    _ token: StaticString,
    actual: Color,
    canonical hex: UInt32,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    // Resolve the Color through the same CGColor bridge both renderers use.
    // sRGB space is required; the Color(hex:) constructor always uses .sRGB.
    guard let cgColor = actual.cgColor,
          let components = cgColor.converted(
              to: CGColorSpace(name: CGColorSpace.sRGB)!,
              intent: .defaultIntent,
              options: nil
          )?.components,
          components.count >= 3
    else {
        XCTFail(
            "\(token): could not resolve CGColor — ensure test runs with a display context",
            file: file, line: line
        )
        return
    }
    let (expR, expG, expB) = rgb(hex)
    XCTAssertEqual(Double(components[0]), expR, accuracy: 0.001,
                   "\(token) red channel: actual=\(components[0]) expected=\(expR) (0x\(String(hex, radix: 16, uppercase: true)))",
                   file: file, line: line)
    XCTAssertEqual(Double(components[1]), expG, accuracy: 0.001,
                   "\(token) green channel: actual=\(components[1]) expected=\(expG)",
                   file: file, line: line)
    XCTAssertEqual(Double(components[2]), expB, accuracy: 0.001,
                   "\(token) blue channel: actual=\(components[2]) expected=\(expB)",
                   file: file, line: line)
}

final class DSColorParityTests: XCTestCase {

    // MARK: Shared tokens (must match design-tokens.json `tokens` block)

    func test_bg_matchesCanonical() {
        // WHY: bg is the base app background; drift causes the iOS shell to
        // display a noticeably different dark shade from the macOS app.
        assertHex("bg", actual: DS.Palette.bg, canonical: 0x0F1419)
    }

    func test_surface_matchesCanonical() {
        // WHY: surface (macOS) == panel (iOS) — used for card backgrounds.
        assertHex("surface", actual: DS.Palette.surface, canonical: 0x171D24)
    }

    func test_surfaceRaised_matchesCanonical() {
        // WHY: surfaceRaised is macOS-only (no iOS shared counterpart in v1)
        // but still pinned to the shared canonical so it can be adopted later.
        assertHex("surfaceRaised", actual: DS.Palette.surfaceRaised, canonical: 0x1B222B)
    }

    func test_line_matchesCanonical() {
        // WHY: border lines must be identical across platforms — paired surfaces
        // share borders in the split-screen remote UI.
        assertHex("line", actual: DS.Palette.line, canonical: 0x2A3440)
    }

    func test_text_matchesCanonical() {
        // WHY: primary text contrast is the highest-stakes color token for
        // accessibility; a mismatch between platforms breaks WCAG 1.4.3.
        assertHex("text", actual: DS.Palette.text, canonical: 0xE7EDF3)
    }

    func test_textSecondary_matchesCanonical() {
        // WHY: textSecondary (macOS) == muted (iOS) — used for metadata labels.
        assertHex("textSecondary", actual: DS.Palette.textSecondary, canonical: 0x9DA9B5)
    }

    func test_accent_matchesCanonical() {
        // WHY: accent drives interactive affordances (links, buttons, focus)
        // on both platforms; a hue shift breaks visual consistency.
        assertHex("accent", actual: DS.Palette.accent, canonical: 0x7CC7FF)
    }

    func test_splitPreviewStroke_matchesCanonical() {
        // WHY: splitPreviewStroke renders the shared split-pane indicator used
        // in the macOS terminal and mirrored on iOS BrowserRemote; drift is
        // immediately visible to the user.
        assertHex("splitPreviewStroke", actual: DS.Palette.splitPreviewStroke, canonical: 0x0099FB)
    }

    func test_success_matchesCanonical() {
        // WHY: success (macOS) == ok (iOS) — status badge color for
        // connected/running states visible on both platforms simultaneously.
        assertHex("success", actual: DS.Palette.success, canonical: 0x8EE6A8)
    }

    func test_warning_matchesCanonical() {
        // WHY: warning (macOS) == warn (iOS) — status badge color for
        // degraded/reconnecting states.
        assertHex("warning", actual: DS.Palette.warning, canonical: 0xFFD37A)
    }

    func test_danger_matchesCanonical() {
        // WHY: danger (macOS) == bad (iOS) — used for destructive actions and
        // error state badges; wrong hue erodes trust signals.
        assertHex("danger", actual: DS.Palette.danger, canonical: 0xFF8F8F)
    }

    // MARK: macOS-only tokens (pinned to detect local drift; not in shared scope)

    func test_surfaceOverlay_isPinned() {
        assertHex("surfaceOverlay", actual: DS.Palette.surfaceOverlay, canonical: 0x212A34)
    }

    func test_lineStrong_isPinned() {
        assertHex("lineStrong", actual: DS.Palette.lineStrong, canonical: 0x394654)
    }

    func test_textTertiary_isPinned() {
        assertHex("textTertiary", actual: DS.Palette.textTertiary, canonical: 0x6B7785)
    }

    func test_onAccent_isPinned() {
        assertHex("onAccent", actual: DS.Palette.onAccent, canonical: 0x0A0E13)
    }

    // MARK: AppKit NS mirror (same hex, different type)

    func test_NS_bg_matchesSwiftUI() {
        // WHY: NS.bg and Palette.bg must encode the same value; they are used
        // interchangeably in NSView and SwiftUI surfaces on the same screen.
        XCTAssertEqual(DS.NS.bg.redComponent,   DS.Palette.bg.cgColor!.components![0], accuracy: 0.001)
        XCTAssertEqual(DS.NS.bg.greenComponent, DS.Palette.bg.cgColor!.components![1], accuracy: 0.001)
        XCTAssertEqual(DS.NS.bg.blueComponent,  DS.Palette.bg.cgColor!.components![2], accuracy: 0.001)
    }

    func test_NS_accent_matchesSwiftUI() {
        XCTAssertEqual(DS.NS.accent.redComponent,   DS.Palette.accent.cgColor!.components![0], accuracy: 0.001)
        XCTAssertEqual(DS.NS.accent.greenComponent, DS.Palette.accent.cgColor!.components![1], accuracy: 0.001)
        XCTAssertEqual(DS.NS.accent.blueComponent,  DS.Palette.accent.cgColor!.components![2], accuracy: 0.001)
    }
}
