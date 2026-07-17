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

    /// WHY: release-soak setup creates hidden auxiliary terminals, accepts a
    /// workload, then polls `surface.read_text` for `RC2_AUX_XX_READY`. Old
    /// behavior buffered hidden PTY bytes only into `hiddenRendererBuffer` and
    /// returned an unfed/blank ANSI renderer (or blank parked Ghostty grid) so
    /// the marker never appeared. This must fail on that regression: hidden
    /// output is readable while still hidden and after pending drain/reveal.
    ///
    /// Uses the reader inject seam (same `appendDataAsync` path as PTY output)
    /// so the regression runs when the sandbox blocks `forkpty`.
    func test_hiddenAuxiliaryPTYOutputReadableAfterPendingWithoutReveal() throws {
        let surface = try TerminalSurface(
            workspaceID: WorkspaceID(),
            title: "hidden aux inject",
            launch: .sshPlaceholder(cwd: NSTemporaryDirectory())
        )
        defer { surface.close() }

        // Match soak auxiliaries: surface is not the selected/visible terminal.
        surface.didBecomeHidden()
        XCTAssertFalse(
            surface.readerAllowsRenderForTesting,
            "aux readiness must be observed while the terminal stays render-suppressed"
        )

        let marker = "RC2_AUX_02_READY"
        surface.injectReaderOutputForTesting(Data("\(marker)\n".utf8))

        let whileHidden = surface.readTextSnapshot()
        XCTAssertTrue(
            whileHidden.text.contains(marker),
            "surface.read_text must return hidden PTY transcript (healed ANSI mirror) even before reveal; blank Ghostty/unfed renderer is the soak setup failure"
        )
        XCTAssertEqual(
            whileHidden.source,
            "ansi_fallback",
            "while still hidden, read_text must use the healed renderer — not a parked Ghostty viewport"
        )
        XCTAssertFalse(
            surface.readerAllowsRenderForTesting,
            "observing the marker must not require flipping the surface visible"
        )
        XCTAssertGreaterThan(
            surface.runtimeHealth().outputPendingBytes,
            0,
            "honest pending state must remain until visibility reconciliation drains Ghostty"
        )

        // Visibility reconciliation / reveal zeros pending and may leave Ghostty
        // blank for a beat; transcript must still contain the marker.
        surface.didBecomeVisible()
        XCTAssertEqual(surface.runtimeHealth().outputPendingBytes, 0)
        let afterDrain = surface.readTextSnapshot()
        XCTAssertTrue(
            afterDrain.text.contains(marker),
            "after pending drain/reveal, read_text must still expose the readiness marker even if Ghostty viewport is blank"
        )
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
