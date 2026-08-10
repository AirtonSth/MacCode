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

    // F3: the view re-parses markdown on every body pass (keystroke/streaming/hover/
    // resize). Identical content must be parsed once and served from cache thereafter,
    // and the cached result must equal a fresh parse (no correctness drift).
    func test_blocks_areMemoizedByContent() {
        let probe = "## F3 cache probe \u{2728}\n\n- one\n- two\n\n`inline code` and **bold**"
        AgentMessageMarkdown.blocksComputeCountForTesting = 0
        let first = AgentMessageMarkdown.blocks(from: probe)
        let second = AgentMessageMarkdown.blocks(from: probe)
        XCTAssertEqual(AgentMessageMarkdown.blocksComputeCountForTesting, 1,
                       "identical content must be tokenized exactly once; repeat renders hit the cache")
        XCTAssertEqual(first, second, "cached blocks must equal a fresh parse — no correctness drift")
    }

    func test_attributedInline_isMemoizedByContent() {
        let probe = "F3 inline probe \u{2728} with `code` and *emphasis*"
        AgentMessageMarkdown.inlineComputeCountForTesting = 0
        let first = AgentMessageMarkdown.attributedInline(probe)
        let second = AgentMessageMarkdown.attributedInline(probe)
        XCTAssertEqual(AgentMessageMarkdown.inlineComputeCountForTesting, 1,
                       "AttributedString(markdown:) is the expensive per-cell call; identical text must run it once")
        XCTAssertEqual(first, second, "cached attributed inline must equal a fresh parse")
    }

    // MARK: - R4-B streaming partial cache thrash

    /// Live streaming rows pass `cache: false` so growing prefixes never call setObject.
    /// WHY: each intermediate length is a unique NSCache key; countLimit alone still
    /// retained every partial until eviction thrash under memory pressure.
    func test_blocks_cacheFalse_doesNotStoreStreamingPartials() {
        AgentMessageMarkdown.blocksCacheStoreCountForTesting = 0
        var text = ""
        for i in 0..<80 {
            text += "tok\(i) "
            let blocks = AgentMessageMarkdown.blocks(from: text, cache: false)
            XCTAssertFalse(blocks.isEmpty, "live path must still parse without storing")
        }
        XCTAssertEqual(
            AgentMessageMarkdown.blocksCacheStoreCountForTesting, 0,
            "cache:false must never insert growing stream partials into NSCache"
        )
    }

    func test_attributedInline_cacheFalse_doesNotStoreStreamingPartials() {
        AgentMessageMarkdown.inlineCacheStoreCountForTesting = 0
        var text = ""
        for i in 0..<40 {
            text += "w\(i) "
            _ = AgentMessageMarkdown.attributedInline(text, cache: false)
        }
        XCTAssertEqual(
            AgentMessageMarkdown.inlineCacheStoreCountForTesting, 0,
            "cache:false must skip attributedInline store for live partials"
        )
    }

    func test_shouldStoreMarkdownCache_respectsFlagAndSizeBand() {
        XCTAssertTrue(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 64, cache: true))
        XCTAssertFalse(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 64, cache: false),
                       "live path flag must disable store even for small text")
        XCTAssertFalse(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 0, cache: true))
        // 48 KiB band — above must not store (finished large bodies still parse; just no pin).
        XCTAssertFalse(
            AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 49 * 1_024, cache: true),
            "size band must refuse store for oversized source keys"
        )
    }

    /// cache:true still memoizes identical finished content (regression pin for F3).
    func test_blocks_cacheTrue_stillMemoizesFinishedContent() {
        let probe = "R4-B finished body memo \(UUID().uuidString)"
        AgentMessageMarkdown.blocksComputeCountForTesting = 0
        AgentMessageMarkdown.blocksCacheStoreCountForTesting = 0
        _ = AgentMessageMarkdown.blocks(from: probe, cache: true)
        _ = AgentMessageMarkdown.blocks(from: probe, cache: true)
        XCTAssertEqual(AgentMessageMarkdown.blocksComputeCountForTesting, 1)
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheStoreCountForTesting, 1)
    }

    func test_selectionGroups_keepAdjacentProseInOneSelectableSurface() {
        let blocks = AgentMessageMarkdown.blocks(from: """
        First paragraph.

        ## Heading

        - first bullet
        - second bullet

        | Before | After |
        | --- | --- |
        | One | Two |

        Final paragraph.
        """)

        let groups = AgentMessageMarkdown.selectionGroups(from: blocks)

        XCTAssertEqual(groups.map(\.count), [4, 1, 1],
                       "adjacent prose must share one AppKit text surface so a drag can select across paragraph, heading, and list lines; tables remain isolated")
        XCTAssertEqual(groups[0].map(\.text), [
            "First paragraph.", "Heading", "first bullet", "second bullet",
        ])
        XCTAssertEqual(groups[2][0].text, "Final paragraph.")
    }
}
