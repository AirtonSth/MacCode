import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// MOR-04 / MOR-08: a durable replay exists so a reconnecting phone gets the
/// events it missed instead of a full snapshot. The driver pushed the backlog
/// through the coalescing batcher but paced itself on the outbound queue only
/// after a whole 256 KiB slice. The batcher admits 512 frames, so a backlog
/// with a long run of `agent.item.delta` overflowed it, dropped everything
/// pending and forced the baseline the replay was meant to avoid; and a slice
/// larger than a slow link's 64 KiB budget hit `queueFull`. The batcher must
/// be flushed at every slice boundary, before the wait reads the queue.
final class DurableReplayBatcherBackpressureTests: XCTestCase {
    private func state(_ bus: EventBus, _ marker: String) {
        bus.publish(kind: .workspaceUpdated, payload: .object([
            "workspace_id": .string("w-1"), "name": .string(marker),
        ]))
    }

    private func delta(_ bus: EventBus, text: String) {
        bus.publish(kind: .agentItemDelta, payload: .object([
            "thread_id": .string("t-1"), "item_id": .string("i-1"), "delta": .string(text),
        ]))
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var accounted = Set<Int64>()
        private var overflowReasons: [String] = []

        func account(_ sequence: Int64) {
            lock.lock(); accounted.insert(sequence); lock.unlock()
        }

        func overflow(_ reason: String) {
            lock.lock(); overflowReasons.append(reason); lock.unlock()
        }

        var accountedSequences: Set<Int64> {
            lock.lock(); defer { lock.unlock() }
            return accounted
        }

        var overflows: [String] {
            lock.lock(); defer { lock.unlock() }
            return overflowReasons
        }
    }

    func test_driver_flushesTheBatcherBeforeEachSliceWait() {
        let bus = EventBus(recentLimit: 100)
        state(bus, "anchor")
        let cursor = bus.currentSeq
        for index in 1...6 { state(bus, "s\(index)") }
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        var log: [String] = []
        let driver = DurableReplayDriver(
            sliceBytes: 1,
            firstPage: nil,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { log.append("event \($0.seq)") },
            deliverFiltered: { log.append("filtered \($0)") },
            advanceWatermark: { log.append("advance \($0)") },
            isOpen: { true },
            waitForRoom: { _, _ in log.append("wait"); return .ready },
            sendGap: { _ in true },
            requireBaseline: { _ in XCTFail("no baseline expected") }
        )

        XCTAssertEqual(driver.run(subscription: subscription), .completed(eventsReplayed: 6, gapsSent: 0))

        let waits = log.indices.filter { log[$0] == "wait" }
        XCTAssertEqual(waits.count, 6)
        for index in waits {
            guard index >= 2, log[index - 2].hasPrefix("event ") else {
                return XCTFail("a wait must follow a delivered event: \(log)")
            }
            let sequence = log[index - 2].dropFirst("event ".count)
            XCTAssertEqual(
                log[index - 1],
                "advance \(sequence)",
                "the slice must leave the batcher before backpressure reads the outbound queue: \(log)"
            )
        }
    }

    func test_longDeltaBacklog_replaysThroughTheRealBatcherWithoutOverflow() {
        let bus = EventBus(recentLimit: 4_096)
        state(bus, "anchor")
        let cursor = bus.currentSeq
        for index in 0..<2_000 { delta(bus, text: "tok\(index)") }
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        XCTAssertEqual(subscription.plan.ringBacklog.count, 2_000, "the backlog must come from the ring")

        let recorder = Recorder()
        let batcher = WebSocketEventBatcher(
            enabled: false,
            filter: .full,
            coalescesStreamingDeltas: true,
            onCoalescedAway: { recorder.account($0) },
            onAdmissionOverflow: { _, reason in recorder.overflow(reason) },
            sendKnownEvent: { recorder.account($0.event.seq) }
        )
        defer { batcher.stop() }
        let driver = DurableReplayDriver(
            sliceBytes: DirectHTTPServer.durableReplaySliceBytes,
            firstPage: nil,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { event in
                guard let known = event.knownEvent else { return XCTFail("expected a typed event") }
                batcher.enqueue(KnownConnectionEventFrame(
                    event: known,
                    connectionId: "connection-1",
                    hostId: "host-1",
                    bootEpoch: 7
                ))
            },
            deliverFiltered: { recorder.account($0) },
            advanceWatermark: { _ in batcher.flush() },
            isOpen: { true },
            waitForRoom: { _, _ in .ready },
            sendGap: { _ in true },
            requireBaseline: { _ in XCTFail("no baseline expected") }
        )

        XCTAssertEqual(driver.run(subscription: subscription), .completed(eventsReplayed: 2_000, gapsSent: 0))
        batcher.flush()

        XCTAssertEqual(recorder.overflows, [],
                       "an overflow drops the pending tokens and turns the cheap replay into a full snapshot")
        XCTAssertEqual(recorder.accountedSequences, Set((cursor + 1)...(cursor + 2_000)),
                       "every replayed token is sent or merged into a sent frame")
    }

