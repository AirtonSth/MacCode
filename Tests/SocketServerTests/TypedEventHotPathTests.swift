import XCTest
import RemoteCodeTreaty
@testable import SocketServer

final class TypedEventHotPathTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var current: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Data?

        func store(_ data: Data) {
            lock.lock()
            value = data
            lock.unlock()
        }

        var current: Data? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testTypedDeltaIsTransformedThenSerializedExactlyOnce() throws {
        let encoded = expectation(description: "encoded once")
        let counter = Counter()
        let written = XCTestExpectation(description: "written")
        let writtenData = DataBox()

        let outbound = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1_024,
            applicationWriter: { data in
                writtenData.store(data)
                written.fulfill()
                return true
            },
            knownEventEncoder: { frame in
                counter.increment()
                encoded.fulfill()
                return try? frame.encoded()
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in },
            didSendTerminal: {}
        )

        let batcher = WebSocketEventBatcher(
            enabled: false,
            filter: .full,
            delay: 10,
            coalescesStreamingDeltas: true,
            sendKnownEvent: { frame in
                XCTAssertEqual(outbound.enqueueEvent(frame), .accepted)
            }
        )
        let first = makeDelta(sequence: 1, append: "A")
        let second = makeDelta(sequence: 2, append: "B")
        XCTAssertEqual(first.encodedByteCount, try first.encoded().count)
        XCTAssertEqual(second.encodedByteCount, try second.encoded().count)

        batcher.enqueue(first)
        batcher.enqueue(second)
        batcher.flush()
        wait(for: [encoded, written], timeout: 2)
        outbound.finish()

        XCTAssertEqual(counter.current, 1)
        let data = writtenData.current
        guard let data,
              case .event(let frame) = try ConnectionTransportFrame.decodeStrict(data),
              case .object(let payload) = frame.payload else {
            return XCTFail("expected one encoded event frame")
        }
        XCTAssertEqual(frame.sequence, 2)
        XCTAssertEqual(frame.kind, RemoteCodeEventKind.agentItemDelta.rawValue)
        XCTAssertEqual(payload["body_append"], .string("AB"))
        XCTAssertEqual(data.count, second.replacingPayload(payload).encodedByteCount)
    }

    func testTypedQueueDegradeCoalescesBeforeItsOnlyEncode() {
        let writerStarted = expectation(description: "writer blocked")
        let releaseWriter = DispatchSemaphore(value: 0)
        let counter = Counter()
        let outbound = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1_024,
            applicationWriter: { data in
                if data == Data("block".utf8) {
                    writerStarted.fulfill()
                    _ = releaseWriter.wait(timeout: .now() + 2)
                }
                return true
            },
            knownEventEncoder: { frame in
                counter.increment()
                return try? frame.encoded()
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in },
            didSendTerminal: {}
        )
        XCTAssertEqual(outbound.enqueueApplication(Data("block".utf8)), .accepted)
        wait(for: [writerStarted], timeout: 2)

        XCTAssertEqual(outbound.enqueueEvent(makeBrowser(sequence: 10, title: "old")), .accepted)
        XCTAssertEqual(outbound.enqueueEvent(makeBrowser(sequence: 11, title: "new")), .accepted)
        let outcome = outbound.degrade()
        XCTAssertEqual(outcome.coalescedAwayFrames, 1)
        XCTAssertEqual(outcome.droppedEventSequences, [10])
        XCTAssertEqual(counter.current, 0, "degrade must not pre-encode typed events")

        releaseWriter.signal()
        outbound.finish()
        XCTAssertEqual(counter.current, 1, "kept event must encode only at final write")
    }

    private func makeDelta(sequence: Int64, append: String) -> KnownConnectionEventFrame {
        KnownConnectionEventFrame(
            event: EventBus.KnownEvent(
                seq: sequence,
                kind: .agentItemDelta,
                payload: [
                    "thread_id": .string("thread-1"),
                    "item_id": .string("item-1"),
                    "turn_id": .string("turn-1"),
                    "body_append": .string(append),
                ],
                ts: 1_700_000_000 + Double(sequence)
            ),
            connectionId: "connection-1",
            hostId: "host-1",
            bootEpoch: 7
        )
    }

    private func makeBrowser(sequence: Int64, title: String) -> KnownConnectionEventFrame {
        KnownConnectionEventFrame(
            event: EventBus.KnownEvent(
                seq: sequence,
                kind: .surfaceBrowser,
                payload: [
                    "surface_id": .string("surface-1"),
                    "title": .string(title),
                ],
                ts: 1_700_000_000 + Double(sequence)
            ),
            connectionId: "connection-1",
            hostId: "host-1",
            bootEpoch: 7
        )
    }
}
