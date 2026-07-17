import CoreModel
import XCTest

@testable import Surfaces

@MainActor
final class TerminalHiddenOverflowTruthRegressionTests: XCTestCase {
  func test_hiddenOutputBeyondReplayCapRemainsExplicitlyPartialAfterReveal() throws {
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "hidden overflow truth",
      launch: .shell(cwd: NSTemporaryDirectory())
    )
    let id = surface.descriptor.id

    SurfaceRegistry.shared.setVisibleSurfaceIDs([])
    SurfaceRegistry.shared.register(surface)
    SurfaceRegistry.shared.setVisibleSurfaceIDs([id])
    SurfaceRegistry.shared.setVisibleSurfaceIDs([])
    defer {
      SurfaceRegistry.shared.setVisibleSurfaceIDs([])
      SurfaceRegistry.shared.unregister(id)
      surface.close()
    }

    let replayCapBytes = 4 * 1024 * 1024
    let emittedBytes = replayCapBytes + (128 * 1024)
    XCTAssertEqual(
      surface.sendTextStatus(
        "yes RC2_HIDDEN_OVERFLOW | head -c \(emittedBytes); printf '\\nRC2_HIDDEN_OVERFLOW_DONE\\n'\n"
      ),
      .accepted,
      "the hidden terminal must accept the producer command before overflow truth can be verified"
    )

    let hiddenHealth = try waitForHealth(surface, timeout: 15) {
      $0.outputPendingBytes >= emittedBytes
    }
    XCTAssertGreaterThanOrEqual(
      hiddenHealth.outputPendingBytes,
      emittedBytes,
      "the test must prove output exceeded the hidden replay cap before revealing the terminal"
    )

    SurfaceRegistry.shared.setVisibleSurfaceIDs([id])
    let revealedHealth = surface.runtimeHealth()

    XCTAssertTrue(
      revealedHealth.outputPartial,
      "once hidden output exceeds the replay cap, reveal must preserve output_partial=true because the ANSI/iOS snapshot can never reconstruct the dropped tail"
    )
  }

  private func waitForHealth(
    _ surface: TerminalSurface,
    timeout: TimeInterval,
    predicate: (TerminalRuntimeHealth) -> Bool
  ) throws -> TerminalRuntimeHealth {
    let deadline = Date().addingTimeInterval(timeout)
    var last = surface.runtimeHealth()
    while Date() < deadline {
      last = surface.runtimeHealth()
      if predicate(last) { return last }
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    XCTFail("timed out waiting for hidden overflow; last health=\(last)")
    throw Timeout()
  }

  private struct Timeout: Error {}
}
