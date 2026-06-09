import XCTest
import CoreModel
@testable import Surfaces

/// Tests `TerminalRestartDecision.spawnRequest(from:)`.
///
/// WHY these tests matter:
/// The restart button is the single touch-point between a dead terminal and a
/// fresh shell. The decision helper is the only logic that determines (a) whether
/// the button appears at all, and (b) what cwd the new shell opens in. Regressions
/// here silently drop the user's working directory or show the button for SSH
/// surfaces (which have their own reconnect flow).
final class TerminalRestartTests: XCTestCase {

    // MARK: - eligible: local shell with cwd

    func test_spawnRequest_returnsRequest_forShellDescriptorWithCwd() {
        // A freshly spawned local terminal always has type=.terminal + cwd in metadata.
        // The helper must surface that cwd so the restarted shell opens in the same directory.
        let desc = SurfaceDescriptor(
            type: .terminal,
            title: "my terminal",
            metadata: ["cwd": "/Users/alice/project"]
        )

        let result = TerminalRestartDecision.spawnRequest(from: desc)

        XCTAssertNotNil(result, "local shell terminal must produce a spawn request")
        XCTAssertEqual(result?.cwd, "/Users/alice/project",
                       "restart must preserve cwd so the user stays in their working directory")
        XCTAssertEqual(result?.title, "my terminal",
                       "restart must preserve title for tab identity")
    }

    func test_spawnRequest_preservesDeepCwd() {
        // cwd can be any depth; the helper must not truncate or transform it.
        let cwd = "/Users/alice/code/remote-code/macos-app/Sources"
        let desc = SurfaceDescriptor(
            type: .terminal,
            title: "terminal",
            metadata: ["cwd": cwd]
        )

        let result = TerminalRestartDecision.spawnRequest(from: desc)

        XCTAssertEqual(result?.cwd, cwd,
                       "cwd must be passed through verbatim — any truncation breaks the user's context")
    }

    // MARK: - ineligible: SSH surface

    func test_spawnRequest_returnsNil_forSSHDescriptor() {
        // SSH surfaces have their own reconnect flow; showing a generic "Restart shell"
        // button for SSH would trigger a local shell spawn instead of an SSH reconnect,
        // silently losing the remote context.
        let desc = SurfaceDescriptor(
            type: .ssh,
            title: "prod server",
            metadata: ["cwd": "/home/alice", "ssh_destination": "alice@prod"]
        )

        let result = TerminalRestartDecision.spawnRequest(from: desc)

        XCTAssertNil(result, "SSH surface must not produce a restart request — it has a separate reconnect flow")
    }

    // MARK: - ineligible: missing or empty cwd

    func test_spawnRequest_returnsNil_whenCwdMissing() {
        // A descriptor without cwd cannot restart correctly (forkpty would chdir to "").
        // Returning nil prevents the button from appearing rather than spawning a
        // shell in an undefined directory.
        let desc = SurfaceDescriptor(
            type: .terminal,
            title: "terminal",
            metadata: [:]
        )

        let result = TerminalRestartDecision.spawnRequest(from: desc)

        XCTAssertNil(result, "missing cwd must block restart to avoid spawning in an undefined directory")
    }

    func test_spawnRequest_returnsNil_whenCwdEmpty() {
        // Empty string cwd is treated the same as missing — not a valid spawn target.
        let desc = SurfaceDescriptor(
            type: .terminal,
            title: "terminal",
            metadata: ["cwd": ""]
        )

        let result = TerminalRestartDecision.spawnRequest(from: desc)

        XCTAssertNil(result, "empty cwd must block restart")
    }

    // MARK: - other surface types

    func test_spawnRequest_returnsNil_forBrowserDescriptor() {
        // Browser surfaces are never terminal shells; the restart affordance must
        // not appear on them even if they somehow carry a cwd in metadata.
        let desc = SurfaceDescriptor(
            type: .browser,
            title: "browser",
            metadata: ["cwd": "/Users/alice"]
        )

        let result = TerminalRestartDecision.spawnRequest(from: desc)

        XCTAssertNil(result, "non-terminal surface types must not produce a restart request")
    }
}
