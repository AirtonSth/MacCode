import Foundation

/// RFC 6455 client→server frame reassembly + contract close codes.
///
/// Pure state machine (no I/O). Matches `contract-schema.json` websocket rules:
/// FIN/continuation, interleaved control frames, 1 MiB aggregate fragmented-message
/// cap, UTF-8 for text/close reasons, close codes 1002 / 1007 / 1009.
public struct WebSocketClientFrameAssembler: Sendable {
    public static let maxFragmentedMessageBytes = 1_048_576
    public static let controlFrameMaxBytes = 125
    public static let invalidCloseCode: UInt16 = 1002
    public static let invalidUtf8CloseCode: UInt16 = 1007
    public static let tooLargeCloseCode: UInt16 = 1009

    public enum Event: Equatable, Sendable {
        /// Need more bytes before a complete frame header/payload is available.
        case needMore
        /// A non-final data fragment was accepted; advance the buffer, keep reading.
        case fragmentProgress
        /// Complete text message (opcode 1), UTF-8 validated.
        case text(Data)
        /// Complete binary message (opcode 2).
        case binary(Data)
        case ping(Data)
        case pong(Data)
        /// Peer close frame. `code`/`reason` when payload is present and valid.
        case peerClose(code: UInt16?, reason: Data)
        /// Host must close the socket with this RFC close code.
        case mustClose(code: UInt16)
    }

    /// In-progress data message opcode (1 or 2). Nil when not mid-fragment.
    private var fragmentOpcode: UInt8?
    private var fragmentBuffer = Data()

    public init() {}

    public var isFragmenting: Bool { fragmentOpcode != nil }

    /// Consume zero or one complete frame starting at `from`.
    /// Returns `(event, bytesConsumed)`. `needMore` always consumes 0.
    public mutating func consume(buf: [UInt8], from start: Int) -> (Event, Int) {
        guard let hdr = Self.frameHeader(buf: buf, from: start) else {
            return (.needMore, 0)
        }

        if hdr.shouldReject {
            return (.mustClose(code: hdr.rejectCloseCode), max(hdr.headerEnd, 2))
        }

        // RFC6455 s5.2: RSV bits must be 0 unless an extension is negotiated.
        if hdr.rsv != 0 {
            return (.mustClose(code: Self.invalidCloseCode), hdr.headerEnd)
        }

        guard hdr.masked else {
            // RFC6455 s5.1/s5.3: client frames MUST be masked.
            return (.mustClose(code: Self.invalidCloseCode), hdr.headerEnd)
        }

        let maskLen = 4
        let available = buf.count - start
        let totalNeeded = hdr.headerEnd + maskLen + hdr.payloadLen
        guard available >= totalNeeded else {
            return (.needMore, 0)
        }

        let maskStart = start + hdr.headerEnd
        let payloadStart = maskStart + maskLen
        var payload = [UInt8](repeating: 0, count: hdr.payloadLen)
        for i in 0..<hdr.payloadLen {
            payload[i] = buf[payloadStart + i] ^ buf[maskStart + (i & 3)]
        }
        let payloadData = Data(payload)
        let consumed = totalNeeded

        let isControl = hdr.opcode == 0x8 || hdr.opcode == 0x9 || hdr.opcode == 0xA
        if isControl {
            // Control frames must not be fragmented and payload ≤ 125.
            if !hdr.fin || hdr.payloadLen > Self.controlFrameMaxBytes {
                return (.mustClose(code: Self.invalidCloseCode), consumed)
            }
            switch hdr.opcode {
            case 0x9:
                return (.ping(payloadData), consumed)
            case 0xA:
                return (.pong(payloadData), consumed)
            case 0x8:
                return (parseClosePayload(payloadData), consumed)
            default:
                return (.mustClose(code: Self.invalidCloseCode), consumed)
            }
        }

        switch hdr.opcode {
        case 0x0:
            // Continuation only valid while a fragmented message is open.
            guard let op = fragmentOpcode else {
                return (.mustClose(code: Self.invalidCloseCode), consumed)
            }
            if fragmentBuffer.count + payloadData.count > Self.maxFragmentedMessageBytes {
                fragmentOpcode = nil
                fragmentBuffer = Data()
                return (.mustClose(code: Self.tooLargeCloseCode), consumed)
            }
            fragmentBuffer.append(payloadData)
            if hdr.fin {
                let complete = fragmentBuffer
                fragmentOpcode = nil
                fragmentBuffer = Data()
                return (finishDataMessage(opcode: op, payload: complete), consumed)
            }
            return (.fragmentProgress, consumed)

        case 0x1, 0x2:
            // Cannot start a new data message while fragmenting.
            if fragmentOpcode != nil {
                return (.mustClose(code: Self.invalidCloseCode), consumed)
            }
            if payloadData.count > Self.maxFragmentedMessageBytes {
                return (.mustClose(code: Self.tooLargeCloseCode), consumed)
            }
            if !hdr.fin {
                fragmentOpcode = hdr.opcode
                fragmentBuffer = payloadData
                return (.fragmentProgress, consumed)
            }
            return (finishDataMessage(opcode: hdr.opcode, payload: payloadData), consumed)

        default:
            return (.mustClose(code: Self.invalidCloseCode), consumed)
        }
    }

