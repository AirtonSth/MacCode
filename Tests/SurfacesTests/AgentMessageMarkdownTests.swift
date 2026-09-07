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

    /// WHY (perf CH-04): the live streaming row used to bypass the cache on the
    /// READ as well, so every token re-parsed every earlier paragraph of the
    /// growing answer (O(n²) in answer length). `cache:false` must mean
    /// "don't store", never "don't read".
    func test_attributedInline_cacheFalse_stillReadsTheCache() {
        let text = "stable paragraph parsed while finished"
        _ = AgentMessageMarkdown.attributedInline(text, cache: true)
        AgentMessageMarkdown.inlineComputeCountForTesting = 0
        _ = AgentMessageMarkdown.attributedInline(text, cache: false)
        XCTAssertEqual(
            AgentMessageMarkdown.inlineComputeCountForTesting, 0,
            "a live row (cache:false) must still READ cached parses of identical text"
        )
    }

    /// WHY (perf CH-04): during a stream only the LAST block of a group grows;
    /// stable earlier blocks must parse once and hit the cache on every tick.
    func test_selectableProse_liveGroup_reparsesOnlyTheLastBlock() {
        let blocks = [
            AgentMessageMarkdownBlock(kind: .paragraph, text: "first stable paragraph"),
            AgentMessageMarkdownBlock(kind: .paragraph, text: "second stable paragraph"),
            AgentMessageMarkdownBlock(kind: .paragraph, text: "growing tail")
        ]
        AgentMessageMarkdown.inlineComputeCountForTesting = 0
        _ = AgentMessageMarkdown.selectableProse(from: blocks, compact: false, cache: false)
        let computesAfterFirstPaint = AgentMessageMarkdown.inlineComputeCountForTesting
        XCTAssertEqual(computesAfterFirstPaint, 3, "sanity: the first paint parses all blocks")

        // Ten stream ticks with the same stable prefix: only the tail reparses.
        for _ in 0..<10 {
            _ = AgentMessageMarkdown.selectableProse(from: blocks, compact: false, cache: false)
        }
        XCTAssertEqual(
            AgentMessageMarkdown.inlineComputeCountForTesting,
            computesAfterFirstPaint + 10,
            "10 ticks on a 3-block live group must reparse only the last block (10 computes), not 30"
        )
    }

    func test_shouldStoreMarkdownCache_respectsFlagAndSizeBand() {
        XCTAssertTrue(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 64, cache: true))
        XCTAssertFalse(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 64, cache: false),
                       "live path flag must disable store even for small text")
        XCTAssertFalse(AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 0, cache: true))
        XCTAssertTrue(
            AgentMessageMarkdown.shouldStoreMarkdownCache(textUTF8Count: 60 * 1_024, cache: true),
            "finished 60 KiB replies must cache so a conversation switch does not reparse"
        )
    }

    func test_inlineCacheCountLimitIs512() {
        XCTAssertEqual(AgentMessageMarkdown.inlineCacheCountLimit, 512)
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheCountLimit, 512)
        XCTAssertEqual(
            AgentMessageMarkdown.inlineCacheCountLimit,
            AgentMessageMarkdown.blocksCacheCountLimit
        )
    }

    func test_markdownCacheCostLimits_are4MiB() {
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheCostLimit, 4 * 1_024 * 1_024)
        XCTAssertEqual(AgentMessageMarkdown.inlineCacheCostLimit, 4 * 1_024 * 1_024)
    }

    func test_finishedLargeReply_secondParseHitsCache() {
        #if DEBUG
        AgentMessageMarkdown.blocksComputeCountForTesting = 0
        AgentMessageMarkdown.blocksCacheStoreCountForTesting = 0
        let text = String(repeating: "paragraph with enough body. ", count: 2_400)
        XCTAssertGreaterThan(text.utf8.count, 48 * 1_024)
        _ = AgentMessageMarkdown.blocks(from: text, cache: true)
        let afterFirst = AgentMessageMarkdown.blocksComputeCountForTesting
        _ = AgentMessageMarkdown.blocks(from: text, cache: true)
        XCTAssertEqual(
            AgentMessageMarkdown.blocksComputeCountForTesting,
            afterFirst,
            "a finished 60 KiB reply must not reparse on the second conversation paint"
        )
        #endif
    }

    func test_selectableProse_secondCallHitsGroupCache() {
        let blocks = [
            AgentMessageMarkdownBlock(kind: .paragraph, text: "Hello cache"),
            AgentMessageMarkdownBlock(kind: .paragraph, text: "Second line")
        ]
        let first = AgentMessageMarkdown.selectableProse(from: blocks, compact: false, cache: true)
        let second = AgentMessageMarkdown.selectableProse(from: blocks, compact: false, cache: true)
        XCTAssertEqual(String(first.characters), String(second.characters))
    }

    func test_retentionEstimate_markdownCost_raisedForFinishedReplies() {
        let blocks = AgentMessageMarkdown.blocksCacheCostLimit
        let inline = AgentMessageMarkdown.inlineCacheCostLimit
        XCTAssertGreaterThanOrEqual(blocks, 4 * 1_024 * 1_024)
        XCTAssertGreaterThanOrEqual(inline, 4 * 1_024 * 1_024)
        XCTAssertEqual(blocks + inline, 8 * 1_024 * 1_024)
    }

    func test_inlineMarkdownCountLimit_is512() {
        XCTAssertEqual(AgentMessageMarkdown.inlineCacheCountLimit, 512)
    }

    func test_blocksMarkdownCountLimit_is512() {
        XCTAssertEqual(AgentMessageMarkdown.blocksCacheCountLimit, 512)
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

    // MARK: - R9 markdown link/hover residuals (#4, #5)

    /// ~20 KiB of prose with 50 URL + 50 path tokens so `applyingDetectedLinks`
    /// is measured on a stream-like last paragraph, not a toy string.
    static func linkHeavyFixture(minUTF8: Int = 20 * 1024) -> String {
        var chunks: [String] = []
        chunks.reserveCapacity(100)
        for i in 0..<50 {
            chunks.append("Visit https://example.com/item/\(i)/page now.")
            chunks.append("See Sources/Module\(i)/File\(i).swift for the change.")
        }
        var text = chunks.joined(separator: " ")
        if text.utf8.count < minUTF8 {
            let pad = minUTF8 - text.utf8.count
            text += String(repeating: " lorem", count: pad / 6 + 1)
        }
        return text
    }

    static func linkCount(in attributed: AttributedString) -> Int {
        attributed.runs.reduce(0) { $0 + ($1.link == nil ? 0 : 1) }
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let n = sorted.count
        precondition(n > 0)
        if n % 2 == 1 { return sorted[n / 2] }
        return (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    func test_linkHeavyFixture_has20KiBAndAtLeast50Matches() {
        let text = Self.linkHeavyFixture()
        XCTAssertGreaterThanOrEqual(text.utf8.count, 20 * 1024,
                                    "stream-tail fixture must be ~20 KiB so distance() cost is visible")
        let attributed = AgentMessageMarkdown.applyingDetectedLinks(to: AttributedString(text))
        let matches = Self.linkCount(in: attributed)
        XCTAssertGreaterThanOrEqual(matches, 50,
                                    "fixture must contain ≥50 path/URL links; got \(matches)")
        XCTAssertEqual(matches, 100,
                       "50 URL + 50 path tokens must all linkify — a cursor bug that drops matches fails here")
    }

    /// WHY: hover used to live on the parent and re-enter `blocks(from:)` for the
    /// whole message. After the first finished parse, a cache-hit lookup is still
    /// a parent-body cost; hover isolation must keep lookup/compute at 0.
    func test_finishedMultiGroupMessage_secondParseIsCacheHit() {
        var md = ""
        for i in 0..<10 {
            md += "Paragraph \(i) with some prose about the change.\n\n```swift\nlet value\(i) = \(i)\n```\n\n"
        }
        let groups = AgentMessageMarkdown.selectionGroups(from: AgentMessageMarkdown.blocks(from: md))
        XCTAssertGreaterThanOrEqual(groups.count, 10,
                                    "finished answer must have many groups so parent invalidation is expensive")
        AgentMessageMarkdown.blocksComputeCountForTesting = 0
        AgentMessageMarkdown.blocksLookupCountForTesting = 0
        _ = AgentMessageMarkdown.blocks(from: md)
        XCTAssertEqual(AgentMessageMarkdown.blocksComputeCountForTesting, 0,
                       "finished identical text must not re-tokenize")
        XCTAssertEqual(AgentMessageMarkdown.blocksLookupCountForTesting, 1,
                       "a parent body pass still looks up; hover must not cause this call")
    }

    func test_markdownView_isEquatableOnTextCompactAndCacheFlag() {
        let a = AgentMessageMarkdownView(text: "same body", compact: false, cacheResults: true)
        let b = AgentMessageMarkdownView(text: "same body", compact: false, cacheResults: true)
        let otherText = AgentMessageMarkdownView(text: "other", compact: false, cacheResults: true)
        let otherCompact = AgentMessageMarkdownView(text: "same body", compact: true, cacheResults: true)
        let otherCache = AgentMessageMarkdownView(text: "same body", compact: false, cacheResults: false)
        XCTAssertEqual(a, b, "identical text/compact/cacheResults must compare equal so SwiftUI can skip body")
        XCTAssertNotEqual(a, otherText)
        XCTAssertNotEqual(a, otherCompact)
        XCTAssertNotEqual(a, otherCache)
    }

    /// WHY: hovering Copy used to flip parent @State and re-enter body, which
    /// called `blocks(from:)` for every group. Child chrome has no path to that parse.
    func test_codeBlockCopyChrome_hoverPathDoesNotCallBlocksFrom() {
        var md = ""
        for i in 0..<10 {
            md += "Paragraph \(i) with some prose about the change.\n\n```swift\nlet value\(i) = \(i)\n```\n\n"
        }
        _ = AgentMessageMarkdown.blocks(from: md)
        AgentMessageMarkdown.blocksLookupCountForTesting = 0
        AgentMessageMarkdown.blocksComputeCountForTesting = 0
        let chrome = CodeBlockCopyChrome(text: "let value0 = 0")
        XCTAssertEqual(chrome.text, "let value0 = 0")
        XCTAssertEqual(
            AgentMessageMarkdown.blocksLookupCountForTesting, 0,
            "Copy hover lives on CodeBlockCopyChrome; it must not call blocks(from:)"
        )
        XCTAssertEqual(
            AgentMessageMarkdown.blocksComputeCountForTesting, 0,
            "hover enter/leave must not re-tokenize a finished multi-group message"
        )
    }

    /// WHY: `@State hoveredCode` on `AgentMessageMarkdownView` invalidates every
    /// group. Copy chrome must own hover/copied so parent body (and `blocks(from:)`)
    /// does not re-run on enter/leave.
    func test_hoverStateLivesOnCodeBlockCopyChrome_notParent() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Surfaces/AgentMessageMarkdown.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(
            source.contains("@State private var hoveredCode"),
            "parent hover @State re-runs blocks(from:) for every group on Copy enter/leave"
        )
        XCTAssertFalse(
            source.contains("@State private var copiedCode"),
            "copied feedback @State on the parent has the same whole-message invalidation"
        )
        XCTAssertTrue(
            source.contains("struct CodeBlockCopyChrome"),
            "Copy hover/copied must live on a child view"
        )
        XCTAssertTrue(
            source.contains("@State private var hovered"),
            "CodeBlockCopyChrome must own hovered @State"
        )
    }

    /// Microbench for issue #4. Prints raw medians; the ≥5% target is recorded in
    /// `loops-out/20260906-agent-app-memperf-r9-markdown/performance-proof.md`
    /// from HEAD vs patched runs (not a hardcoded CI baseline).
    func test_applyingDetectedLinks_microbench_20KiB_50matches_300iters() {
        let text = Self.linkHeavyFixture()
        let source = AttributedString(text)
        let warmup = 2
        let samplesN = 5
        let iterations = 300
        for _ in 0..<warmup {
            _ = AgentMessageMarkdown.applyingDetectedLinks(to: source)
        }
        var samples: [Double] = []
        samples.reserveCapacity(samplesN)
        for _ in 0..<samplesN {
            let t0 = CFAbsoluteTimeGetCurrent()
            var lastCount = 0
            for _ in 0..<iterations {
                let result = AgentMessageMarkdown.applyingDetectedLinks(to: source)
                lastCount = Self.linkCount(in: result)
            }
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            XCTAssertEqual(lastCount, 100, "bench must keep 100 links; index conversion must not drop matches")
        }
        let med = median(samples)
        let raw = samples.map { String(format: "%.3f", $0) }.joined(separator: ",")
        NSLog(
            "[perf-proof] applyingDetectedLinks utf8=%d matches=100 warmup=%d n=%d iters=%d samples_ms=%@ median_ms=%.3f",
            text.utf8.count, warmup, samplesN, iterations, raw, med
        )
        if let out = ProcessInfo.processInfo.environment["AGENT_MARKDOWN_BENCH_OUT"], !out.isEmpty {
            let line = "median_ms=\(med) samples_ms=\(raw) utf8=\(text.utf8.count) matches=100 warmup=\(warmup) n=\(samplesN) iters=\(iterations)\n"
            FileManager.default.createFile(atPath: out, contents: Data(line.utf8))
        }
        XCTAssertGreaterThan(med, 0)
        XCTAssertEqual(samples.count, samplesN)
    }
}
