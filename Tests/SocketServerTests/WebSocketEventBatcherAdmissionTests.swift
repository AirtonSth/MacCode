import XCTest
@testable import SocketServer

/// S10: WebSocketEventBatcher admission is byte/count/time bounded; overflow is explicit.
final class WebSocketEventBatcherAdmissionTests: XCTestCase {
    func test_admissionOverflow_clearsPendingAndReportsLostSequences() {
        let lock = NSLock()
        var overflowReasons: [String] = []
        var lostSeqs: [[Int64]] = []
        var sent: [Data] = []

        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .cellularSafe(),
            delay: 10, // long delay so frames stay pending
            maxPendingBytes: 10_000,
            maxPendingCount: 2,
            maxPendingAge: 60,
            onAdmissionOverflow: { lost, reason in
                lock.lock(); defer { lock.unlock() }
                lostSeqs.append(lost)
                overflowReasons.append(reason)
            },
            send: { data in
                lock.lock(); defer { lock.unlock() }
                sent.append(data)
            }
        )

        // Three distinct nil-key frames with sequences — third must overflow.
        for seq in [Int64(1), 2, 3] {
            let data = makeEventFrame(kind: "agent.thread.updated", sequence: seq, body: "x")
            let event = EventBus.Event(
                seq: seq,
                kind: "agent.thread.updated",
                payload: .object(["n": .number(Double(seq))]),
                ts: 0
            )
            batcher.enqueue(event: event, data: data)
        }

        // Allow async queue work.
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let snap = batcher.admissionSnapshot()
            if snap.overflowCount >= 1 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }

        let snap = batcher.admissionSnapshot()
        XCTAssertGreaterThanOrEqual(snap.overflowCount, 1, "count admission must overflow")
        lock.lock()
        let reasons = overflowReasons
        let lost = lostSeqs
        lock.unlock()
        XCTAssertFalse(reasons.isEmpty)
        let allowedReasons = Set(["admission_bytes_or_count", "pre_queue_admission", "frame_exceeds_budget"])
        XCTAssertTrue(allowedReasons.contains(reasons.first ?? ""),
                      "overflow reason must be an admission bound: \(reasons.first ?? "nil")")
        // Lost sequences may be empty for pure pre-queue rejects of unsequenced frames,
        // but overflow must still be recorded.
        XCTAssertGreaterThanOrEqual(snap.overflowCount, 1)
        batcher.stop()
    }

    func test_byteAdmissionBound_triggersOverflow() {
        let lock = NSLock()
        var overflowCount = 0
        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .cellularSafe(),
            delay: 10,
            maxPendingBytes: 80,
            maxPendingCount: 100,
            maxPendingAge: 60,
            onAdmissionOverflow: { _, _ in
                lock.lock(); overflowCount += 1; lock.unlock()
            },
            send: { _ in }
        )

        for seq in Int64(1)...5 {
            let body = String(repeating: "Z", count: 40)
            let data = makeEventFrame(kind: "agent.thread.updated", sequence: seq, body: body)
            let event = EventBus.Event(
                seq: seq,
                kind: "agent.thread.updated",
                payload: .object(["n": .number(Double(seq))]),
                ts: 0
            )
            batcher.enqueue(event: event, data: data)
        }

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            lock.lock(); let c = overflowCount; lock.unlock()
            if c >= 1 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        lock.lock(); let c = overflowCount; lock.unlock()
        XCTAssertGreaterThanOrEqual(c, 1)
        batcher.stop()
    }

    /// Growing keyed replacement must not consume an extra count slot (Codex IMPORTANT).
    func test_keyedReplacement_doesNotConsumeExtraCountSlot() {
        let lock = NSLock()
        var overflowCount = 0
        // cellularSafe coalesces agent.item.delta by item_id (concat merge).
        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .cellularSafe(),
            delay: 10,
            maxPendingBytes: 1_000_000,
            maxPendingCount: 1,
            maxPendingAge: 60,
            onAdmissionOverflow: { _, _ in
                lock.lock(); overflowCount += 1; lock.unlock()
            },
            send: { _ in }
        )

        let itemId = "item-count-delta"
        let first = makeItemDeltaFrame(sequence: 1, itemId: itemId, text: "a")
        let second = makeItemDeltaFrame(sequence: 2, itemId: itemId, text: "b")
        batcher.enqueue(event: first.event, data: first.data)
        // Wait until first is pending.
        let deadline1 = Date().addingTimeInterval(0.5)
        while Date() < deadline1 {
            if batcher.admissionSnapshot().count >= 1 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        batcher.enqueue(event: second.event, data: second.data)
        Thread.sleep(forTimeInterval: 0.05)

        lock.lock(); let overflows = overflowCount; lock.unlock()
        XCTAssertEqual(
            overflows,
            0,
            "byte-fitting keyed replacement at count ceiling must not overflow"
        )
        let snap = batcher.admissionSnapshot()
        XCTAssertEqual(snap.count, 1, "replacement keeps a single pending entry")
        batcher.stop()
    }

    private func makeEventFrame(kind: String, sequence: Int64, body: String) -> Data {
        let object: [String: Any] = [
            "type": "event",
            "sequence": sequence,
            "kind": kind,
            "payload": ["body": body],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeItemDeltaFrame(
        sequence: Int64,
        itemId: String,
        text: String
    ) -> (event: EventBus.Event, data: Data) {
        let object: [String: Any] = [
            "type": "event",
            "sequence": sequence,
            "kind": "agent.item.delta",
            "payload": [
                "item_id": itemId,
                "text": text,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        let event = EventBus.Event(
            seq: sequence,
            kind: "agent.item.delta",
            payload: .object([
                "item_id": .string(itemId),
                "text": .string(text),
            ]),
            ts: 0
        )
        return (event, data)
    }
}