    private func finishDataMessage(opcode: UInt8, payload: Data) -> Event {
        if opcode == 0x1 {
            guard Self.isValidUTF8(payload) else {
                return .mustClose(code: Self.invalidUtf8CloseCode)
            }
            return .text(payload)
        }
        return .binary(payload)
    }

    private func parseClosePayload(_ payload: Data) -> Event {
        if payload.isEmpty {
            return .peerClose(code: nil, reason: Data())
        }
        if payload.count == 1 {
            // Single-byte close payload is illegal (RFC6455 s5.5.1).
            return .mustClose(code: Self.invalidCloseCode)
        }
        let code = (UInt16(payload[payload.startIndex]) << 8)
            | UInt16(payload[payload.startIndex + 1])
        let reason = Data(payload.dropFirst(2))
        if !reason.isEmpty && !Self.isValidUTF8(reason) {
            return .mustClose(code: Self.invalidUtf8CloseCode)
        }
        // RFC6455 s7.4: reject reserved/out-of-range status codes with 1002.
        if !Self.isValidCloseStatusCode(code) {
            return .mustClose(code: Self.invalidCloseCode)
        }
        return .peerClose(code: code, reason: reason)
    }

    /// RFC6455 s7.4: wire status codes must be 1000…4999, excluding reserved
    /// codes that MUST NOT appear in a Close control frame (1004–1006, 1015).
    static func isValidCloseStatusCode(_ code: UInt16) -> Bool {
        switch code {
        case 1004, 1005, 1006, 1015:
            return false
        case 1000...4999:
            return true
        default:
            return false
        }
    }

    public static func isValidUTF8(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        return String(data: data, encoding: .utf8) != nil
    }

    // MARK: - Header parse

    public struct FrameHeader: Equatable, Sendable {
        public let fin: Bool
        public let rsv: UInt8
        public let opcode: UInt8
        public let masked: Bool
        public let payloadLen: Int
        public let headerEnd: Int
        public let shouldReject: Bool
        public let rejectCloseCode: UInt16
    }

    public static func frameHeader(buf: [UInt8], from start: Int) -> FrameHeader? {
        let available = buf.count - start
        guard available >= 2 else { return nil }
        let b0 = buf[start]
        let b1 = buf[start + 1]
        let fin = (b0 & 0x80) != 0
        let rsv = (b0 >> 4) & 0x07
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7F)
        var idx = 2
        if len == 126 {
            guard available >= 4 else { return nil }
            len = (Int(buf[start + 2]) << 8) | Int(buf[start + 3])
            idx = 4
        } else if len == 127 {
            guard available >= 10 else { return nil }
            var wideLen: UInt64 = 0
            for i in 0..<8 {
                wideLen = (wideLen << 8) | UInt64(buf[start + 2 + i])
            }
            guard wideLen <= UInt64(Int.max) else {
                return FrameHeader(
                    fin: fin, rsv: rsv, opcode: opcode, masked: masked,
                    payloadLen: 0, headerEnd: 10, shouldReject: true,
                    rejectCloseCode: tooLargeCloseCode
                )
            }
            len = Int(wideLen)
            idx = 10
        }
        // Per-frame and aggregate cap share the 1 MiB contract limit.
        if len > maxFragmentedMessageBytes {
            return FrameHeader(
                fin: fin, rsv: rsv, opcode: opcode, masked: masked,
                payloadLen: 0, headerEnd: idx, shouldReject: true,
                rejectCloseCode: tooLargeCloseCode
            )
        }
        return FrameHeader(
            fin: fin, rsv: rsv, opcode: opcode, masked: masked,
            payloadLen: len, headerEnd: idx, shouldReject: false,
            rejectCloseCode: invalidCloseCode
        )
    }
}
