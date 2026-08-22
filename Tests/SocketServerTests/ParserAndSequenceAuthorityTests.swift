import XCTest
@testable import SocketServer

/// Deterministic contracts for the macOS invariant
/// “Preservar semântica do parser e sequência autoritativa”.
///
/// Covers only gaps not already locked by `RFC6455MaskingTests`,
/// `ConnectionSnapshotPhase3Tests`, `EventBusOrderingTests`, or
/// `HTTPServerTests` outbound-owner suites.
final class ParserAndSequenceAuthorityTests: XCTestCase {

    // MARK: - Frame helpers

    /// Build a masked client frame with optional RSV bits (RFC6455 s5.2).
    private func makeClientFrame(
        fin: Bool,
        rsv: UInt8 = 0,
        opcode: UInt8,
        payload: [UInt8],
        maskKey: [UInt8]? = [0x37, 0xFA, 0x21, 0x3D]
    ) -> [UInt8] {
        var frame: [UInt8] = []
        frame.append((fin ? 0x80 : 0x00) | ((rsv & 0x07) << 4) | (opcode & 0x0F))
        let len = payload.count
        let maskedBit: UInt8 = (maskKey != nil) ? 0x80 : 0x00
        if len < 126 {
            frame.append(maskedBit | UInt8(len))
        } else if len <= 0xFFFF {
            frame.append(maskedBit | 126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(maskedBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((len >> shift) & 0xFF))
            }
        }
        if let key = maskKey {
            frame.append(contentsOf: key)
            frame.append(contentsOf: payload.enumerated().map { i, b in b ^ key[i & 3] })
        } else {
            frame.append(contentsOf: payload)
        }
        return frame
    }

    private func makeCloseFrame(code: UInt16?, reason: [UInt8] = []) -> [UInt8] {
        var payload: [UInt8] = []
        if let code {
            payload.append(UInt8((code >> 8) & 0xFF))
            payload.append(UInt8(code & 0xFF))
            payload.append(contentsOf: reason)
        }
        return makeClientFrame(fin: true, opcode: 0x8, payload: payload)
    }

    private func drain(
        _ assembler: inout WebSocketClientFrameAssembler,
        buf: [UInt8]
    ) -> [WebSocketClientFrameAssembler.Event] {
        var events: [WebSocketClientFrameAssembler.Event] = []
        var offset = 0
        while offset < buf.count {
            let (event, consumed) = assembler.consume(buf: buf, from: offset)
            events.append(event)
            switch event {
            case .needMore:
                return events
            case .mustClose, .peerClose:
                offset += consumed
                return events
            case .fragmentProgress, .text, .binary, .ping, .pong:
                offset += consumed
            }
        }
        return events
    }

    private func eventJSON(
        seq: Int64,
        kind: String,
        payload: [String: Any] = [:]
    ) throws -> Data {
        let object: [String: Any] = [
            "type": "event",
            "sequence": seq,
            "kind": kind,
            "payload": payload,
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - Fragmented data (missing vs RFC6455MaskingTests)

    func test_fragmentedBinary_reassemblesAcrossContinuations() {
        // WHY: Binary is the wire path for compressed / opaque payloads.
        // Text-only fragment tests leave a hole where a regression could
        // reassemble text but drop binary continuations.
        let part1: [UInt8] = [0x00, 0x01, 0x02]
        let part2: [UInt8] = [0xFE, 0xFF]
        let buf =
            makeClientFrame(fin: false, opcode: 0x2, payload: part1)
            + makeClientFrame(fin: true, opcode: 0x0, payload: part2)

        var assembler = WebSocketClientFrameAssembler()
        let events = drain(&assembler, buf: buf)

        XCTAssertEqual(events.count, 2)
        guard case .fragmentProgress = events[0] else {
            return XCTFail("first event must be fragmentProgress, got \(events[0])")
        }
        guard case .binary(let data) = events[1] else {
            return XCTFail("completed binary must surface as .binary, got \(events[1])")
        }
        XCTAssertEqual([UInt8](data), part1 + part2)
        XCTAssertFalse(assembler.isFragmenting)
    }

    func test_threePartFragmentedText_reassemblesInOrder() {
        // WHY: Two-fragment tests miss mid-stream continuations (FIN=0 opcode 0).
        // A three-part message proves intermediate continuation keeps the open
        // fragment and only FIN=1 completes the text message.
        let buf =
            makeClientFrame(fin: false, opcode: 0x1, payload: Array("aa".utf8))
            + makeClientFrame(fin: false, opcode: 0x0, payload: Array("bb".utf8))
            + makeClientFrame(fin: true, opcode: 0x0, payload: Array("cc".utf8))

        var assembler = WebSocketClientFrameAssembler()
        let events = drain(&assembler, buf: buf)

        XCTAssertEqual(events.count, 3)
        guard case .fragmentProgress = events[0],
              case .fragmentProgress = events[1],
              case .text(let data) = events[2] else {
            return XCTFail("expected progress, progress, text; got \(events)")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "aabbcc")
    }

    func test_interleavedPongDuringBinaryFragmentation_doesNotAbortMessage() {
        // WHY: Ping interleave is covered; pong (and any control) must also be
        // allowed mid-fragment without resetting the binary reassembly buffer.
        let part1: [UInt8] = [0x10, 0x20]
        let part2: [UInt8] = [0x30]
        let pongPayload: [UInt8] = [0xAA]
        let buf =
            makeClientFrame(fin: false, opcode: 0x2, payload: part1)
            + makeClientFrame(fin: true, opcode: 0xA, payload: pongPayload)
            + makeClientFrame(fin: true, opcode: 0x0, payload: part2)

        var assembler = WebSocketClientFrameAssembler()
        let events = drain(&assembler, buf: buf)

        XCTAssertEqual(events.count, 3)
        guard case .fragmentProgress = events[0] else {
            return XCTFail("expected fragmentProgress, got \(events[0])")
        }
        guard case .pong(let pong) = events[1] else {
            return XCTFail("expected interleaved pong, got \(events[1])")
        }
        XCTAssertEqual([UInt8](pong), pongPayload)
        guard case .binary(let data) = events[2] else {
            return XCTFail("expected completed binary after pong, got \(events[2])")
        }
        XCTAssertEqual([UInt8](data), part1 + part2)
    }

    // MARK: - Invalid order / opcode / RSV / control

    func test_continuationWithoutOpenFragment_mustClose1002() {
        // WHY: A lone continuation is a protocol error (RFC6455 s5.4). Accepting
        // it would fabricate a data message from a dangling fragment and break
        // the authoritative client→host stream.
        let buf = makeClientFrame(fin: true, opcode: 0x0, payload: Array("x".utf8))
        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: buf, from: 0)
        XCTAssertGreaterThan(consumed, 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("orphan continuation must mustClose, got \(event)")
        }
        XCTAssertEqual(code, WebSocketClientFrameAssembler.invalidCloseCode)
        XCTAssertEqual(code, 1002)
    }

    func test_newDataOpcodeWhileFragmenting_mustClose1002() {
        // WHY: Starting a second data message before FIN of the first violates
        // continuation ordering. Silent accept would interleave two logical
        // messages into one reassembly buffer.
        let buf =
            makeClientFrame(fin: false, opcode: 0x1, payload: Array("ab".utf8))
            + makeClientFrame(fin: true, opcode: 0x1, payload: Array("cd".utf8))

        var assembler = WebSocketClientFrameAssembler()
        let (e1, c1) = assembler.consume(buf: buf, from: 0)
        guard case .fragmentProgress = e1 else {
            return XCTFail("first fragment must be accepted, got \(e1)")
        }
        let (e2, c2) = assembler.consume(buf: buf, from: c1)
        XCTAssertGreaterThan(c2, 0)
        guard case .mustClose(let code) = e2 else {
            return XCTFail("overlapping data message must mustClose, got \(e2)")
        }
        XCTAssertEqual(code, 1002)
    }

    func test_rsvBitsNonZero_mustClose1002() {
        // WHY: No extension is negotiated; any RSV bit must close with 1002
        // (RFC6455 s5.2) so a peer cannot smuggle extension state into the host.
        for rsv: UInt8 in [0b001, 0b010, 0b100, 0b111] {
            let buf = makeClientFrame(
                fin: true, rsv: rsv, opcode: 0x1, payload: Array("ok".utf8)
            )
            var assembler = WebSocketClientFrameAssembler()
            let (event, consumed) = assembler.consume(buf: buf, from: 0)
            XCTAssertGreaterThan(consumed, 0, "rsv=\(rsv)")
            guard case .mustClose(let code) = event else {
                return XCTFail("rsv=\(rsv) must mustClose, got \(event)")
            }
            XCTAssertEqual(code, 1002, "rsv=\(rsv)")
        }
    }

    func test_fragmentedControlFrame_mustClose1002() {
        // WHY: Control frames must not be fragmented (RFC6455 s5.5). A FIN=0
        // ping would otherwise hang the receive loop waiting for a control
        // continuation that the protocol forbids.
        let buf = makeClientFrame(fin: false, opcode: 0x9, payload: [0x01])
        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: buf, from: 0)
        XCTAssertGreaterThan(consumed, 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("fragmented control must mustClose, got \(event)")
        }
        XCTAssertEqual(code, 1002)
    }

