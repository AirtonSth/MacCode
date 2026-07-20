import XCTest
import CoreModel
@testable import Surfaces

/// WHY: `GhosttyTerminalView.resetSurfaceOutput` freezes the C surface for
/// history replay. The old path called `releaseHostResourcesAfterClose`, which
/// nil'd `onInputData`. After that, Ghostty still drew and accepted key events,
/// but `io_write` had nowhere to go — the terminal looked alive and the user
/// could not type. Workspace reattach / restored-tab replay must preserve the
/// owner input callback.
@MainActor
final class TerminalInputAfterResetTests: XCTestCase {
    func test_resetSurfaceOutputPreservesInputDataHandler() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "input after reset",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        XCTAssertTrue(
            surface.ghosttyInputHandlerPresentForTesting,
            "fresh terminals must wire Ghostty io_write → writeToPTY"
        )

        // Same path as history didPrepareReplay.
        surface.replayResetSurfaceOutputForTesting(Data("restored scrollback\n".utf8))

        XCTAssertTrue(
            surface.ghosttyInputHandlerPresentForTesting,
            "history replay must not wipe onInputData — otherwise keys never reach the PTY"
        )
    }

    func test_resetSurfaceOutputStillDeliversTypedBytesToOwner() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "input delivery after reset",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        var received = Data()
        surface.replaceInputCaptureForTesting { received.append($0) }
        surface.replayResetSurfaceOutputForTesting(Data("scrollback\n".utf8))

        let probe = Data("typed-after-reset".utf8)
        surface.injectGhosttyInputWriteForTesting(probe)

        XCTAssertEqual(
            received,
            probe,
            "post-replay Ghostty io_write must still reach the TerminalSurface write path"
        )
    }
}
