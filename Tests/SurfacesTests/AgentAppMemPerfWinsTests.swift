import AppKit
import CoreModel
import ImageIO
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
}
