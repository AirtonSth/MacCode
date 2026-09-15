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
