import XCTest
@testable import AppShell

final class FilesHighlightPerformanceTests: XCTestCase {

    /// WHY: full-document highlighting is still used when a file first opens,
    /// when the palette changes, and when an edit replaces the whole document.
    /// A regression here stalls the editor before incremental highlighting can
    /// help, so CI needs a repeatable large-document guard.
    func test_performance_fullDocumentHighlight_largeSwiftFile() {
        let line = "let value = try await client.request(path: \"/api/items\", method: .post) // comment\n"
        let text = String(repeating: line, count: 5_000)
        let palette = EditorColorPalette.resolve(isDark: true)

        XCTAssertGreaterThan(text.utf8.count, 400_000,
                             "fixture must be large enough to exercise full-document highlight cost")

        measure {
            _ = highlightedCodeAttributedString(text, palette: palette)
        }
    }
}
