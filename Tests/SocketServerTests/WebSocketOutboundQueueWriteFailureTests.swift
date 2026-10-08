import XCTest
import RemoteCodeTreaty
@testable import SocketServer

/// MHS-04 / MOR-06: a socket write can fail after part of a frame is on the
/// wire. The queue then wrote a closing text frame and a close frame on the
/// same fd. If the peer resumed reading, those bytes were spliced into the
/// truncated frame (iOS reads that as a terminal codec error), and each write
/// could block for another 60 s idle timeout, holding the fd, its thread and
/// its subscription for minutes. After a failed socket write nothing more
/// may be written: the fd is shut down at once.
final class WebSocketOutboundQueueWriteFailureTests: XCTestCase {
    private final class Recorded: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock(); values.append(value); lock.unlock()
        }

        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private func makeQueue(
        recorded: Recorded,
        applicationWriter: @escaping @Sendable (Data) -> Bool = { _ in true },
        knownEventEncoder: @escaping @Sendable (KnownConnectionEventFrame) -> Data? = { try? $0.encoded() },
        controlSucceeds: @escaping @Sendable (UInt8) -> Bool = { _ in true }
    ) -> WebSocketOutboundQueue {
        WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1_024,
            applicationWriter: { data in
                recorded.append("app:\(String(decoding: data, as: UTF8.self))")
                return applicationWriter(data)
            },
            knownEventEncoder: knownEventEncoder,
            controlWriter: { opcode, data in
                recorded.append("control:\(opcode):\(String(decoding: data, as: UTF8.self))")
                return controlSucceeds(opcode)
            },
            writeFailureClosingData: Data("write-failure".utf8),
            onTerminal: { reason in recorded.append("terminal:\(reason)") },
            didSendTerminal: { recorded.append("shutdown") }
        )
    }

    func test_failedApplicationWrite_shutsDownWithoutWritingAnotherByte() {
        let recorded = Recorded()
        let queue = makeQueue(recorded: recorded, applicationWriter: { _ in false })

        XCTAssertEqual(queue.enqueueApplication(Data("event".utf8)), .accepted)
        queue.finish()

        XCTAssertEqual(recorded.snapshot, ["app:event", "terminal:write_failed", "shutdown"],
                       "bytes written after a partial frame corrupt the stream the peer is still reading")
    }

    func test_failedControlWrite_shutsDownWithoutWritingAnotherByte() {
        let recorded = Recorded()
        let queue = makeQueue(recorded: recorded, controlSucceeds: { _ in false })

        XCTAssertEqual(queue.enqueueControl(opcode: 0xA, data: Data("pong".utf8)), .accepted)
        queue.finish()

        XCTAssertEqual(recorded.snapshot, ["control:10:pong", "terminal:write_failed", "shutdown"])
    }

    /// Nothing reached the wire here, so the stream is still frame-aligned and
    /// the client keeps its retry hint.
    func test_unencodableFrame_stillSendsClosingAndClose() {
        let recorded = Recorded()
        let queue = makeQueue(recorded: recorded, knownEventEncoder: { _ in nil })
        let frame = KnownConnectionEventFrame(
            event: EventBus.KnownEvent(
                seq: 1,
                kind: .workspaceUpdated,
                payload: ["workspace_id": .string("w-1")],
                ts: 0
            ),
            connectionId: "connection-1",
            hostId: "host-1",
            bootEpoch: 1
        )

        XCTAssertEqual(queue.enqueueEvent(frame), .accepted)
        queue.finish()

        XCTAssertEqual(recorded.snapshot, [
            "terminal:write_failed",
            "control:1:write-failure",
            "control:8:",
            "shutdown",
        ])
    }

    /// The heartbeat timeout queues its close behind the write that is stuck
    /// on the dead peer. When that write fails the socket must go down once,
    /// with no closing frames waiting on further idle timeouts.
    func test_queuedHeartbeatTerminate_behindAFailedWrite_shutsDownOnceAndWritesNothing() {
        let recorded = Recorded()
        let writeEntered = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let queue = makeQueue(recorded: recorded, applicationWriter: { _ in
            writeEntered.signal()
            _ = releaseWrite.wait(timeout: .now() + 5)
            return false
        })

        XCTAssertEqual(queue.enqueueApplication(Data("event".utf8)), .accepted)
        XCTAssertEqual(writeEntered.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(queue.terminate(
            errorData: nil,
            closingData: Data("closing".utf8),
            reason: "heartbeatTimeout"
        ))
        releaseWrite.signal()
        queue.finish()

        let frames = recorded.snapshot
        XCTAssertEqual(frames.filter { $0 == "shutdown" }.count, 1)
        XCTAssertTrue(frames.filter { $0.hasPrefix("control:") }.isEmpty,
                      "no closing frame may follow the failed write: \(frames)")
        XCTAssertEqual(frames.first, "app:event")
    }
}
