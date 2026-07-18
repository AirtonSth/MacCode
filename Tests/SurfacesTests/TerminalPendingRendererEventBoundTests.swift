import Foundation
import XCTest
@testable import Surfaces

@MainActor
final class TerminalPendingRendererEventBoundTests: XCTestCase {
    func test_100kResizeOnlyEventsTriggerBoundedPeriodicFlushes() {
        // WHY: resize events carry zero bytes. A byte-only cap allowed an idle,
        // continuously resized terminal to retain an unbounded event array.
        var eventCount = 1 // One pending byte makes subsequent resizes defer.
        var peakCount = eventCount
        var flushCount = 0

        for _ in 0..<100_000 {
            eventCount += 1
            peakCount = max(peakCount, eventCount)
            if TerminalSurface.pendingRendererBufferExceeded(
                byteCount: 1,
                eventCount: eventCount
            ) {
                flushCount += 1
                eventCount = 0
            }
        }

        XCTAssertGreaterThan(flushCount, 0, "resize-only pressure must force periodic renderer flushes")
        XCTAssertLessThanOrEqual(
            peakCount,
            TerminalSurface.maxPendingRendererEvents + 1,
            "the event array may cross the cap by only the event that triggers its immediate flush"
        )
    }

    func test_forcedResizeFlushPreservesEventOrderAndFinalRendererGeometry() {
        // WHY: bounding the queue must replay rather than drop/coalesce resizes;
        // intermediate widths can change terminal reflow semantics.
        let renderer = ANSIRenderer(rows: 24, cols: 80)
        var events: [TerminalSurface.PendingRendererEvent] = [
            .bytes(Data("renderer-bound-marker".utf8))
        ]
        var pendingByteCount = Data("renderer-bound-marker".utf8).count
        var flushCount = 0
        let resizeCount = TerminalSurface.maxPendingRendererEvents + 257

        for index in 0..<resizeCount {
            let rows = index.isMultiple(of: 2) ? 17 : 31
            let cols = index.isMultiple(of: 2) ? 71 : 113
            events.append(.resize(rows: rows, cols: cols))
            if TerminalSurface.pendingRendererBufferExceeded(
                byteCount: pendingByteCount,
                eventCount: events.count
            ) {
                TerminalSurface.replay(events, into: renderer)
                events.removeAll(keepingCapacity: true)
                pendingByteCount = 0
                flushCount += 1
            }
        }
        TerminalSurface.replay(events, into: renderer)

        XCTAssertEqual(flushCount, 1, "the first cap crossing must flush the complete ordered queue")
        XCTAssertEqual(renderer.rows, 17, "the final even resize must win after the forced flush")
        XCTAssertEqual(renderer.cols, 71, "the final even resize must win after the forced flush")
        XCTAssertTrue(
            renderer.snapshot().string.contains("renderer-bound-marker"),
            "forced flushing must preserve pending terminal bytes"
        )
    }
}
