import XCTest

/// WHY: live RemoteCode pid 11567 spent 100% of a 4s sample on the main thread
/// in SwiftUI `SelectionOverlay.updateNSView` → `NSTextField.invalidateIntrinsicContentSize`.
/// That overlay is created by `.textSelection(.enabled)` on SwiftUI `Text` during
/// streaming transcript paint. AppKit `AgentSelectablePlainText` / NSTextView is
/// the allowed selection path. This test fails if the overlay returns on live surfaces.
final class AgentChatTextSelectionAuditTests: XCTestCase {
    func test_liveChatAndDiffSourcesDoNotUseSwiftUITextSelection() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let files = [
            "Sources/Surfaces/AgentAppSurface.swift",
            "Sources/Surfaces/AgentMessageMarkdown.swift",
            "Sources/Surfaces/AgentChatLiveTurnChrome.swift",
            "Sources/Surfaces/AgentChatTranscriptChrome.swift",
            "Sources/Surfaces/DiffPanelSurface.swift",
            "Sources/AppShell/BotsWindow.swift",
        ]
        var dirty: [String] = []
        for rel in files {
            let url = repoRoot.appendingPathComponent(rel)
            let raw = try String(contentsOf: url, encoding: .utf8)
            if Self.codeWithoutComments(raw).contains(".textSelection(.enabled)") {
                dirty.append(rel)
            }
        }
        XCTAssertTrue(
            dirty.isEmpty,
            "SwiftUI .textSelection(.enabled) returned on live surfaces: \(dirty.joined(separator: ", "))"
        )
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
                    if let nl = source[i...].firstIndex(of: "\n") {
                        i = nl
                    } else {
                        break
                    }
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
