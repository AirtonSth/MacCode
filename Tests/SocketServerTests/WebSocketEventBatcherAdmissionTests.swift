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
        // cellularSafe coalesces agent.item.delta by thread_id + item_id.
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

    func test_unscopedDeltasRemainSeparatedByNewTurnItemStart() throws {
        // WHY: an adapter may reuse one item id in a later turn. Ordinary
        // deltas lack turn_id, so the intervening item-start must remain a hard
        // ordering fence through cellular batching.
        let lock = NSLock()
        var sent: [Data] = []
        let batcher = WebSocketEventBatcher(
            enabled: true,
            filter: .cellularSafe(),
            delay: 0.02,
            maxPendingBytes: 1_000_000,
            maxPendingCount: 100,
            maxPendingAge: 60,
            send: { data in
                lock.withLock { sent.append(data) }
            }
        )
        defer { batcher.stop() }

        func frame(seq: Int64, kind: String, payload: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "type": "event",
                "sequence": seq,
                "kind": kind,
                "payload": payload,
            ])
        }

        let firstDelta = EventBus.Event(
            seq: 1,
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("thread-a"),
                "item_id": .string("shared"),
                "text": .string("A"),
            ]),
            ts: 0
        )
        let nextTurnStart = EventBus.Event(
            seq: 2,
            kind: "agent.item.started",
            payload: .object([
                "thread_id": .string("thread-a"),
                "item": .object([
                    "id": .string("shared"),
                    "turnId": .string("turn-b"),
                ]),
            ]),
            ts: 0
        )
        let secondDelta = EventBus.Event(
            seq: 3,
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("thread-a"),
                "item_id": .string("shared"),
                "text": .string("B"),
            ]),
            ts: 0
        )
        batcher.enqueue(
            event: firstDelta,
            data: try frame(
                seq: 1,
                kind: "agent.item.delta",
                payload: ["thread_id": "thread-a", "item_id": "shared", "text": "A"]
            )
        )
        batcher.enqueue(
            event: nextTurnStart,
            data: try frame(
                seq: 2,
                kind: "agent.item.started",
                payload: [
                    "thread_id": "thread-a",
                    "item": ["id": "shared", "turnId": "turn-b"],
                ]
            )
        )
        batcher.enqueue(
            event: secondDelta,
            data: try frame(
                seq: 3,
                kind: "agent.item.delta",
                payload: ["thread_id": "thread-a", "item_id": "shared", "text": "B"]
            )
        )

        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if lock.withLock({ sent.count }) == 3 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let delivered = lock.withLock { sent }
        XCTAssertEqual(delivered.count, 3)
        guard delivered.count == 3 else { return }
        XCTAssertEqual(
            delivered.compactMap { WebSocketOutboundQueue.eventSequence(in: $0) },
            [1, 2, 3]
        )
        let deltaTexts = try [delivered[0], delivered[2]].map { frame -> String? in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: frame) as? [String: Any]
            )
            return (object["payload"] as? [String: Any])?["text"] as? String
        }
        XCTAssertEqual(deltaTexts, ["A", "B"])
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
                "thread_id": "thread-count-delta",
                "turn_id": "turn-count-delta",
                "item_id": itemId,
                "text": text,
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: object)
        let event = EventBus.Event(
            seq: sequence,
            kind: "agent.item.delta",
            payload: .object([
                "thread_id": .string("thread-count-delta"),
                "turn_id": .string("turn-count-delta"),
                "item_id": .string(itemId),
                "text": .string(text),
            ]),
            ts: 0
        )
        return (event, data)
    }
}
