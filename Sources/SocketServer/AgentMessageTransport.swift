import CryptoKit
import Foundation
import CoreModel
import Persistence

/// Frozen bounded wire contract for message list/get/event transport.
///
/// Legacy callers remain unchanged. Version 1 responses are measured after JSON
/// escaping, including their JSON-RPC wrapper, so a large body can never consume
/// the live WebSocket frame budget.
public enum AgentMessageTransport {
    public static let listMaxBodyBytesCap = 1_048_576
    public static let getMaxBytesCap = 256 * 1_024
    public static let minimumResponseBytes = 1_024
    public static let eventContentMaxBytes = 2_048
    public static let eventPayloadMaxBytes = 64 * 1_024
    public static let attachmentJSONMaxBytes = 16 * 1_024
    public static let attachmentWireMaxBytes = 4 * 1_024
    public static let attachmentCountLimit = 32
    /// Exact authenticated opt-in. Clients must compare the complete object;
    /// public HTTP capability data is advisory and never authorizes v1.
    public static let capabilityMarker: JSONValue = .object([
        "protocol": .string("agent.message.v1"),
        "version": .number(1),
        "list": .string("bounded-envelope"),
        "get": .string("rpc-byte-offset"),
        "event": .string("bounded-preview"),
        "metadata": .string("offset-zero-only"),
        "digest": .string("sha256-hex"),
        "revision": .string("body_revision"),
    ])

    public static func clampListMaxBodyBytes(_ raw: Int) -> Int {
        min(max(1, raw), listMaxBodyBytesCap)
    }

    public static func clampGetMaxBytes(_ raw: Int) -> Int {
        min(max(1, raw), getMaxBytesCap)
    }

    public static func supportsResponseBudget(_ bytes: Int) -> Bool {
        bytes >= minimumResponseBytes
    }

    /// Leave room for escaped metadata while still selecting the prioritized
    /// row in SQL. The transport performs the final exact-envelope fit.
    public static func sqlContentLimit(for responseBytes: Int) -> Int {
        max(1, responseBytes / 2)
    }

