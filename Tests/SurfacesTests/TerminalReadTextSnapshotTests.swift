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
}
