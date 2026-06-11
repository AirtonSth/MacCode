import XCTest
@testable import CoreModel

final class SurfaceOutputBusTests: XCTestCase {
    func testFlushNowDeliversPendingTerminalOutputSynchronouslyForHistoryRead() {
        let bus = SurfaceOutputBus()
        let surfaceID = SurfaceID()
        var chunks: [String] = []
        var seqs: [Int] = []

        bus.sink = { id, seq, data in
            guard id == surfaceID else { return }
            seqs.append(seq)
            chunks.append(String(decoding: data, as: UTF8.self))
        }

        bus.emit(surfaceID, Data("complete ".utf8))
        bus.emit(surfaceID, Data("history".utf8))
        bus.flushNow(surfaceID)

        XCTAssertEqual(chunks, ["complete history"],
                       "surface.read_history must be able to flush the current terminal batch before returning an authoritative snapshot")
        XCTAssertEqual(seqs, [1])
    }

    func testBurstTerminalOutputIsBatchedBeforeMirrorDelivery() {
        let bus = SurfaceOutputBus()
        let surfaceID = SurfaceID()
        let delivered = expectation(description: "batched terminal output delivered")
        var chunks: [String] = []
        var seqs: [Int] = []

        bus.sink = { id, seq, data in
            guard id == surfaceID else { return }
            seqs.append(seq)
            chunks.append(String(decoding: data, as: UTF8.self))
            delivered.fulfill()
        }

        bus.emit(surfaceID, Data("long ".utf8))
        bus.emit(surfaceID, Data("command ".utf8))
        bus.emit(surfaceID, Data("output".utf8))

        XCTAssertTrue(
            chunks.isEmpty,
            "Burst terminal output should not synchronously fan out one mirror event per PTY read; batching protects the Mac UI and iOS mirror during noisy commands."
        )
        wait(for: [delivered], timeout: 1.0)
        XCTAssertEqual(chunks, ["long command output"])
        XCTAssertEqual(seqs, [1],
                       "batched terminal output must publish one monotonic per-surface seq per delivered mirror chunk")
    }

    // MARK: - L16 remove(surfaceId:) leak prevention

    func testRemove_clearsSeqAndPendingForClosedSurface() {
        // WHY: surfaceSeq and pending grew unbounded before the remove API;
        // after a surface is closed its entries must be evicted so terminal
        // churn on long-running sessions does not leak memory.
        let bus = SurfaceOutputBus(flushDelay: 60) // long delay so pending stays
        let sid = SurfaceID()
        bus.sink = { _, _, _ in }

        bus.emit(sid, Data("output".utf8))
        // pending is non-empty; seq starts at 0 until first flush
        bus.remove(surfaceId: sid)

        // After remove, currentSequence returns 0 (entry gone)
        let seqAfterRemove = bus.currentSequence(sid)
        XCTAssertEqual(seqAfterRemove, 0,
            "surfaceSeq entry must be removed after close; non-zero means the entry was retained (leak)")

        // A subsequent flush-now must be a no-op (nothing to flush)
        var flushed = false
        bus.sink = { id, _, _ in if id == sid { flushed = true } }
        bus.flushNow(sid)
        XCTAssertFalse(flushed,
            "pending entry must be removed after close; flush must find nothing to deliver")
    }

    func testRemove_absentId_isNoOp() {
        // WHY: idempotency required; teardown paths may call remove more than
        // once or on a surface that was never used with the bus.
        let bus = SurfaceOutputBus()
        let absent = SurfaceID()
        // Must not crash or corrupt state
        bus.remove(surfaceId: absent)
        XCTAssertEqual(bus.currentSequence(absent), 0,
            "remove on absent id must leave seq at 0 and must not crash")
    }

    func testRemove_doesNotAffectUnrelatedSurface() {
        // WHY: the remove must be scoped to exactly the closed surface;
        // a broader wipe would silently drop output for live siblings.
        let bus = SurfaceOutputBus(flushDelay: 60)
        let closed = SurfaceID()
        let live = SurfaceID()
        bus.sink = { _, _, _ in }

        bus.emit(closed, Data("a".utf8))
        bus.emit(live, Data("b".utf8))
        bus.flushNow(live)                      // advance live seq to 1

        bus.remove(surfaceId: closed)

        XCTAssertEqual(bus.currentSequence(live), 1,
            "remove for a closed surface must not disturb the seq of a live sibling surface")

        var liveDelivered = false
        bus.sink = { id, _, _ in if id == live { liveDelivered = true } }
        bus.emit(live, Data("c".utf8))
        bus.flushNow(live)
        XCTAssertTrue(liveDelivered,
            "live surface must remain functional after an unrelated surface is removed")
    }
}
