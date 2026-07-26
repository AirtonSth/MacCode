import XCTest
@testable import AppShell

/// UX-MAC_AGENT-OPEN-SPLIT: agent file links in adjacent Files split must open
/// previewable kinds in Preview with a collapsed tree, without changing the
/// default Source mode for manual Files opens.
final class FilesAgentSplitOpenPresentationTests: XCTestCase {

    // MARK: - Preview preference by extension

    func test_markdownAndHtmlPreferPreview() {
        // WHY: the user clicks prompt.md / index.html from the agent transcript
        // and expects rendered content, not the raw Source editor.
        XCTAssertTrue(filesPathPrefersReaderPreview("docs/prompt.md"))
        XCTAssertTrue(filesPathPrefersReaderPreview("README.markdown"))
        XCTAssertTrue(filesPathPrefersReaderPreview("page.HTML"))
        XCTAssertTrue(filesPathPrefersReaderPreview("nested/index.htm"))
    }

    func test_pdfAndMediaPreferPreview() {
        // WHY: pdf/image/video already have dedicated preview bodies; opening
        // them in Source is a dead end for binary-ish content.
        XCTAssertTrue(filesPathPrefersReaderPreview("spec.pdf"))
        XCTAssertTrue(filesPathPrefersReaderPreview("shot.PNG"))
        XCTAssertTrue(filesPathPrefersReaderPreview("clip.mov"))
    }

    func test_sourceCodeDoesNotForcePreview() {
        // WHY: agent-open only forces Preview for rich/media kinds. Swift/JSON
        // stay Source so the default edit path is not surprising.
        XCTAssertFalse(filesPathPrefersReaderPreview("Sources/App.swift"))
        XCTAssertFalse(filesPathPrefersReaderPreview("package.json"))
        XCTAssertFalse(filesPathPrefersReaderPreview("Makefile"))
    }

    // MARK: - Presentation bundle

    func test_presentationForMarkdown_isPreviewAndHidesSidebar() {
        // WHY: both preview mode and collapsed tree are required for the
        // reading-focused agent split open of a markdown link.
        let p = FilesAgentSplitOpenPresentation.forRelativePath("twitter-x/prompt_hourly.md")
        XCTAssertEqual(p.readerMode, "preview")
        XCTAssertTrue(p.hideSidebar)
    }

    func test_presentationForCode_keepsSourceButHidesSidebar() {
        // WHY: non-previewable kinds still collapse the tree for focus, but
        // keep Source so the user can edit immediately.
        let p = FilesAgentSplitOpenPresentation.forRelativePath("Sources/Main.swift")
        XCTAssertEqual(p.readerMode, "source")
        XCTAssertTrue(p.hideSidebar)
    }
}
