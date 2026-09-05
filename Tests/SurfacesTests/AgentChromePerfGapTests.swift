import CoreModel
import SwiftUI
import Testing
@testable import Surfaces

/// Regression locks for remaining Agent chrome/markdown hotspots CH-13, CH-14, CH-16.
///
/// Each test encodes WHY the old shape was expensive, not just the new call shape.
@Suite("Agent chrome perf gaps CH-13/14/16", .serialized)
struct AgentChromePerfGapTests {

    // MARK: - CH-14 applyingDetectedLinks index mapping

    /// WHY: `String.Index.distance(from: startIndex)` (and `index(_:offsetBy:)`)
    /// is O(offset). Doing that per regex match is O(matches × len) on every
    /// markdown paint. A monotonic cursor walks each character a constant
    /// number of times, so the step count must stay O(len) and beat the
    /// distance-from-start baseline by a wide margin.
    @Test("CH-14 monotonic offset beats per-match distance-from-start")
    func applyingDetectedLinks_usesMonotonicIndexCursor_notDistanceFromStart() {
        let matchCount = 200
        let pad = 80
        let text = denseLinkProse(matchCount: matchCount, pad: pad)
        let attributed = AttributedString(text)
        let matchRanges = urlMatchRanges(in: text)
        #expect(matchRanges.count == matchCount, "fixture must actually contain \(matchCount) URLs")

        var distanceBaseline = 0
        for range in matchRanges {
            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            // Production used to walk String then AttributedString from the start.
            distanceBaseline += 2 * (startOffset + length)
        }
        #expect(distanceBaseline > text.count * 20, "sanity: distance-from-start is quadratic-ish")

        AgentMessageMarkdown.linkIndexAdvanceCountForTesting = 0
        let linked = AgentMessageMarkdown.applyingDetectedLinks(to: attributed)
        let steps = AgentMessageMarkdown.linkIndexAdvanceCountForTesting
        let found = linked.runs.filter { $0.link != nil }.count

        #expect(found == matchCount, "link marking must stay correct while the cursor changes")
        #expect(
            steps <= max(text.count * 8, 64),
            "monotonic mapping must stay O(len); got \(steps) steps for \(text.count) characters (distance baseline \(distanceBaseline))"
        )
        #expect(
            steps * 5 < distanceBaseline,
            "monotonic cursor must beat distance-from-start by >5×; steps=\(steps) baseline=\(distanceBaseline)"
        )

        // Wall-clock of the index-mapping hotspot only (not regex/marking).
        let attributedForTiming = AttributedString(text)
        for _ in 0..<2 {
            _ = distanceBasedIndexWalk(text: text, attributed: attributedForTiming, ranges: matchRanges)
            _ = monotonicIndexWalk(text: text, attributed: attributedForTiming, ranges: matchRanges)
        }
        var beforeSamples: [Double] = []
        var afterSamples: [Double] = []
        for _ in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = distanceBasedIndexWalk(text: text, attributed: attributedForTiming, ranges: matchRanges)
            beforeSamples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            let t1 = CFAbsoluteTimeGetCurrent()
            _ = monotonicIndexWalk(text: text, attributed: attributedForTiming, ranges: matchRanges)
            afterSamples.append((CFAbsoluteTimeGetCurrent() - t1) * 1000)
        }
        print(
            "CH-14 numeric chars=\(text.count) matches=\(matchCount) steps=\(steps) distanceBaseline=\(distanceBaseline) beforeMs=\(beforeSamples.map { String(format: "%.3f", $0) }) afterMs=\(afterSamples.map { String(format: "%.3f", $0) })"
        )
    }

    @Test("CH-14 dense URL fixture still round-trips loadable links")
    func applyingDetectedLinks_denseURLs_remainTappable() {
        let text = denseLinkProse(matchCount: 12, pad: 8)
        let linked = AgentMessageMarkdown.applyingDetectedLinks(to: AttributedString(text))
        let urls = linked.runs.compactMap(\.link)
        #expect(urls.count == 12)
        #expect(urls.first?.absoluteString.hasPrefix("https://example.com/item/") == true)
    }

    // MARK: - CH-13 hover state isolation

    /// WHY: `@State hoveredCode` on `AgentMessageMarkdownView` invalidates every
    /// paragraph, table, and sibling code block on mouse-enter. Hover belongs
    /// on an Equatable `CodeBlockView` with its own `@State`.
    @Test("CH-13 hover state lives on CodeBlockView, not the message body")
    func markdownView_doesNotStoreHoverState_codeBlockOwnsIt() {
        let markdown = AgentMessageMarkdownView(text: "intro\n\n```\nlet x = 1\n```\n\noutro")
        let parentLabels = Mirror(reflecting: markdown).children.compactMap(\.label)
        #expect(
            !parentLabels.contains { $0.localizedCaseInsensitiveContains("hover") },
            "hoveredCode @State on the message view rebuilds every sibling on hover"
        )
        #expect(
            !parentLabels.contains { $0.localizedCaseInsensitiveContains("copied") },
            "copy feedback is per-block chrome; parent @State copiedCode has the same blast radius"
        )

        let block = AgentMessageMarkdownCodeBlockView(text: "let x = 1")
        let blockLabels = Mirror(reflecting: block).children.compactMap(\.label)
        #expect(
            blockLabels.contains { $0.localizedCaseInsensitiveContains("hover") },
            "CodeBlockView must own hovered @State so only the overlay invalidates"
        )
    }

    @Test("CH-13 CodeBlockView equality ignores transient hover/copy")
    func codeBlockView_isEquatableOnTextNotHover() {
        let a = AgentMessageMarkdownCodeBlockView(text: "let x = 1")
        let b = AgentMessageMarkdownCodeBlockView(text: "let x = 1")
        let c = AgentMessageMarkdownCodeBlockView(text: "let y = 2")
        #expect(a == b, "equal fenced text must skip parent-driven body via EquatableView")
        #expect(a != c)
    }

    @Test("CH-13 evaluating code-block body does not bump parent markdown body")
    func codeBlockBodyEvaluation_doesNotRebuildParentMarkdown() {
        AgentMessageMarkdownView.bodyCountForTesting = 0
        AgentMessageMarkdownCodeBlockView.bodyCountForTesting = 0
        _ = AgentMessageMarkdownCodeBlockView(text: "let isolated = true").body
        #expect(AgentMessageMarkdownCodeBlockView.bodyCountForTesting >= 1)
        #expect(
            AgentMessageMarkdownView.bodyCountForTesting == 0,
            "hover/copy chrome lives on the code block; evaluating it must not rebuild the message"
        )
    }

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

    // MARK: - Helpers

    private func denseLinkProse(matchCount: Int, pad: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(matchCount)
        for i in 0..<matchCount {
            parts.append(String(repeating: "w", count: pad) + " https://example.com/item/\(i) ")
        }
        return parts.joined()
    }

    /// Post-fix mapping: one forward walk of both character views.
    private func monotonicIndexWalk(
        text: String,
        attributed: AttributedString,
        ranges: [Range<String.Index>]
    ) -> Int {
        var stringIndex = text.startIndex
        var attrIndex = attributed.startIndex
        var mapped = 0
        let characters = attributed.characters
        for range in ranges {
            while stringIndex < range.lowerBound, stringIndex < text.endIndex, attrIndex < characters.endIndex {
                stringIndex = text.index(after: stringIndex)
                attrIndex = characters.index(after: attrIndex)
            }
            while stringIndex < range.upperBound, stringIndex < text.endIndex, attrIndex < characters.endIndex {
                stringIndex = text.index(after: stringIndex)
                attrIndex = characters.index(after: attrIndex)
            }
            mapped += 1
        }
        return mapped
    }

    /// The pre-fix mapping: `distance(from: start)` + `index(_:offsetBy:)` per match.
    private func distanceBasedIndexWalk(
        text: String,
        attributed: AttributedString,
        ranges: [Range<String.Index>]
    ) -> Int {
        var mapped = 0
        for range in ranges {
            let startOffset = text.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.distance(from: range.lowerBound, to: range.upperBound)
            guard let start = attributed.characters.index(
                attributed.startIndex,
                offsetBy: startOffset,
                limitedBy: attributed.endIndex
            ),
            let end = attributed.characters.index(
                start,
                offsetBy: length,
                limitedBy: attributed.endIndex
            ) else { continue }
            _ = start
            _ = end
            mapped += 1
        }
        return mapped
    }

    private func urlMatchRanges(in text: String) -> [Range<String.Index>] {
        let pattern = #"https://example.com/item/\d+"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let full = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: full).compactMap { Range($0.range, in: text) }
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
