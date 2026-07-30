import CryptoKit
import CoreModel
import Foundation

/// Versioned, byte-paged projection for `agent.plan.notes.get` / compact
/// `agent.plan.notes.updated` events.
///
/// WHY: plan notes are authoritative and may be multi-MiB. Returning the full
/// string on every get or mirror event can exceed the WebSocket frame/queue
/// budget on a weak link and drop the live stream. Persistence stays full and
/// unchanged; only the wire projection is bounded. Legacy clients that omit
/// `protocol_version` keep the pre-v1 full-string get response.
public enum PlanNotesProjectionV1: Sendable {
    public static let protocolVersion = 1
    /// Raw UTF-8 ceiling for one page of note text (before JSON escaping).
    public static let maxBytesCeiling = 64 * 1024
    /// Hard proof target for a fully encoded JSON-RPC response (escape-heavy).
    public static let maxEncodedResponseBytes = 512 * 1024
    /// Compact update event preview — small enough that the event cannot blow
    /// the outbound queue even when many threads update.
    public static let eventPreviewMaxBytes = 256

    public struct Page: Sendable, Equatable {
        public let notes: String
        public let totalBytes: Int
        public let returnedBytes: Int
        public let offsetBytes: Int
        public let nextOffsetBytes: Int
        public let hasMore: Bool
        public let truncated: Bool
        public let contentDigest: String
        public let revision: String

        public var json: JSONValue {
            .object([
                "protocol_version": .number(Double(PlanNotesProjectionV1.protocolVersion)),
                "notes": .string(notes),
                "total_bytes": .number(Double(totalBytes)),
                "returned_bytes": .number(Double(returnedBytes)),
                "offset_bytes": .number(Double(offsetBytes)),
                "next_offset_bytes": .number(Double(nextOffsetBytes)),
                "has_more": .bool(hasMore),
                "truncated": .bool(truncated),
                "content_digest": .string(contentDigest),
                "revision": .string(revision),
            ])
        }
    }

    public struct Caps: Sendable, Equatable {
        public let offsetBytes: Int
        public let maxBytes: Int
        /// When set, must equal the current notes digest or the page fails closed.
        public let expectedContentDigest: String?

        public init(offsetBytes: Int, maxBytes: Int, expectedContentDigest: String?) {
            self.offsetBytes = offsetBytes
            self.maxBytes = maxBytes
            self.expectedContentDigest = expectedContentDigest
        }
    }

    /// Parse opt-in v1 paging caps.
    ///
    /// - Returns `nil` when `protocol_version` is absent (legacy full-string path).
    /// - Throws `invalidParams` when the key is present but the request is not a
    ///   valid integral v1 page (no silent downgrade).
    public static func parseCaps(_ params: [String: JSONValue]) throws -> Caps? {
        guard params["protocol_version"] != nil else { return nil }

        guard let version = strictNonNegativeInt(params["protocol_version"]),
              version == protocolVersion else {
            throw JSONRPCError.invalidParams
        }

        let offset: Int
        if params["offset_bytes"] == nil {
            offset = 0
        } else if let value = strictNonNegativeInt(params["offset_bytes"]) {
            offset = value
        } else {
            throw JSONRPCError.invalidParams
        }

        let maxBytes: Int
        if params["max_bytes"] == nil {
            maxBytes = maxBytesCeiling
        } else if let value = strictPositiveInt(params["max_bytes"]),
                  value <= maxBytesCeiling {
            maxBytes = value
        } else {
            throw JSONRPCError.invalidParams
        }

        let expected: String?
        if let raw = params["content_digest"] {
            guard let digest = raw.stringValue, isSHA256Hex(digest) else {
                throw JSONRPCError.invalidParams
            }
            expected = digest
        } else {
            expected = nil
        }

        return Caps(offsetBytes: offset, maxBytes: maxBytes, expectedContentDigest: expected)
    }

