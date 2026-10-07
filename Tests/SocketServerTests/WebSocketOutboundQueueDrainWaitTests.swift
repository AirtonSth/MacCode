import XCTest
@testable import SocketServer

/// C8: a durable replay waits for the outbound queue to drain between 256 KiB
/// slices. It used to poll every 2 ms on a GCD worker for as long as a stalled
/// socket stayed open (60 s or more on cellular). The wait must wake on the
/// drain itself, end when the socket closes, and give up at its timeout so the
/// replay can fall back to a baseline.
final class WebSocketOutboundQueueDrainWaitTests: XCTestCase {
    private func blockedQueue() -> (WebSocketOutboundQueue, DispatchSemaphore) {
        let gate = DispatchSemaphore(value: 0)
        let queue = WebSocketOutboundQueue(
            maxQueuedBytes: 1 << 20,
            writer: { _ in gate.wait(); return true },
            onClose: { _ in }
        )
        XCTAssertEqual(queue.enqueueApplication(Data(repeating: 0x61, count: 4_096)), .accepted)
        return (queue, gate)
    }

    func test_waitForRoom_timesOut_whileTheSocketDoesNotDrain() {
        let (queue, gate) = blockedQueue()
        defer { gate.signal() }
        let started = Date()
        XCTAssertEqual(queue.waitForRoom(atMost: 1_024, timeout: 0.2), .timedOut)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)
    }

    func test_waitForRoom_wakesOnTheDrain() {
        let (queue, gate) = blockedQueue()
        let done = expectation(description: "room")
        var result: WebSocketOutboundQueue.RoomWait?
        var waited: TimeInterval = 0
        DispatchQueue.global().async {
            let started = Date()
            result = queue.waitForRoom(atMost: 1_024, timeout: 10)
            waited = Date().timeIntervalSince(started)
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(result, .room)
        XCTAssertLessThan(waited, 2, "woken by the drain, not by the 10 s timeout")
        XCTAssertEqual(queue.waitForRoom(atMost: 1_024, timeout: 0), .room, "already under the limit")
    }

    func test_waitForRoom_endsWhenTheSocketCloses() {
        let (queue, gate) = blockedQueue()
        defer { gate.signal() }
        let done = expectation(description: "closed")
        var result: WebSocketOutboundQueue.RoomWait?
        DispatchQueue.global().async {
            result = queue.waitForRoom(atMost: 1_024, timeout: 10)
            done.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.05)
        queue.close()
        wait(for: [done], timeout: 2)
        XCTAssertEqual(result, .closed)
    }
}
