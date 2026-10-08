import XCTest
@testable import SocketServer

/// MHS-05: `terminate` runs on the heartbeat timer or the EventBus delivery
/// thread while the connection thread tears the socket down (`close()`,
/// `finish()`, then `close(fd)`). `terminate` used to reserve the terminal
/// state, release its lock, and only later submit the block that writes the
/// closing frames and shuts the fd down. A teardown in that window found an
/// empty queue, returned and closed the fd; the late block then wrote to and
/// shut down that fd number, which by then can belong to the reconnecting
/// device's new socket.
final class WebSocketOutboundQueueTerminateTeardownTests: XCTestCase {
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

    func test_terminatePreemptedBeforeItReturns_isFlushedByTeardown_beforeTheFDCloses() {
        let recorded = Recorded()
        let terminatePaused = DispatchSemaphore(value: 0)
        let resumeTerminate = DispatchSemaphore(value: 0)
        let queue = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1_024,
            applicationWriter: { _ in true },
            controlWriter: { opcode, data in
                recorded.append("control:\(opcode):\(String(decoding: data, as: UTF8.self))")
                return true
            },
            writeFailureClosingData: Data(),
            onTerminal: { _ in
                // The terminating thread is held here, after it reserved the
                // terminal state and before it returns.
                terminatePaused.signal()
                _ = resumeTerminate.wait(timeout: .now() + 5)
            },
            didSendTerminal: { recorded.append("shutdown") }
        )
        let terminated = expectation(description: "terminate returned")
        DispatchQueue.global().async {
            _ = queue.terminate(
                errorData: nil,
                closingData: Data("closing".utf8),
                reason: "heartbeatTimeout"
            )
            terminated.fulfill()
        }
        XCTAssertEqual(terminatePaused.wait(timeout: .now() + 2), .success)

        // The connection thread's teardown, as the /v1/ws handler runs it.
        queue.close()
        queue.finish()
        recorded.append("fd-closed")

        resumeTerminate.signal()
        wait(for: [terminated], timeout: 2)
        queue.finish()
        XCTAssertEqual(
            recorded.snapshot,
            ["control:1:closing", "control:8:", "shutdown", "fd-closed"],
            "the terminal block must have run before teardown closes the fd, never after"
        )
    }
}
