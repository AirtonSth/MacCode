import AppKit
import AgentRuntime
import CoreModel
import ImageIO
import Persistence
import SwiftUI
import XCTest
@testable import Surfaces

/// Live Agent App CPU/RSS wins: cached tool JSON, Equatable live rows,
/// occluded 5s clocks, and 2048px Files/File Preview thumbs.
final class AgentAppMemPerfWinsTests: XCTestCase {

    // MARK: - Win 1: toolCommandPreview uses toolInputObject

    private func bashItem(id: String, command: String) -> AssistantItem {
        AssistantItem(
            id: id,
            turnId: "t-memperf",
            type: .tool,
            state: .completed,
            summary: "Bash",
            body: #"{"command":"\#(command)"}"#,
            startedAtMs: 1,
            finishedAtMs: 2
        )
    }

    func test_toolCommandPreview_streamingPaintsParseEachUniqueToolOnce() {
        // WHY: live tool rows used to JSON-decode item.body on every token
        // paint. 20 completed Bash tools × 200 growing assistant prefixes
        // must parse once per unique body, not N×deltas.
        let toolCount = 20
        let deltas = 200
        let pad = String(repeating: "x", count: 48)
        let items = (0..<toolCount).map { index in
            bashItem(id: "tool-\(index)", command: "echo tool-\(index) \(pad)")
        }

        let before = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting
        for _ in 0..<deltas {
            for item in items {
                XCTAssertFalse(
                    AgentTimelineItemPresentation.toolCommandPreview(for: item)?.isEmpty ?? true,
                    "preview must still surface the bash command"
                )
            }
        }
        let parses = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting - before
        XCTAssertEqual(
            parses,
            toolCount,
            "after: preview path must parse unique tools once (got \(parses); before this cache wire it was ≥ \(toolCount * deltas))"
        )
    }

    func test_toolCommandPreview_warmCacheDoesNotJSONParseAgain() {
        // WHY: wall-clock of 4 KiB JSON vs NSCache can be microseconds either
        // way. The live-turn contract is parse count: 20 tools × 200 paints
        // must not increment the compute seam after the first fill.
        let toolCount = 20
        let deltas = 200
        let samples = 5
        let payload = String(repeating: "n", count: 4_096)
        let items = (0..<toolCount).map { index in
            bashItem(id: "bench-\(index)", command: "echo \(index) \(payload)")
        }

        func jsonParse(_ item: AssistantItem) {
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = body.data(using: .utf8) else { return }
            _ = try? JSONSerialization.jsonObject(with: data)
        }

        for item in items {
            _ = AgentTimelineItemPresentation.toolCommandPreview(for: item)
        }
        let afterWarm = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting

        func timeLoop(_ body: () -> Void) -> Double {
            let start = CFAbsoluteTimeGetCurrent()
            body()
            return (CFAbsoluteTimeGetCurrent() - start) * 1_000
        }

        var jsonSamples: [Double] = []
        var cacheSamples: [Double] = []
        jsonSamples.reserveCapacity(samples)
        cacheSamples.reserveCapacity(samples)
        for _ in 0..<samples {
            jsonSamples.append(timeLoop {
                for _ in 0..<deltas {
                    for item in items { jsonParse(item) }
                }
            })
            cacheSamples.append(timeLoop {
                for _ in 0..<deltas {
                    for item in items {
                        _ = AgentTimelineItemPresentation.toolCommandPreview(for: item)
                    }
                }
            })
        }
        let extraParses = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting - afterWarm
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        NSLog(
            "[perf-proof] toolCommandPreview json_ms=%@ cache_ms=%@ json_median=%.3f cache_median=%.3f extra_parses=%d tools=%d deltas=%d samples=%d",
            String(describing: jsonSamples),
            String(describing: cacheSamples),
            median(jsonSamples),
            median(cacheSamples),
            extraParses,
            toolCount,
            deltas,
            samples
        )
        XCTAssertEqual(
            extraParses,
            0,
            "warm toolCommandPreview must not JSON-parse again (got \(extraParses); before this wire each paint parsed)"
        )
    }

