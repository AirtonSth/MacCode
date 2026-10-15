import XCTest
@testable import CoreModel

/// Contract §4: the images an assistant message talks about. Mac and iPhone
/// must pick the same images in the same order, and the host RPC accepts
/// only refs this detection would produce from the message text.
final class AgentMessageImageRefsTests: XCTestCase {
    private let home = "/Users/tester"

    private func refs(_ content: String, _ attachments: [AgentAttachment] = []) -> [String] {
        AgentMessageImageRefs.extract(content: content, attachments: attachments, homeDirectory: home).map(\.ref)
    }

    func test_M7_markdownImageThenBareURLInOrder() {
        XCTAssertEqual(
            refs("See ![shot](/tmp/a.png) and https://ex.com/b.JPG and [doc](https://ex.com/(x)/y)."),
            ["/tmp/a.png", "https://ex.com/b.JPG"],
            "the doc link is not an image; the uppercase .JPG is"
        )
    }

    /// WHY: a bot screenshot is the main thing the user wants to see; it
    /// comes first, even when the text also mentions images.
    func test_imageAttachmentsComeFirstAndFileAttachmentsAreIgnored() {
        let shot = AgentAttachment(id: "att-1", path: "/store/abc", displayName: "screenshot.jpg", kind: .image, mimeType: "image/jpeg")
        let doc = AgentAttachment(id: "att-2", path: "/store/def", displayName: "notes.pdf", kind: .file, mimeType: "application/pdf")
        let found = AgentMessageImageRefs.extract(content: "📷 login and /tmp/x.png", attachments: [doc, shot], homeDirectory: home)
        XCTAssertEqual(found.map(\.ref), ["att-1", "/tmp/x.png"])
        XCTAssertEqual(found.first?.source, .attachment(id: "att-1", path: "/store/abc"))
        XCTAssertEqual(found.first?.displayName, "screenshot.jpg")
    }

    func test_pathForms_fileURLTildeAndAbsolute_resolveToLocalPaths() {
        let found = AgentMessageImageRefs.extract(
            content: "a file:///tmp/My%20Shot.png b ~/Desktop/c.webp d /var/e.HEIC",
            homeDirectory: home
        )
        XCTAssertEqual(found.map(\.ref), ["file:///tmp/My%20Shot.png", "~/Desktop/c.webp", "/var/e.HEIC"],
                       "ref is the literal token, so the RPC can find it in the message")
        XCTAssertEqual(found.map(\.localPath), ["/tmp/My Shot.png", "/Users/tester/Desktop/c.webp", "/var/e.HEIC"])
    }

    /// WHY: code is not "talking about" an image: a fenced block of paths must
    /// not flood the gallery, while a path in inline code is a real mention.
    func test_fencedCodeIsIgnoredButInlineCodeCounts() {
        XCTAssertEqual(refs("```\n/tmp/in-fence.png\n```\n~~~\n![x](/tmp/tilde.png)\n~~~\nsaved to `/tmp/out.png`."),
                       ["/tmp/out.png"])
        XCTAssertEqual(refs("literal `![x](/tmp/a.png)` is shown as code"), ["/tmp/a.png"],
                       "inside code the markdown is literal text, but the path in it is still a mention")
    }

    func test_relativePathsNonImagesAndOtherSchemesAreNotImages() {
        XCTAssertEqual(refs("see shots/a.png, /tmp/report.pdf, ftp://x/y.png, https://ex.com/page and /tmp/a.png.bak"), [])
    }

    func test_duplicatesCollapseAndTrailingPunctuationIsTrimmed() {
        XCTAssertEqual(refs("(/tmp/a.png), again /tmp/a.png. and ![s](/tmp/a.png) plus https://x.y/p.png?w=2."),
                       ["/tmp/a.png", "https://x.y/p.png?w=2"])
    }

    func test_markdownImageWithAngleBracketsTitleAndParensInSource() {
        XCTAssertEqual(refs(#"![a](</tmp/with space.png> "t") ![b](https://x.y/a_(1).png)"#),
                       ["/tmp/with space.png", "https://x.y/a_(1).png"])
    }

    func test_plainReplyPaysNoScan() {
        XCTAssertFalse(AgentMessageImageRefs.mayContainTextReference("All tests pass. Merged to main."))
        XCTAssertTrue(AgentMessageImageRefs.mayContainTextReference("look at ![x](y)"))
        XCTAssertTrue(AgentMessageImageRefs.mayContainTextReference("saved /tmp/A.PNG"))
    }
}