    /// The outbound queue budgets wire bytes, and every event frame carries an
    /// envelope (connection, host, boot epoch, event id) that the retained
    /// size does not count. A slice sized in retained bytes put about three
    /// times its size on the wire for small events; with the remainder the
    /// wait allows, that passed the bulk lane of a 64 KiB budget, hit
    /// `queueFull` and turned the replay into a full snapshot.
    func test_sliceOfSmallEvents_staysWithinTheSliceInWireBytes() {
        let bus = EventBus(recentLimit: 1_024)
        state(bus, "anchor")
        let cursor = bus.currentSeq
        for index in 0..<400 { state(bus, "s\(index)") }
        let subscription = bus.subscribeDurableReplay(since: cursor)
        defer { bus.unsubscribe(subscription.id) }
        XCTAssertEqual(subscription.plan.ringBacklog.count, 400, "the backlog must come from the ring")

        let sliceBytes = DirectHTTPServer.durableReplaySliceBytes
        var sliceWireBytes = 0
        var largestFrame = 0
        var slices: [Int] = []
        let driver = DurableReplayDriver(
            sliceBytes: sliceBytes,
            firstPage: nil,
            readPage: { bus.readDurableReplayPage(after: $0, through: $1, maxBytes: $2) },
            deliverEvent: { event in
                // The frame the socket queues, with production-sized ids.
                let frame = ConnectionEventFrame(
                    protocolVersion: ConnectionTransportFrame.protocolVersion,
                    type: "event",
                    connectionId: "5F0C1F0E-6A55-4B7B-9C39-0C6B7B1E2A11",
                    hostId: "9B2E7C44-1D0A-4E6F-8A3B-5D4C3B2A1F00",
                    bootEpoch: 1_760_000_000,
                    sequence: event.seq,
                    eventId: "1760000000:\(event.seq)",
                    occurredAtEpochMs: Int64(event.ts * 1_000),
                    kind: event.kind,
                    payload: event.payload
                )
                sliceWireBytes += frame.encodedByteCount
                largestFrame = max(largestFrame, frame.encodedByteCount)
            },
            deliverFiltered: { _ in },
            advanceWatermark: { _ in },
            isOpen: { true },
            waitForRoom: { _, _ in
                slices.append(sliceWireBytes)
                sliceWireBytes = 0
                return .ready
            },
            sendGap: { _ in true },
            requireBaseline: { _ in XCTFail("no baseline expected") }
        )

        XCTAssertEqual(driver.run(subscription: subscription), .completed(eventsReplayed: 400, gapsSent: 0))

        XCTAssertGreaterThan(slices.count, 1, "the backlog must span several slices")
        XCTAssertLessThanOrEqual(
            slices.max() ?? 0,
            sliceBytes + largestFrame,
            "a slice must be sized in the bytes the outbound queue counts: \(slices)"
        )
    }

    func test_goLive_checkpointsEveryBatchOfBufferedItems_andNeverAfterGoingLive() {
        let bus = EventBus()
        let subscription = bus.subscribeDurableReplay(since: bus.currentSeq)
        defer { bus.unsubscribe(subscription.id) }
        for index in 0..<300 { state(bus, "buffered-\(index)") }
        let lock = NSLock()
        var delivered = 0
        var checkpoints: [Int] = []

        let outcome = subscription.goLive(
            deliver: { _ in lock.lock(); delivered += 1; lock.unlock() },
            onOverflow: { _ in XCTFail("no overflow expected") },
            afterBufferedBatch: { lock.lock(); checkpoints.append(delivered); lock.unlock() }
        )

        XCTAssertEqual(outcome, .live)
        state(bus, "live-1")
        state(bus, "live-2")
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(delivered, 302)
        XCTAssertEqual(
            checkpoints,
            [128, 256],
            "a long live buffer is flushed in batches below the batcher bound, and never from the EventBus delivery queue"
        )
    }
}
