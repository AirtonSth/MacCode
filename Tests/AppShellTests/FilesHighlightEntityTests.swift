import AppKit
import XCTest
@testable import AppShell

final class FilesHighlightEntityTests: XCTestCase {
    func test_highlightedMarkupKeepsAttributesAlignedAfterEscapedEntities() {
        // WHY: markup highlighting escapes `<`, `>`, and `&` before converting spans back
        // to attributed-string ranges. If decoded entity lengths are counted incorrectly,
        // syntax colors shift onto plain text after `&amp;` or miss later tag tokens.
        let source = #"<button title="Tom & Jerry">Go</button>"#
        let palette = EditorColorPalette.resolve(isDark: false)
        let attributed = highlightedCodeAttributedString(source, palette: palette)
        let nsSource = source as NSString

        XCTAssertEqual(attributed.string, source,
            "highlighting must preserve the original editor text, not the escaped HTML")
        assertSyntaxColor(in: attributed, source: nsSource, needle: "&", palette: palette,
            "ampersand inside an escaped string literal must retain string syntax color")
        assertSyntaxColor(in: attributed, source: nsSource, needle: "\">Go", offsetWithinNeedle: 1, palette: palette,
            "closing tag punctuation after &amp; must stay aligned")
        assertBaseTextColor(in: attributed, source: nsSource, needle: "Go", palette: palette,
            "plain text content after the escaped attribute must not inherit syntax color")
        assertSyntaxColor(in: attributed, source: nsSource, needle: "</button>", offsetWithinNeedle: 1, palette: palette,
            "closing tag after escaped attribute text must still receive syntax color")
    }

    private func assertSyntaxColor(
        in attributed: NSAttributedString,
        source: NSString,
        needle: String,
        offsetWithinNeedle: Int = 0,
        palette: EditorColorPalette,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color = color(in: attributed, source: source, needle: needle, offsetWithinNeedle: offsetWithinNeedle) else {
            XCTFail("missing foreground color for \(needle)", file: file, line: line)
            return
        }

        XCTAssertFalse(color.isEqual(palette.text), message, file: file, line: line)
    }

    private func assertBaseTextColor(
        in attributed: NSAttributedString,
        source: NSString,
        needle: String,
        offsetWithinNeedle: Int = 0,
        palette: EditorColorPalette,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color = color(in: attributed, source: source, needle: needle, offsetWithinNeedle: offsetWithinNeedle) else {
            XCTFail("missing foreground color for \(needle)", file: file, line: line)
            return
        }

        XCTAssertTrue(color.isEqual(palette.text), message, file: file, line: line)
    }

    private func color(
        in attributed: NSAttributedString,
        source: NSString,
        needle: String,
        offsetWithinNeedle: Int
    ) -> NSColor? {
        let range = source.range(of: needle)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(
            .foregroundColor,
            at: range.location + offsetWithinNeedle,
            effectiveRange: nil
        ) as? NSColor
    }
}