    func test_toolInputObject_whitespaceVariantsReuseTrimmedBodyCache() throws {
        // WHY: tool bodies can include transport whitespace; trimming must keep
        // parsed output unchanged and avoid duplicate cache entries.
        let command = "echo cache-\(UUID().uuidString)"
        let body = #"{"command":"\#(command)"}"#
        let before = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting

        let padded = try XCTUnwrap(AgentTimelineItemPresentation.toolInputObject(forBody: " \n\(body)\t"))
        let canonical = try XCTUnwrap(AgentTimelineItemPresentation.toolInputObject(forBody: body))

        XCTAssertEqual(padded["command"] as? String, command)
        XCTAssertEqual(canonical["command"] as? String, command)
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting - before,
            1,
            "whitespace-only transport differences should reuse the same parsed body"
        )
    }

    // MARK: - Win 3: ElapsedTickSchedule lowFrequency

    func test_elapsedTickSchedule_lowFrequencyFirstStepIs5s() {
        // WHY: occluded Agent App tool clocks used a forced 1s cadence for
        // the first minute. SwiftUI lowFrequency must pin 5s like Desk.
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = ElapsedTickSchedule(start: start)
        let early = start.addingTimeInterval(10)

        var regular = schedule.entries(from: early, mode: .normal)
        XCTAssertEqual(regular.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(
            regular.next()?.timeIntervalSince(early),
            1,
            "a visible Agent App clock inside the first minute ticks every second"
        )

        var lowFrequency = schedule.entries(from: early, mode: .lowFrequency)
        XCTAssertEqual(lowFrequency.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(
            lowFrequency.next()?.timeIntervalSince(early),
            5,
            "an occluded/minimized Agent App clock must not tick every second"
        )
    }

    func test_elapsedTickSchedule_lowFrequencyEmitsAbout12TicksInFirstMinute() {
        let start = Date(timeIntervalSince1970: 2_000)
        func collect(_ mode: TimelineScheduleMode) -> [TimeInterval] {
            var iterator = ElapsedTickSchedule(start: start).entries(from: start, mode: mode)
            var elapsed: [TimeInterval] = []
            while let date = iterator.next() {
                let offset = date.timeIntervalSince(start)
                if offset >= 60 { break }
                elapsed.append(offset)
                if elapsed.count > 80 { break }
            }
            return elapsed
        }

        let normal = collect(.normal)
        let lowFrequency = collect(.lowFrequency)
        XCTAssertEqual(normal.count, 60, "visible clocks tick once a second for 60s")
        XCTAssertEqual(lowFrequency.count, 12, "occluded clocks tick every 5s → 12 wakes / minute")
        XCTAssertEqual(lowFrequency.first, 0)
        XCTAssertEqual(lowFrequency.dropFirst().first, 5)
    }

    // MARK: - Win 2: Equatable live rows

    func test_liveRowEquality_completedToolStaysEqualWhileAssistantGrows() {
        // WHY: a last-item token used to rebuild every completed tool row.
        // Render-relevant identity must keep completed tools equal across 200 prefixes.
        let tool = bashItem(id: "bash-1", command: "swift test")
        var prefixes: [AssistantItem] = []
        var body = ""
        for index in 0..<200 {
            body += "tok\(index) "
            prefixes.append(
                AssistantItem(
                    id: "ans",
                    turnId: "t-memperf",
                    type: .assistantMessage,
                    state: .streaming,
                    body: body,
                    startedAtMs: 10
                )
            )
        }

        XCTAssertTrue(AgentChatLiveTurnChrome.liveRowItemInputsMatch(tool, tool))
        let collapsed = AgentChatLiveToolRow(item: tool, expandedIDs: .constant([]))
        let collapsedAgain = AgentChatLiveToolRow(item: tool, expandedIDs: .constant([]))
        XCTAssertEqual(collapsed, collapsedAgain)

        var unequalAssistantPairs = 0
        for index in 1..<prefixes.count {
            if !AgentChatLiveTurnChrome.liveRowItemInputsMatch(prefixes[index - 1], prefixes[index]) {
                unequalAssistantPairs += 1
            }
        }
        XCTAssertEqual(
            unequalAssistantPairs,
            prefixes.count - 1,
            "streaming assistant prefixes must invalidate only the growing row"
        )

        let expanded = AgentChatLiveToolRow(item: tool, expandedIDs: .constant([tool.id]))
        XCTAssertNotEqual(collapsed, expanded, "expanding this row must still refresh its body")
    }

    func test_liveReasoningAndItemRow_equalityUsesIdStateAndUtf8Counts() {
        let reasoning = AssistantItem(
            id: "r1",
            turnId: "t-memperf",
            type: .reasoning,
            state: .completed,
            summary: "Thought",
            body: "because the test was red",
            startedAtMs: 1,
            finishedAtMs: 2
        )
        let rowA = AgentChatReasoningRow(item: reasoning, expandedIDs: .constant([]))
        let rowB = AgentChatReasoningRow(item: reasoning, expandedIDs: .constant([]))
        XCTAssertEqual(rowA, rowB)

        let grown = AssistantItem(
            id: "r1",
            turnId: "t-memperf",
            type: .reasoning,
            state: .streaming,
            body: reasoning.body + "!",
            startedAtMs: 1
        )
        XCTAssertFalse(AgentChatLiveTurnChrome.liveRowItemInputsMatch(reasoning, grown))

        let itemA = AgentChatLiveItemRow(
            item: reasoning,
            expandedReasoning: .constant([]),
            expandedTools: .constant([])
        )
        let itemB = AgentChatLiveItemRow(
            item: reasoning,
            expandedReasoning: .constant([]),
            expandedTools: .constant([])
        )
        XCTAssertEqual(itemA, itemB)
        let itemExpanded = AgentChatLiveItemRow(
            item: reasoning,
            expandedReasoning: .constant([reasoning.id]),
            expandedTools: .constant([])
        )
        XCTAssertNotEqual(itemA, itemExpanded)
    }

    func test_liveRowEquality_progressChangeInvalidatesEvenWhenTextLengthMatches() {
        // WHY: itemProgress updates the displayed percent while body/output
        // utf8 counts stay put. Equatable must include progress.
        func tool(progress: Double?) -> AssistantItem {
            var item = bashItem(id: "bash-progress", command: "swift test")
            item.progress = progress
            return item
        }
        XCTAssertTrue(
            AgentChatLiveTurnChrome.liveRowItemInputsMatch(tool(progress: 0.2), tool(progress: 0.2))
        )
        XCTAssertFalse(
            AgentChatLiveTurnChrome.liveRowItemInputsMatch(tool(progress: 0.2), tool(progress: 0.8)),
            "20% → 80% must refresh the live row"
        )
        let rowA = AgentChatLiveToolRow(item: tool(progress: 0.2), expandedIDs: .constant([]))
        let rowB = AgentChatLiveToolRow(item: tool(progress: 0.8), expandedIDs: .constant([]))
        XCTAssertNotEqual(rowA, rowB)
    }

    func test_liveRowEquality_equalLengthTextReplacementInvalidates() {
        // WHY: comparing only utf8 counts froze equal-length replacements
        // (e.g. "hello world" → "HELLO WORLD").
        let a = AssistantItem(
            id: "ans",
            turnId: "t-memperf",
            type: .assistantMessage,
            state: .streaming,
            body: "hello world",
            startedAtMs: 1
        )
        let b = AssistantItem(
            id: "ans",
            turnId: "t-memperf",
            type: .assistantMessage,
            state: .streaming,
            body: "HELLO WORLD",
            startedAtMs: 1
        )
        XCTAssertEqual(a.body.utf8.count, b.body.utf8.count)
        XCTAssertFalse(
            AgentChatLiveTurnChrome.liveRowItemInputsMatch(a, b),
            "equal-length body replacement must still refresh"
        )
        XCTAssertNotEqual(
            AgentChatLiveTurnChrome.liveTextFingerprint(a.body),
            AgentChatLiveTurnChrome.liveTextFingerprint(b.body)
        )

        var withPath = bashItem(id: "file-1", command: "cat x")
        withPath.resourcePath = "/tmp/a"
        var otherPath = withPath
        otherPath.resourcePath = "/tmp/b"
        XCTAssertFalse(
            AgentChatLiveTurnChrome.liveRowItemInputsMatch(withPath, otherPath),
            "resourcePath is render-relevant and must invalidate the row"
        )
    }

    // MARK: - Win 4: File Preview thumbnail cap

    func test_filePreviewThumbnail_capsDecodedPixelsAt2048() throws {
        // WHY: 4096² RGBA is ~64 MiB per Files/preview image. Cap at 2048² (~16 MiB).
        XCTAssertEqual(FilePreviewSurface.thumbnailMaxPixelSize, 2048)
        let url = try Self.writeSolidPNG(width: 3000, height: 2200)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try XCTUnwrap(
            FilePreviewSurface.decodeDownsampled(url: url),
            "ImageIO thumbnail must succeed for a PNG fixture"
        )
        guard let cg = decoded.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            XCTFail("decoded NSImage must vend a CGImage")
            return
        }
        XCTAssertLessThanOrEqual(cg.width, 2048)
        XCTAssertLessThanOrEqual(cg.height, 2048)
        let pixelBytes = cg.bytesPerRow * cg.height
        XCTAssertLessThanOrEqual(
            pixelBytes,
            2048 * 2048 * 4,
            "decoded pixels must fit in 2048² RGBA (got \(pixelBytes) bytes, \(cg.width)×\(cg.height))"
        )
        NSLog(
            "[perf-proof] filePreview thumb source=3000x2200 decoded=%dx%d bytes=%d cap=2048 before_budget=%d after_budget=%d",
            cg.width,
            cg.height,
            pixelBytes,
            4096 * 4096 * 4,
            2048 * 2048 * 4
        )
    }

    private static func writeSolidPNG(width: Int, height: Int) throws -> URL {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "AgentAppMemPerfWinsTests", code: 1)
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw NSError(domain: "AgentAppMemPerfWinsTests", code: 2)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-memperf-thumb-\(UUID().uuidString).png")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw NSError(domain: "AgentAppMemPerfWinsTests", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "AgentAppMemPerfWinsTests", code: 4)
        }
        return url
    }

    // MARK: - Rank 1: toolInputCache lookup latency

    func test_toolInputCache_usesBodyKeyToAvoidPreviewLatencyRegression() throws {
        // WHY: identical base/head workloads measured a 22.8% warm-preview
        // latency regression with fingerprint generation on every cache lookup.
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let chunk = try functionChunk(
            source,
            start: "static func toolInputObject(for item: AssistantItem)",
            endMarker: "static func intMillis(from value: Any?)"
        )
        XCTAssertTrue(
            chunk.contains("let key = body as NSString"),
            "toolInputCache must avoid re-hashing the full JSON body on each warm preview"
        )
        XCTAssertFalse(
            chunk.contains("AgentMessageMarkdown.cacheKey(for: body)"),
            "fingerprint generation on each preview lookup exceeded the settled-latency guardrail"
        )
    }

    func test_toolInputCache_sameLengthBodiesStillMissIndependently() {
        // WHY: distinct equal-length JSON bodies must never share a parsed
        // object cache entry, regardless of the cache key representation.
        let a = #"{"command":"echo A \#(String(repeating: "a", count: 200))"}"#
        let b = #"{"command":"echo B \#(String(repeating: "b", count: 200))"}"#
        XCTAssertEqual(a.utf8.count, b.utf8.count)
        XCTAssertNotEqual(
            AgentMessageMarkdown.cacheKey(for: a),
            AgentMessageMarkdown.cacheKey(for: b),
            "equal-length bodies must still miss — hash is part of the key"
        )
        let itemA = bashItem(id: "a", command: "echo A \(String(repeating: "a", count: 200))")
        let itemB = bashItem(id: "b", command: "echo B \(String(repeating: "b", count: 200))")
        let before = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting
        XCTAssertNotNil(AgentTimelineItemPresentation.toolInputObject(for: itemA))
        XCTAssertNotNil(AgentTimelineItemPresentation.toolInputObject(for: itemB))
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting - before,
            2,
            "two distinct bodies must parse twice even when utf8 counts match"
        )
    }

    // MARK: - Rank 2: assistant normalize/compact keys are fingerprints

    func test_assistantTextCaches_keysByFingerprintNotFullBody() throws {
        // WHY: hide-set rebuilds normalize AND compact every assistant body.
        // Two caches keyed by `text as NSString` duplicated up to 2×128 KiB
        // of source bodies on top of the transformed values. Fingerprint keys
        // drop that to ~10 KiB while warm hits still skip unicode walks.
        let body = String(repeating: "word ", count: 800)
        XCTAssertEqual(body.utf8.count, 4_000)
        let key = AgentMessageMarkdown.cacheKey(for: body)
        XCTAssertLessThan((key as String).utf8.count, 80)
        let twoCachesBefore = 2 * 128 * 1_024
        let twoCachesAfter = 2 * 128 * (key as String).utf8.count
        XCTAssertEqual(twoCachesBefore, 262_144)
        XCTAssertLessThan(twoCachesAfter, 20_480)

        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let normalized = try functionChunk(
            source,
            start: "private static func normalizedAssistantText(_ text: String)",
            endMarker: "private static func makeNormalizedAssistantText"
        )
        let compact = try functionChunk(
            source,
            start: "private static func compactAssistantText(_ text: String)",
            endMarker: "private static func makeCompactAssistantText"
        )
        XCTAssertTrue(normalized.contains("AgentMessageMarkdown.cacheKey(for: text)"))
        XCTAssertTrue(compact.contains("AgentMessageMarkdown.cacheKey(for: text)"))
        XCTAssertFalse(normalized.contains("let key = text as NSString"))
        XCTAssertFalse(compact.contains("let key = text as NSString"))
    }

    func test_assistantTextCaches_warmHitSkipsUnicodeWalkAndDistinctBodiesMiss() {
        // WHY: fingerprint keys must still hit for the same body (compute
        // stays 1) and miss for a same-length different body (compute += 1).
        let wordA = "a\(UUID().uuidString.prefix(8))"
        let wordB = "b\(UUID().uuidString.prefix(8))"
        let a = String(repeating: "\(wordA) ", count: 40)
        let b = String(repeating: "\(wordB) ", count: 40)
        XCTAssertEqual(a.utf8.count, b.utf8.count)
        XCTAssertNotEqual(AgentMessageMarkdown.cacheKey(for: a), AgentMessageMarkdown.cacheKey(for: b))

        let beforeNorm = AgentAppView.normalizedTextCacheComputeCountForTesting
        let beforeCompact = AgentAppView.compactTextCacheComputeCountForTesting
        XCTAssertEqual(
            AgentAppView.normalizedAssistantTextForTesting(a),
            String(repeating: "\(wordA) ", count: 39) + wordA
        )
        XCTAssertEqual(
            AgentAppView.compactAssistantTextForTesting(a),
            String(repeating: wordA, count: 40)
        )
        XCTAssertEqual(AgentAppView.normalizedTextCacheComputeCountForTesting - beforeNorm, 1)
        XCTAssertEqual(AgentAppView.compactTextCacheComputeCountForTesting - beforeCompact, 1)

        for _ in 0..<20 {
            _ = AgentAppView.normalizedAssistantTextForTesting(a)
            _ = AgentAppView.compactAssistantTextForTesting(a)
        }
        XCTAssertEqual(
            AgentAppView.normalizedTextCacheComputeCountForTesting - beforeNorm,
            1,
            "warm fingerprint hit must not re-walk unicode scalars"
        )
        XCTAssertEqual(AgentAppView.compactTextCacheComputeCountForTesting - beforeCompact, 1)

        _ = AgentAppView.normalizedAssistantTextForTesting(b)
        _ = AgentAppView.compactAssistantTextForTesting(b)
        XCTAssertEqual(
            AgentAppView.normalizedTextCacheComputeCountForTesting - beforeNorm,
            2,
            "a different same-length body must miss the fingerprint key"
        )
        XCTAssertEqual(AgentAppView.compactTextCacheComputeCountForTesting - beforeCompact, 2)
    }

    // MARK: - Rank 3: snapshot mentionableBots per contentGeneration

    @MainActor
    func test_mentionableBotsSnapshot_columnAndHeaderShareGenerationCache() throws {
        // WHY: TranscriptReactiveScope used to call mentionableBotsProvider on
        // every timeline @Published assign (including tool-body-only ticks).
        // The header SubagentActivityBadge did the same on every VM chrome
        // publish. One snapshot per contentGeneration must serve both; composer
        // @ stays live on the provider.
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }
        var providerCalls = 0
        var botsRevision: UInt64 = 0
        var bots = [
            BotDefinition(handle: "ceo", name: "Ceo", title: "CEO", description: "", avatarSymbol: "star.fill")
        ]
        vm.mentionableBotsProvider = {
            providerCalls += 1
            return bots
        }
        vm.mentionableBotsRevisionProvider = { botsRevision }
        let view = AgentAppView(vm: vm)
        let before = AgentAppView.mentionableBotsSnapshotProviderCallCountForTesting

        XCTAssertEqual(view.snapshotMentionableBotsForTesting().map(\.handle), ["ceo"])
        for _ in 0..<10 {
            XCTAssertEqual(view.snapshotMentionableBotsForTesting().count, 1)
        }
        XCTAssertEqual(providerCalls, 1, "generation-stable header+column re-entry must not recopy listCached")
        XCTAssertEqual(AgentAppView.mentionableBotsSnapshotProviderCallCountForTesting - before, 1)

        let now = Date(timeIntervalSince1970: 1)
        vm.applySubagentActivity(
            SubagentActivitySnapshot(
                active: [
                    SubagentActivityItem(
                        id: UUID(),
                        runId: nil,
                        threadId: AgentThreadID(),
                        nodeId: "n1",
                        displayName: "worker",
                        provider: .codex,
                        model: nil,
                        phase: .working,
                        lifecycleStatus: .accepted,
                        finalRunStatus: nil,
                        admittedAt: now,
                        finalizedAt: nil,
                        lifecycleUpdatedAt: now,
                        isActive: true
                    )
                ],
                done: []
            )
        )
        XCTAssertEqual(
            view.snapshotMentionableBotsForTesting().count,
            1
        )
        XCTAssertEqual(
            providerCalls,
            1,
            "applySubagentActivity (header chrome publish) must reuse the generation snapshot"
        )

        bots = [
            BotDefinition(handle: "ceo", name: "Chief Executive", title: "CEO", description: "", avatarSymbol: "person.fill")
        ]
        botsRevision &+= 1
        XCTAssertEqual(view.snapshotMentionableBotsForTesting().map(\.name), ["Chief Executive"])
        XCTAssertEqual(providerCalls, 2, "bot catalog revision must refresh without a transcript change")

        vm.messages = [
            AgentMessage(threadId: AgentThreadID(), role: .user, content: "bump generation")
        ]
        XCTAssertEqual(view.snapshotMentionableBotsForTesting().count, 1)
        XCTAssertEqual(providerCalls, 3, "contentGeneration bump must refresh the catalog snapshot")

        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let header = try functionChunk(source, start: "private var header: some View {", endMarker: "private var fullAccessBanner")
        XCTAssertTrue(header.contains("snapshotMentionableBots()"))
        XCTAssertFalse(
            header.contains("mentionableBotsProvider()"),
            "header badge must not live-call the provider on VM chrome publishes"
        )
        let column = try functionChunk(
            source,
            start: "let flow = cachedChatFlowPaint(",
            endMarker: "VStack(alignment: .leading, spacing: 32)"
        )
        XCTAssertTrue(column.contains("snapshotMentionableBots()"))
        XCTAssertFalse(column.contains("mentionableBotsProvider()"))
        XCTAssertTrue(
            source.contains("mentionableBots = mentionableBotsProvider()"),
            "composer @ must stay live on the provider"
        )
    }

    // MARK: - Rank 4: skip signature builder on generation-stable counts

    @MainActor
    func test_cachedChatRowPaintContext_skipsSignatureBuilderOnGenerationStableCounts() throws {
        // WHY: even after bots are snapshotted, F2 still allocated a growing
        // signature string (every bot handle|name|symbol) on every column body.
        // Tool-body-only ticks already know generation + row/visible counts;
        // building that string is wasted alloc+hash (~2 KiB for 50 bots).
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }
        var botsRevision: UInt64 = 0
        vm.mentionableBotsRevisionProvider = { botsRevision }
        let view = AgentAppView(vm: vm)
        let turn = AssistantTurnSnapshot(turnId: "t-stable", finalAssistantMessage: "ok", finished: true)
        let entries: [AgentAppView.TranscriptEntry] = [.turn(turn)]
        let rows = entries.map(AgentAppView.ChatFlowRow.entry)
        let bots = (0..<50).map { index in
            BotDefinition(
                handle: "bot\(index)",
                name: "Bot \(index)",
                title: "",
                description: "",
                avatarSymbol: "person.fill"
            )
        }

        let beforeCompute = AgentAppView.chatRowPaintContextComputeCountForTesting
        let beforeSignature = AgentAppView.chatRowPaintContextSignatureBuilderCountForTesting
        _ = view.cachedChatRowPaintContextForTesting(rows: rows, visibleEntries: entries, bots: bots)
        XCTAssertEqual(AgentAppView.chatRowPaintContextComputeCountForTesting - beforeCompute, 1)
        XCTAssertEqual(AgentAppView.chatRowPaintContextSignatureBuilderCountForTesting - beforeSignature, 1)

        for _ in 0..<200 {
            _ = view.cachedChatRowPaintContextForTesting(rows: rows, visibleEntries: entries, bots: bots)
        }
        XCTAssertEqual(
            AgentAppView.chatRowPaintContextComputeCountForTesting - beforeCompute,
            1,
            "generation-stable re-entry must not rebuild paint context"
        )
        XCTAssertEqual(
            AgentAppView.chatRowPaintContextSignatureBuilderCountForTesting - beforeSignature,
            1,
            "matching generation+row/visible counts must return before chatRowPaintContextSignature"
        )

        botsRevision &+= 1
        _ = view.cachedChatRowPaintContextForTesting(rows: rows, visibleEntries: entries, bots: bots)
        XCTAssertEqual(
            AgentAppView.chatRowPaintContextComputeCountForTesting - beforeCompute,
            2,
            "bot catalog revisions must invalidate peer context without transcript changes"
        )
        XCTAssertEqual(AgentAppView.chatRowPaintContextSignatureBuilderCountForTesting - beforeSignature, 2)

        vm.messages = [
            AgentMessage(threadId: AgentThreadID(), role: .assistant, content: "generation moves")
        ]
        _ = view.cachedChatRowPaintContextForTesting(rows: rows, visibleEntries: entries, bots: bots)
        XCTAssertEqual(AgentAppView.chatRowPaintContextComputeCountForTesting - beforeCompute, 3)
        XCTAssertEqual(AgentAppView.chatRowPaintContextSignatureBuilderCountForTesting - beforeSignature, 3)

        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let chunk = try functionChunk(
            source,
            start: "private func cachedChatRowPaintContext(",
            endMarker: "private func snapshotMentionableBots()"
        )
        let countsIdx = try XCTUnwrap(chunk.range(of: "chatRowPaintContextCache.rowCount == rows.count"))
        let signatureIdx = try XCTUnwrap(chunk.range(of: "Self.chatRowPaintContextSignature("))
        XCTAssertTrue(
            countsIdx.lowerBound < signatureIdx.lowerBound,
            "generation+counts hit must precede the signature builder"
        )
    }

    // MARK: - Rank 5 unique: normalizedFinalsMemo cost + fingerprint key

    func test_normalizedFinalsMemo_costLimitAndFingerprintKey() throws {
        // WHY: finished-turn hide-set walks used an unbounded-cost NSCache
        // keyed only by final utf8 length. Equal-length final swaps missed,
        // and occupancy had no byte ceiling.
        XCTAssertEqual(AgentChatLiveTurnChrome.normalizedFinalsMemoCountLimit, 128)
        XCTAssertEqual(AgentChatLiveTurnChrome.normalizedFinalsMemoCostLimit, 128 * 1024)
        let source = try repoSource("Sources/Surfaces/AgentChatLiveTurnChrome.swift")
        let chunk = try functionChunk(
            source,
            start: "public static func normalizedAssistantFinals(for turn: AssistantTurnSnapshot)",
            endMarker: "public static func paintsLiveTurnChrome"
        )
        XCTAssertTrue(chunk.contains("AgentMessageMarkdown.sourceFingerprint(for:"))
        XCTAssertFalse(
            chunk.contains("finalAssistantMessage?.utf8.count"),
            "length-only keys miss equal-length finished finals"
        )
        XCTAssertTrue(source.contains("totalCostLimit = normalizedFinalsMemoCostLimit"))

        let before = 512
        let after = AgentChatLiveTurnChrome.normalizedFinalsMemoCountLimit
        XCTAssertEqual(Double(before - after) / Double(before), 0.75, accuracy: 0.001)
    }

    func test_normalizedFinalsMemo_equalLengthFinalReplacementMisses() {
        // WHY: fingerprint the finished final so "alpha" → "bravo" (same utf8
        // count) does not reuse the hide-set memo.
        func turn(final: String) -> AssistantTurnSnapshot {
            AssistantTurnSnapshot(
                turnId: "t-final",
                items: [
                    AssistantItem(
                        id: "a1",
                        turnId: "t-final",
                        type: .assistantMessage,
                        state: .completed,
                        body: final,
                        startedAtMs: 1,
                        finishedAtMs: 2
                    )
                ],
                finalAssistantMessage: final,
                finished: true
            )
        }
        let a = turn(final: "alpha")
        let b = turn(final: "bravo")
        XCTAssertEqual(a.finalAssistantMessage?.utf8.count, b.finalAssistantMessage?.utf8.count)
        let before = AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting
        XCTAssertFalse(AgentChatLiveTurnChrome.normalizedAssistantFinals(for: a).isEmpty)
        XCTAssertFalse(AgentChatLiveTurnChrome.normalizedAssistantFinals(for: b).isEmpty)
        XCTAssertGreaterThanOrEqual(
            AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting - before,
            2,
            "equal-length finals must miss independently"
        )
        _ = AgentChatLiveTurnChrome.normalizedAssistantFinals(for: a)
        let afterWarm = AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting
        _ = AgentChatLiveTurnChrome.normalizedAssistantFinals(for: a)
        XCTAssertEqual(
            AgentChatLiveTurnChrome.normalizedFinalsComputeCountForTesting,
            afterWarm,
            "warm fingerprint hit must not re-normalize"
        )
    }

    // MARK: - Rank 6 unique: Edit/diff JSON reuses toolInputCache

    func test_editDiffJSON_reusesToolInputCache() throws {
        // WHY: live tool rows already JSON-decode item.body. Edit/diff
        // extraction used to JSONSerialization-parse the same object again.
        let source = try repoSource("Sources/Surfaces/AgentChatUXPresentation.swift")
        let jsonChunk = try functionChunk(
            source,
            start: "private static func jsonObject(_ body: String)",
            endMarker: "// MARK: - Thread rail row copy"
        )
        XCTAssertTrue(jsonChunk.contains("toolInputObject(forBody:"))
        XCTAssertFalse(jsonChunk.contains("JSONSerialization.jsonObject"))

        let body = #"{"file_path":"/tmp/x.swift","old_string":"a","new_string":"b"}"#
        let item = AssistantItem(
            id: "edit-1",
            turnId: "t-edit",
            type: .tool,
            state: .completed,
            summary: "Edit",
            body: body,
            startedAtMs: 1,
            finishedAtMs: 2
        )
        let before = AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting
        XCTAssertNotNil(AgentTimelineItemPresentation.toolInputObject(for: item))
        XCTAssertEqual(AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting - before, 1)
        XCTAssertNotNil(AgentFileEditDiffPresentation.synthesizeDiffFromEditJSON(body))
        XCTAssertEqual(
            AgentTimelineItemPresentation.toolInputObjectComputeCountForTesting - before,
            1,
            "Edit JSON must hit the warmed toolInputCache (no second parse)"
        )
    }

    // MARK: - Unique vs 404: skip split + live weave on chrome-only ticks

    @MainActor
    func test_cachedChatFlowPaint_skipsRebuildOnChromeOnlyTicks() throws {
        // WHY: chrome-only / paint-tick bodies split and wove ChatFlowRow on
        // every column pass. History identity (generation + history first/last
        // ids + count) is stable on those ticks — rebuilding the finished
        // weave is wasted. The live suffix still weaves every pass so progress
        // and same-length tool text cannot go stale.
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }
        let view = AgentAppView(vm: vm)
        let history = AssistantTurnSnapshot(
            turnId: "t-hist",
            finalAssistantMessage: "done",
            finished: true
        )
        let live = AssistantTurnSnapshot(turnId: "t-live", finished: false)
        let paint: [AgentAppView.TranscriptEntry] = [.turn(history), .turn(live)]
        let extra = AgentMessage(threadId: AgentThreadID(), role: .user, content: "tail")

        let before = AgentAppView.chatFlowPaintComputeCountForTesting
        let beforeLive = AgentAppView.chatFlowPaintLiveComputeCountForTesting
        let beforeSplit = AgentAppView.chatFlowPaintSplitCountForTesting
        let first = view.cachedChatFlowPaintForTesting(
            paintSequence: paint,
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(first.historyRows.count, 1)
        XCTAssertEqual(first.liveRows.count, 1)
        XCTAssertEqual(AgentAppView.chatFlowPaintComputeCountForTesting - before, 1)
        XCTAssertEqual(AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive, 1)

        for _ in 0..<200 {
            let again = view.cachedChatFlowPaintForTesting(
                paintSequence: paint,
                latestLiveTurnId: "t-live"
            )
            XCTAssertEqual(again.allRows.map(\.id), first.allRows.map(\.id))
        }
        XCTAssertEqual(
            AgentAppView.chatFlowPaintComputeCountForTesting - before,
            1,
            "chrome-only ticks with a live turn must skip the history weave"
        )
        XCTAssertEqual(
            AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive,
            201,
            "live tail must reweave on every paint so progress and text stay fresh"
        )
        XCTAssertEqual(
            AgentAppView.chatFlowPaintSplitCountForTesting - beforeSplit,
            1,
            "chrome-only ticks with stable paint ends must skip splitTrailingLiveTurns"
        )

        let longer = paint + [.message(extra)]
        let afterTail = view.cachedChatFlowPaintForTesting(
            paintSequence: longer,
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            AgentAppView.chatFlowPaintComputeCountForTesting - before,
            1,
            "appending onto the live suffix must not rebuild history"
        )
        XCTAssertEqual(afterTail.liveRows.count, 2)

        let older = AssistantTurnSnapshot(
            turnId: "t-older",
            finalAssistantMessage: "earlier",
            finished: true
        )
        _ = view.cachedChatFlowPaintForTesting(
            paintSequence: [.turn(older)] + paint,
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            AgentAppView.chatFlowPaintComputeCountForTesting - before,
            2,
            "history first/last/count change must miss"
        )

        vm.messages = [extra]
        _ = view.cachedChatFlowPaintForTesting(
            paintSequence: [.turn(older)] + paint,
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            AgentAppView.chatFlowPaintComputeCountForTesting - before,
            3,
            "contentGeneration bump must miss even when paint ids match"
        )

        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let helper = try functionChunk(
            source,
            start: "private func cachedChatFlowPaint(",
            endMarker: "func cachedChatRowPaintContextForTesting"
        )
        XCTAssertTrue(helper.contains("Self.splitTrailingLiveTurns("))
        XCTAssertFalse(helper.contains("liveTailGrowthSignature"))
        XCTAssertFalse(
            helper.contains("chatFlowPaintCache.liveRows"),
            "live ChatFlowRows must not be memoized"
        )
        let countsIdx = try XCTUnwrap(helper.range(of: "chatFlowPaintCache.count == count"))
        let rowsIdx = try XCTUnwrap(helper.range(of: "Self.chatFlowRows("))
        XCTAssertTrue(
            countsIdx.lowerBound < rowsIdx.lowerBound,
            "generation+first/last/count hit must precede history chatFlowRows"
        )
        let column = try functionChunk(
            source,
            start: "let flow = cachedChatFlowPaint(",
            endMarker: "VStack(alignment: .leading, spacing: 32)"
        )
        XCTAssertTrue(column.contains("flow.historyRows"))
        XCTAssertFalse(column.contains("Self.chatFlowRows("))
    }

    @MainActor
    func test_cachedChatFlowPaint_liveToolBodyGrowthMissesLiveTail() throws {
        // WHY: commitStreamQuantum grows tool output / appends tools without
        // bumping contentGeneration. Caching ChatFlowRow snapshots for the
        // live suffix freezes that paint. History weave must still hit.
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }
        let view = AgentAppView(vm: vm)
        let history = AssistantTurnSnapshot(
            turnId: "t-hist",
            finalAssistantMessage: "done",
            finished: true
        )
        var live = AssistantTurnSnapshot(
            turnId: "t-live",
            items: [
                AssistantItem(
                    id: "tool-1",
                    turnId: "t-live",
                    type: .tool,
                    body: "ls",
                    output: "a",
                    startedAtMs: 2
                )
            ],
            finished: false
        )
        let paint: [AgentAppView.TranscriptEntry] = [.turn(history), .turn(live)]
        let before = AgentAppView.chatFlowPaintComputeCountForTesting
        let beforeLive = AgentAppView.chatFlowPaintLiveComputeCountForTesting
        let first = view.cachedChatFlowPaintForTesting(
            paintSequence: paint,
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(Self.chatFlowToolPayloads(first.liveRows), ["tool-1:ls:a"])
        XCTAssertEqual(AgentAppView.chatFlowPaintComputeCountForTesting - before, 1)
        XCTAssertEqual(AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive, 1)

        live.items[0].output = String(repeating: "x", count: 8_192)
        let grown = view.cachedChatFlowPaintForTesting(
            paintSequence: [.turn(history), .turn(live)],
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            Self.chatFlowToolPayloads(grown.liveRows),
            ["tool-1:ls:" + String(repeating: "x", count: 8_192)],
            "live tool-body growth must miss the live-tail cache"
        )
        XCTAssertEqual(
            AgentAppView.chatFlowPaintComputeCountForTesting - before,
            1,
            "tool-body growth must not rebuild finished history"
        )
        XCTAssertEqual(AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive, 2)

        live.items.append(
            AssistantItem(id: "tool-2", turnId: "t-live", type: .tool, body: "pwd", startedAtMs: 3)
        )
        let extraTool = view.cachedChatFlowPaintForTesting(
            paintSequence: [.turn(history), .turn(live)],
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            Self.chatFlowToolPayloads(extraTool.liveRows),
            [
                "tool-1:ls:" + String(repeating: "x", count: 8_192),
                "tool-2:pwd:"
            ],
            "an extra live tool must paint without a generation bump"
        )
        XCTAssertEqual(AgentAppView.chatFlowPaintComputeCountForTesting - before, 1)
        XCTAssertEqual(AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive, 3)

        live.items[0].output = "b"
        let replaced = view.cachedChatFlowPaintForTesting(
            paintSequence: [.turn(history), .turn(live)],
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            Self.chatFlowToolPayloads(replaced.liveRows).first,
            "tool-1:ls:b",
            "same-length tool output replacement must miss the live-tail cache"
        )
        XCTAssertEqual(AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive, 4)

        live.items[0].progress = 0.4
        let progressed = view.cachedChatFlowPaintForTesting(
            paintSequence: [.turn(history), .turn(live)],
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            Self.firstLiveTool(progressed.liveRows)?.progress,
            0.4,
            "progress-only updates must miss the live-tail cache"
        )
        XCTAssertEqual(AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive, 5)

        live.items[0].summary = "compile"
        let summarized = view.cachedChatFlowPaintForTesting(
            paintSequence: [.turn(history), .turn(live)],
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(
            Self.firstLiveTool(summarized.liveRows)?.summary,
            "compile",
            "summary-only updates must miss the live-tail cache"
        )
        XCTAssertEqual(AgentAppView.chatFlowPaintLiveComputeCountForTesting - beforeLive, 6)
    }

    func test_workingStripScan_warmedTrailingWalkBeatsFullTimeline() {
        // WHY: header chrome scanned every finished turn. The replacement must
        // be faster on the same 800-turn workload, five warmed samples, and
        // inside max(25ms, 5%). A full-text live-row hash failed that bar, so
        // live rows stay uncached.
        let item = AssistantItem(
            id: "old-tool",
            turnId: "t",
            type: .tool,
            state: .completed,
            body: "echo",
            startedAtMs: 1
        )
        let finished = (0..<800).map { index in
            AssistantTurnSnapshot(
                turnId: "t-\(index)",
                items: Array(repeating: item, count: 25),
                finished: true
            )
        }
        let turns = finished + [AssistantTurnSnapshot(turnId: "t-live", finished: false)]
        func fullScan() -> Bool {
            var found = false
            for _ in 0..<40 {
                found = turns.contains { turn in
                    !turn.finished && turn.items.contains {
                        $0.state == .streaming && AgentAppView.isGroupableTool($0.type)
                    }
                }
            }
            return found
        }
        func trailingScan() -> Bool {
            var found = false
            for _ in 0..<40 {
                found = AgentAppView.hasStreamingGroupableTools(in: turns)
            }
            return found
        }
        for _ in 0..<3 {
            _ = fullScan()
            _ = trailingScan()
        }
        var beforeMs: [Double] = []
        var afterMs: [Double] = []
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertFalse(fullScan())
            beforeMs.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        for _ in 0..<5 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertFalse(trailingScan())
            afterMs.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
        }
        let beforeMedian = beforeMs.sorted()[beforeMs.count / 2]
        let afterMedian = afterMs.sorted()[afterMs.count / 2]
        let allowance = max(25.0, beforeMedian * 0.05)
        print(
            "[perf-proof] working-strip before_ms=\(beforeMs) after_ms=\(afterMs) before_median=\(beforeMedian) after_median=\(afterMedian)"
        )
        XCTAssertLessThan(afterMedian, beforeMedian, "trailing scan must beat the full timeline walk")
        XCTAssertLessThanOrEqual(afterMedian, beforeMedian + allowance)
    }

    @MainActor
    func test_cachedChatFlowPaint_refreshesHistoricalPayloadAfterAggregateBudgetEviction() throws {
        // WHY: aggregate text eviction can clear a historical tool output without
        // changing transcript generation, row count, or endpoint IDs. The paint
        // cache must release and stop displaying the evicted payload immediately.
        let (vm, rootURL) = try makeVM()
        defer {
            vm.dispose()
            try? FileManager.default.removeItem(at: rootURL)
        }
        vm.aggregateHotTextByteLimitForTesting = 10_000
        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "t-history"))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "tool-history",
            turnId: "t-history",
            type: .tool,
            state: .completed,
            body: "",
            output: String(repeating: "payload", count: 1_000),
            startedAtMs: 1
        )))
        timeline.apply(.turnCompleted(turnId: "t-history", finalMessage: nil))
        timeline.apply(.turnStarted(turnId: "t-live"))
        XCTAssertGreaterThan(timeline.aggregateHotTextByteCount, 7_000)
        XCTAssertLessThan(timeline.aggregateHotTextByteCount, 10_000)

        func quantum(_ value: AssistantTimelineState) -> StreamQuantumReduceResult {
            StreamQuantumReduceResult(
                appliedEvent: true,
                timeline: value,
                currentRunId: nil,
                status: .running,
                lastErrorRecoverable: false,
                liveBackgroundShellCount: 0,
                liveBackgroundTasks: [],
                suppressStaleActivePlanUpdates: false,
                seedRunStartedAt: false,
                runThreadBindings: [:],
                hasProposedPlan: false,
                forceAggregateBudget: true,
                appliedEventCount: 1
            )
        }
        vm.commitStreamQuantum(quantum(timeline))
        let view = AgentAppView(vm: vm)
        let beforeEvictionGeneration = vm.transcriptState.contentGeneration
        let paint = { vm.timeline.turns.map { AgentAppView.TranscriptEntry.turn($0) } }
        let before = view.cachedChatFlowPaintForTesting(
            paintSequence: paint(),
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(Self.chatFlowToolPayloads(before.historyRows), [
            "tool-history::" + String(repeating: "payload", count: 1_000)
        ])

        vm.aggregateHotTextByteLimitForTesting = 1_000
        vm.commitStreamQuantum(quantum(timeline))
        XCTAssertEqual(vm.transcriptState.contentGeneration, beforeEvictionGeneration)
        XCTAssertNil(vm.timeline.turns.first?.items.first?.output)
        let after = view.cachedChatFlowPaintForTesting(
            paintSequence: paint(),
            latestLiveTurnId: "t-live"
        )
        XCTAssertEqual(Self.chatFlowToolPayloads(after.historyRows), ["tool-history::"])
    }

    // MARK: - Unique vs 393: header clock sentinel

    func test_subagentActivityBadgeNow_skipsClockWhenEmptyAndClosed() throws {
        // WHY: Auto routing always mounts Subagents chrome. An empty closed
        // badge still called vm.currentTime() on every header body, churning
        // Date identity with no elapsed UI to feed.
        var calls = 0
        let live = Date(timeIntervalSince1970: 99)
        let clock: () -> Date = {
            calls += 1
            return live
        }
        XCTAssertEqual(
            AgentAppView.subagentActivityBadgeNow(
                snapshotEmpty: true,
                popoverPresented: false,
                currentTime: clock
            ),
            AgentAppView.subagentActivityBadgeStableNow
        )
        XCTAssertEqual(calls, 0, "empty closed badge must not call currentTime")

        XCTAssertEqual(
            AgentAppView.subagentActivityBadgeNow(
                snapshotEmpty: true,
                popoverPresented: true,
                currentTime: clock
            ),
            live
        )
        XCTAssertEqual(calls, 1, "open popover still needs a live clock")

        XCTAssertEqual(
            AgentAppView.subagentActivityBadgeNow(
                snapshotEmpty: false,
                popoverPresented: false,
                currentTime: clock
            ),
            live
        )
        XCTAssertEqual(calls, 2, "non-empty snapshot still needs a live clock")

        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let header = try functionChunk(
            source,
            start: "private var header: some View {",
            endMarker: "private var fullAccessBanner"
        )
        XCTAssertTrue(header.contains("subagentActivityBadgeNow("))
        XCTAssertFalse(
            header.contains("now: vm.currentTime()"),
            "header must not unconditionally Date() the empty closed badge"
        )
        XCTAssertTrue(
            source.contains("mentionableBots = mentionableBotsProvider()"),
            "composer @ must stay live on the provider"
        )
    }

    func test_relativeTimestampNowBucket_isOneSecondIdentity() {
        // WHY: user bubbles formatted relative time against Date() in every
        // body. A 1 Hz bucket keeps Equatable rows stable across ~30 Hz ticks
        // inside the same second.
        let a = Date(timeIntervalSinceReferenceDate: 100.2)
        let b = Date(timeIntervalSinceReferenceDate: 100.9)
        let c = Date(timeIntervalSinceReferenceDate: 101.0)
        XCTAssertEqual(
            AgentAppView.relativeTimestampNowBucket(a),
            AgentAppView.relativeTimestampNowBucket(b)
        )
        XCTAssertNotEqual(
            AgentAppView.relativeTimestampNowBucket(a),
            AgentAppView.relativeTimestampNowBucket(c)
        )
        XCTAssertEqual(
            AgentChatUserBubble(
                text: "hi",
                createdAt: a,
                now: AgentAppView.relativeTimestampNowBucket(a)
            ),
            AgentChatUserBubble(
                text: "hi",
                createdAt: a,
                now: AgentAppView.relativeTimestampNowBucket(b)
            )
        )
    }

    func test_hasStreamingGroupableTools_stopsAtFirstFinishedTurnFromTheEnd() {
        // WHY: the header working strip walked every turn's items on ~30 Hz
        // chrome. Streaming tools can only exist on trailing unfinished turns.
        let finishedTool = AssistantItem(
            id: "old-tool",
            turnId: "t-old",
            type: .tool,
            state: .streaming,
            body: "echo old",
            startedAtMs: 1
        )
        let finished = AssistantTurnSnapshot(
            turnId: "t-old",
            items: [finishedTool],
            finished: true
        )
        let liveIdle = AssistantTurnSnapshot(turnId: "t-live", finished: false)
        XCTAssertFalse(
            AgentAppView.hasStreamingGroupableTools(in: [finished, liveIdle]),
            "a streaming item on a finished turn must not light the working strip"
        )
        let liveStreaming = AssistantTurnSnapshot(
            turnId: "t-live",
            items: [
                AssistantItem(
                    id: "live-tool",
                    turnId: "t-live",
                    type: .tool,
                    state: .streaming,
                    body: "echo live",
                    startedAtMs: 2
                )
            ],
            finished: false
        )
        XCTAssertTrue(
            AgentAppView.hasStreamingGroupableTools(in: [finished, liveStreaming])
        )
        let many = (0..<400).map { index in
            AssistantTurnSnapshot(
                turnId: "t-\(index)",
                items: [finishedTool],
                finished: true
            )
        } + [liveIdle]
        XCTAssertFalse(AgentAppView.hasStreamingGroupableTools(in: many))
    }

    private static func chatFlowToolPayloads(_ rows: [AgentAppView.ChatFlowRow]) -> [String] {
        chatFlowToolPayloadItems(rows).map { "\($0.id):\($0.body):\($0.output ?? "")" }
    }

    private static func firstLiveTool(_ rows: [AgentAppView.ChatFlowRow]) -> AssistantItem? {
        chatFlowToolPayloadItems(rows).first
    }

    private static func chatFlowToolPayloadItems(_ rows: [AgentAppView.ChatFlowRow]) -> [AssistantItem] {
        rows.flatMap { row -> [AssistantItem] in
            switch row {
            case .entry(.turn(let turn)):
                return turn.items
            case .entry(.message):
                return []
            case .segment(let segment):
                return segment.snapshot.items
            }
        }.filter { $0.type == .tool }
    }

    private func repoSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func functionChunk(_ source: String, start: String, endMarker: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing \(start)")
        let rest = source[startRange.lowerBound...]
        let end = rest.range(of: endMarker)?.lowerBound ?? rest.endIndex
        return String(source[startRange.lowerBound..<end])
    }

    @MainActor
    private func makeVM() throws -> (AgentAppViewModel, URL) {
        let rootURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc-memperf-wins-" + UUID().uuidString)
        let (_, db) = try Bootstrap(channel: .debug, appSupportOverride: rootURL.path).run()
        let threadRepo = AgentThreadRepository(db: db)
        let messageRepo = AgentMessageRepository(db: db)
        let runRepo = AgentRunRepository(db: db)
        let coordinator = AgentRunCoordinator(
            runRepo: runRepo,
            messageRepo: messageRepo,
            threadRepo: threadRepo,
            providers: [:]
        )
        let vm = AgentAppViewModel(
            workspaceID: WorkspaceID(),
            cwd: rootURL.path,
            coordinator: coordinator,
            threadRepo: threadRepo,
            messageRepo: messageRepo,
            draftRepo: AgentThreadDraftRepository(db: db)
        )
        return (vm, rootURL)
    }
}
