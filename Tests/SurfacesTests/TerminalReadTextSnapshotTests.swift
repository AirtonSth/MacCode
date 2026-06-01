import XCTest
import AppKit
import CoreModel
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

    func test_readTextSnapshotStaysPartialWhenHiddenOutputIsPending() {
        XCTAssertFalse(TerminalSurface.readTextComplete(outputPartial: false, outputPendingBytes: 42, historyWriteFailures: 0),
                       "surface.read_text must stay incomplete while hidden terminal bytes have not completed their visible drain")
        XCTAssertEqual(TerminalSurface.readTextPartialReason(outputPartial: false, outputPendingBytes: 42, historyWriteFailures: 0),
                       "hidden_output_pending")
    }

    func test_renderDiagnosticsNameRegistryVisibilityDriftBeforeClaimingCompleteSnapshot() {
        let diagnostics = TerminalRenderDiagnostics(
            logicalVisible: true,
            registryVisible: false,
            drainingHiddenBacklog: false,
            windowAttached: true,
            parked: false,
            hasUsableBounds: true,
            hiddenAncestor: false
        )

        XCTAssertFalse(diagnostics.canRender,
                       "a terminal that is mounted in a window but registry-hidden must not render as healthy")
        XCTAssertEqual(diagnostics.blockedReason, "registry_hidden",
                       "freeze diagnostics must point at the exact gate suppressing host render")
        XCTAssertEqual(TerminalSurface.readTextPartialReason(
            outputPartial: false,
            outputPendingBytes: 0,
            historyWriteFailures: 0,
            renderBlockedReason: diagnostics.blockedReason
        ), "registry_hidden",
                       "surface.read_text must stay partial when render is suppressed by stale visibility truth")
    }

    func test_terminalBellMarksActivityWithoutFlashingVisibleBackground() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "terminal",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }
        let originalBackground = surface.view.layer?.backgroundColor

        surface.handleBell()
        RunLoop.main.run(until: Date().addingTimeInterval(0.20))

        XCTAssertTrue(surface.descriptor.hasUnreadActivity,
                      "terminal BEL output must still mark activity for tabs and mirrors")
        XCTAssertCGColorEqual(surface.view.layer?.backgroundColor, originalBackground,
                             "visible terminal BEL output must not repaint the pane background because repeated CLI bells read as flicker")
    }

    func test_terminalBusyStateTracksForegroundProcessGroupNotShellLiveness() {
        XCTAssertFalse(TerminalSurface.isTerminalJobBusy(
            processAlive: true,
            shellPID: 100,
            foregroundProcessGroup: 100
        ), "an idle shell at a prompt is alive, but must not show tab or workspace spinners")
        XCTAssertTrue(TerminalSurface.isTerminalJobBusy(
            processAlive: true,
            shellPID: 100,
            foregroundProcessGroup: 200
        ), "a foreground command owns the terminal process group while it runs, so the spinner must show")
        XCTAssertFalse(TerminalSurface.isTerminalJobBusy(
            processAlive: false,
            shellPID: 100,
            foregroundProcessGroup: 200
        ), "a dead terminal must not keep stale spinners")
        XCTAssertFalse(TerminalSurface.isTerminalJobBusy(
            processAlive: true,
            shellPID: 100,
            foregroundProcessGroup: nil
        ), "unknown foreground process-group state must fail closed so idle prompts do not spin forever")
    }

    func test_terminalBusyStatePollingCoversDelayedStartAndLongRunningCommands() {
        let now = Date()

        XCTAssertTrue(TerminalSurface.shouldContinueBusyStatePolling(
            isBusy: false,
            now: now,
            probeUntil: now.addingTimeInterval(1)
        ), "after sending terminal input, polling must keep probing briefly because shell job-control can flip after the first refresh")
        XCTAssertTrue(TerminalSurface.shouldContinueBusyStatePolling(
            isBusy: true,
            now: now,
            probeUntil: now.addingTimeInterval(-1)
        ), "while a foreground command or Claude/Codex TUI owns the terminal, polling must continue until the spinner can clear")
        XCTAssertFalse(TerminalSurface.shouldContinueBusyStatePolling(
            isBusy: false,
            now: now,
            probeUntil: now.addingTimeInterval(-1)
        ), "after the prompt is idle past the probe window, polling must stop so the terminal does not refresh forever")
    }

    func test_focusRepairRetriesAfterTerminalViewAttachesToWindow() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "terminal",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }
        SurfaceRegistry.shared.register(surface)
        defer {
            SurfaceRegistry.shared.unregister(surface.descriptor.id)
            SurfaceRegistry.shared.setVisibleSurfaceIDs([])
        }
        SurfaceRegistry.shared.setVisibleSurfaceIDs([surface.descriptor.id])

        surface.repairTerminalFocus(reason: "unit_test_before_attach")
        XCTAssertFalse(surface.ownsTerminalFocusForTesting,
                       "initial repair cannot focus a terminal before the view has a usable window")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        surface.view.frame = window.contentView!.bounds
        surface.view.autoresizingMask = [.width, .height] as NSView.AutoresizingMask
        window.contentView?.addSubview(surface.view)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        XCTAssertTrue(surface.ownsTerminalFocusForTesting,
                      "bounded delayed repair must focus the terminal once AppKit attaches and lays out the view")
    }

    private func XCTAssertCGColorEqual(
        _ actual: CGColor?,
        _ expected: CGColor?,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch (actual, expected) {
        case (.none, .none):
            return
        case let (.some(actual), .some(expected)):
            XCTAssertTrue(CFEqual(actual, expected), message, file: file, line: line)
        default:
            XCTFail(message, file: file, line: line)
        }
    }
}
