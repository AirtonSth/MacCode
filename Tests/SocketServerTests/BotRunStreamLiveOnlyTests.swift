import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// MOR-02: the host publishes one `bot.run.stream` per token of a Bot answer.
/// The kind carries no state (iOS treats it as a liveness tick), yet it was
/// handled as a durable state event: every token moved the `sync.snapshot`
/// fence (the phone's baseline failed -32012 for as long as a Bot streamed),
/// wrote an event-log row, and could not be shed from a saturated socket.
/// It must behave like the other live-only stream kinds. The terminal Bot
/// events stay durable and fence-breaking.
final class BotRunStreamLiveOnlyTests: XCTestCase {
    private func stream(_ bus: EventBus, _ index: Int) {
        bus.publish(kind: .botRunStream, payload: .object([
            "run_id": .string("run-1"), "chunk": .number(Double(index)),
        ]))
    }

    private func completed(_ bus: EventBus) {
        bus.publish(kind: .botRunCompleted, payload: .object(["run_id": .string("run-1")]))
    }

    func test_botRunStream_doesNotAdvanceTheSnapshotFence() {
        let bus = EventBus()
        bus.publish(kind: .surfaceCreated, payload: .object(["surface_id": .string("s-1")]))
        let before = bus.snapshotMetadata()

        for index in 0..<50 { stream(bus, index) }

        let during = bus.snapshotMetadata()
        XCTAssertEqual(during.sequence, before.sequence + 50, "the tokens are still sequenced and delivered")
        XCTAssertEqual(during.fenceRevision, before.fenceRevision,
                       "a streaming Bot must not make every sync.snapshot read retry and fail")
        XCTAssertEqual(during.stateRevision, before.stateRevision)

        completed(bus)
        XCTAssertGreaterThan(bus.snapshotMetadata().fenceRevision, before.fenceRevision,
                             "the run's terminal event is state and still fences a snapshot")
    }

    func test_botRunStream_isNotWrittenToTheEventLog_andNeedsNoAck() {
        let bus = EventBus()
        let log = FakeDurableEventLog()
        log.acknowledgeImmediately = false
        log.wire(bus)
        defer { FakeDurableEventLog.unwire(bus) }

        for index in 0..<5 { stream(bus, index) }

        let resume = bus.durableResumeState()
        XCTAssertNotNil(resume, "a token must not leave a durable write pending: the log would never be complete")
        XCTAssertEqual(resume?.lostStreams.isEmpty, true, "the kind has no replay stream, so it never produces a gap")

        completed(bus)
        XCTAssertNil(bus.durableResumeState(), "the terminal event is durable and waits for its write")
        log.acknowledgePending(bus)
        XCTAssertNotNil(bus.durableResumeState())
        XCTAssertEqual(
            log.page(after: 0, through: bus.currentSeq, limit: 100).events.map(\.kind),
            ["bot.run.completed"]
        )
    }

    func test_botRunStream_isShedBeforeStateUnderPressure() {
        let writerStarted = expectation(description: "writer blocked")
        let releaseWriter = DispatchSemaphore(value: 0)
        let written = WrittenKinds()
        let outbound = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1_024,
            applicationWriter: { data in
                if data == Data("block".utf8) {
                    writerStarted.fulfill()
                    _ = releaseWriter.wait(timeout: .now() + 2)
                } else if let kind = WebSocketOutboundQueue.eventKind(in: data) {
                    written.append(kind)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in },
            didSendTerminal: {}
        )
        XCTAssertEqual(outbound.enqueueApplication(Data("block".utf8)), .accepted)
        wait(for: [writerStarted], timeout: 2)

        XCTAssertEqual(outbound.enqueueEvent(frame(.botRunStream, sequence: 10)), .accepted)
        XCTAssertEqual(outbound.enqueueEvent(frame(.workspaceUpdated, sequence: 11)), .accepted)
        let outcome = outbound.degrade()

        XCTAssertEqual(outcome.droppedEventSequences, [10],
                       "under pressure the liveness tick goes first, so state keeps its place in the queue")
        releaseWriter.signal()
        outbound.finish()
        XCTAssertEqual(written.all, ["workspace.updated"])
    }

    private func frame(_ kind: RemoteCodeEventKind, sequence: Int64) -> KnownConnectionEventFrame {
        KnownConnectionEventFrame(
            event: EventBus.KnownEvent(
                seq: sequence,
                kind: kind,
                payload: ["run_id": .string("run-1"), "workspace_id": .string("w-1")],
                ts: 1_700_000_000 + Double(sequence)
            ),
            connectionId: "connection-1",
            hostId: "host-1",
            bootEpoch: 7
        )
    }

    private final class WrittenKinds: @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [String] = []

        func append(_ kind: String) {
            lock.lock(); kinds.append(kind); lock.unlock()
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return kinds
        }
    }
}