    func test_controlPayloadOver125_mustClose1002() {
        // WHY: Control payload max is 125 bytes. Oversized control must fail
        // closed rather than allocate or treat as application data.
        let payload = [UInt8](repeating: 0x41, count: 126)
        let buf = makeClientFrame(fin: true, opcode: 0x9, payload: payload)
        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: buf, from: 0)
        XCTAssertGreaterThan(consumed, 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("control >125 must mustClose, got \(event)")
        }
        XCTAssertEqual(code, 1002)
    }

    func test_unknownDataOpcode_mustClose1002() {
        // WHY: Reserved data opcodes (3–7) and reserved control (B–F) are
        // protocol errors. Accepting them would let a peer inject untyped
        // frames into the reassembly state machine.
        for opcode: UInt8 in [0x3, 0x7, 0xB, 0xF] {
            let buf = makeClientFrame(fin: true, opcode: opcode, payload: [0x00])
            var assembler = WebSocketClientFrameAssembler()
            let (event, _) = assembler.consume(buf: buf, from: 0)
            guard case .mustClose(let code) = event else {
                return XCTFail("opcode \(opcode) must mustClose, got \(event)")
            }
            XCTAssertEqual(code, 1002, "opcode \(opcode)")
        }
    }

    func test_singleFrameOverOneMib_mustClose1009() {
        // WHY: Aggregate overflow is covered for multi-fragment; a single FIN=1
        // frame above the 1 MiB contract must also reject with 1009 without
        // allocating the payload body.
        let over = WebSocketClientFrameAssembler.maxFragmentedMessageBytes + 1
        // Header-only path: 64-bit length field claims oversize.
        var oversize: [UInt8] = [
            0x82, // FIN + binary
            0xFF, // MASK + 127 (64-bit length)
        ]
        // big-endian UInt64 length = over
        var wide = UInt64(over)
        var lengthBytes = [UInt8](repeating: 0, count: 8)
        for i in stride(from: 7, through: 0, by: -1) {
            lengthBytes[i] = UInt8(wide & 0xFF)
            wide >>= 8
        }
        oversize += lengthBytes
        // Mask key present so the reject path is evaluated after header parse.
        oversize += [0x01, 0x02, 0x03, 0x04]

        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: oversize, from: 0)
        XCTAssertGreaterThan(consumed, 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("single-frame oversize must mustClose, got \(event)")
        }
        XCTAssertEqual(code, WebSocketClientFrameAssembler.tooLargeCloseCode)
        XCTAssertEqual(code, 1009)
    }

    // MARK: - Close / UTF-8 edge contracts

    func test_emptyClosePayload_isPeerCloseWithoutCode() {
        // WHY: Empty close payload is legal (RFC6455 s5.5.1). Host teardown
        // must treat it as peerClose, not invent a status code.
        let buf = makeCloseFrame(code: nil)
        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: buf, from: 0)
        XCTAssertGreaterThan(consumed, 0)
        guard case .peerClose(let code, let reason) = event else {
            return XCTFail("empty close must be peerClose, got \(event)")
        }
        XCTAssertNil(code)
        XCTAssertTrue(reason.isEmpty)
    }

    func test_singleByteClosePayload_mustClose1002() {
        // WHY: A one-byte close body is illegal (RFC6455 s5.5.1). Protocol
        // error close is 1002 so session teardown never observes a half status.
        let buf = makeClientFrame(fin: true, opcode: 0x8, payload: [0x03])
        var assembler = WebSocketClientFrameAssembler()
        let (event, _) = assembler.consume(buf: buf, from: 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("single-byte close must mustClose, got \(event)")
        }
        XCTAssertEqual(code, 1002)
    }

    func test_closeReasonInvalidUTF8_mustClose1007() {
        // WHY: Close reason, like text frames, must be valid UTF-8. Invalid
        // reason must close with 1007 (not 1002) so clients can distinguish
        // encoding faults from protocol faults.
        let badReason: [UInt8] = [0xC3, 0x28]
        let buf = makeCloseFrame(code: 1000, reason: badReason)
        var assembler = WebSocketClientFrameAssembler()
        let (event, _) = assembler.consume(buf: buf, from: 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("invalid close reason UTF-8 must mustClose, got \(event)")
        }
        XCTAssertEqual(code, WebSocketClientFrameAssembler.invalidUtf8CloseCode)
        XCTAssertEqual(code, 1007)
    }

    func test_fragmentedTextCompletingWithInvalidUTF8_mustClose1007() {
        // WHY: UTF-8 is validated only when the message completes. A valid
        // first fragment plus an invalid final continuation must not emit
        // partial text to JSON-RPC.
        let buf =
            makeClientFrame(fin: false, opcode: 0x1, payload: [0x41])
            + makeClientFrame(fin: true, opcode: 0x0, payload: [0xC3, 0x28])

        var assembler = WebSocketClientFrameAssembler()
        let (e1, c1) = assembler.consume(buf: buf, from: 0)
        guard case .fragmentProgress = e1 else {
            return XCTFail("first fragment must progress, got \(e1)")
        }
        let (e2, _) = assembler.consume(buf: buf, from: c1)
        guard case .mustClose(let code) = e2 else {
            return XCTFail("completed invalid UTF-8 text must mustClose, got \(e2)")
        }
        XCTAssertEqual(code, 1007)
        XCTAssertFalse(assembler.isFragmenting)
    }

    // MARK: - Sequence authority (EventBus + connection watermark fences)

    func test_eventBus_publishAllocatesStrictlyMonotonicSequences() {
        // WHY: EventBus is the single sequence authority for the host. Publish
        // must allocate 1,2,3… with no gaps/duplicates so connection watermarks
        // and iOS reducers share one total order.
        let bus = EventBus()
        var seen: [Int64] = []
        _ = bus.subscribe(since: nil) { seen.append($0.seq) }

        for i in 0..<5 {
            bus.publish(kind: "k.\(i)", payload: .null)
        }

        XCTAssertEqual(seen, [1, 2, 3, 4, 5])
        XCTAssertEqual(bus.currentSeq, 5)
        XCTAssertEqual(bus.snapshot().lastSeq, 5)
    }

    func test_eventBus_commitPersistedEventsSharesAuthorityWithPublish() throws {
        // WHY: Receipt commits and live publish must share one counter. A
        // second authority would let HTTP mutation receipts race ahead of WS
        // events and create false gaps on the client.
        let bus = EventBus()
        bus.publish(kind: "live", payload: .null) // seq 1

        let committed = try bus.commitPersistedEvents { floor in
            XCTAssertEqual(floor, 1, "commit floor is the publish watermark")
            return [
                EventBus.Event(seq: floor + 1, kind: "receipt", payload: .null, ts: 0),
                EventBus.Event(seq: floor + 2, kind: "receipt", payload: .null, ts: 0),
            ]
        }
        XCTAssertEqual(committed.map(\.seq), [2, 3])
        XCTAssertEqual(bus.currentSeq, 3)

        bus.publish(kind: "after", payload: .null)
        XCTAssertEqual(bus.currentSeq, 4,
                       "publish after commit must continue the same monotonic counter")
    }

    func test_connectionWatermark_beginSnapshotIsSingleFlightFence() {
        // WHY: Two concurrent snapshot adoptions on one connection would race
        // pending/filtered sets. beginSnapshot must refuse a second in-flight
        // snapshot so adoption remains a single fence. HTTPServer maps the
        // collision to -32602 + data.reason=snapshot_reservation_held so clients
        // wait out the transfer-cache lease instead of thrashing begin.
        let watermark = ConnectionSequenceWatermark(initialSequence: 0)
        XCTAssertTrue(watermark.beginSnapshot())
        XCTAssertFalse(watermark.beginSnapshot(),
                       "second beginSnapshot while in flight must fail closed")
        XCTAssertEqual(watermark.adoptSnapshot(sequence: 0), .adopted(sequence: 0))
        XCTAssertTrue(watermark.beginSnapshot(),
                      "after adoption a new snapshot may begin")
    }

    func test_connectionWatermark_monotonicAdvanceThenLoudGap() {
        // WHY: Outside snapshot buffering, the watermark must advance only on
        // contiguous seq and fail loud on holes — that gap is how clients are
        // forced to baseline instead of applying out-of-order state.
        let watermark = ConnectionSequenceWatermark(initialSequence: 0)
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 1), .advanced)
        XCTAssertEqual(watermark.recordEnqueuedEvent(sequence: 2), .advanced)
        XCTAssertEqual(
            watermark.recordEnqueuedEvent(sequence: 4),
            .gap(expected: 3, received: 4)
        )
        XCTAssertEqual(watermark.value, 2,
                       "a gap must not advance the connection watermark")
    }

    // MARK: - Coalescing fences (outbound degrade pure contracts)

    func test_coalesceApplicationFrames_lwwSummaryAndConcatDeltaPreserveNonKeyedOrder() throws {
        // WHY: Degrade LWW for surface summaries is safe (geometry/counts) but
        // agent.item.delta must concatenate or tokens disappear. Non-keyed
        // frames must keep arrival order so critical lifecycle events stay fenced.
        let s1 = try eventJSON(seq: 1, kind: "surface.output.summary",
                               payload: ["surface_id": "s1", "v": 1])
        let critical = try eventJSON(seq: 2, kind: "agent.run.completed",
                                     payload: ["thread_id": "t"])
        let s2 = try eventJSON(seq: 3, kind: "surface.output.summary",
                               payload: ["surface_id": "s1", "v": 2])
        let d1 = try eventJSON(seq: 4, kind: "agent.item.delta",
                               payload: ["thread_id": "t", "item_id": "i1", "text": "Hel"])
        let d2 = try eventJSON(seq: 5, kind: "agent.item.delta",
                               payload: ["thread_id": "t", "item_id": "i1", "text": "lo"])

        let coalesced = WebSocketOutboundQueue.coalesceApplicationFrames(
            [s1, critical, s2, d1, d2]
        )

        XCTAssertEqual(coalesced.count, 3,
                       "two summaries LWW to one; two deltas merge; critical kept")
        XCTAssertEqual(WebSocketOutboundQueue.eventKind(in: coalesced[0]),
                       "surface.output.summary")
        XCTAssertEqual(WebSocketOutboundQueue.eventSequence(in: coalesced[0]), 3,
                       "LWW keeps the later summary sequence")
        XCTAssertEqual(WebSocketOutboundQueue.eventKind(in: coalesced[1]),
                       "agent.run.completed")
        XCTAssertEqual(WebSocketOutboundQueue.eventSequence(in: coalesced[1]), 2,
                       "non-keyed critical must not move relative to surrounding keys' slots")
        XCTAssertEqual(WebSocketOutboundQueue.eventKind(in: coalesced[2]),
                       "agent.item.delta")

        // Merged delta payload must retain both text chunks (concat, not LWW).
        let mergedObject = try JSONSerialization.jsonObject(with: coalesced[2]) as? [String: Any]
        let payload = mergedObject?["payload"] as? [String: Any]
        let text = payload?["text"] as? String
        XCTAssertEqual(text, "Hello",
                       "delta coalesce must concatenate append fields, not last-write-wins")
    }

    func test_coalesceApplicationFrames_agentDeltaUsesThreadItemTupleAndMonotonicReceipt() throws {
        // WHY: provider item IDs can repeat across threads, while a trusted
        // distill_applied bit must survive later nil/false append frames.
        let trustedA = try eventJSON(
            seq: 1,
            kind: "agent.item.delta",
            payload: [
                "thread_id": "thread-a",
                "item_id": "shared",
                "text": "A",
                "distill_applied": true,
            ]
        )
        let threadB = try eventJSON(
            seq: 2,
            kind: "agent.item.delta",
            payload: [
                "thread_id": "thread-b",
                "item_id": "shared",
                "text": "X",
                "distill_applied": false,
            ]
        )
        let laterA = try eventJSON(
            seq: 3,
            kind: "agent.item.delta",
            payload: [
                "thread_id": "thread-a",
                "item_id": "shared",
                "text": "B",
                "distill_applied": false,
            ]
        )
        let legacyWithoutThread = try eventJSON(
            seq: 4,
            kind: "agent.item.delta",
            payload: ["item_id": "shared", "text": "legacy"]
        )

        let frames = WebSocketOutboundQueue.coalesceApplicationFrames([
            trustedA,
            threadB,
            laterA,
            legacyWithoutThread,
        ])

        XCTAssertEqual(frames.count, 3,
                       "only deltas sharing both thread_id and item_id may coalesce")
        let payloads = try frames.map { frame -> [String: Any] in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: frame) as? [String: Any]
            )
            return try XCTUnwrap(object["payload"] as? [String: Any])
        }
        XCTAssertEqual(payloads[0]["thread_id"] as? String, "thread-a")
        XCTAssertEqual(payloads[0]["text"] as? String, "AB")
        XCTAssertEqual(payloads[0]["distill_applied"] as? Bool, true,
                       "false from a later delta must not erase trusted true")
        XCTAssertEqual(payloads[1]["thread_id"] as? String, "thread-b")
        XCTAssertEqual(payloads[1]["text"] as? String, "X")
        XCTAssertNil(payloads[2]["thread_id"],
                     "legacy frames without thread identity stay independently deliverable")
        XCTAssertEqual(payloads[2]["text"] as? String, "legacy")
    }

    func test_coalesceApplicationFrames_keepsTurnScopedDistillTruthSeparateFromReusedItemID() throws {
        // WHY: a provider may reuse an item id in another turn. The host-only
        // attestation must remain its own turn-scoped reducer frame instead of
        // being OR-carried onto ordinary or later-turn content.
        let trusted = try eventJSON(
            seq: 1,
            kind: "agent.item.delta",
            payload: [
                "thread_id": "thread-a",
                "turn_id": "turn-a",
                "item_id": "shared",
                "distill_applied": true,
            ]
        )
        let ordinary = try eventJSON(
            seq: 2,
            kind: "agent.item.delta",
            payload: [
                "thread_id": "thread-a",
                "item_id": "shared",
                "text": "new turn content",
            ]
        )
        let otherTurn = try eventJSON(
            seq: 3,
            kind: "agent.item.delta",
            payload: [
                "thread_id": "thread-a",
                "turn_id": "turn-b",
                "item_id": "shared",
                "distill_applied": false,
            ]
        )

        let frames = WebSocketOutboundQueue.coalesceApplicationFrames([
            trusted,
            ordinary,
            otherTurn,
        ])

        XCTAssertEqual(frames.count, 3)
        let payloads = try frames.map { frame -> [String: Any] in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: frame) as? [String: Any]
            )
            return try XCTUnwrap(object["payload"] as? [String: Any])
        }
        XCTAssertEqual(payloads[0]["turn_id"] as? String, "turn-a")
        XCTAssertEqual(payloads[0]["distill_applied"] as? Bool, true)
        XCTAssertNil(payloads[1]["distill_applied"])
        XCTAssertEqual(payloads[1]["text"] as? String, "new turn content")
        XCTAssertEqual(payloads[2]["turn_id"] as? String, "turn-b")
    }

    func test_degradePreservesControlFramesWhileSheddingBulk() throws {
        // WHY: Coalescing/shedding must never drop pong/close control frames.
        // Losing a pong under pressure kills a healthy session and weakens the
        // liveness authority that fences sequence recovery.
        let stall = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1024,
            applicationWriter: { data in
                if String(decoding: data, as: UTF8.self).contains("\"sequence\":1") {
                    stall.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("degrade must never terminate") },
            didSendTerminal: { XCTFail("degrade must never shut down") }
        )

        let first = try eventJSON(seq: 1, kind: "agent.item.delta",
                                  payload: ["item_id": "i", "text": "a"])
        XCTAssertEqual(owner.enqueueApplication(first), .accepted)
        XCTAssertEqual(stall.wait(timeout: .now() + 2), .success)

        for seq in 2...5 {
            let frame = try eventJSON(seq: Int64(seq), kind: "surface.output",
                                      payload: ["surface_id": "s", "base64": "QQ=="])
            XCTAssertEqual(owner.enqueueApplication(frame), .accepted)
        }
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0x01, 0x02])),
                       .accepted, "pong control must queue under load")

        let before = owner.queuedFrameCountForTests
        let outcome = owner.degrade()
        XCTAssertGreaterThan(before, 0)
        XCTAssertTrue(
            outcome.discardedBulkFrames > 0
                || outcome.coalescedAwayFrames > 0
                || outcome.needsBaselineRequired,
            "degrade should report pressure work when bulk is queued"
        )
        // Control frame remains accounted in the queue after application shed.
        XCTAssertGreaterThanOrEqual(owner.queuedFrameCountForTests, 1,
                                    "control frames must survive degrade")
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0x03])),
                       .accepted, "socket stays open; control still accepted")

        release.signal()
        owner.finish()
    }

    func test_isSheddableKind_fencesCriticalLifecycleEvents() {
        // WHY: Only bulk/diagnostic kinds may be discarded under pressure.
        // Shedding agent.run.completed or settings.updated would silently
        // desync the client from the authoritative EventBus sequence.
        XCTAssertTrue(WebSocketOutboundQueue.isSheddableKind("surface.output"))
        XCTAssertTrue(WebSocketOutboundQueue.isSheddableKind("agent.item.delta"))
        XCTAssertTrue(WebSocketOutboundQueue.isSheddableKind("diagnostic.tick"))
        XCTAssertTrue(WebSocketOutboundQueue.isSheddableKind("metrics.sample"))
        XCTAssertFalse(WebSocketOutboundQueue.isSheddableKind("agent.run.completed"))
        XCTAssertFalse(WebSocketOutboundQueue.isSheddableKind("settings.updated"))
        XCTAssertFalse(WebSocketOutboundQueue.isSheddableKind("workspace.updated"))
    }

    // MARK: - Outbound application priority (wire fields only)

    func test_applicationPriority_classifiesExistingWireTypesWithoutInventingSemantics() throws {
        // WHY: End-to-end priority must use only existing ConnectionTransport
        // `type` and sheddable event `kind` fields. Inventing input/stop
        // outbound classes would be unverified protocol invention.
        let baseline = try JSONSerialization.data(withJSONObject: [
            "type": "baselineRequired",
            "reason": "outbound_queue_pressure",
        ])
        let error = try JSONSerialization.data(withJSONObject: [
            "type": "error",
            "code": 1011,
            "message": "x",
        ])
        let heartbeat = try JSONSerialization.data(withJSONObject: [
            "type": "heartbeat",
            "nonce": "n",
        ])
        let snapshot = try JSONSerialization.data(withJSONObject: [
            "type": "snapshot",
            "sequence": 9,
        ])
        let bulkEvent = try eventJSON(seq: 1, kind: "agent.item.delta",
                                      payload: ["item_id": "i", "text": "a"])
        let completion = try eventJSON(seq: 2, kind: "agent.run.completed",
                                       payload: ["thread_id": "t"])
        let opaque = Data("not-json".utf8)
        // Wave-4 WS multiplex: `sync.snapshot` success wraps ConnectionSnapshotFrame
        // under result — existing keys only, not a new priority vocabulary.
        let snapshotRPC = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 7,
            "result": [
                "type": "snapshot",
                "sequence": 42,
                "state": ["workspaces": []],
            ],
        ])
        let stopRPC = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 8,
            "result": ["ok": true, "stopped": true],
        ])

        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: baseline), .priority)
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: error), .priority)
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: heartbeat), .priority)
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: snapshot), .bulk)
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: bulkEvent), .bulk)
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: completion), .normal)
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: opaque), .normal)
        XCTAssertTrue(WebSocketOutboundQueue.isSnapshotRPCSuccessEnvelope(snapshotRPC))
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: snapshotRPC), .bulk,
                       "nested result.type=snapshot must be bulk so it leaves control free")
        XCTAssertTrue(WebSocketOutboundQueue.isSheddableApplicationFrame(snapshotRPC),
                      "snapshot RPC bulk must be sheddable under degrade pressure")
        XCTAssertFalse(WebSocketOutboundQueue.isSnapshotRPCSuccessEnvelope(stopRPC))
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: stopRPC), .normal,
                       "stop/input-style RPC results are not bulk (caller uses control lane)")
        XCTAssertTrue(WebSocketOutboundQueue.isSheddableApplicationFrame(snapshot),
                      "snapshots are bulk under pressure so degrade can free capacity")
    }

    func test_controlInteractive_drainsAheadOfAcceptedSnapshotRPCBulk() throws {
        // WHY: "Impedir snapshot grande de bloquear stop/input" — once a large
        // sync.snapshot success body is accepted on the bulk application lane,
        // stop/input RPC replies and WebSocket pongs must still drain first on
        // the control lane, not wait behind the snapshot bulk FIFO.
        let recorded = LockedStringArray()
        let holdEntered = DispatchSemaphore(value: 0)
        let releaseHold = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 256 * 1024,
            applicationWriter: { data in
                if WebSocketOutboundQueue.eventSequence(in: data) == 1 {
                    holdEntered.signal()
                    _ = releaseHold.wait(timeout: .now() + 2)
                }
                let label: String
                if WebSocketOutboundQueue.isSnapshotRPCSuccessEnvelope(data) {
                    label = "snapshot-rpc"
                } else if let seq = WebSocketOutboundQueue.eventSequence(in: data) {
                    label = "event:\(seq)"
                } else if let type = WebSocketOutboundQueue.frameType(in: data) {
                    label = type
                } else {
                    label = "app-other"
                }
                recorded.append(label)
                return true
            },
            controlWriter: { opcode, data in
                if opcode == 0xA {
                    recorded.append("pong")
                } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["jsonrpc"] as? String == "2.0" {
                    let idValue: Int
                    if let n = object["id"] as? Int {
                        idValue = n
                    } else if let n = object["id"] as? NSNumber {
                        idValue = n.intValue
                    } else {
                        idValue = -1
                    }
                    recorded.append("rpc-control:\(idValue)")
                } else {
                    recorded.append("control:\(opcode)")
                }
                return true
            },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("must not terminate") },
            didSendTerminal: {}
        )

        let hold = try eventJSON(seq: 1, kind: "agent.run.completed", payload: ["t": "hold"])
        XCTAssertEqual(owner.enqueueApplication(hold), .accepted)
        XCTAssertEqual(holdEntered.wait(timeout: .now() + 2), .success)

        let snapshotRPC = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "type": "snapshot",
                "sequence": 99,
                "blob": String(repeating: "S", count: 2_048),
            ],
        ])
        let stopRPC = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["ok": true, "stopped": true],
        ])

        // Production path after the fix: snapshot RPC → application bulk;
        // stop/input → control. Both are accepted while a prior write holds drain.
        XCTAssertEqual(WebSocketOutboundQueue.applicationPriority(of: snapshotRPC), .bulk)
        XCTAssertEqual(owner.enqueueApplication(snapshotRPC), .accepted)
        XCTAssertEqual(owner.enqueueControl(opcode: 0x1, data: stopRPC), .accepted)
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0x01])), .accepted)

        releaseHold.signal()
        owner.finish()

        let labels = recorded.snapshot
        guard let stopIndex = labels.firstIndex(of: "rpc-control:2"),
              let pongIndex = labels.firstIndex(of: "pong"),
              let snapshotIndex = labels.firstIndex(of: "snapshot-rpc") else {
            return XCTFail("expected stop RPC, pong, and snapshot-rpc in drain order; got \(labels)")
        }
        XCTAssertLessThan(stopIndex, snapshotIndex,
                          "stop/input RPC on control must drain before accepted snapshot bulk")
        XCTAssertLessThan(pongIndex, snapshotIndex,
                          "pong control must drain before accepted snapshot bulk")
        XCTAssertEqual(labels.first, "event:1",
                       "in-flight application write still completes first (RFC6455)")
    }

    func test_degradeShedsSnapshotRPCBulkWithoutDroppingControl() throws {
        // WHY: Accepted snapshot RPC bulk must free capacity under pressure so
        // baseline recovery and control can continue; dropping control would
        // kill liveness while the bulk body is sheddable by contract.
        let holdEntered = DispatchSemaphore(value: 0)
        let releaseHold = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 16 * 1024,
            applicationWriter: { data in
                if WebSocketOutboundQueue.eventSequence(in: data) == 1 {
                    holdEntered.signal()
                    _ = releaseHold.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("degrade must never terminate") },
            didSendTerminal: { XCTFail("degrade must never shut down") }
        )

        let hold = try eventJSON(seq: 1, kind: "agent.run.completed", payload: [:])
        XCTAssertEqual(owner.enqueueApplication(hold), .accepted)
        XCTAssertEqual(holdEntered.wait(timeout: .now() + 2), .success)

        for i in 0..<8 {
            let snapshotRPC = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0",
                "id": i,
                "result": [
                    "type": "snapshot",
                    "sequence": 100 + i,
                    "blob": String(repeating: "S", count: 400),
                ],
            ])
            _ = owner.enqueueApplication(snapshotRPC)
        }
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0xAB])), .accepted)

        let before = owner.queuedFrameCountForTests
        let outcome = owner.degrade()
        XCTAssertGreaterThan(outcome.discardedBulkFrames, 0,
                             "nested snapshot RPC envelopes must shed as bulk")
        XCTAssertTrue(outcome.needsBaselineRequired)
        XCTAssertLessThan(owner.queuedFrameCountForTests, before)
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0xCD])), .accepted,
                       "control must remain available after shedding snapshot RPC bulk")

        releaseHold.signal()
        owner.finish()
    }

    func test_priorityApplication_overtakesQueuedBulkWhilePreservingSequencedFIFO() throws {
        // WHY: A large snapshot/replay backlog must not starve baselineRequired
        // recovery frames. Sequenced events must stay FIFO relative to each
        // other so client gap detection keeps sequence authority.
        let recorded = LockedStringArray()
        let firstWriteEntered = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1024,
            applicationWriter: { data in
                let label: String
                if let type = WebSocketOutboundQueue.frameType(in: data) {
                    if type == "event", let seq = WebSocketOutboundQueue.eventSequence(in: data) {
                        label = "event:\(seq)"
                    } else {
                        label = type
                    }
                } else {
                    label = "opaque"
                }
                recorded.append(label)
                if label == "event:1" {
                    firstWriteEntered.signal()
                    _ = releaseFirstWrite.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("must not terminate") },
            didSendTerminal: {}
        )

        let first = try eventJSON(seq: 1, kind: "agent.run.completed", payload: ["t": "1"])
        XCTAssertEqual(owner.enqueueApplication(first), .accepted)
        XCTAssertEqual(firstWriteEntered.wait(timeout: .now() + 2), .success)

        let snapshot = try JSONSerialization.data(withJSONObject: [
            "type": "snapshot", "sequence": 10, "payload": String(repeating: "x", count: 64),
        ])
        let bulk = try eventJSON(seq: 2, kind: "surface.output",
                                 payload: ["surface_id": "s", "base64": "QQ=="])
        let completion = try eventJSON(seq: 3, kind: "agent.run.completed",
                                       payload: ["thread_id": "t"])
        let baseline = try JSONSerialization.data(withJSONObject: [
            "type": "baselineRequired",
            "reason": "outbound_queue_pressure",
            "currentSequence": 3,
        ])

        XCTAssertEqual(owner.enqueueApplication(snapshot), .accepted)
        XCTAssertEqual(owner.enqueueApplication(bulk), .accepted)
        XCTAssertEqual(owner.enqueueApplication(completion), .accepted)
        XCTAssertEqual(owner.enqueueApplication(baseline), .accepted)

        releaseFirstWrite.signal()
        owner.finish()

        XCTAssertEqual(recorded.snapshot, [
            "event:1",
            "baselineRequired",
            "snapshot",
            "event:2",
            "event:3",
        ], "baselineRequired overtakes bulk/events not yet writing; event seq order stays FIFO")
    }

    func test_controlAndRecoveryDrainAheadOfBulkPreservingSequencedFIFOAndSecretFreeMetrics() throws {
        // WHY: Composite macOS outbound invariant for open P1 priority TODOs
        // ("Aplicar prioridade…", "Impedir snapshot grande de bloquear stop/input"):
        // queued control (stop/input-style RPC + pong) and recovery
        // (baselineRequired) must drain ahead of sheddable snapshot/bulk
        // application frames; sequenced normal events stay FIFO relative to
        // each other (no reordering or duplication); wait metrics stay
        // secret-free on existing priority/normal/bulk lanes only.
        let recorded = LockedStringArray()
        let clock = LockedMonotonicClock(start: 500)
        let firstWriteEntered = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1024,
            applicationWriter: { data in
                let label: String
                if WebSocketOutboundQueue.isSnapshotRPCSuccessEnvelope(data) {
                    label = "snapshot-rpc"
                } else if let type = WebSocketOutboundQueue.frameType(in: data) {
                    if type == "event", let seq = WebSocketOutboundQueue.eventSequence(in: data) {
                        label = "event:\(seq)"
                    } else {
                        label = type
                    }
                } else {
                    label = "opaque"
                }
                recorded.append(label)
                if label == "event:1" {
                    firstWriteEntered.signal()
                    _ = releaseFirstWrite.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { opcode, data in
                if opcode == 0xA {
                    recorded.append("pong")
                } else if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          object["jsonrpc"] as? String == "2.0" {
                    let idValue: Int
                    if let n = object["id"] as? Int {
                        idValue = n
                    } else if let n = object["id"] as? NSNumber {
                        idValue = n.intValue
                    } else {
                        idValue = -1
                    }
                    recorded.append("rpc-control:\(idValue)")
                } else {
                    recorded.append("control:\(opcode)")
                }
                return true
            },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("must not terminate") },
            didSendTerminal: {},
            now: { clock.now }
        )

        let hold = try eventJSON(seq: 1, kind: "agent.run.completed", payload: ["t": "hold"])
        XCTAssertEqual(owner.enqueueApplication(hold), .accepted)
        XCTAssertEqual(firstWriteEntered.wait(timeout: .now() + 2), .success)

        // Application bulk + sequenced normal share one FIFO (seq authority).
        let snapshotRPC = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "type": "snapshot",
                "sequence": 99,
                "blob": String(repeating: "S", count: 128),
                "token": "must-not-appear-in-metrics",
            ],
        ])
        let bulkEvent = try eventJSON(seq: 2, kind: "surface.output",
                                      payload: ["surface_id": "s", "base64": "QQ=="])
        let completion = try eventJSON(seq: 3, kind: "agent.run.completed",
                                       payload: ["thread_id": "t"])
        let baseline = try JSONSerialization.data(withJSONObject: [
            "type": "baselineRequired",
            "reason": "outbound_queue_pressure",
            "host": "secret.example",
        ])
        let stopRPC = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "result": ["ok": true, "stopped": true],
        ])

        clock.advance(by: 0.010)
        XCTAssertEqual(owner.enqueueApplication(snapshotRPC), .accepted)
        XCTAssertEqual(owner.enqueueApplication(bulkEvent), .accepted)
        XCTAssertEqual(owner.enqueueApplication(completion), .accepted)
        // Recovery arrives after bulk but must overtake on the priority lane.
        XCTAssertEqual(owner.enqueueApplication(baseline), .accepted)
        // Production stop/input path: interactive RPC replies + pong on control.
        XCTAssertEqual(owner.enqueueControl(opcode: 0x1, data: stopRPC), .accepted)
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0x01])), .accepted)

        releaseFirstWrite.signal()
        owner.finish()

        let labels = recorded.snapshot
        XCTAssertEqual(labels, [
            "event:1",
            "rpc-control:2",
            "pong",
            "baselineRequired",
            "snapshot-rpc",
            "event:2",
            "event:3",
        ], "control then recovery then shared app FIFO; no reordering/duplication")

        // Wait metrics attributed only to existing application lanes; control excluded.
        let wait = owner.queueWaitMetricsSnapshot
        XCTAssertEqual(wait.priority.count, 1, "baselineRequired only")
        XCTAssertEqual(wait.bulk.count, 2, "snapshot-rpc + surface.output bulk")
        XCTAssertGreaterThanOrEqual(wait.normal.count, 2, "hold + completion")
        let health = connectionMetricsJSON(
            activeClients: 1,
            totalQueuedBytes: owner.queuedByteCount,
            slowClientDrops: 0,
            outboundQueueWait: wait
        )
        guard let encoded = try? JSONSerialization.data(withJSONObject: health),
              let text = String(data: encoded, encoding: .utf8) else {
            return XCTFail("health connections JSON must encode")
        }
        for leak in ["must-not-appear-in-metrics", "secret.example", "baselineRequired",
                     "snapshot", "stopped", "surface.output"] {
            XCTAssertFalse(text.contains(leak),
                           "queue wait health metrics must not leak \(leak)")
        }
        let waitJSON = health["outbound_queue_wait_ms"] as? [String: Any]
        XCTAssertEqual(Set((waitJSON ?? [:]).keys), Set(["priority", "normal", "bulk"]))
    }

    func test_bulkOccupancyCap_leavesRoomForCompletionAndControlReserve() throws {
        // WHY: Snapshot/replay bulk must not fill the entire outbound budget or
        // interactive completions and pongs starve. Capacity reservations are
        // classified from existing wire fields only.
        let stall = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 1_024,
            applicationWriter: { data in
                if WebSocketOutboundQueue.eventSequence(in: data) == 1 {
                    stall.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("must not terminate") },
            didSendTerminal: {}
        )

        // Hold the drain on the first normal frame so subsequent bulk stays queued.
        let hold = try eventJSON(seq: 1, kind: "agent.run.completed", payload: ["t": "hold"])
        XCTAssertEqual(owner.enqueueApplication(hold), .accepted)
        XCTAssertEqual(stall.wait(timeout: .now() + 2), .success)

        var bulkAccepted = 0
        for i in 0..<64 {
            // ~200-byte bulk snapshots to pressure the bulk ceiling quickly.
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "type": "snapshot",
                "sequence": 100 + i,
                "blob": String(repeating: "Z", count: 180),
            ])
            if owner.enqueueApplication(snapshot) == .accepted {
                bulkAccepted += 1
            } else {
                break
            }
        }
        XCTAssertGreaterThan(bulkAccepted, 0, "at least one bulk frame must queue")
        XCTAssertEqual(
            owner.enqueueApplication(try JSONSerialization.data(withJSONObject: [
                "type": "snapshot",
                "sequence": 999,
                "blob": String(repeating: "Z", count: 180),
            ])),
            .queueFull,
            "bulk must hit its occupancy cap before the full application budget"
        )

        let completion = try eventJSON(seq: 2, kind: "agent.run.completed",
                                       payload: ["thread_id": "t"])
        XCTAssertEqual(owner.enqueueApplication(completion), .accepted,
                       "interactive/completion must still fit in reserved interactive capacity")

        let baseline = try JSONSerialization.data(withJSONObject: [
            "type": "baselineRequired",
            "reason": "outbound_queue_pressure",
        ])
        XCTAssertEqual(owner.enqueueApplication(baseline), .accepted,
                       "baseline recovery must enqueue under bulk backlog")

        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0xAA])),
                       .accepted,
                       "control reserve must accept pong while application holds bulk")

        release.signal()
        owner.finish()
    }

    func test_degradeShedsSnapshotBulkThenBaselineRecoversCapacity() throws {
        // WHY: When the queue is saturated with snapshot bulk, degrade must free
        // capacity and surface baseline_required so sequence authority recovers
        // without closing the socket.
        let stall = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 4_096,
            applicationWriter: { data in
                if WebSocketOutboundQueue.eventSequence(in: data) == 1 {
                    stall.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("degrade must never terminate") },
            didSendTerminal: { XCTFail("degrade must never shut down") }
        )

        let hold = try eventJSON(seq: 1, kind: "agent.run.completed", payload: [:])
        XCTAssertEqual(owner.enqueueApplication(hold), .accepted)
        XCTAssertEqual(stall.wait(timeout: .now() + 2), .success)

        for i in 0..<20 {
            let snapshot = try JSONSerialization.data(withJSONObject: [
                "type": "snapshot",
                "sequence": 50 + i,
                "blob": String(repeating: "S", count: 200),
            ])
            _ = owner.enqueueApplication(snapshot)
        }
        let before = owner.queuedFrameCountForTests
        XCTAssertGreaterThan(before, 1)

        let outcome = owner.degrade()
        XCTAssertGreaterThan(outcome.discardedBulkFrames, 0,
                             "snapshots must be sheddable bulk under pressure")
        XCTAssertTrue(outcome.needsBaselineRequired,
                      "shedding accepted bulk requires client rebaseline")
        XCTAssertLessThan(owner.queuedFrameCountForTests, before)

        let baseline = try JSONSerialization.data(withJSONObject: [
            "type": "baselineRequired",
            "reason": "outbound_queue_pressure",
        ])
        XCTAssertEqual(owner.enqueueApplication(baseline), .accepted,
                       "after degrade, baseline recovery frames must enqueue")

        release.signal()
        owner.finish()
    }

    // MARK: - Queue wait by existing application priority lane

    func test_queueWait_attributedToExistingLanes_withInjectableClock() throws {
        // WHY: "Medir tempo de fila por prioridade" is only useful if each
        // frame's enqueue→dequeue wait is charged to the lane derived from
        // existing wire fields — not a single undifferentiated timer, and not
        // invented input/stop classes.
        let clock = LockedMonotonicClock(start: 1_000)
        let stall = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let tracker = WSConnectionTracker()
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 64 * 1024,
            applicationWriter: { data in
                // Hold the first (normal) write so later frames sit in queue
                // while the injectable clock advances.
                if WebSocketOutboundQueue.eventSequence(in: data) == 1 {
                    stall.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
                return true
            },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("wait instrumentation must not terminate") },
            didSendTerminal: {},
            now: { clock.now },
            onApplicationQueueWaitRecorded: { priority, waitMs in
                tracker.recordOutboundQueueWait(priority: priority, waitMilliseconds: waitMs)
            }
        )

        let normalHold = try eventJSON(seq: 1, kind: "agent.run.completed", payload: ["t": "hold"])
        XCTAssertEqual(owner.enqueueApplication(normalHold), .accepted)
        XCTAssertEqual(stall.wait(timeout: .now() + 2), .success)

        // Enqueue one frame per existing application lane while drain is blocked.
        clock.advance(by: 0.010) // 10ms wall of queue time before bulk stamp
        let bulk = try JSONSerialization.data(withJSONObject: [
            "type": "snapshot",
            "sequence": 50,
            "blob": "bulk-body",
        ])
        XCTAssertEqual(owner.enqueueApplication(bulk), .accepted)

        clock.advance(by: 0.020) // bulk has waited 20ms more; normal-next enqueues now
        let normalNext = try eventJSON(seq: 2, kind: "agent.run.completed",
                                       payload: ["thread_id": "t"])
        XCTAssertEqual(owner.enqueueApplication(normalNext), .accepted)

        clock.advance(by: 0.005)
        let priority = try JSONSerialization.data(withJSONObject: [
            "type": "baselineRequired",
            "reason": "outbound_queue_pressure",
            "token": "must-not-appear-in-metrics",
            "host": "secret.example",
        ])
        XCTAssertEqual(owner.enqueueApplication(priority), .accepted)

        // Advance clock so every queued frame has a deterministic wait when drained.
        // Priority drains next (overtakes bulk/normal FIFO), then bulk, then normal.
        //
        // Timeline (clock seconds from start 1000):
        //   normalHold @ 1000.000 (immediate dequeue, wait≈0)
        //   bulk @ 1000.010
        //   normalNext @ 1000.030
        //   priority @ 1000.035
        //   advance to 1000.135 then release
        // At dequeue (same now=1000.135):
        //   priority wait = 100ms
        //   bulk wait = 125ms
        //   normalNext wait = 105ms
        clock.advance(by: 0.100)
        release.signal()
        owner.finish()

        let queueSnap = owner.queueWaitMetricsSnapshot
        let trackerSnap = tracker.outboundQueueWaitMetrics

        // First normal hold may have near-zero wait (drained immediately).
        XCTAssertGreaterThanOrEqual(queueSnap.normal.count, 2,
                                    "hold + completion must both attribute to normal lane")
        XCTAssertEqual(queueSnap.priority.count, 1,
                       "baselineRequired must attribute only to priority lane")
        XCTAssertEqual(queueSnap.bulk.count, 1,
                       "snapshot must attribute only to bulk lane")

        XCTAssertEqual(queueSnap.priority.maxMilliseconds, 100, accuracy: 0.001)
        XCTAssertEqual(queueSnap.bulk.maxMilliseconds, 125, accuracy: 0.001)
        XCTAssertEqual(queueSnap.priority.totalMilliseconds, 100, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(queueSnap.normal.maxMilliseconds, 105 - 0.001)

        // Tracker mirror must match queue (process-scoped health sink).
        XCTAssertEqual(trackerSnap.priority.count, queueSnap.priority.count)
        XCTAssertEqual(trackerSnap.bulk.count, queueSnap.bulk.count)
        XCTAssertEqual(trackerSnap.normal.count, queueSnap.normal.count)
        XCTAssertEqual(trackerSnap.priority.maxMilliseconds, queueSnap.priority.maxMilliseconds,
                       accuracy: 0.001)
        XCTAssertEqual(trackerSnap.bulk.maxMilliseconds, queueSnap.bulk.maxMilliseconds,
                       accuracy: 0.001)

        // Health surface stays secret-free even when frames carried secrets.
        let health = connectionMetricsJSON(
            activeClients: 1,
            totalQueuedBytes: owner.queuedByteCount,
            slowClientDrops: 0,
            outboundQueueWait: trackerSnap
        )
        guard let encoded = try? JSONSerialization.data(withJSONObject: health),
              let text = String(data: encoded, encoding: .utf8) else {
            return XCTFail("health connections JSON must encode")
        }
        for leak in ["must-not-appear-in-metrics", "secret.example", "token", "baselineRequired",
                     "snapshot", "agent.run.completed", "bulk-body"] {
            XCTAssertFalse(text.contains(leak),
                           "queue wait health metrics must not leak \(leak)")
        }
        let waitJSON = health["outbound_queue_wait_ms"] as? [String: Any]
        XCTAssertEqual(Set((waitJSON ?? [:]).keys), Set(["priority", "normal", "bulk"]))
    }

    func test_queueWait_controlFramesDoNotInflateApplicationLaneMetrics() throws {
        // WHY: control/pong path is not an application priority lane; counting
        // it as normal/priority would misdiagnose application backlog.
        let clock = LockedMonotonicClock(start: 50)
        let owner = WebSocketOutboundQueue(
            maxQueuedBytes: 4_096,
            applicationWriter: { _ in true },
            controlWriter: { _, _ in true },
            writeFailureClosingData: Data(),
            onTerminal: { _ in XCTFail("must not terminate") },
            didSendTerminal: {},
            now: { clock.now }
        )
        clock.advance(by: 0.050)
        XCTAssertEqual(owner.enqueueControl(opcode: 0xA, data: Data([0x01])), .accepted)
        owner.finish()

        let snap = owner.queueWaitMetricsSnapshot
        XCTAssertEqual(snap.priority, .zero)
        XCTAssertEqual(snap.normal, .zero)
        XCTAssertEqual(snap.bulk, .zero)
    }
}

/// Deterministic monotonic clock for queue-wait tests (seconds).
private final class LockedMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(start: TimeInterval) {
        self.value = start
    }

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(by delta: TimeInterval) {
        lock.lock()
        value += max(0, delta)
        lock.unlock()
    }
}

/// Thread-safe string log for outbound writer tests.
private final class LockedStringArray: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock(); storage.append(value); lock.unlock()
    }

    var snapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
