import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// C20: the outbound byte budget must follow real link drain capacity, and a
/// single non-sheddable event must never be refused by an empty queue. A
/// refusal drops the event (filtered seq + `baseline_required`), so iOS loses
/// e.g. a large Claude tool_result `agent.item.started` until a full resync.
final class WebSocketOutboundQueueBudgetTests: XCTestCase {
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 1_000

        var now: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return value
        }

        func advance(_ seconds: TimeInterval) {
            lock.lock(); value += seconds; lock.unlock()
        }
    }

    private final class WrittenSizes: @unchecked Sendable {
        private let lock = NSLock()
        private var sizes: [Int] = []

        func append(_ size: Int) {
            lock.lock(); sizes.append(size); lock.unlock()
        }

        var all: [Int] {
            lock.lock(); defer { lock.unlock() }
            return sizes
        }
    }

    private static let oneMiB = 1_024 * 1_024
    private static let largePayloadBytes = 100 * 1_024

    /// Healthy fast link with a small event trickle (300 B every 100 ms). The
    /// idle gaps between writes are producer time, not drain time, so they must
    /// not shrink the budget to the 64 KiB floor: a brief burst of two large
    /// tool results has to fit while the first one is still being written.
    func testIdleTrickleOnFastLinkDoesNotShrinkBudgetToFloor() {
        let clock = FakeClock()
        let gate = WriterGate()
        let queue = makeQueue(clock: clock, onWrite: { data in
            gate.passIfBlocking(data)
        })

        for index in 0..<10 {
            XCTAssertEqual(queue.enqueueApplication(Data(repeating: UInt8(ascii: "a"), count: 300)), .accepted, "trickle \(index)")
            queue.finish()
            // Idle gap on both the injected and the wall clock, so no clock
            // source can make producer idle time look like drain time.
            clock.advance(0.1)
            Thread.sleep(forTimeInterval: 0.1)
        }

        XCTAssertEqual(
            queue.effectiveMaxQueuedBytes,
            Self.oneMiB,
            "a 3 KB/s production trickle is not the link's drain capacity"
        )

        gate.blockNextWrite()
        XCTAssertEqual(queue.enqueueApplication(Data("block".utf8)), .accepted)
        gate.waitUntilBlocked()
        XCTAssertEqual(queue.enqueueEvent(makeLargeItemStarted(sequence: 100)), .accepted)
        XCTAssertEqual(queue.enqueueEvent(makeLargeItemStarted(sequence: 101)), .accepted)
        gate.release()
        queue.finish()
    }

    /// Genuinely slow link (each write takes bytes / 2 KB/s): the
    /// budget legitimately drops to the 64 KiB floor, yet a single 100 KiB
    /// non-sheddable event on an empty queue is one frame, not backlog, and
    /// must still be admitted and written instead of being dropped.
    func testSingleLargeNonSheddableEventIsAdmittedOnEmptyQueueWhenBudgetIsAtFloor() {
        let clock = FakeClock()
        let gate = WriterGate()
        let written = WrittenSizes()
        let queue = makeQueue(clock: clock, onWrite: { data in
            gate.passIfBlocking(data)
            // Simulate a 2,000 B/s link: each write takes bytes / rate.
            clock.advance(Double(data.count) / 2_000)
            written.append(data.count)
        })

        for _ in 0..<10 {
            XCTAssertEqual(queue.enqueueApplication(Data(repeating: UInt8(ascii: "b"), count: 1_000)), .accepted)
            queue.finish()
        }

        XCTAssertEqual(queue.queuedByteCount, 0)
        XCTAssertEqual(
            queue.effectiveMaxQueuedBytes,
            WebSocketOutboundQueue.minimumQueuedBytes,
            "slow-link sizing must still clamp backlog to the floor"
        )

        let large = makeLargeItemStarted(sequence: 200)
        XCTAssertGreaterThan(large.encodedByteCount, WebSocketOutboundQueue.minimumQueuedBytes)
        XCTAssertEqual(queue.enqueueEvent(large), .accepted)
        queue.finish()
        XCTAssertEqual(written.all.last, large.encodedByteCount, "the large event must reach the client")

        // Backpressure is preserved: a second large frame behind a queued one
        // is still refused at the floor budget.
        gate.blockNextWrite()
        XCTAssertEqual(queue.enqueueEvent(makeLargeItemStarted(sequence: 201)), .accepted)
        gate.waitUntilBlocked()
        XCTAssertEqual(queue.enqueueEvent(makeLargeItemStarted(sequence: 202)), .queueFull)
        gate.release()
        queue.finish()
    }

    // MARK: - Helpers

    /// Blocks exactly one write (the next one) until released.
    private final class WriterGate: @unchecked Sendable {
        private let lock = NSLock()
        private var shouldBlock = false
        private let blocked = DispatchSemaphore(value: 0)
        private let releaseSignal = DispatchSemaphore(value: 0)

        func blockNextWrite() {
            lock.lock(); shouldBlock = true; lock.unlock()
        }

        func passIfBlocking(_ data: Data) {
            lock.lock()
            let block = shouldBlock
            shouldBlock = false
            lock.unlock()
            guard block else { return }
            blocked.signal()
            _ = releaseSignal.wait(timeout: .now() + 5)
        }

        func waitUntilBlocked() {
            XCTAssertEqual(blocked.wait(timeout: .now() + 5), .success)
        }

        func release() {
            releaseSignal.signal()
        }
    }

    private func makeQueue(
        clock: FakeClock,
        onWrite: @escaping @Sendable (Data) -> Void
    ) -> WebSocketOutboundQueue {
        WebSocketOutboundQueue(
            maxQueuedBytes: Self.oneMiB,
            applicationWriter: { data in
                onWrite(data)
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in },
            didSendTerminal: {},
            now: { clock.now }
        )
    }

    /// Claude tool_result items are published whole via `agent.item.started`.
    private func makeLargeItemStarted(sequence: Int64) -> KnownConnectionEventFrame {
        KnownConnectionEventFrame(
            event: EventBus.KnownEvent(
                seq: sequence,
                kind: .agentItemStarted,
                payload: [
                    "thread_id": .string("thread-1"),
                    "item": .object([
                        "id": .string("item-\(sequence)"),
                        "type": .string("tool_result"),
                        "output": .string(String(repeating: "x", count: Self.largePayloadBytes)),
                    ]),
                ],
                ts: 1_700_000_000 + Double(sequence)
            ),
            connectionId: "connection-1",
            hostId: "host-1",
            bootEpoch: 7
        )
    }
}
