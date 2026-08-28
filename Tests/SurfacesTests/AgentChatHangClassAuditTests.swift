import XCTest

/// WHY: live RemoteCode pid 62995 spent 100% main-thread CPU in
/// LazyVStackLayout.sizeThatFits + AgentLinkedInlineTextRepresentable while
/// grok-acp.parse split unbounded itemDelta bodies. These source probes fail
/// if the hang class returns.
final class AgentChatHangClassAuditTests: XCTestCase {
    func test_liveHistoryLayoutDisablesLazyWhileATurnIsLive() throws {
        let source = try Self.readRepoFile("Sources/Surfaces/AgentAppSurface.swift")
        XCTAssertTrue(
            source.contains("liveTurnActive: latestLiveId != nil"),
            "Agent App history LazyVStack must turn off while a turn is live"
        )
        let desk = try Self.readRepoFile("Sources/AppShell/BotsWindow.swift")
        XCTAssertTrue(
            desk.contains("liveTurnActive: latestLiveTurnID != nil"),
            "Desk history LazyVStack must turn off while a turn is live"
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

    func test_staticListsAreNotTheLiveHangClass() throws {
        // Diff / Feed / SSH LazyVStacks paint mostly-static rows, not ACP
        // token streams. They stay out of this hang class unless they host
        // AgentLinkedInlineTextRepresentable inside LazyVStack during a live run.
        let diff = try Self.readRepoFile("Sources/Surfaces/DiffPanelSurface.swift")
        XCTAssertFalse(
            Self.codeWithoutComments(diff).contains("AgentLinkedInlineTextRepresentable"),
            "Diff panel must not mount the transcript NSTextView representable"
        )
    }

    private static func readRepoFile(_ rel: String) throws -> String {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent(rel), encoding: .utf8)
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
