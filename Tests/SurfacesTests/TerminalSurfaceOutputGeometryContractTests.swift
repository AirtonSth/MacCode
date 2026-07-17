import XCTest

@testable import CoreModel
@testable import Surfaces

@MainActor
final class TerminalSurfaceOutputGeometryContractTests: XCTestCase {
  func testTerminalMainActorCapturesViewportForOutputBusDelivery() throws {
    // WHY: AppShell's output sink runs on the bus queue and must not reach
    // back into a MainActor-isolated TerminalSurface to discover geometry.
    // The terminal must capture rows/cols while handling its own output and
    // hand those scalar values to the bus with the bytes.
    let bus = SurfaceOutputBus(flushDelay: 60)
    let workspaceID = WorkspaceID()
    var deliveries: [SurfaceOutputBus.OutputFrame] = []
    bus.sink = { frame in
      deliveries.append(frame)
    }
    let terminal = try TerminalSurface(
      workspaceID: workspaceID,
      title: "Geometry capture",
      launch: .sshPlaceholder(cwd: NSTemporaryDirectory()),
      outputBus: bus
    )
    defer { terminal.close() }

    bus.flushNow(terminal.descriptor.id)

    let delivery = try XCTUnwrap(deliveries.last)
    let rows = try XCTUnwrap(delivery.rows)
    let cols = try XCTUnwrap(delivery.cols)
    XCTAssertEqual(delivery.surfaceID, terminal.descriptor.id)
    XCTAssertEqual(delivery.sequence, 1)
    XCTAssertEqual(rows, terminal.viewportSize.rows)
    XCTAssertEqual(cols, terminal.viewportSize.cols)
    XCTAssertGreaterThan(rows, 0)
    XCTAssertGreaterThan(cols, 0)
  }
}