    /// Page `notes` at a UTF-8-safe byte cursor. Never mutates `notes`.
    ///
    /// WHY mid-page digest check: reassembly across pages must not splice two
    /// revisions of the same thread's notes into one client buffer.
    public static func page(notes: String, caps: Caps) throws -> Page {
        let data = Data(notes.utf8)
        let total = data.count
        let digest = contentDigest(of: data)

        if let expected = caps.expectedContentDigest, expected != digest {
            throw JSONRPCError(
                code: -32009,
                message: "Plan notes changed during pagination.",
                data: .object([
                    "content_digest": .string(digest),
                    "expected_content_digest": .string(expected),
                    "revision": .string(digest),
                ])
            )
        }

        guard caps.offsetBytes <= total else {
            throw JSONRPCError.invalidParams
        }
        guard isUTF8Boundary(data, offset: caps.offsetBytes) else {
            throw JSONRPCError.invalidParams
        }

        if caps.offsetBytes == total {
            return Page(
                notes: "",
                totalBytes: total,
                returnedBytes: 0,
                offsetBytes: caps.offsetBytes,
                nextOffsetBytes: total,
                hasMore: false,
                truncated: total > 0,
                contentDigest: digest,
                revision: digest
            )
        }

        var end = min(caps.offsetBytes + caps.maxBytes, total)
        // `end` is exclusive: a valid cut is EOF or the start of a scalar
        // (not a continuation). Walking only from end-1 would leave a lead
        // byte of the next scalar in the slice and produce invalid UTF-8.
        while end > caps.offsetBytes && end < total && isUTF8Continuation(data[end]) {
            end -= 1
        }
        // If the budget cannot hold even one scalar, still emit one so
        // pagination always makes progress (at most +3 bytes over max_bytes).
        if end == caps.offsetBytes {
            end = nextScalarEnd(data, from: caps.offsetBytes)
        }

        let slice = data[caps.offsetBytes..<end]
        guard let chunk = String(data: slice, encoding: .utf8) else {
            // Authoritative notes are always valid UTF-8 from Swift String storage;
            // a failed decode here means a cursor bug, not bad user data.
            throw JSONRPCError.invalidParams
        }

        let returned = slice.count
        let next = caps.offsetBytes + returned
        let hasMore = next < total
        return Page(
            notes: chunk,
            totalBytes: total,
            returnedBytes: returned,
            offsetBytes: caps.offsetBytes,
            nextOffsetBytes: next,
            hasMore: hasMore,
            truncated: hasMore || caps.offsetBytes > 0,
            contentDigest: digest,
            revision: digest
        )
    }

    /// Compact realtime payload — digest/revision + bounded preview only.
    ///
    /// WHY: the previous event embedded full `notes`, which could exceed the WS
    /// outbound budget and stall the live stream. Full text stays fetchable via
    /// `agent.plan.notes.get` with protocol_version 1.
    public static func compactUpdateEvent(threadId: AgentThreadID, notes: String) -> JSONValue {
        let data = Data(notes.utf8)
        let digest = contentDigest(of: data)
        let preview = utf8Prefix(notes, maxBytes: eventPreviewMaxBytes)
        let previewBytes = preview.utf8.count
        return .object([
            "thread_id": .string(threadId.value.uuidString),
            "protocol_version": .number(Double(protocolVersion)),
            "content_digest": .string(digest),
            "revision": .string(digest),
            "total_bytes": .number(Double(data.count)),
            "preview": .string(preview),
            "preview_bytes": .number(Double(previewBytes)),
            "preview_truncated": .bool(previewBytes < data.count),
            "rehydrate_required": .bool(true),
        ])
    }

    public static func contentDigest(of notes: String) -> String {
        contentDigest(of: Data(notes.utf8))
    }

    public static func contentDigest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Encode a JSON-RPC success envelope the same way the socket path does,
    /// so tests can prove the final frame stays under `maxEncodedResponseBytes`.
    public static func encodedJSONRPCResponseBytes(id: JSONRPCID, page: Page) throws -> Int {
        let response = JSONRPCResponse(id: id, result: page.json)
        return try JSONEncoder().encode(response).count
    }

    // MARK: - Parsing helpers

    /// Finite, integral, non-negative number only (rejects NaN/Inf/fractional).
    public static func strictNonNegativeInt(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value,
              number.isFinite,
              number >= 0,
              number.rounded(.towardZero) == number,
              let exact = Int(exactly: number) else {
            return nil
        }
        return exact
    }

    /// Finite, integral, positive number only.
    public static func strictPositiveInt(_ value: JSONValue?) -> Int? {
        guard let value = strictNonNegativeInt(value), value > 0 else { return nil }
        return value
    }

    public static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    // MARK: - UTF-8 cursor helpers

    public static func isUTF8Boundary(_ data: Data, offset: Int) -> Bool {
        if offset == 0 || offset == data.count { return true }
        guard offset > 0, offset < data.count else { return false }
        return !isUTF8Continuation(data[offset])
    }

    public static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (byte & 0xC0) == 0x80
    }

    /// End index (exclusive) of the UTF-8 scalar that starts at `from`.
    public static func nextScalarEnd(_ data: Data, from: Int) -> Int {
        guard from < data.count else { return from }
        let lead = data[from]
        let width: Int
        if lead < 0x80 {
            width = 1
        } else if lead < 0xE0 {
            width = 2
        } else if lead < 0xF0 {
            width = 3
        } else {
            width = 4
        }
        return min(from + width, data.count)
    }

    /// Longest UTF-8-safe prefix of `text` with at most `maxBytes` raw bytes.
    public static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(text.utf8)
        guard data.count > maxBytes else { return text }
        var end = maxBytes
        // Exclusive end must sit on a scalar boundary (see page()).
        while end > 0 && end < data.count && isUTF8Continuation(data[end]) {
            end -= 1
        }
        if end == 0 {
            end = nextScalarEnd(data, from: 0)
        }
        return String(data: data[0..<end], encoding: .utf8) ?? ""
    }
}
