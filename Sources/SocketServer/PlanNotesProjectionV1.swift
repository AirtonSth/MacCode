import CryptoKit
import CoreModel
import Foundation

/// Versioned, byte-paged projection for `agent.plan.notes.get` / compact
/// `agent.plan.notes.updated` events / digest-CAS `agent.plan.notes.save`.
///
/// WHY: plan notes are authoritative and may be multi-MiB. Returning the full
/// string on every get or mirror event — or echoing the entire prior body as
/// `expected_notes` on save — can exceed the WebSocket frame/queue budget on a
/// weak link and drop the live stream. Persistence stays full and unchanged;
/// only the wire projection/CAS token is bounded. Legacy clients that omit
/// `protocol_version` keep the pre-v1 full-string get and full-body CAS save.
public enum PlanNotesProjectionV1: Sendable {
    public static let protocolVersion = 1
    /// Raw UTF-8 ceiling for one page of note text (before JSON escaping).
    public static let maxBytesCeiling = 64 * 1024
    /// Negotiated iOS weak-link/edit safety ceiling. Does not truncate or change
    /// authoritative macOS persistence or legacy full-body clients.
    public static let maxEditableBytes = 256 * 1024
    /// Hard proof target for a fully encoded JSON-RPC response (escape-heavy).
    public static let maxEncodedResponseBytes = 512 * 1024
    /// Compact update event preview — small enough that the event cannot blow
    /// the outbound queue even when many threads update.
    public static let eventPreviewMaxBytes = 256

    /// Exact `agent.plan_notes` object for every host capability authority that
    /// ships v1 get + digest-CAS save (this module). HTTP public/authenticated
    /// envelopes and legacy `system.capabilities` must both use these builders
    /// so a new iOS client never opts into `protocol_version:1` against an
    /// older host that would ignore unknown params and save without CAS.
    public enum CapabilityAdvertisement: Sendable {
        public static let digestCAS = true
        public static let transport = "http_preferred"

        /// Foundation dictionary for `DirectHTTPServer.capabilitiesPayload`.
        public static var foundationObject: [String: Any] {
            [
                "protocol_version": PlanNotesProjectionV1.protocolVersion,
                "max_page_bytes": PlanNotesProjectionV1.maxBytesCeiling,
                "max_editable_bytes": PlanNotesProjectionV1.maxEditableBytes,
                "digest_cas": digestCAS,
                "transport": transport,
            ]
        }

        /// JSON-RPC value for authenticated `system.capabilities`.
        public static var jsonValue: JSONValue {
            .object([
                "protocol_version": .number(Double(PlanNotesProjectionV1.protocolVersion)),
                "max_page_bytes": .number(Double(PlanNotesProjectionV1.maxBytesCeiling)),
                "max_editable_bytes": .number(Double(PlanNotesProjectionV1.maxEditableBytes)),
                "digest_cas": .bool(digestCAS),
                "transport": .string(transport),
            ])
        }
    }

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

    /// Opt-in v1 save CAS token — digest of the previously hydrated notes body.
    public struct SaveCaps: Sendable, Equatable {
        public let expectedContentDigest: String

