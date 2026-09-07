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

        let source = try surfacesSource("AgentChatSharedChrome.swift")
        #expect(
            source.contains("ForEach(attachments, id: \\.path)"),
            "composer chips must key ForEach by path"
        )
        #expect(
            !source.contains("ForEach(attachments, id: \\.self)"),
            "id:\\.self remounts the thumbnail when the struct changes"
        )
    }

    private func surfacesSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/\(name)"),
            encoding: .utf8
        )
    }
}
