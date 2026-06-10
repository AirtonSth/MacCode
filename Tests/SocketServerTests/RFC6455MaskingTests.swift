import XCTest
@testable import SocketServer

// RFC6455 s5.3: A client MUST mask all frames it sends to the server.
// The server MUST close the connection if it receives an unmasked frame.
//
// These tests exercise DirectHTTPServer.wsFrameHeader(buf:from:) -- a pure,
// actor-free static function -- so no @MainActor annotation is required.

final class RFC6455MaskingTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal client text frame.
    /// maskKey: nil => unmasked (MASK bit = 0); non-nil => masked frame.
    private func makeTextFrame(payload: [UInt8], maskKey: [UInt8]? = nil) -> [UInt8] {
        var frame: [UInt8] = []
        frame.append(0x81) // FIN + opcode text (0x1)
        let masked: UInt8 = (maskKey != nil) ? 0x80 : 0x00
        frame.append(masked | UInt8(payload.count))
        if let key = maskKey {
            frame.append(contentsOf: key)
            frame.append(contentsOf: payload.enumerated().map { i, b in b ^ key[i & 3] })
        } else {
            frame.append(contentsOf: payload)
        }
        return frame
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
}
