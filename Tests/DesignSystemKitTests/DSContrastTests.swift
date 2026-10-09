import XCTest
import SwiftUI
@testable import DesignSystemKit

// MARK: - Contrast of chat text and on-accent glyphs
//
// WHY: the palette is dark-only and the chat prints 10-11pt text. A token
// pair below WCAG 4.5:1 is unreadable at that size, and nothing in the
// compiler stops a view from picking it. Each test pins the ratio of a pair
// and the chat site that must use the passing one, so a token edit or a
// view edit that brings the failing pair back is caught here.
//
// Ratios are WCAG 2.x relative luminance over the sRGB components that
// Color(hex:) produces, the same path DSColorParityTests resolves.

private func srgbComponents(
    _ color: Color,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> (Double, Double, Double) {
    let cgColor = try XCTUnwrap(color.cgColor, "color must resolve to a CGColor", file: file, line: line)
    let converted = try XCTUnwrap(
        cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
        file: file, line: line
    )
    let components = try XCTUnwrap(converted.components, file: file, line: line)
    XCTAssertGreaterThanOrEqual(components.count, 3, file: file, line: line)
    return (Double(components[0]), Double(components[1]), Double(components[2]))
}

private func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
    func linear(_ channel: Double) -> Double {
        channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
}

private func contrastRatio(
    _ foreground: Color,
    on background: Color,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Double {
    let first = relativeLuminance(try srgbComponents(foreground, file: file, line: line))
    let second = relativeLuminance(try srgbComponents(background, file: file, line: line))
    return (max(first, second) + 0.05) / (min(first, second) + 0.05)
}

/// The source between two markers of a chat chrome file, markers included.
private func chatSource(
    _ relativePath: String,
    from startMarker: String,
    to endMarker: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    let start = try XCTUnwrap(source.range(of: startMarker), "\(startMarker) must exist", file: file, line: line)
    let end = try XCTUnwrap(
        source.range(of: endMarker, range: start.upperBound..<source.endIndex),
        "\(endMarker) must follow \(startMarker)",
        file: file, line: line
    )
    return String(source[start.lowerBound..<end.upperBound])
}

final class DSContrastTests: XCTestCase {

    func test_scrollToLatestGlyphUsesOnAccent_becauseWhiteOnAccentIsUnreadable() throws {
        // WHY: the "scroll to latest" arrow sits on an accent disc. White on
        // accent is 1.83:1, so the arrow all but disappeared; onAccent is the
        // token made for this fill.
        XCTAssertGreaterThanOrEqual(
            try contrastRatio(DS.Palette.onAccent, on: DS.Palette.accent),
            4.5,
            "onAccent must stay readable on the accent fill"
        )
        XCTAssertLessThan(
            try contrastRatio(Color(hex: 0xFFFFFF), on: DS.Palette.accent),
            3.0,
            "white on accent is under even the 3:1 floor for a control glyph"
        )
        let glyph = try chatSource(
            "Sources/Surfaces/AgentChatTimelineChrome.swift",
            from: "Image(systemName: \"arrow.down\")",
            to: ".background(DS.Palette.accent)"
        )
        XCTAssertTrue(
            glyph.contains(".foregroundColor(DS.Palette.onAccent)"),
            "the scroll-to-latest arrow must be drawn in onAccent"
        )
        XCTAssertFalse(glyph.contains(".white"), "white on the accent disc is 1.83:1")
    }

    func test_chatMetadataUsesTextSecondary_becauseTertiaryFailsAAOnSurface() throws {
        // WHY: the thread-row subtitle (model and time) and the message
        // timestamp are 10pt text the owner reads to pick a thread. They are
        // information, not decoration, so they need 4.5:1.
        XCTAssertGreaterThanOrEqual(
            try contrastRatio(DS.Palette.textSecondary, on: DS.Palette.surface),
            4.5,
            "textSecondary is the dimmest tier allowed for information text"
        )
        // Documents the measured value: textTertiary stays a decoration tier.
        // If the token is ever lifted past 4.5, this fails and the rule above
        // can be revisited on purpose.
        XCTAssertEqual(
            try contrastRatio(DS.Palette.textTertiary, on: DS.Palette.surface),
            3.72,
            accuracy: 0.01,
            "textTertiary on surface is 3.72:1, below 4.5:1"
        )
        let subtitle = try chatSource(
            "Sources/Surfaces/AgentChatSharedChrome.swift",
            from: "Text(subtitle)",
            to: ".lineLimit(1)"
        )
        XCTAssertTrue(
            subtitle.contains(".foregroundColor(DS.Palette.textSecondary)"),
            "thread-row subtitle must use textSecondary"
        )
        XCTAssertFalse(subtitle.contains("textTertiary"), "3.72:1 on the rail, 2.64:1 on a selected row")
        let timestamp = try chatSource(
            "Sources/Surfaces/AgentChatTranscriptChrome.swift",
            from: "Text(AgentChatTranscriptChrome.relativeTimestamp(",
            to: ".accessibilityIdentifier(\"bots.desk.timestamp\")"
        )
        XCTAssertTrue(
            timestamp.contains(".foregroundColor(DS.Palette.textSecondary)"),
            "message timestamp must use textSecondary"
        )
        XCTAssertFalse(timestamp.contains("textTertiary"), "4.06:1 on the transcript background")
    }

    func test_emptyStateSubtitleUsesTextSecondary_becauseItCarriesInstructions() throws {
        // WHY: the empty-state subtitle is the instruction for the screen
        // ("@mention a bot to choose who answers."), printed at 12pt on bg.
        // textTertiary there is 4.06:1; textSecondary is the dimmest tier
        // allowed for text the owner has to read.
        XCTAssertGreaterThanOrEqual(
            try contrastRatio(DS.Palette.textSecondary, on: DS.Palette.bg),
            4.5,
            "textSecondary must stay readable on the window background"
        )
        XCTAssertLessThan(
            try contrastRatio(DS.Palette.textTertiary, on: DS.Palette.bg),
            4.5,
            "textTertiary on bg is 4.06:1, below 4.5:1"
        )
        let subtitle = try chatSource(
            "Sources/DesignSystemKit/Components.swift",
            from: "Text(subtitle)",
            to: ".multilineTextAlignment(.center)"
        )
        XCTAssertTrue(
            subtitle.contains(".foregroundColor(DS.Palette.textSecondary)"),
            "DSEmptyState subtitle must use textSecondary"
        )
        XCTAssertFalse(subtitle.contains("textTertiary"), "4.06:1 at 12pt on bg")
    }
}
