import XCTest

@testable import CoreModel

final class SurfaceOutputBusGeometryContractTests: XCTestCase {
  func testGeometryOnlyFramesCarryEmptyBytesAndMonotonicSequence() {
    // WHY: an idle terminal can resize without producing PTY output. iOS
    // still needs a sequenced frame immediately so its grid stays aligned.
    let bus = SurfaceOutputBus(flushDelay: 60)
    let surfaceID = SurfaceID()
    var deliveries: [SurfaceOutputBus.OutputFrame] = []
    bus.sink = { deliveries.append($0) }

    bus.emitGeometry(surfaceID, rows: 24, cols: 80)
    bus.flushNow(surfaceID)
    bus.emitGeometry(surfaceID, rows: 40, cols: 120)
    bus.flushNow(surfaceID)

    XCTAssertEqual(
      deliveries,
      [
        SurfaceOutputBus.OutputFrame(
          surfaceID: surfaceID, sequence: 1, data: Data(), rows: 24, cols: 80),
        SurfaceOutputBus.OutputFrame(
          surfaceID: surfaceID, sequence: 2, data: Data(), rows: 40, cols: 120),
      ],
      "geometry-only mirror frames must use empty bytes and the same monotonic per-surface sequence as output"
    )
  }

  func testGeometryChangeCoalescesWithPendingOutput() {
    // WHY: a resize racing a PTY batch must publish one authoritative frame,
    // not an output frame with stale dimensions followed by corrective churn.
    let bus = SurfaceOutputBus(flushDelay: 60)
    let surfaceID = SurfaceID()
    var deliveries: [SurfaceOutputBus.OutputFrame] = []
    bus.sink = { deliveries.append($0) }

    bus.emit(surfaceID, Data("prompt".utf8), rows: 24, cols: 80)
    bus.emitGeometry(surfaceID, rows: 40, cols: 120)
    bus.flushNow(surfaceID)

    XCTAssertEqual(
      deliveries,
      [
        SurfaceOutputBus.OutputFrame(
          surfaceID: surfaceID,
          sequence: 1,
          data: Data("prompt".utf8),
          rows: 40,
          cols: 120)
      ],
      "pending output must coalesce with the newest terminal geometry"
    )
  }

  func testUnchangedGeometryDoesNotEmitDuplicateFrames() {
    // WHY: AppKit can report the same viewport repeatedly during layout.
    // Mirroring each report wastes bandwidth and advances sequence for no state change.
    let bus = SurfaceOutputBus(flushDelay: 60)
    let surfaceID = SurfaceID()
    var deliveries: [SurfaceOutputBus.OutputFrame] = []
    bus.sink = { deliveries.append($0) }

    bus.emitGeometry(surfaceID, rows: 24, cols: 80)
    bus.flushNow(surfaceID)
    bus.emitGeometry(surfaceID, rows: 24, cols: 80)
    bus.flushNow(surfaceID)

    XCTAssertEqual(
      deliveries,
      [
        SurfaceOutputBus.OutputFrame(
          surfaceID: surfaceID, sequence: 1, data: Data(), rows: 24, cols: 80)
      ],
      "unchanged terminal geometry must be deduplicated"
    )
  }

  func testRemoveClearsGeometryDeduplicationMetadata() {
    // WHY: surface IDs can be restored after teardown. Retaining the old
    // geometry would suppress the replacement surface's initial baseline.
    let bus = SurfaceOutputBus(flushDelay: 60)
    let surfaceID = SurfaceID()
    var deliveries: [SurfaceOutputBus.OutputFrame] = []
    bus.sink = { deliveries.append($0) }

    bus.emitGeometry(surfaceID, rows: 24, cols: 80)
    bus.flushNow(surfaceID)
    bus.remove(surfaceId: surfaceID)
    bus.emitGeometry(surfaceID, rows: 24, cols: 80)
    bus.flushNow(surfaceID)

    XCTAssertEqual(deliveries.count, 2)
    XCTAssertEqual(
      deliveries.map(\.sequence), [1, 1],
      "remove must reset sequence state for the replacement surface lifecycle")
    XCTAssertEqual(
      deliveries.map(\.rows), [24, 24],
      "remove must clear geometry metadata so an identical replacement baseline is emitted")
    XCTAssertEqual(deliveries.map(\.cols), [80, 80])
  }
}
