import AppKit
import Foundation

struct TerminalViewportSize: Equatable {
    let rows: Int
    let cols: Int
}

enum TerminalViewportGeometry {
    static let fallbackSize = TerminalViewportSize(rows: 40, cols: 120)

    static func cellSize(for font: NSFont) -> NSSize {
        let glyphSize = ("W" as NSString).size(withAttributes: [.font: font])
        let width = max(1, ceil(glyphSize.width))
        let height = max(1, ceil(font.ascender - font.descender + font.leading))
        return NSSize(width: width, height: height)
    }

    static func size(for viewport: NSSize, font: NSFont, inset: NSSize) -> TerminalViewportSize {
        let cell = cellSize(for: font)
        let usableWidth = max(0, finite(viewport.width) - finite(inset.width) * 2)
        let usableHeight = max(0, finite(viewport.height) - finite(inset.height) * 2)
        let cols = max(1, Int(floor(usableWidth / cell.width)))
        let rows = max(1, Int(floor(usableHeight / cell.height)))
        return TerminalViewportSize(rows: rows, cols: cols)
    }

    private static func finite(_ value: CGFloat) -> CGFloat {
        value.isFinite ? value : 0
    }
}
