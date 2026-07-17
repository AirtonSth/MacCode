import CoreModel
import XCTest

@testable import Surfaces

@MainActor
final class TerminalRestoredBackgroundVisibilityRegressionTests: XCTestCase {
  func test_restoredTerminalStartsHiddenUntilRegistrySelectsIt() throws {
    let surface = try TerminalSurface(
      workspaceID: WorkspaceID(),
      title: "restored background terminal",
      launch: .shell(cwd: NSTemporaryDirectory()),
      restoredSurfaceID: SurfaceID()
    )
    let id = surface.descriptor.id

    SurfaceRegistry.shared.setVisibleSurfaceIDs([])
    SurfaceRegistry.shared.register(surface)
    defer {
      SurfaceRegistry.shared.setVisibleSurfaceIDs([])
      SurfaceRegistry.shared.unregister(id)
      surface.close()
    }

    XCTAssertFalse(
      surface.runtimeHealth().renderDiagnostics?.logicalVisible ?? true,
      "a restored background terminal must not start logically visible before its pane selects it; otherwise hidden output bypasses the replay path"
    )

    SurfaceRegistry.shared.setVisibleSurfaceIDs([id])

    XCTAssertTrue(
      surface.runtimeHealth().renderDiagnostics?.logicalVisible ?? false,
      "registry selection must be the transition that activates a restored terminal and its live renderer"
    )
  }
}
