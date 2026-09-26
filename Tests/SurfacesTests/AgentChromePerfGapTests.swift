import CoreModel
import SwiftUI
import Testing
@testable import Surfaces

/// Stable attachment identity when metadata changes.
@Suite("Agent attachment chip identity", .serialized)
struct AgentChromePerfGapTests {
    // MARK: - CH-16 attachment chip identity

    /// WHY: `ForEach(id: \.self)` remounts the chip — and cancels
    /// `AgentChatAttachmentThumbnail.task` — when a later probe fills
    /// `sizeBytes`/`sha256`. Path is the stable file identity.
    @Test("CH-16 chip ForEach identity is path, not Hashable-self")
    func attachmentChipIdentity_isPath_notWholeStruct() throws {
        let before = AgentAttachment(
            path: "/tmp/shot.png",
            displayName: "shot.png",
            kind: .image,
            sizeBytes: nil
        )
        let after = AgentAttachment(
            path: "/tmp/shot.png",
            displayName: "shot.png",
            kind: .image,
            sha256: "abc",
            sizeBytes: 4096
        )
        #expect(before != after, "metadata fill changes Hashable-self identity")
        #expect(
            AgentChatAttachmentChips.chipIdentity(before) == AgentChatAttachmentChips.chipIdentity(after),
            "SwiftUI identity must stay on path so the thumbnail task is not cancelled"
        )
        #expect(AgentChatAttachmentChips.chipIdentity(before) == before.path)
        #expect(!AgentChatAttachmentChips.wouldRemountChip(from: before, to: after))

