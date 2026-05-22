import XCTest
@testable import Surfaces

final class MarkdownRenderTests: XCTestCase {
    @MainActor func test_headings_andBold_render() {
        let html = MarkdownSurface.renderHTML(markdown: "# Hello\n\nThis is **bold** and *italic*.")
        XCTAssertTrue(html.contains("<h1>Hello</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
    }

    @MainActor func test_codeFences_render() {
        let html = MarkdownSurface.renderHTML(markdown: "```swift\nlet x = 1\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"lang-swift\">"))
    }

    @MainActor func test_lists_render() {
        let html = MarkdownSurface.renderHTML(markdown: "- a\n- b\n- c")
        XCTAssertTrue(html.contains("<ul>"))
        XCTAssertTrue(html.contains("<li>a</li>"))
    }

    @MainActor func test_links_render() {
        let html = MarkdownSurface.renderHTML(markdown: "[foo](https://x.y)")
        XCTAssertTrue(html.contains("<a href=\"https://x.y\">foo</a>"))
    }

    @MainActor func test_markdownPreviewReadsBoundedPrefixForLargeFiles() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-large-markdown-\(UUID().uuidString).md")
        try ("# title\n" + String(repeating: "a", count: 128)).write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let body = MarkdownSurface.loadMarkdownBody(filePath: file.path, maxBytes: 32)

        XCTAssertTrue(body.hasPrefix("# title"), "markdown preview should still render the useful beginning of a large file")
        XCTAssertTrue(body.contains("Preview truncated"), "large markdown previews must disclose truncation instead of reading the whole file into memory")
    }
}
