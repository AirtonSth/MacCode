import XCTest
@testable import SocketServer

// RFC6455 s5.3: A client MUST mask all frames it sends to the server.
// The server MUST close the connection if it receives an unmasked frame.
//
// Header tests exercise DirectHTTPServer.wsFrameHeader(buf:from:). Live-path
// reassembly is proven via WebSocketClientFrameAssembler (used by wsServeLoop).

final class RFC6455MaskingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal client text frame.
    /// maskKey: nil => unmasked (MASK bit = 0); non-nil => masked frame.
    private func makeTextFrame(payload: [UInt8], maskKey: [UInt8]? = nil) -> [UInt8] {
        makeClientFrame(fin: true, opcode: 0x1, payload: payload, maskKey: maskKey)
    }

    /// Build a masked client frame (data or control).
    private func makeClientFrame(
        fin: Bool,
        opcode: UInt8,
        payload: [UInt8],
        maskKey: [UInt8]? = [0x37, 0xFA, 0x21, 0x3D]
    ) -> [UInt8] {
        var frame: [UInt8] = []
        frame.append((fin ? 0x80 : 0x00) | (opcode & 0x0F))
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

    /// Drain assembler until needMore (or a terminal event). Returns all events.
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
            case .mustClose, .peerClose, .binary:
                offset += consumed
                return events
            case .fragmentProgress, .text, .ping, .pong:
                offset += consumed
            }
        }
        return events
    }

    // MARK: - wsFrameHeader: masked bit accurately reported

    func test_header_masked_bit_true_for_masked_frame() {
        // WHY: wsFrameHeader must correctly read the MASK bit so that
        // parseClientFrame can enforce RFC6455 s5.3 masking requirement.
        let key: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        let raw = makeTextFrame(payload: [0x48, 0x65, 0x6C, 0x6C, 0x6F], maskKey: key)
        let hdr = DirectHTTPServer.wsFrameHeader(buf: raw, from: 0)
        XCTAssertNotNil(hdr, "should parse a complete masked frame header")
        XCTAssertTrue(hdr!.masked, "MASK bit must be true for a masked client frame")
        XCTAssertFalse(hdr!.shouldReject, "masked frame within size limits must not be rejected")
        XCTAssertEqual(hdr!.opcode, 0x1, "opcode must be text (0x1)")
        XCTAssertEqual(hdr!.payloadLen, 5)
        XCTAssertEqual(hdr!.headerEnd, 2)
    }

    func test_header_masked_bit_false_for_unmasked_frame() {
        // WHY: wsFrameHeader must expose masked=false for unmasked frames so
        // parseClientFrame can reject them per RFC6455 s5.3.
        let raw = makeTextFrame(payload: [0x48, 0x65, 0x6C, 0x6C, 0x6F], maskKey: nil)
        let hdr = DirectHTTPServer.wsFrameHeader(buf: raw, from: 0)
        XCTAssertNotNil(hdr)
        XCTAssertFalse(hdr!.masked, "MASK bit must be false for an unmasked frame")
        XCTAssertFalse(hdr!.shouldReject,
            "shouldReject is for size/overflow, not masking -- masking is checked separately")
    }

    // MARK: - wsFrameHeader: incomplete buffer returns nil

    func test_header_nil_when_only_one_byte_available() {
        // WHY: partial frames must not produce incorrect results; the loop
        // must wait for more data rather than mis-parse.
        let raw: [UInt8] = [0x81]
        let hdr = DirectHTTPServer.wsFrameHeader(buf: raw, from: 0)
        XCTAssertNil(hdr, "one byte is insufficient for a frame header")
    }

    func test_header_nil_when_extended_16bit_length_incomplete() {
        // WHY: if the length says 16-bit but fewer than 4 bytes are available,
        // wsFrameHeader must return nil (not crash or mis-parse).
        // b1 = 0x7E means payload-len = 126 (next 2 bytes carry actual length).
        let raw: [UInt8] = [0x81, 0x7E, 0x00] // only 3 bytes; need 4 for 16-bit len
        let hdr = DirectHTTPServer.wsFrameHeader(buf: raw, from: 0)
        XCTAssertNil(hdr)
    }

    // MARK: - wsFrameHeader: shouldReject for overflow length

    func test_header_shouldReject_for_overflow_payload_length() {
        // WHY: a client sending a frame claiming > maxClientFramePayloadBytes
        // must trigger a close; shouldReject=true signals this without
        // allocating the payload.
        // Build a 16-bit extended-length frame claiming 0xFFFF bytes.
        let raw: [UInt8] = [
            0x82,       // FIN + binary
            0x7E,       // payload len = 126 -> next 2 bytes
            0xFF, 0xFF  // claimed length = 65535 (< 1 MB limit of 1048576)
        ]
        // 65535 < 1 MB so this is NOT oversized; verify that first.
        let hdr = DirectHTTPServer.wsFrameHeader(buf: raw, from: 0)
        XCTAssertNotNil(hdr)
        XCTAssertFalse(hdr!.shouldReject, "65535 bytes is within the 1 MB limit")

        // Now build one that exceeds 1 MB (0x10_0001 = 1048577) via 64-bit length field.
        var oversize: [UInt8] = [
            0x82,   // FIN + binary
            0x7F    // payload len = 127 -> next 8 bytes
        ]
        // 1048577 = 0x00_00_00_00_00_10_00_01
        oversize += [0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x01]
        let hdr2 = DirectHTTPServer.wsFrameHeader(buf: oversize, from: 0)
        XCTAssertNotNil(hdr2)
        XCTAssertTrue(hdr2!.shouldReject, "payload length > maxClientFramePayloadBytes must set shouldReject")
    }

    // MARK: - Unmasked frame rejected (opcode 0x8 close sentinel)

    func test_unmasked_frame_masked_bit_is_false() {
        // WHY: RFC6455 s5.3 mandates that the server close the connection on
        // receiving an unmasked frame. parseClientFrame must return a WSFrame
        // with opcode 0x8 (close) so that wsServeLoop terminates the session
        // rather than continuing to process invalid traffic.
        //
        // We verify the rule via wsFrameHeader: masked=false + shouldReject=false
        // means parseClientFrame will enforce the masking rule independently.
        let raw = makeTextFrame(payload: [0x48, 0x65, 0x6C, 0x6C, 0x6F], maskKey: nil)
        let hdr = DirectHTTPServer.wsFrameHeader(buf: raw, from: 0)
        XCTAssertNotNil(hdr)
        XCTAssertFalse(hdr!.masked,
            "unmasked frame: masked must be false -- parseClientFrame uses this to close with 1002")
    }

    // MARK: - Masked frame: payload unmasks correctly

    func test_masked_payload_unmasks_correctly() {
        // WHY: correct XOR unmask of the 4-byte key across the payload is the
        // core of RFC6455 s5.3. If masking math breaks, all client messages
        // are garbled. This test encodes a known string with a known key and
        // asserts the decoded bytes match the original.
        //
        // We verify wsFrameHeader exposes the right headerEnd (= 2, before the
        // mask key) so that callers can locate the key at offset headerEnd.
        let original: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F] // \"Hello\"
        let key: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        let maskedPayload = original.enumerated().map { i, b in b ^ key[i & 3] }

        var raw: [UInt8] = [0x81, 0x85] // FIN+text, MASK=1, len=5
        raw += key
        raw += maskedPayload

        let hdr = DirectHTTPServer.wsFrameHeader(buf: raw, from: 0)
        XCTAssertNotNil(hdr)
        XCTAssertTrue(hdr!.masked)
        XCTAssertEqual(hdr!.payloadLen, 5)
        XCTAssertEqual(hdr!.headerEnd, 2, "headerEnd must point just past the 2-byte fixed header")

        // Manually unmask using headerEnd to locate the key.
        let keyStart = hdr!.headerEnd
        let payStart = keyStart + 4
        let decodedKey = Array(raw[keyStart..<keyStart + 4])
        let decoded = raw[payStart...].enumerated().map { i, b in b ^ decodedKey[i & 3] }
        XCTAssertEqual(Array(decoded), original, "XOR unmask must recover the original payload")
    }

    // MARK: - Non-zero start offset

    func test_header_parsed_correctly_with_nonzero_start_offset() {
        // WHY: wsServeLoop maintains a read offset into a growing buffer.
        // wsFrameHeader must correctly index from `start`, not from 0,
        // so that back-to-back frames in the same buffer parse correctly.
        let prefix: [UInt8] = [0xDE, 0xAD] // 2 bytes of prior data
        let key: [UInt8] = [0x01, 0x02, 0x03, 0x04]
        let payload: [UInt8] = [0x41, 0x42] // \"AB\"
        var frame: [UInt8] = [0x81, 0x82] // text, MASK=1, len=2
        frame += key
        frame += payload.enumerated().map { i, b in b ^ key[i & 3] }
        let buf = prefix + frame

        let hdr = DirectHTTPServer.wsFrameHeader(buf: buf, from: 2)
        XCTAssertNotNil(hdr)
        XCTAssertTrue(hdr!.masked)
        XCTAssertEqual(hdr!.payloadLen, 2)
        XCTAssertEqual(hdr!.opcode, 0x1)
    }

    // MARK: - Assembler path (wsServeLoop real path)

    func test_assembler_fragmented_text_reassembles() {
        // WHY: wsServeLoop now drives WebSocketClientFrameAssembler. Fragmented
        // text (FIN=0 text + continuation FIN=1) must reassemble to one .text
        // so JSON-RPC / rc2.interest see the full message, not each fragment.
        let part1: [UInt8] = Array("Hel".utf8)
        let part2: [UInt8] = Array("lo".utf8)
        let buf =
            makeClientFrame(fin: false, opcode: 0x1, payload: part1)
            + makeClientFrame(fin: true, opcode: 0x0, payload: part2)

        var assembler = WebSocketClientFrameAssembler()
        let events = drain(&assembler, buf: buf)

        XCTAssertEqual(events.count, 2, "expect fragmentProgress then text")
        guard case .fragmentProgress = events[0] else {
            return XCTFail("first event must be fragmentProgress, got \(events[0])")
        }
        guard case .text(let data) = events[1] else {
            return XCTFail("second event must be text, got \(events[1])")
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), "Hello")
        XCTAssertFalse(assembler.isFragmenting)
    }

    func test_assembler_interleaved_ping_during_fragmentation() {
        // WHY: RFC6455 allows control frames between data fragments. A ping
        // mid-fragment must surface as .ping (so wsServeLoop can pong) without
        // aborting the in-progress text message.
        let part1: [UInt8] = Array("AB".utf8)
        let part2: [UInt8] = Array("CD".utf8)
        let pingPayload: [UInt8] = [0x01, 0x02]
        let buf =
            makeClientFrame(fin: false, opcode: 0x1, payload: part1)
            + makeClientFrame(fin: true, opcode: 0x9, payload: pingPayload)
            + makeClientFrame(fin: true, opcode: 0x0, payload: part2)

        var assembler = WebSocketClientFrameAssembler()
        let events = drain(&assembler, buf: buf)

        XCTAssertEqual(events.count, 3)
        guard case .fragmentProgress = events[0] else {
            return XCTFail("expected fragmentProgress, got \(events[0])")
        }
        guard case .ping(let ping) = events[1] else {
            return XCTFail("expected interleaved ping, got \(events[1])")
        }
        XCTAssertEqual([UInt8](ping), pingPayload)
        guard case .text(let text) = events[2] else {
            return XCTFail("expected completed text after ping, got \(events[2])")
        }
        XCTAssertEqual(String(data: text, encoding: .utf8), "ABCD")
    }

    func test_assembler_invalid_utf8_text_mustClose_1007() {
        // WHY: RFC6455 + contract: invalid UTF-8 in a text message must close
        // with 1007. wsServeLoop maps .mustClose to protocolError terminate.
        // 0xFF is never valid UTF-8 lead/continuation as a lone byte sequence
        // that fails String(data:encoding:.utf8).
        let bad: [UInt8] = [0xC3, 0x28] // invalid UTF-8 overlong/truncated form
        let buf = makeClientFrame(fin: true, opcode: 0x1, payload: bad)

        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: buf, from: 0)
        XCTAssertGreaterThan(consumed, 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("invalid UTF-8 must produce mustClose, got \(event)")
        }
        XCTAssertEqual(code, WebSocketClientFrameAssembler.invalidUtf8CloseCode)
        XCTAssertEqual(code, 1007)
    }

    func test_assembler_one_mib_aggregate_overflow_mustClose_1009() {
        // WHY: Contract caps fragmented messages at 1 MiB. Exceeding the
        // aggregate must close with 1009 so a client cannot force unbounded
        // reassembly memory on the host.
        let max = WebSocketClientFrameAssembler.maxFragmentedMessageBytes
        XCTAssertEqual(max, 1_048_576)

        // First fragment: exactly at the cap (accepted as fragmentProgress).
        // Second fragment: one more byte => aggregate overflow => 1009.
        let first = [UInt8](repeating: 0x41, count: max)
        let second: [UInt8] = [0x42]
        let buf =
            makeClientFrame(fin: false, opcode: 0x1, payload: first)
            + makeClientFrame(fin: true, opcode: 0x0, payload: second)

        var assembler = WebSocketClientFrameAssembler()
        // Step 1: accept first fragment.
        let (e1, c1) = assembler.consume(buf: buf, from: 0)
        guard case .fragmentProgress = e1 else {
            return XCTFail("first fragment within 1 MiB must be fragmentProgress, got \(e1)")
        }
        XCTAssertGreaterThan(c1, 0)
        XCTAssertTrue(assembler.isFragmenting)

        // Step 2: continuation that overflows.
        let (e2, c2) = assembler.consume(buf: buf, from: c1)
        XCTAssertGreaterThan(c2, 0)
        guard case .mustClose(let code) = e2 else {
            return XCTFail("aggregate overflow must produce mustClose, got \(e2)")
        }
        XCTAssertEqual(code, WebSocketClientFrameAssembler.tooLargeCloseCode)
        XCTAssertEqual(code, 1009)
        XCTAssertFalse(assembler.isFragmenting)
    }

    func test_assembler_unmasked_frame_mustClose_1002() {
        // WHY: Live path uses the assembler for mask enforcement; unmasked
        // client frames must close with 1002 (protocol error), not silently
        // accept or treat as peerClose without a code.
        let raw = makeTextFrame(payload: Array("Hello".utf8), maskKey: nil)
        var assembler = WebSocketClientFrameAssembler()
        let (event, _) = assembler.consume(buf: raw, from: 0)
        guard case .mustClose(let code) = event else {
            return XCTFail("unmasked frame must produce mustClose, got \(event)")
        }
        XCTAssertEqual(code, WebSocketClientFrameAssembler.invalidCloseCode)
        XCTAssertEqual(code, 1002)
    }

    func test_assembler_needMore_on_partial_frame() {
        // WHY: Incomplete frames must not be mis-parsed; wsServeLoop waits for
        // more bytes when the assembler returns .needMore with consumed=0.
        let full = makeTextFrame(payload: Array("Hello".utf8), maskKey: [0x37, 0xFA, 0x21, 0x3D])
        let partial = Array(full.prefix(3))
        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: partial, from: 0)
        XCTAssertEqual(event, .needMore)
        XCTAssertEqual(consumed, 0)
    }

    // MARK: - Close status code validation (RFC6455 s7.4)

    /// Build a masked client close frame (opcode 0x8) with optional status + reason.
    private func makeCloseFrame(code: UInt16?, reason: [UInt8] = []) -> [UInt8] {
        var payload: [UInt8] = []
        if let code {
            payload.append(UInt8((code >> 8) & 0xFF))
            payload.append(UInt8(code & 0xFF))
            payload.append(contentsOf: reason)
        }
        return makeClientFrame(fin: true, opcode: 0x8, payload: payload)
    }

    func test_assembler_close_valid_1000_is_peerClose() {
        // WHY: Normal Closure (1000) is the common clean-shutdown code; the
        // host must treat it as peerClose so the session can complete teardown.
        let buf = makeCloseFrame(code: 1000)
        var assembler = WebSocketClientFrameAssembler()
        let (event, consumed) = assembler.consume(buf: buf, from: 0)
        XCTAssertGreaterThan(consumed, 0)
        guard case .peerClose(let code, let reason) = event else {
            return XCTFail("close 1000 must produce peerClose, got \(event)")
        }
        XCTAssertEqual(code, 1000)
        XCTAssertTrue(reason.isEmpty)
    }

    func test_assembler_close_application_codes_3000_to_4999_accepted() {
        // WHY: 3000–3999 (libraries) and 4000–4999 (private use) are legal on
        // the wire; rejecting them would break app-level close semantics.
        for status: UInt16 in [3000, 3999, 4000, 4999] {
            let buf = makeCloseFrame(code: status, reason: Array("bye".utf8))
            var assembler = WebSocketClientFrameAssembler()
            let (event, _) = assembler.consume(buf: buf, from: 0)
            guard case .peerClose(let code, let reason) = event else {
                return XCTFail("close \(status) must produce peerClose, got \(event)")
            }
            XCTAssertEqual(code, status, "application close code \(status)")
            XCTAssertEqual(String(data: reason, encoding: .utf8), "bye")
        }
    }

    func test_assembler_close_reserved_and_out_of_range_mustClose_1002() {
        // WHY: RFC6455 s7.4 forbids reserved codes (1004–1006, 1015) and codes
        // outside 1000…4999 on the wire. Protocol error close is 1002 so a
        // misbehaving peer cannot smuggle invalid status into session teardown.
        let invalid: [UInt16] = [0, 999, 1004, 1005, 1006, 1015, 5000, 65535]
        for status in invalid {
            let buf = makeCloseFrame(code: status)
            var assembler = WebSocketClientFrameAssembler()
            let (event, consumed) = assembler.consume(buf: buf, from: 0)
            XCTAssertGreaterThan(consumed, 0, "status \(status)")
            guard case .mustClose(let code) = event else {
                return XCTFail("invalid close \(status) must produce mustClose, got \(event)")
            }
            XCTAssertEqual(code, WebSocketClientFrameAssembler.invalidCloseCode, "status \(status)")
            XCTAssertEqual(code, 1002, "status \(status)")
        }
    }
}
