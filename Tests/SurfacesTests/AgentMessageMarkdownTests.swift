import XCTest
@testable import Surfaces

final class AgentMessageMarkdownTests: XCTestCase {
    func test_blocksPreserveChatMarkdownStructure() {
        let blocks = AgentMessageMarkdown.blocks(from: """
        # Review

        This has **risk** and `code`.

        - first fix
        - second fix

        ```swift
        let pass = true
        ```
        """)

        XCTAssertEqual(blocks.map(\.kind), [
            .heading(1),
            .paragraph,
            .bullet(indent: 0),
            .bullet(indent: 0),
            .code(language: "swift")
        ], "chat answers must keep headings, bullets, and fenced code as renderable blocks instead of one plain paragraph")
        XCTAssertEqual(blocks.last?.text, "let pass = true",
                       "fenced code must render without the backtick fence markers")
    }

    func test_orderedListsRenderAsNumberedBlocksNotRunOnParagraph() {
        let blocks = AgentMessageMarkdown.blocks(from: """
        Steps:

        1. clone the repo
        2. run the tests
        3. open a PR
        """)
        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph,
            .numbered(number: 1, indent: 0),
            .numbered(number: 2, indent: 0),
            .numbered(number: 3, indent: 0),
        ], "numbered lists must render as ordered items, not a single run-on paragraph")
        XCTAssertEqual(blocks[1].text, "clone the repo")
    }

    func test_nestedBulletKeepsIndent() {
        let blocks = AgentMessageMarkdown.blocks(from: "- top\n    - nested")
        XCTAssertEqual(blocks.map(\.kind), [.bullet(indent: 0), .bullet(indent: 2)])
    }

    func test_blocksLeavePlainChatTextAsOneParagraph() {
        let blocks = AgentMessageMarkdown.blocks(from: "plain answer")

        XCTAssertEqual(blocks, [AgentMessageMarkdownBlock(kind: .paragraph, text: "plain answer")],
                       "plain messages must not be split or reformatted just because Markdown rendering is enabled")
    }
}
