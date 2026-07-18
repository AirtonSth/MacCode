import AppKit
import XCTest
@testable import CoreModel
@testable import Surfaces

/// Proves permanent close releases materialized mirror/viewport resources without
/// sleeping for correctness. Covers the post-hidden-flood materialization path
/// that left ANSI rings, snapshot caches, Ghostty host state, and hosted views
/// alive after workspace/tab close (post-close RSS/FD recovery gate).
@MainActor
final class TerminalPostCloseResourceReleaseTests: XCTestCase {
    func test_materializedHiddenOutputReleasesHeavyStateOnClose() throws {
        // WHY: selecting a hidden flood terminal materializes Ghostty + ANSI +
        // snapshot cache. close() used to free only the C surface/PTY and leave
        // the full mirror ring / cache / view host until late ARC, so post-close
        // RSS stayed hundreds of MB above pre-workspace baseline.
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "post-close materialize release",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )

        surface.didBecomeHidden()
        XCTAssertFalse(surface.readerAllowsRenderForTesting)

        // Exceed the 4 MiB recoverability budget so the force-flush + overflow
        // path runs (same shape as the soak hidden-flood producer).
        let chunk = Data(repeating: UInt8(ascii: "m"), count: 1024 * 1024)
        for _ in 0..<5 {
            surface.injectReaderOutputForTesting(chunk)
        }
        let marker = "RC2_POST_CLOSE_TAIL_MARKER"
        surface.injectReaderOutputForTesting(Data("\(marker)\n".utf8))

        XCTAssertGreaterThan(surface.hiddenMirrorAcceptedBytesForTesting, 4 * 1024 * 1024)
        XCTAssertTrue(surface.hiddenRendererBufferOverflowedForTesting)

        // Materialize as workspace.select does: reveal, drain backlog, snapshot.
        surface.didBecomeVisible()
        let snap = surface.readTextSnapshot()
        XCTAssertTrue(
            snap.text.contains(marker) || surface.runtimeHealth().outputPartial,
            "materialized path must keep recoverable tail or honest partial"
        )
        XCTAssertTrue(
            surface.cachedTextSnapshotRetainedForTesting
                || surface.ansiMirrorScrollbackRowsForTesting > 0
                || !snap.text.isEmpty,
            "precondition: materialization must populate mirror and/or cache"
        )

        surface.close()

        // Explicit deallocation probes — no sleep-based correctness.
        XCTAssertFalse(
            surface.hasLiveGhosttySurfaceForTesting,
            "close must free the Ghostty C surface before return"
        )
        XCTAssertEqual(
            surface.hiddenMirrorRetainedRawBytesForTesting,
            0,
            "pending/heal raw mirror bytes must drop on close"
        )
        XCTAssertEqual(
            surface.ansiMirrorScrollbackRowsForTesting,
            0,
            "ANSI scrollback ring must be replaced with an empty renderer on close"
        )
        XCTAssertFalse(
            surface.cachedTextSnapshotRetainedForTesting,
            "readTextSnapshot cache must not retain transcript text after close"
        )
        XCTAssertFalse(
            surface.inputPumpRetainedForTesting,
            "input pump (and any stalled stdin payload) must be dropped on close"
        )
        XCTAssertNil(
            surface.view.superview,
            "closed terminal view must detach from pane/parking hierarchy immediately"
        )
    }

    func test_closeDropsSurfaceAndViewAfterOwnerReleasesStrongRefs() throws {
        // WHY: permanentlyCloseRuntimeSurface unregisters after close. The
        // TerminalSurface NSObject + GhosttyTerminalView must actually deinit so
        // Metal/ioContext pin release can run — not only clear internal buffers.
        weak var weakSurface: TerminalSurface?
        weak var weakView: NSView?

        autoreleasepool {
            let surface = try! TerminalSurface(
                workspaceID: WorkspaceID(),
                title: "post-close deinit",
                launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
            )
            weakSurface = surface
            weakView = surface.view

            surface.didBecomeHidden()
            let payload = Data(repeating: UInt8(ascii: "d"), count: 256 * 1024)
            surface.injectReaderOutputForTesting(payload)
            surface.didBecomeVisible()
            _ = surface.readTextSnapshot()
            surface.close()
            XCTAssertFalse(surface.hasLiveGhosttySurfaceForTesting)
        }

        // Drain MainActor / autorelease work scheduled by close without treating
        // sleep as the pass criterion — poll weak refs with a hard deadline.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, weakSurface != nil || weakView != nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        XCTAssertNil(
            weakSurface,
            "TerminalSurface must deinit after close when no owner retains it"
        )
        XCTAssertNil(
            weakView,
            "terminal host view must deinit after close+detach so Metal/ioContext release"
        )
    }
}