        public init(expectedContentDigest: String) {
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

    /// Parse opt-in v1 save CAS caps.
    ///
    /// - Returns `nil` when `protocol_version` is absent (legacy full-body
    ///   `expected_notes` path).
    /// - Throws `invalidParams` when the key is present but the request is not
    ///   a valid integral v1 digest CAS (no silent downgrade, no dual body).
    public static func parseSaveCaps(_ params: [String: JSONValue]) throws -> SaveCaps? {
        guard params["protocol_version"] != nil else { return nil }

        guard let version = strictNonNegativeInt(params["protocol_version"]),
              version == protocolVersion else {
            throw JSONRPCError.invalidParams
        }

        // Modern clients must not pay both the digest and the full prior body.
        if params["expected_notes"] != nil {
            throw JSONRPCError.invalidParams
        }

        guard let digest = params["expected_content_digest"]?.stringValue,
              isSHA256Hex(digest) else {
            throw JSONRPCError.invalidParams
        }

        return SaveCaps(expectedContentDigest: digest)
    }

    /// Compact v1 save success — no notes body, just CAS/size metadata.
    public static func saveResult(notes: String) -> JSONValue {
        let totalBytes = notes.utf8.count
        let digest = contentDigest(of: notes)
        return .object([
            "ok": .bool(true),
            "content_digest": .string(digest),
            "revision": .string(digest),
            "total_bytes": .number(Double(totalBytes)),
        ])
    }

    /// CAS mismatch for save — current digest/revision so the client can rehydrate.
    public static func saveDigestMismatchError(
        currentNotes: String,
        expectedDigest: String
    ) -> JSONRPCError {
        let digest = contentDigest(of: currentNotes)
        return JSONRPCError(
            code: -32009,
            message: "Plan notes changed on another device.",
            data: .object([
                "content_digest": .string(digest),
                "expected_content_digest": .string(expectedDigest),
                "revision": .string(digest),
            ])
        )
    }

    /// Page `notes` at a UTF-8-safe byte cursor. Never mutates `notes`.
    ///
    /// WHY mid-page digest check: reassembly across pages must not splice two
    /// revisions of the same thread's notes into one client buffer.
    ///
    /// PERF: no full-body `Data(notes.utf8)` — total via O(1) `utf8.count`,
    /// digest via contiguous UTF-8 hash, and the admitted window is decoded
    /// from a `withUTF8` slice. Multi-MiB notes only allocate the returned page.
    public static func page(notes: String, caps: Caps) throws -> Page {
        let total = notes.utf8.count
        let digest = contentDigest(of: notes)

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

        if caps.offsetBytes == total {
            // EOF cursor — no buffer walk needed.
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

        var copy = notes
        var chunk = ""
        var returned = 0
        var boundaryOK = false
        copy.withUTF8 { buffer in
            guard isUTF8Boundary(buffer, offset: caps.offsetBytes) else { return }
            boundaryOK = true

            var end = min(caps.offsetBytes + caps.maxBytes, total)
            // `end` is exclusive: a valid cut is EOF or the start of a scalar
            // (not a continuation). Walking only from end-1 would leave a lead
            // byte of the next scalar in the slice and produce invalid UTF-8.
            while end > caps.offsetBytes && end < total && isUTF8Continuation(buffer[end]) {
                end -= 1
            }
            // If the budget cannot hold even one scalar, still emit one so
            // pagination always makes progress (at most +3 bytes over max_bytes).
            if end == caps.offsetBytes {
                end = nextScalarEnd(buffer, from: caps.offsetBytes)
            }

            // Authoritative notes are always valid UTF-8 from Swift String storage.
            let slice = buffer[caps.offsetBytes..<end]
            chunk = String(decoding: slice, as: UTF8.self)
            returned = slice.count
        }
        guard boundaryOK else {
            throw JSONRPCError.invalidParams
        }

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
    ///
    /// PERF: total size via O(1) `utf8.count`, digest via contiguous UTF-8 hash
    /// (no intermediate `Data(notes.utf8)`), preview via O(1) under-budget /
    /// bounded-head `utf8Prefix` — multi-MiB notes must not allocate a second
    /// full-body copy just to ship a 256-byte preview event.
    public static func compactUpdateEvent(threadId: AgentThreadID, notes: String) -> JSONValue {
        let totalBytes = notes.utf8.count
        let digest = contentDigest(of: notes)
        let preview = utf8Prefix(notes, maxBytes: eventPreviewMaxBytes)
        let previewBytes = preview.utf8.count
        return .object([
            "thread_id": .string(threadId.value.uuidString),
            "protocol_version": .number(Double(protocolVersion)),
            "content_digest": .string(digest),
            "revision": .string(digest),
            "total_bytes": .number(Double(totalBytes)),
            "preview": .string(preview),
            "preview_bytes": .number(Double(previewBytes)),
            "preview_truncated": .bool(previewBytes < totalBytes),
            "rehydrate_required": .bool(true),
        ])
    }

    /// SHA-256 lowercase hex of `notes` UTF-8 — same digest as `contentDigest(of: Data(notes.utf8))`.
    ///
    /// Hashes contiguous UTF-8 storage without a `Data(text.utf8)` intermediate, and
    /// formats hex with a nibble table instead of per-byte `String(format:)`.
    public static func contentDigest(of notes: String) -> String {
        var hasher = SHA256()
        var copy = notes
        copy.withUTF8 { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hexDigest(hasher.finalize())
    }

    public static func contentDigest(of data: Data) -> String {
        hexDigest(SHA256.hash(data: data))
    }

    private static let hexNibbleAlphabet: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for byte in digest {
            out.append(hexNibbleAlphabet[Int(byte >> 4)])
            out.append(hexNibbleAlphabet[Int(byte & 0x0f)])
        }
        return String(bytes: out, encoding: .utf8) ?? ""
    }

    /// Success JSON-RPC envelope UTF-8 size without allocating encoder Data.
    /// Length-equal to default `JSONEncoder` so page-fit admissions stay identical.
    public static func encodedJSONRPCResponseBytes(id: JSONRPCID, page: Page) throws -> Int {
        EventBus.jsonRPCResponseByteCount(id: id, result: page.json)
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
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            return isUTF8Boundary(buffer, offset: offset)
        }
    }

    /// Same contract as the `Data` overload; used by `page` / `utf8Prefix` on
    /// contiguous UTF-8 storage without an intermediate `Data` copy.
    public static func isUTF8Boundary(
        _ buffer: UnsafeBufferPointer<UInt8>,
        offset: Int
    ) -> Bool {
        if offset == 0 || offset == buffer.count { return true }
        guard offset > 0, offset < buffer.count else { return false }
        return !isUTF8Continuation(buffer[offset])
    }

    public static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        (byte & 0xC0) == 0x80
    }

    /// End index (exclusive) of the UTF-8 scalar that starts at `from`.
    public static func nextScalarEnd(_ data: Data, from: Int) -> Int {
        data.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: UInt8.self)
            return nextScalarEnd(buffer, from: from)
        }
    }

    public static func nextScalarEnd(
        _ buffer: UnsafeBufferPointer<UInt8>,
        from: Int
    ) -> Int {
        guard from < buffer.count else { return from }
        let lead = buffer[from]
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
        return min(from + width, buffer.count)
    }

    /// Longest UTF-8-safe prefix of `text` with at most `maxBytes` raw bytes.
    ///
    /// Under-budget path is O(1) via `utf8.count` (no `Data(text.utf8)`). Over-budget
    /// walks only the admitted head on contiguous UTF-8 storage and cuts on a scalar
    /// boundary (same contract as the prior `Data` + continuation walk).
    public static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        // O(1) on native Swift strings: under-budget never pays a full-body copy.
        guard text.utf8.count > maxBytes else { return text }
        var copy = text
        var result = ""
        copy.withUTF8 { buffer in
            var end = maxBytes
            // Exclusive end must sit on a scalar boundary (see page()).
            while end > 0 && end < buffer.count && isUTF8Continuation(buffer[end]) {
                end -= 1
            }
            if end == 0 {
                let lead = buffer[0]
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
                end = min(width, buffer.count)
            }
            result = String(decoding: buffer[0..<end], as: UTF8.self)
        }
        return result
    }
}
