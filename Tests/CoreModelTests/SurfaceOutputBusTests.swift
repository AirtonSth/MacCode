import XCTest
@testable import CoreModel

final class SurfaceOutputBusTests: XCTestCase {
    func testFlushNowDeliversPendingTerminalOutputSynchronouslyForHistoryRead() {
        let bus = SurfaceOutputBus()
        let surfaceID = SurfaceID()
        var chunks: [String] = []
        var seqs: [Int] = []

        bus.sink = { frame in
            guard frame.surfaceID == surfaceID else { return }
            seqs.append(frame.sequence)
            chunks.append(String(decoding: frame.data, as: UTF8.self))
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

        bus.sink = { frame in
            guard frame.surfaceID == surfaceID else { return }
            seqs.append(frame.sequence)
            chunks.append(String(decoding: frame.data, as: UTF8.self))
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
        bus.sink = { _ in }

        bus.emit(sid, Data("output".utf8))
        // pending is non-empty; seq starts at 0 until first flush
        bus.remove(surfaceId: sid)

        // After remove, currentSequence returns 0 (entry gone)
        let seqAfterRemove = bus.currentSequence(sid)
        XCTAssertEqual(seqAfterRemove, 0,
            "surfaceSeq entry must be removed after close; non-zero means the entry was retained (leak)")

        // A subsequent flush-now must be a no-op (nothing to flush)
        var flushed = false
        bus.sink = { frame in if frame.surfaceID == sid { flushed = true } }
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
        bus.sink = { _ in }

        bus.emit(closed, Data("a".utf8))
        bus.emit(live, Data("b".utf8))
        bus.flushNow(live)                      // advance live seq to 1

        bus.remove(surfaceId: closed)

        XCTAssertEqual(bus.currentSequence(live), 1,
            "remove for a closed surface must not disturb the seq of a live sibling surface")

        var liveDelivered = false
        bus.sink = { frame in if frame.surfaceID == live { liveDelivered = true } }
        bus.emit(live, Data("c".utf8))
        bus.flushNow(live)
        XCTAssertTrue(liveDelivered,
            "live surface must remain functional after an unrelated surface is removed")
    }

    func testRemove_waitsForActiveSinkBeforeReturning() {
        // WHY: surface.closed is published immediately after remove returns.
        // Returning while an output sink is still active can let late terminal
        // output recreate the closed surface in the iOS mirror.
        let bus = SurfaceOutputBus(flushDelay: 60)
        let sid = SurfaceID()
        let sinkEntered = DispatchSemaphore(value: 0)
        let releaseSink = DispatchSemaphore(value: 0)
        let flushFinished = DispatchSemaphore(value: 0)
        let removeStarted = DispatchSemaphore(value: 0)
        let removeFinished = DispatchSemaphore(value: 0)
        let events = LockedSurfaceOutputEvents()

        bus.sink = { frame in
            guard frame.surfaceID == sid else { return }
            sinkEntered.signal()
            releaseSink.wait()
            events.append("output")
        }
        bus.emit(sid, Data("last output".utf8))

        DispatchQueue.global().async {
            bus.flushNow(sid)
            flushFinished.signal()
        }
        XCTAssertEqual(sinkEntered.wait(timeout: .now() + 1), .success)

        DispatchQueue.global().async {
            removeStarted.signal()
            bus.remove(surfaceId: sid)
            events.append("remove-returned")
            removeFinished.signal()
        }
        XCTAssertEqual(removeStarted.wait(timeout: .now() + 1), .success)

        let prematureReturn = removeFinished.wait(timeout: .now() + 0.1)
        releaseSink.signal()

        XCTAssertEqual(
            prematureReturn,
            .timedOut,
            "remove must remain blocked until an active output sink finishes"
        )
        XCTAssertEqual(flushFinished.wait(timeout: .now() + 1), .success)
        if prematureReturn == .timedOut {
            XCTAssertEqual(removeFinished.wait(timeout: .now() + 1), .success)
        }
        XCTAssertEqual(
            events.snapshot(),
            ["output", "remove-returned"],
            "no output may complete after remove returns and surface.closed can be published"
        )

        bus.flushNow(sid)
        XCTAssertEqual(events.snapshot(), ["output", "remove-returned"])
    }

    func testRemove_fromActiveSinkIsReentrantAndDoesNotDeadlock() {
        // WHY: callers may revoke a surface from output-delivery code. The
        // synchronous barrier must execute inline when already on the bus queue.
        let bus = SurfaceOutputBus(flushDelay: 60)
        let sid = SurfaceID()
        let sinkFinished = expectation(description: "sink removes surface")

        bus.sink = { frame in
            guard frame.surfaceID == sid else { return }
            bus.remove(surfaceId: sid)
            sinkFinished.fulfill()
        }
        bus.emit(sid, Data("output".utf8))

        DispatchQueue.global().async {
            bus.flushNow(sid)
        }

        wait(for: [sinkFinished], timeout: 1)
        XCTAssertEqual(bus.currentSequence(sid), 0)
    }
}

private final class LockedSurfaceOutputEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}
