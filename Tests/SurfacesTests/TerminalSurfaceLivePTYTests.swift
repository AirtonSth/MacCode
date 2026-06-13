import XCTest
import CoreModel
@testable import Surfaces

@MainActor
final class TerminalSurfaceLivePTYTests: XCTestCase {
    func test_shellPTYRoundTripEOFExitCodeAndWinsizePropagation() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "live pty",
            launch: .shell(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        let marker = "RC2_PTY_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let rows = surface.viewportSize.rows
        let cols = surface.viewportSize.cols

        XCTAssertEqual(surface.sendTextStatus("printf '\\n\(marker)_ROUNDTRIP\\n'; stty size; exit 7\n"), .accepted,
                       "live TerminalSurface input must be accepted while the PTY child is alive")

        let output = try waitForSnapshot(surface) { snapshot in
            snapshot.text.contains("\(marker)_ROUNDTRIP") && snapshot.text.contains("\(rows) \(cols)")
        }.text

        XCTAssertTrue(output.contains("\(marker)_ROUNDTRIP"),
                      "readTextSnapshot must include output produced by the live shell child")
        XCTAssertTrue(output.contains("\(rows) \(cols)"),
                      "the PTY winsize must match TerminalSurface.viewportSize so full-screen shells see the same geometry iOS mirrors")

        let health = try waitForDead(surface)
        XCTAssertFalse(health.processAlive, "TerminalSurface must publish dead health after shell EOF")
        XCTAssertEqual(health.terminalDeadReason, "process_exited",
                       "the EOF path must classify a normal shell exit as process_exited")
        XCTAssertEqual(Self.exitCode(from: health.exitStatus), 7,
                       "the raw wait status must preserve the shell exit code shown in the dead-terminal banner")
        XCTAssertTrue(surface.readText().contains("[process exited (code 7)]"),
                      "readText must include the EOF banner users and mirrors rely on after terminal exit")
        XCTAssertEqual(surface.sendTextStatus("pwd\n"), .processExited,
                       "post-exit input must fail loudly instead of silently writing to a closed PTY")
    }

    private func waitForSnapshot(
        _ surface: TerminalSurface,
        timeout: TimeInterval = 6,
        predicate: (TerminalTextSnapshot) -> Bool
    ) throws -> TerminalTextSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var last = surface.readTextSnapshot()
        while Date() < deadline {
            last = surface.readTextSnapshot()
            if predicate(last) { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out waiting for live PTY output; last tail=\(String(last.text.suffix(300)))")
        return last
    }

    private func waitForDead(_ surface: TerminalSurface, timeout: TimeInterval = 6) throws -> TerminalRuntimeHealth {
        let deadline = Date().addingTimeInterval(timeout)
        var last = surface.runtimeHealth()
        while Date() < deadline {
            last = surface.runtimeHealth()
            if last.processAlive == false { return last }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("timed out waiting for PTY EOF; last health=\(last)")
        return last
    }

    private static func exitCode(from rawStatus: Int32?) -> Int32? {
        guard let rawStatus else { return nil }
        guard rawStatus & 0x7F == 0 else { return nil }
        return (rawStatus >> 8) & 0xFF
    }
}
