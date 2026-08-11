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

    func test_inlineCacheCountLimitIs128() {
        XCTAssertEqual(AgentMessageMarkdown.inlineCacheCountLimit, 128)
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheCountLimit, 128)
        // Both process-wide markdown caches share the agent surface ceiling.
        XCTAssertEqual(
            AgentMessageMarkdown.inlineCacheCountLimit,
            AgentMessageMarkdown.blocksCacheCountLimit
        )
    }

    func test_markdownCacheCostLimits_are128KiB() {
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheCostLimit, 128 * 1_024)
        XCTAssertEqual(AgentMessageMarkdown.inlineCacheCostLimit, 128 * 1_024)
    }

    func test_retentionEstimate_markdownCost_256KiBTo128KiBEach() {
        let prior = 256 * 1_024
        let blocks = AgentMessageMarkdown.blocksCacheCostLimit
        let inline = AgentMessageMarkdown.inlineCacheCostLimit
        let reductionBlocks = Double(prior - blocks) / Double(prior)
        let reductionInline = Double(prior - inline) / Double(prior)
        XCTAssertGreaterThan(reductionBlocks, 0.49)
        XCTAssertGreaterThan(reductionInline, 0.49)
        XCTAssertEqual(blocks, 128 * 1_024)
        XCTAssertEqual(inline, 128 * 1_024)

        // Basis: process-wide NSCache totalCostLimit for agent markdown paint.
        // Prior: 2×256 KiB = 512 KiB → 2×128 KiB = 256 KiB (−50%) combined peak budget.
        XCTAssertEqual(prior * 2, 512 * 1_024)
        XCTAssertEqual(blocks + inline, 256 * 1_024)
    }

    func test_retentionEstimate_256InlineMarkdownTo128Window() {
        let uncapped = 256 // prior inlineCache.countLimit
        let limit = AgentMessageMarkdown.inlineCacheCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: modest attributed inline parse ≈ 1KB (long code spans scale
        // with cost limit). Prior countLimit was 256.
        // 256 × 1KB ≈ 256KB → 128 × 1KB ≈ 128KB (−50%).
        let perEntry = 1_024
        XCTAssertEqual(uncapped * perEntry, 262_144)
        XCTAssertEqual(limit * perEntry, 131_072)
    }

    func test_retentionEstimate_256BlocksMarkdownTo128Window() {
        let uncapped = 256 // prior blocksCache.countLimit
        let limit = AgentMessageMarkdown.blocksCacheCountLimit
        let reduction = Double(uncapped - limit) / Double(uncapped)
        XCTAssertGreaterThan(reduction, 0.49)
        XCTAssertEqual(limit, 128)
        // Basis: modest finished-message block tree ≈ 2KB (large docs scale
        // with cost limit). Prior countLimit was 256.
        // 256 × 2KB ≈ 512KB → 128 × 2KB ≈ 256KB (−50%).
        let perEntry = 2_048
        XCTAssertEqual(uncapped * perEntry, 524_288)
        XCTAssertEqual(limit * perEntry, 262_144)
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