        let source = try repoSource("Sources/Surfaces/AgentChatSharedChrome.swift")
        #expect(
            source.contains("ForEach(attachments, id: \\.path)"),
            "composer chips must key ForEach by path"
        )
        #expect(
            !source.contains("ForEach(attachments, id: \\.self)"),
            "id:\\.self remounts the thumbnail when the struct changes"
        )
    }

    @Test("toolInputCache keeps preview latency while assistant-text caches use fingerprints")
    func cacheKeys_matchMeasuredLatencyAndMemoryTradeoffs() throws {
        // WHY: fingerprint generation on every tool preview regressed the
        // comparable warm-path benchmark; assistant-text caches still avoid
        // retaining full source strings as keys.
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let toolStart = try #require(source.range(of: "static func toolInputObject(for item: AssistantItem)"))
        let toolRest = source[toolStart.lowerBound...]
        let toolEnd = toolRest.range(of: "static func intMillis(from value: Any?)")?.lowerBound ?? toolRest.endIndex
        let toolChunk = String(source[toolStart.lowerBound..<toolEnd])
        #expect(toolChunk.contains("let key = body as NSString"))
        #expect(!toolChunk.contains("AgentMessageMarkdown.cacheKey(for: body)"))

        let normStart = try #require(source.range(of: "private static func normalizedAssistantText(_ text: String)"))
        let normRest = source[normStart.lowerBound...]
        let normEnd = normRest.range(of: "private static func makeNormalizedAssistantText")?.lowerBound ?? normRest.endIndex
        let normChunk = String(source[normStart.lowerBound..<normEnd])
        #expect(normChunk.contains("AgentMessageMarkdown.cacheKey(for: text)"))
        #expect(!normChunk.contains("let key = text as NSString"))
    }

    @Test("header and transcript column snapshot mentionableBots; composer @ stays live")
    func mentionableBots_headerAndColumnUseGenerationSnapshot() throws {
        // WHY: live provider calls on every timeline/VM publish recopied the
        // catalog (lock + array) even when contentGeneration was unchanged.
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let headerStart = try #require(source.range(of: "private var header: some View {"))
        let headerRest = source[headerStart.lowerBound...]
        let headerEnd = headerRest.range(of: "private var fullAccessBanner")?.lowerBound ?? headerRest.endIndex
        let header = String(source[headerStart.lowerBound..<headerEnd])
        #expect(header.contains("snapshotMentionableBots()"))
        #expect(!header.contains("mentionableBotsProvider()"))

        let columnMarker = "let flow = cachedChatFlowPaint("
        let columnStart = try #require(source.range(of: columnMarker))
        let columnRest = source[columnStart.lowerBound...]
        let columnEnd = columnRest.range(of: "VStack(alignment: .leading, spacing: 32)")?.lowerBound ?? columnRest.endIndex
        let column = String(source[columnStart.lowerBound..<columnEnd])
        #expect(column.contains("snapshotMentionableBots()"))
        #expect(!column.contains("mentionableBotsProvider()"))
        #expect(source.contains("mentionableBots = mentionableBotsProvider()"))
    }

    @Test("timeline memoizes history chatFlowRows; live tail always weaves")
    func chatFlowPaint_shortCircuitsOnGenerationAndPaintEnds() throws {
        // WHY: chrome-only ticks rebuilt the finished history weave even when
        // generation + history first/last ids + count were unchanged. Live
        // ChatFlowRows embed tool snapshots and must reweave on each pass.
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let start = try #require(source.range(of: "private func cachedChatFlowPaint("))
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "func cachedChatRowPaintContextForTesting")?.lowerBound ?? rest.endIndex
        let chunk = String(source[start.lowerBound..<end])
        let counts = try #require(chunk.range(of: "chatFlowPaintCache.count == count"))
        let first = try #require(chunk.range(of: "chatFlowPaintCache.firstId == firstId"))
        let last = try #require(chunk.range(of: "chatFlowPaintCache.lastId == lastId"))
        let rows = try #require(chunk.range(of: "Self.chatFlowRows(split.history)"))
        let live = try #require(chunk.range(of: "Self.chatFlowRows(split.liveTail)"))
        #expect(counts.lowerBound < rows.lowerBound)
        #expect(first.lowerBound < rows.lowerBound)
        #expect(last.lowerBound < rows.lowerBound)
        #expect(rows.lowerBound < live.lowerBound)
        #expect(chunk.contains("chatFlowPaintCache.generation == generation"))
        #expect(chunk.contains("Self.splitTrailingLiveTurns("))
        #expect(chunk.contains("latestLiveTurnId: latestLiveTurnId"))
        #expect(!chunk.contains("chatFlowPaintCache.liveRows"))
        let columnStart = try #require(source.range(of: "let flow = cachedChatFlowPaint("))
        let columnRest = source[columnStart.lowerBound...]
        let columnEnd = columnRest.range(of: "VStack(alignment: .leading, spacing: 32)")?.lowerBound
            ?? columnRest.endIndex
        let column = String(source[columnStart.lowerBound..<columnEnd])
        #expect(column.contains("flow.historyRows"))
        #expect(!column.contains("Self.chatFlowRows("))
    }

    @Test("header Subagents now skips currentTime when snapshot empty and popover closed")
    func headerSubagentNow_usesStableSentinelWhenEmptyAndClosed() throws {
        // WHY: Auto routing mounts empty Subagents chrome. A fresh Date() on
        // every header body churned identity with no elapsed UI to show.
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let headerStart = try #require(source.range(of: "private var header: some View {"))
        let headerRest = source[headerStart.lowerBound...]
        let headerEnd = headerRest.range(of: "private var fullAccessBanner")?.lowerBound ?? headerRest.endIndex
        let header = String(source[headerStart.lowerBound..<headerEnd])
        #expect(header.contains("subagentActivityBadgeNow("))
        #expect(!header.contains("now: vm.currentTime()"))
        #expect(source.contains("subagentActivityBadgeStableNow"))
        #expect(source.contains("mentionableBots = mentionableBotsProvider()"))
    }

    @Test("cachedChatRowPaintContext returns on generation+counts before building the signature")
    func paintContext_shortCircuitsSignatureBuilder() throws {
        // WHY: the F2 signature concatenated every bot identity on every column
        // body, including tool-body-only ticks that already knew generation and
        // row/visible counts. Count match must win before that String alloc.
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let start = try #require(source.range(of: "private func cachedChatRowPaintContext("))
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "private func snapshotMentionableBots()")?.lowerBound ?? rest.endIndex
        let chunk = String(source[start.lowerBound..<end])
        let counts = try #require(chunk.range(of: "chatRowPaintContextCache.rowCount == rows.count"))
        let signature = try #require(chunk.range(of: "Self.chatRowPaintContextSignature("))
        #expect(counts.lowerBound < signature.lowerBound)
        #expect(chunk.contains("chatRowPaintContextSignatureBuilderCountForTesting"))
    }

    @Test("Edit/diff jsonObject reuses toolInputObject")
    func editDiffJSON_reusesToolInputObject() throws {
        let source = try repoSource("Sources/Surfaces/AgentChatUXPresentation.swift")
        let start = try #require(source.range(of: "private static func jsonObject(_ body: String)"))
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n}")?.lowerBound ?? rest.endIndex
        let chunk = String(source[start.lowerBound..<end])
        #expect(chunk.contains("toolInputObject(forBody:"))
        #expect(!chunk.contains("JSONSerialization.jsonObject"))
    }

    @Test("live tool preview uses toolInputObject cache, not a second JSONSerialization")
    func toolCommandPreview_routesThroughToolInputObject() throws {
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let marker = "static func toolCommandPreview(for item: AssistantItem)"
        let start = try #require(source.range(of: marker))
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n    // MARK: Tool card presentation")?.lowerBound ?? rest.endIndex
        let chunk = String(source[start.lowerBound..<end])
        #expect(
            chunk.contains("toolInputObject(for: item)"),
            "preview must reuse the existing JSON cache"
        )
        #expect(
            !chunk.contains("JSONSerialization"),
            "preview must not JSON-decode item.body on every paint"
        )
    }

    @Test("live tool/reasoning/item rows are Equatable and mounted with .equatable()")
    func liveRows_areEquatableAtMount() throws {
        let chrome = try repoSource("Sources/Surfaces/AgentChatLiveTurnChrome.swift")
        #expect(chrome.contains("public struct AgentChatReasoningRow: View, Equatable"))
        #expect(chrome.contains("public struct AgentChatLiveToolRow: View, Equatable"))
        #expect(chrome.contains("public struct AgentChatLiveItemRow: View, Equatable"))
        #expect(chrome.contains("liveRowItemInputsMatch"))
        let equatableMounts = chrome.components(separatedBy: ".equatable()").count - 1
        #expect(
            equatableMounts >= 4,
            "SwiftUI only consults Equatable through EquatableView / .equatable(); got \(equatableMounts) mounts"
        )
    }

    @Test("Agent App ElapsedTickSchedule pins 5s when occluded")
    func elapsedTickSchedule_pinsLowFrequency() throws {
        let source = try repoSource("Sources/Surfaces/AgentAppSurface.swift")
        let marker = "struct ElapsedTickSchedule: TimelineSchedule"
        let start = try #require(source.range(of: marker))
        let rest = source[start.lowerBound...]
        let end = rest.range(of: "\n/// Pure presentation rules")?.lowerBound ?? rest.endIndex
        let chunk = String(source[start.lowerBound..<end])
        #expect(chunk.contains("mode != .lowFrequency"))
        #expect(chunk.contains("? 1 : 5"))
    }

    @Test("Files and File Preview thumbs cap at 2048px and decode immediately off-main")
    func filesThumbnails_capAt2048() throws {
        let preview = try repoSource("Sources/Surfaces/FilePreviewSurface.swift")
        #expect(preview.contains("thumbnailMaxPixelSize = 2048"))
        #expect(preview.contains("kCGImageSourceShouldCacheImmediately: true"))
        #expect(!preview.contains("kCGImageSourceThumbnailMaxPixelSize: 4096"))

        let files = try repoSource("Sources/AppShell/FilesSurface.swift")
        #expect(files.contains("FilesImageThumbnailMaxPixelSize = 2048"))
        #expect(files.contains("kCGImageSourceShouldCacheImmediately: true"))
        #expect(!files.contains("kCGImageSourceThumbnailMaxPixelSize: 4096"))
    }

    private func repoSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relative),
            encoding: .utf8
        )
    }
}
