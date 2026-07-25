import XCTest
import CoreModel
@testable import Surfaces

/// Regression for workspace-switch terminal garbling.
///
/// WHY: Leaving a terminal in a background workspace tears the Ghostty view
/// out of the live pane, parks it in an off-screen window, then reattaches on
/// return. Each intermediate AppKit frame used to call `TIOCSWINSZ`, so zsh
/// received a SIGWINCH storm and redrew the prompt into a corrupted grid
/// (staircase of prompt fragments, terminal "doesn't work"). Interactive
/// winsize must freeze while hidden/parked and only commit after reveal settles.
@MainActor
final class TerminalPTYWinsizeGateTests: XCTestCase {

    func test_shouldPropagateInteractiveWinsize_onlyWhenVisibleUnparkedUsable() {
        XCTAssertTrue(
            TerminalSurface.shouldPropagateInteractiveWinsize(
                isVisible: true,
                parked: false,
                hasUsableBounds: true
            ),
            "a live selected terminal with real bounds must keep PTY geometry in sync"
        )
        XCTAssertFalse(
            TerminalSurface.shouldPropagateInteractiveWinsize(
                isVisible: false,
                parked: false,
                hasUsableBounds: true
            ),
            "hidden surfaces must not SIGWINCH the shell during workspace teardown"
        )
        XCTAssertFalse(
            TerminalSurface.shouldPropagateInteractiveWinsize(
                isVisible: true,
                parked: true,
                hasUsableBounds: true
            ),
            "parking-window geometry is not the user-visible viewport and must not drive winsize"
        )
        XCTAssertFalse(
            TerminalSurface.shouldPropagateInteractiveWinsize(
                isVisible: true,
                parked: false,
                hasUsableBounds: false
            ),
            "first-layout / zero frames must not push a degenerate PTY size"
        )
    }

    func test_sizeThrashWhileHiddenDoesNotCommitWinsizeUntilReveal() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "winsize gate",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        // Placeholder launch has no live PTY spawn; establish the same one-shot
        // baseline the shell path would commit at init so thrash deltas are measurable.
        surface.applyViewportSizeForTesting(
            TerminalViewportGeometry.fallbackSize,
            force: true
        )
        let afterSpawn = surface.ptyWinsizeCommitCountForTesting
        XCTAssertEqual(afterSpawn, 1,
                       "force-commit must establish an initial PTY winsize baseline")

        surface.didBecomeHidden()
        let afterHide = surface.ptyWinsizeCommitCountForTesting

        // Simulate park/reattach thrash: many intermediate sizes while hidden.
        // Final size must differ from the spawn fallback so reveal is forced to
        // commit a real post-reattach geometry (not a no-op same-size commit).
        let settled = TerminalViewportSize(rows: 32, cols: 100)
        surface.applyViewportSizeForTesting(TerminalViewportSize(rows: 3, cols: 8))
        surface.applyViewportSizeForTesting(TerminalViewportSize(rows: 1, cols: 1))
        surface.applyViewportSizeForTesting(TerminalViewportSize(rows: 12, cols: 40))
        surface.applyViewportSizeForTesting(settled)
        surface.flushPendingPTYWinsizeForTesting()

        XCTAssertEqual(
            surface.ptyWinsizeCommitCountForTesting,
            afterHide,
            "hidden size thrash must not push intermediate COLUMNS/LINES into the shell"
        )
        XCTAssertEqual(
            surface.viewportSize,
            settled,
            "Ghostty/ANSI still track the latest host size so reveal paints at the right grid"
        )

        surface.didBecomeVisible()
        surface.flushPendingPTYWinsizeForTesting()

        XCTAssertEqual(
            surface.ptyWinsizeCommitCountForTesting,
            afterHide + 1,
            "reveal must commit the settled size once, not replaying every thrash frame"
        )
        XCTAssertEqual(
            surface.lastCommittedPTYSizeForTesting,
            settled,
            "the single post-reveal commit must be the final visible geometry"
        )
    }

    func test_hideCancelsPendingDebouncedWinsize() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "winsize cancel",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        let baseline = surface.ptyWinsizeCommitCountForTesting
        // Visible interactive resize schedules a debounced commit.
        surface.applyViewportSizeForTesting(TerminalViewportSize(rows: 24, cols: 80))
        // Hide before debounce fires — must drop the pending commit.
        surface.didBecomeHidden()
        surface.flushPendingPTYWinsizeForTesting()

        XCTAssertEqual(
            surface.ptyWinsizeCommitCountForTesting,
            baseline,
            "a hide that races a debounced resize must cancel it so the shell never sees the intermediate size"
        )
    }
}