    /// Longest valid UTF-8 prefix no larger than `maxBytes`.
    ///
    /// Truncates on a Character boundary (same contract as the prior Character-forward
    /// scan). Implementation jumps O(1) into the UTF-8 view then walks back at most one
    /// grapheme cluster — the softTruncateUTF8Payload pattern — so large list/get/event
    /// envelopes do not pay O(budget) Character index traffic.
    public static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        guard text.utf8.count > maxBytes else { return text }
        var utf8End = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: maxBytes,
            limitedBy: text.utf8.endIndex
        ) ?? text.utf8.endIndex
        while utf8End > text.utf8.startIndex {
            if let end = utf8End.samePosition(in: text) {
                return String(text[..<end])
            }
            text.utf8.formIndex(before: &utf8End)
        }
        return ""
    }

    /// SHA-256 hex digest of the full message body (wire `body_sha256` / digest marker).
    ///
    /// Hashes contiguous UTF-8 storage without a `Data(text.utf8)` intermediate, and
    /// formats hex with a nibble table instead of per-byte `String(format:)`.
    public static func bodySHA256Hex(_ text: String) -> String {
        var hasher = SHA256()
        var copy = text
        copy.withUTF8 { buffer in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(buffer))
        }
        return hexDigest(hasher.finalize())
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

    /// Test/in-memory router adapter. Production AppCommandRouter overrides
    /// this seam with AgentMessageRepository.bodyChunk so this allocation is
    /// never on the shipped host path.
    public static func inMemoryBodyChunk(
        message: AgentMessage,
        offsetBytes: Int,
        maxContentBytes: Int
    ) -> AgentMessageBodyChunk? {
        let bytes = Array(message.content.utf8)
        guard offsetBytes >= 0,
              offsetBytes <= bytes.count,
              isUTF8Boundary(bytes: bytes, offset: offsetBytes) else {
            return nil
        }
        let end = utf8ChunkEnd(
            bytes: bytes,
            offset: offsetBytes,
            maximumBytes: maxContentBytes
        )
        let content = String(
            decoding: bytes[offsetBytes..<end],
            as: UTF8.self
        )
        let attachments = Array(
            message.attachments.prefix(attachmentCountLimit)
        )
        return AgentMessageBodyChunk(
            id: message.id,
            content: content,
            bodyByteCount: bytes.count,
            bodySHA256: bodySHA256Hex(message.content),
            bodyRevision: 1,
            bodyOffset: offsetBytes,
            metadata: offsetBytes == 0
                ? AgentMessageBodyChunkMetadata(
                    threadId: message.threadId,
                    role: message.role,
                    createdAt: message.createdAt,
                    attachments: attachments,
                    attachmentCount: message.attachments.count,
                    attachmentsTruncated:
                        attachments.count < message.attachments.count
                  )
                : nil
        )
    }

    // MARK: - In-memory routing fallback

    public static func pageWithinBodyBudget(
        page: AgentMessagePage,
        budget: Int,
        contentLimit: Int,
        afterDirection: Bool
    ) -> AgentMessageBodyBudgetResult {
        let targetBudget = max(1, budget)
        let perMessageLimit = max(1, contentLimit)
        let priority = afterDirection
            ? page.messages
            : Array(page.messages.reversed())
        var keptIDs = Set<AgentMessageID>()
        var runningBytes = 0
        for message in priority {
            let admittedBytes = min(
                message.content.utf8.count,
                perMessageLimit
            )
            guard keptIDs.isEmpty
                    || runningBytes + admittedBytes <= targetBudget else {
                break
            }
            keptIDs.insert(message.id)
            runningBytes += min(admittedBytes, targetBudget)
        }

        let kept = page.messages.filter { keptIDs.contains($0.id) }
        var contentByID: [AgentMessageID: String] = [:]
        var remaining = targetBudget
        for message in (afterDirection ? kept : Array(kept.reversed())) {
            let capped = utf8Prefix(
                message.content,
                maxBytes: perMessageLimit
            )
            let content = utf8Prefix(capped, maxBytes: remaining)
            contentByID[message.id] = content
            remaining -= content.utf8.count
        }

        var originalByteCounts: [AgentMessageID: Int] = [:]
        var truncatedIDs = Set<AgentMessageID>()
        var attachmentCounts: [AgentMessageID: Int] = [:]
        var attachmentTruncatedIDs = Set<AgentMessageID>()
        let rows = kept.map { message -> AgentMessage in
            let content = contentByID[message.id] ?? ""
            let originalBytes = message.content.utf8.count
            originalByteCounts[message.id] = originalBytes
            if content.utf8.count < originalBytes {
                truncatedIDs.insert(message.id)
            }
            attachmentCounts[message.id] = message.attachments.count
            let attachments = boundedAttachments(message.attachments)
            if attachments.count < message.attachments.count {
                attachmentTruncatedIDs.insert(message.id)
            }
            return AgentMessage(
                id: message.id,
                threadId: message.threadId,
                role: message.role,
                content: content,
                createdAt: message.createdAt,
                attachments: attachments
            )
        }

        let dropped = max(0, page.messages.count - rows.count)
        return AgentMessageBodyBudgetResult(
            rows: rows,
            blanked: dropped,
            hasMoreOlder:
                page.hasMoreOlder || (!afterDirection && dropped > 0),
            nextBefore: rows.first.map {
                AgentMessageCursor(createdAt: $0.createdAt, id: $0.id)
            },
            hasMoreNewer:
                page.hasMoreNewer || (afterDirection && dropped > 0),
            nextAfter: rows.last.map {
                AgentMessageCursor(createdAt: $0.createdAt, id: $0.id)
            },
            originalByteCounts: originalByteCounts,
            truncatedIDs: truncatedIDs,
            attachmentCounts: attachmentCounts,
            attachmentTruncatedIDs: attachmentTruncatedIDs,
            prefersNewestBodies: !afterDirection
        )
    }

    // MARK: - Version 1 list

    /// Returns nil only when even an empty versioned envelope cannot fit the
    /// requested response budget (for example, an adversarially huge request id).
    public static func v1ListResult(
        from source: AgentMessageBodyBudgetResult,
        maxResponseBytes: Int,
        responseID: JSONRPCID?,
        basePayload: (AgentMessage) -> JSONValue,
        encodeCursor: (AgentMessageCursor) -> JSONValue
    ) -> JSONValue? {
        var retained = source.rows
        var droppedForEnvelope = false

        while true {
            // A non-empty source must either return at least one identity row
            // (which owns the pagination cursor) or fail structurally. Returning
            // an empty envelope with has_more=true and null cursors deadlocks the
            // client pager.
            if retained.isEmpty, !source.rows.isEmpty {
                return nil
            }
            let maximumContentBytes = retained.reduce(0) {
                $0 + $1.content.utf8.count
            }
            var lower = 0
            var upper = maximumContentBytes
            var best: JSONValue?
            while lower <= upper {
                let proposed = lower + (upper - lower) / 2
                let result = makeV1ListResult(
                    source: source,
                    retained: retained,
                    contentBudget: proposed,
                    droppedForEnvelope: droppedForEnvelope,
                    basePayload: basePayload,
                    encodeCursor: encodeCursor
                )
                if encodedResponseBytes(id: responseID, result: result)
                    <= maxResponseBytes {
                    best = result
                    lower = proposed + 1
                } else {
                    upper = proposed - 1
                }
            }
            if let best { return best }
            guard !retained.isEmpty else { return nil }
            droppedForEnvelope = true
            if source.prefersNewestBodies {
                retained.removeFirst()
            } else {
                retained.removeLast()
            }
        }
    }

    private static func makeV1ListResult(
        source: AgentMessageBodyBudgetResult,
        retained: [AgentMessage],
        contentBudget: Int,
        droppedForEnvelope: Bool,
        basePayload: (AgentMessage) -> JSONValue,
        encodeCursor: (AgentMessageCursor) -> JSONValue
    ) -> JSONValue {
        let priority = source.prefersNewestBodies
            ? Array(retained.reversed())
            : retained
        var remaining = max(0, contentBudget)
        var contentByID: [AgentMessageID: String] = [:]
        for message in priority {
            let content = utf8Prefix(message.content, maxBytes: remaining)
            contentByID[message.id] = content
            remaining -= content.utf8.count
        }

        let messages = retained.map { message -> JSONValue in
            let content = contentByID[message.id] ?? ""
            let original = source.originalByteCounts[message.id]
                ?? message.content.utf8.count
            let attachmentCount = source.attachmentCounts[message.id]
                ?? message.attachments.count
            let bounded = boundedMessage(message, content: content)
            return messageWireObject(
                base: basePayload(bounded),
                content: content,
                bodyAvailable: true,
                bodyTruncated:
                    original > content.utf8.count
                    || source.truncatedIDs.contains(message.id),
                bodyByteCount: original,
                bodySHA256: nil,
                bodyRevision: nil,
                bodyOffset: nil,
                bodyNextOffset: nil,
                attachmentCount: attachmentCount,
                attachmentsTruncated:
                    source.attachmentTruncatedIDs.contains(message.id)
                    || bounded.attachments.count < attachmentCount
            )
        }

        let droppedOlder = droppedForEnvelope
            && source.prefersNewestBodies
        let droppedNewer = droppedForEnvelope
            && !source.prefersNewestBodies
        return .object([
            "version": .number(1),
            "messages": .array(messages),
            "has_more_older":
                .bool(source.hasMoreOlder || droppedOlder),
            "has_more_newer":
                .bool(source.hasMoreNewer || droppedNewer),
            "next_before": retained.first.map {
                encodeCursor(
                    AgentMessageCursor(createdAt: $0.createdAt, id: $0.id)
                )
            } ?? .null,
            "next_after": retained.last.map {
                encodeCursor(
                    AgentMessageCursor(createdAt: $0.createdAt, id: $0.id)
                )
            } ?? .null,
        ])
    }

    // MARK: - Version 1 get chunks

    /// Fits one already-SQL-bounded body page under the exact JSON-RPC budget.
    /// Persistence owns digest/revision and never returns a full body here.
    public static func v1GetResult(
        chunk: AgentMessageBodyChunk,
        maxResponseBytes: Int,
        responseID: JSONRPCID?,
        basePayload: (AgentMessage) -> JSONValue
    ) -> JSONValue? {
        let offsetBytes = chunk.bodyOffset
        guard offsetBytes >= 0,
              offsetBytes <= chunk.bodyByteCount,
              (offsetBytes == 0) == (chunk.metadata != nil) else {
            return nil
        }
        let maximumChunkBytes = min(
            chunk.content.utf8.count,
            maxResponseBytes
        )
        var lower = 0
        var upper = maximumChunkBytes
        var best: (result: JSONValue, end: Int)?

        while lower <= upper {
            let proposed = lower + (upper - lower) / 2
            let content = utf8Prefix(
                chunk.content,
                maxBytes: proposed
            )
            let end = offsetBytes + content.utf8.count
            let nextOffset: Int? =
                end < chunk.bodyByteCount ? end : nil
            let wire: JSONValue
            if let metadata = chunk.metadata {
                let bounded = AgentMessage(
                    id: chunk.id,
                    threadId: metadata.threadId,
                    role: metadata.role,
                    content: content,
                    createdAt: metadata.createdAt,
                    attachments: metadata.attachments
                )
                wire = messageWireObject(
                    base: basePayload(bounded),
                    content: content,
                    bodyAvailable: true,
                    bodyTruncated: nextOffset != nil,
                    bodyByteCount: chunk.bodyByteCount,
                    bodySHA256: chunk.bodySHA256,
                    bodyRevision: chunk.bodyRevision,
                    bodyOffset: offsetBytes,
                    bodyNextOffset: nextOffset,
                    attachmentCount: metadata.attachmentCount,
                    attachmentsTruncated:
                        metadata.attachmentsTruncated
                )
            } else {
                wire = .object([
                    "id": .string(chunk.id.value.uuidString),
                    "content": .string(content),
                    "body_byte_count":
                        .number(Double(chunk.bodyByteCount)),
                    "body_sha256": .string(chunk.bodySHA256),
                    "body_revision":
                        .number(Double(chunk.bodyRevision)),
                    "body_offset": .number(Double(offsetBytes)),
                    "body_next_offset":
                        nextOffset.map { .number(Double($0)) } ?? .null,
                    "body_truncated": .bool(nextOffset != nil),
                ])
            }
            let result: JSONValue = .object([
                "version": .number(1),
                "message": wire,
                "body_offset": .number(Double(offsetBytes)),
                "body_next_offset":
                    nextOffset.map { .number(Double($0)) } ?? .null,
            ])
            if encodedResponseBytes(id: responseID, result: result)
                <= maxResponseBytes {
                if best == nil || end > best!.end {
                    best = (result, end)
                }
                lower = proposed + 1
            } else {
                upper = proposed - 1
            }
        }

        guard let best else { return nil }
        // A non-final chunk must always advance; otherwise a client could loop.
        guard best.end > offsetBytes
                || offsetBytes == chunk.bodyByteCount else {
            return nil
        }
        return best.result
    }

    // MARK: - Appended event

    public static func appendedEventPayload(
        from message: AgentMessage
    ) -> JSONValue {
        let bodyBytes = message.content.utf8.count
        let content = utf8Prefix(
            message.content,
            maxBytes: eventContentMaxBytes
        )
        let attachments = boundedAttachments(message.attachments)
        // PERF: build the wire object directly. The prior path encoded a bounded
        // AgentMessage then immediately decoded it as JSONValue solely to swap
        // attachments — a full JSON round-trip on every agent.message.appended
        // (including multi-KB assistant bodies truncated only after encode).
        // Identity fields match default Codable shape (`{value: uuid}` IDs,
        // deferredToDate createdAt); attachments use the reference projection.
        let base: JSONValue = .object([
            "id": .object(["value": .string(message.id.value.uuidString)]),
            "threadId": .object([
                "value": .string(message.threadId.value.uuidString),
            ]),
            "role": .string(message.role.rawValue),
            "content": .string(content),
            "createdAt": .number(
                message.createdAt.timeIntervalSinceReferenceDate
            ),
            "attachments": attachmentReferenceValues(attachments),
        ])
        let payload = messageWireObject(
            base: base,
            content: content,
            bodyAvailable: true,
            bodyTruncated: content.utf8.count < bodyBytes,
                bodyByteCount: bodyBytes,
                bodySHA256: bodySHA256Hex(message.content),
                bodyRevision: 1,
                bodyOffset: nil,
                bodyNextOffset: nil,
            attachmentCount: message.attachments.count,
            attachmentsTruncated:
                attachments.count < message.attachments.count
        )
        assert(
            encodedValueBytes(payload) <= eventPayloadMaxBytes,
            "bounded agent.message.appended payload exceeded its event cap"
        )
        return payload
    }

    // MARK: - Helpers

    private static func boundedMessage(
        _ message: AgentMessage,
        content: String
    ) -> AgentMessage {
        AgentMessage(
            id: message.id,
            threadId: message.threadId,
            role: message.role,
            content: content,
            createdAt: message.createdAt,
            attachments: boundedAttachments(message.attachments)
        )
    }

    private static func boundedAttachments(
        _ source: [AgentAttachment]
    ) -> [AgentAttachment] {
        var result: [AgentAttachment] = []
        var encodedBytes = 2
        for attachment in source.prefix(attachmentCountLimit) {
            guard let reference = AgentAttachmentReference(attachment) else {
                continue
            }
            // Measure the same wire object clients receive (not a second
            // Codable encoding of the reference that is later re-encoded).
            let bytes = encodedValueBytes(attachmentReferenceValue(reference))
            guard encodedBytes + bytes + 1 <= attachmentWireMaxBytes else {
                break
            }
            result.append(attachment)
            encodedBytes += bytes + 1
        }
        return result
    }

    private static func attachmentReferenceValues(
        _ attachments: [AgentAttachment]
    ) -> JSONValue {
        .array(attachments.compactMap { attachment in
            guard let reference = AgentAttachmentReference(attachment) else {
                return nil
            }
            return attachmentReferenceValue(reference)
        })
    }

    /// Path-free attachment reference as wire JSON — same keys as default
    /// `AgentAttachmentReference` Codable (optional `mimeType` omitted when nil).
    ///
    /// PERF: avoids encode→decode of each reference on every message event/list
    /// envelope that projects attachments.
    private static func attachmentReferenceValue(
        _ reference: AgentAttachmentReference
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(reference.id),
            "displayName": .string(reference.displayName),
            "kind": .string(reference.kind.rawValue),
            "sha256": .string(reference.sha256),
            "sizeBytes": .number(Double(reference.sizeBytes)),
        ]
        if let mimeType = reference.mimeType {
            object["mimeType"] = .string(mimeType)
        }
        return .object(object)
    }

    private static func messageWireObject(
        base: JSONValue,
        content: String,
        bodyAvailable: Bool,
        bodyTruncated: Bool,
        bodyByteCount: Int,
        bodySHA256: String?,
        bodyRevision: Int?,
        bodyOffset: Int?,
        bodyNextOffset: Int?,
        attachmentCount: Int,
        attachmentsTruncated: Bool
    ) -> JSONValue {
        guard case .object(var object) = base else { return .null }
        object["content"] = .string(content)
        object["body_available"] = .bool(bodyAvailable)
        object["body_truncated"] = .bool(bodyTruncated)
        object["body_byte_count"] = .number(Double(bodyByteCount))
        object["attachment_count"] = .number(Double(attachmentCount))
        object["attachments_truncated"] =
            .bool(attachmentsTruncated)
        if let bodySHA256 {
            object["body_sha256"] = .string(bodySHA256)
        }
        if let bodyRevision {
            object["body_revision"] = .number(Double(bodyRevision))
        }
        if let bodyOffset {
            object["body_offset"] = .number(Double(bodyOffset))
            object["body_next_offset"] =
                bodyNextOffset.map { .number(Double($0)) } ?? .null
        }
        return .object(object)
    }

    // PERF: v1 list/get binary-search fits re-encode the envelope ~log(N) times
    // per RPC, and attachment wire sizing encodes each reference. JSONEncoder is
    // not thread-safe — serialize concurrent fits under a short lock.
    private static let encodeLock = NSLock()
    private static let sharedEncoder = JSONEncoder()

    private static func encodedResponseBytes(
        id: JSONRPCID?,
        result: JSONValue
    ) -> Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return (try? sharedEncoder.encode(
            JSONRPCResponse(id: id, result: result)
        ).count) ?? Int.max
    }

    private static func encodedValueBytes(_ value: JSONValue) -> Int {
        encodeLock.lock()
        defer { encodeLock.unlock() }
        return (try? sharedEncoder.encode(value).count) ?? Int.max
    }

    private static func isUTF8Boundary(
        bytes: [UInt8],
        offset: Int
    ) -> Bool {
        offset == 0
            || offset == bytes.count
            || bytes[offset] & 0xC0 != 0x80
    }

    private static func utf8ChunkEnd(
        bytes: [UInt8],
        offset: Int,
        maximumBytes: Int
    ) -> Int {
        var end = min(bytes.count, offset + max(0, maximumBytes))
        while end > offset,
              end < bytes.count,
              bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }
        return end
    }
}
