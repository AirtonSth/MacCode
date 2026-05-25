import XCTest
@testable import Surfaces

@MainActor
final class TerminalReadTextSnapshotTests: XCTestCase {
    func test_readTextPrefersRendererScrollbackWhenGhosttyViewportCollapsesToPrompt() {
        let viewport = "samuel@MacBook test % "
        let renderer = "samuel@MacBook test % ls\nsnake-game\nsamuel@MacBook test % "

        XCTAssertTrue(TerminalSurface.shouldPreferRendererSnapshotForReadText(viewportText: viewport, rendererText: renderer),
                      "surface.read_text must not return only the current prompt when the renderer still has full terminal scrollback for iOS")
    }

    func test_readTextKeepsViewportForMultilineTUIFrames() {
        let viewport = "Claude Code\n> "
        let renderer = "old shell scrollback\nClaude Code\n> "

        XCTAssertFalse(TerminalSurface.shouldPreferRendererSnapshotForReadText(viewportText: viewport, rendererText: renderer),
                       "TUI-like multiline viewport text must stay host-owned instead of being replaced by older renderer scrollback")
    }
}
