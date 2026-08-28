import XCTest
@testable import Surfaces

/// WHY: live RemoteCode pid 62995 spent 100% main-thread CPU in
/// LazyVStackLayout.sizeThatFits + AgentLinkedInlineTextRepresentable while
/// grok-acp.parse split unbounded itemDelta bodies. These source probes fail
/// if the hang class returns.
final class AgentChatHangClassAuditTests: XCTestCase {
    func test_transcriptHistoryNeverUsesLazyVStack() throws {
        XCTAssertFalse(AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 9))
        XCTAssertFalse(
            AgentChatTimelineHistoryLayout.usesLazyLayout(entryCount: 40, liveTurnActive: false)
        )
        let app = try Self.readRepoFile("Sources/Surfaces/AgentAppSurface.swift")
        let marker = try XCTUnwrap(app.range(of: "Live streaming turns"))
        let before = String(app[app.startIndex..<marker.lowerBound])
        XCTAssertFalse(
            before.contains("LazyVStack(alignment: .leading, spacing: 32)"),
            "Agent App ChatFlowRow history must not use LazyVStack"
        )
        let desk = try Self.readRepoFile("Sources/AppShell/BotsWindow.swift")
        let start = try XCTUnwrap(desk.range(of: "private func deskTimeline"))
        let rest = desk[start.lowerBound...]
        let end = rest.range(of: "\n    private func deskBubble")?.lowerBound ?? rest.endIndex
        let slice = String(desk[start.lowerBound..<end])
        XCTAssertFalse(
            slice.contains("LazyVStack("),
            "Desk transcript history must not use LazyVStack"
        )
    }

    func test_linkedTranscriptTextDoesNotApplyVerticalFixedSize() throws {
        let source = try Self.readRepoFile("Sources/Surfaces/AgentLinkedInlineText.swift")
        let marker = try XCTUnwrap(source.range(of: "struct AgentLinkedAttributedText"))
        let rest = source[marker.lowerBound...]
        let end = rest.range(of: "\nstruct AgentLinkedInlineTextAppliedState")?.lowerBound
            ?? rest.endIndex
        let chunk = String(source[marker.lowerBound..<end])
        XCTAssertFalse(
            chunk.contains(".fixedSize(horizontal: false, vertical: true)"),
            "representable-level vertical fixedSize retriggers Lazy/eager placement"
        )
    }

    func test_liveStreamingAssistantUsesPlainTextNotFullMarkdown() throws {
        let source = try Self.readRepoFile("Sources/Surfaces/AgentChatLiveTurnChrome.swift")
        let marker = try XCTUnwrap(source.range(of: "case .assistantMessage:"))
        let rest = source[marker.lowerBound...]
        let end = rest.range(of: "\n        case .plan:")?.lowerBound ?? rest.endIndex
        let chunk = String(source[marker.lowerBound..<end])
        XCTAssertTrue(
            chunk.contains("item.state == .streaming"),
            "streaming assistant items must take a cheap path"
        )
        XCTAssertTrue(
            chunk.contains("AgentSelectablePlainText"),
            "streaming assistant items must not rebuild markdown+NSTextView every token"
        )
    }

    func test_lazyStacksDoNotHostTranscriptNSTextView() throws {
        let needles = [
            "AgentLinkedInlineTextRepresentable",
            "AgentLinkedAttributedText(",
            "AgentLinkedInlineText(",
            "AgentSelectablePlainText(",
            "AgentMessageMarkdownView(",
            "IntrinsicHeightTextView",
        ]
        let sources = Self.repoRoot().appendingPathComponent("Sources")
        var dirty: [String] = []
        for file in try Self.swiftFiles(under: sources) {
            let raw = Self.codeWithoutComments(try String(contentsOf: file, encoding: .utf8))
            let rel = Self.relativePath(file)
            for block in Self.lazyContainerBlocks(in: raw) {
                if needles.contains(where: { block.contains($0) }) {
                    dirty.append(rel)
                    break
                }
            }
        }
        XCTAssertTrue(
            dirty.isEmpty,
            "LazyVStack/HStack/Grid must not host transcript NSTextView cells: \(dirty.joined(separator: ", "))"
        )
        let diff = Self.codeWithoutComments(try Self.readRepoFile("Sources/Surfaces/DiffPanelSurface.swift"))
        let linesView = diff.components(separatedBy: "private var diffLinesView").last ?? ""
        XCTAssertFalse(
            linesView.contains("AgentLinkedAttributedText(")
                || linesView.contains("AgentSelectablePlainText(")
                || linesView.contains("AgentLinkedInlineText("),
            "diff find-line LazyVStack must stay SwiftUI Text, not NSTextView cells"
        )
        XCTAssertTrue(
            linesView.contains("Text(lineText)"),
            "diff find-line rows must be SwiftUI Text so LazyVStack stays safe"
        )
    }

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func readRepoFile(_ rel: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)
    }

    private static func relativePath(_ file: URL) -> String {
        let root = repoRoot().standardizedFileURL.path
        let path = file.standardizedFileURL.path
        if path.hasPrefix(root + "/") {
            return String(path.dropFirst(root.count + 1))
        }
        return file.lastPathComponent
    }

    private static func swiftFiles(under dir: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }

    /// Brace-matched `LazyVStack` / `LazyHStack` / `LazyVGrid` / `LazyHGrid`
    /// bodies. File-level scans false-positive when the same file also has a
    /// Text-only lazy list plus an NSTextView banner outside that list.
    private static func lazyContainerBlocks(in source: String) -> [String] {
        let markers = ["LazyVStack(", "LazyHStack(", "LazyVGrid(", "LazyHGrid("]
        var blocks: [String] = []
        var search = source.startIndex
        while search < source.endIndex {
            var hit: Range<String.Index>?
            for marker in markers {
                if let range = source.range(of: marker, range: search..<source.endIndex) {
                    if hit == nil || range.lowerBound < hit!.lowerBound {
                        hit = range
                    }
                }
            }
            guard let start = hit else { break }
            guard let open = source[start.lowerBound...].firstIndex(of: "{") else {
                search = source.index(after: start.lowerBound)
                continue
            }
            var depth = 0
            var index = open
            var close = open
            var found = false
            while index < source.endIndex {
                let ch = source[index]
                if ch == "{" {
                    depth += 1
                } else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        close = index
                        found = true
                        break
                    }
                }
                index = source.index(after: index)
            }
            if found {
                blocks.append(String(source[start.lowerBound...close]))
                search = source.index(after: close)
            } else {
                search = source.index(after: start.lowerBound)
            }
        }
        return blocks
    }

    private static func codeWithoutComments(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        var block = false
        while i < source.endIndex {
            let next = source.index(after: i)
            if block {
                if source[i] == "*", next < source.endIndex, source[next] == "/" {
                    block = false
                    i = source.index(after: next)
                    continue
                }
                i = next
                continue
            }
            if source[i] == "/", next < source.endIndex {
                if source[next] == "/" {
                    while i < source.endIndex, source[i] != "\n" { i = source.index(after: i) }
                    continue
                }
                if source[next] == "*" {
                    block = true
                    i = source.index(after: next)
                    continue
                }
            }
            out.append(source[i])
            i = next
        }
        return out
    }
}
