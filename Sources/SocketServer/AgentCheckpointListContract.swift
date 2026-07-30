import Foundation
import CoreModel

/// Wire contract for `agent.checkpoint.list` (legacy + response_version 1).
///
/// Explicit `response_version: 1` is HTTP JSON-RPC only and is forbidden in
/// nested `rpc.batch` and top-level JSON-RPC array batches. Legacy calls
/// (no `response_version`) retain prior Unix / WebSocket / batch behavior and
/// the historical full-array response shape.
public enum AgentCheckpointListContract: Sendable {
    public static let method = "agent.checkpoint.list"
    public static let responseVersion = 1

    // MARK: - Ceilings (shared with capability advertisement)

    public static let maxEntries = AgentTurnCheckpointListWireProjection.maxEntries
    public static let maxEncodedItemBytes = AgentTurnCheckpointListWireProjection.maxEncodedItemBytes
    public static let maxEncodedResponseBytes = AgentTurnCheckpointListWireProjection.maxEncodedResponseBytes
    public static let maxEncodedResponseIDBytes = maxEncodedItemBytes
    /// Complete encoded JSON-RPC request (id + method + params + escaping).
    /// Applies to explicit v1 envelopes; legacy transport behavior is unchanged.
    public static let maxEncodedRequestBytes = 16 * 1_024
    public static let maxThreadIDUTF8Bytes = 36
    public static let maxCursorTurnIDUTF8Bytes =
        AgentTurnCheckpointWireIdentity.maximumEncodedTurnIDBytes
    public static let maxCursorCompletedAtUTF8Bytes = 40
    public static let maxWorkspaceIDUTF8Bytes = 36

    // MARK: - Stale-cursor recovery

    public static let staleCursorCode = -32_020
    public static let staleCursorMessage = "checkpoint list catalog revision is stale"
    public static let sessionRecovery = "restart_once"

    public static func staleCursorError(currentRevision: Int64) -> JSONRPCError {
        JSONRPCError(
            code: staleCursorCode,
            message: staleCursorMessage,
            data: .object([
                "reason": .string("stale_cursor"),
                "recovery": .string(sessionRecovery),
                "restart_once": .bool(true),
                "catalog_revision": .number(Double(currentRevision)),
            ])
        )
    }

    // MARK: - Transport

    public enum WireTransport: String, Sendable, Equatable {
        case http
        case unix
        case webSocket
        /// Same-process unit tests / harnesses (not a production entry).
        case localTest
    }

    /// True when the client opted into response_version 1 (explicit key present).
    public static func isExplicitV1(params: [String: JSONValue]?) -> Bool {
        params?["response_version"] != nil
    }

    /// Untyped HTTP/JSONSerialization param map variant.
    public static func isExplicitV1(params: [String: Any]?) -> Bool {
        params?["response_version"] != nil
    }

    /// Transport admission for **explicit v1 only**.
    /// Legacy `agent.checkpoint.list` (no `response_version`) is a no-op here so
    /// Unix / WebSocket / batch retain prior host behavior.
    public static func preflightTransport(
        method: String,
        transport: WireTransport,
        inBatch: Bool,
        isExplicitV1: Bool
    ) throws {
        guard method == Self.method, isExplicitV1 else { return }
        if inBatch {
            throw JSONRPCError(
                code: -32600,
                message: "agent.checkpoint.list response_version 1 is forbidden in batch RPC.",
                data: .object([
                    "reason": .string("checkpoint_list_batch_forbidden"),
                    "method": .string(method),
                    "transport": .string("http_jsonrpc_only"),
                ])
            )
        }
        switch transport {
        case .http, .localTest:
            return
        case .unix, .webSocket:
            throw JSONRPCError(
                code: -32600,
                message: "agent.checkpoint.list response_version 1 is HTTP JSON-RPC only.",
                data: .object([
                    "reason": .string("checkpoint_list_http_only"),
                    "method": .string(method),
                    "transport": .string(transport.rawValue),
                ])
            )
        }
    }

    // MARK: - Request admission (v1)

    public static let allowedV1ParamKeys: Set<String> = [
        "thread_id",
        "response_version",
        "max_entries",
        "before",
        "catalog_revision",
    ]

    public struct V1Request: Sendable, Equatable {
        public let threadId: AgentThreadID
        public let maxEntries: Int
        public let before: AgentTurnCheckpointCursor?
        public let catalogRevision: Int64?
    }

    /// Validate exact v1 params + complete request envelope before repository work.
    public static func parseV1Request(
        id: JSONRPCID?,
        params: [String: JSONValue],
        fullRequest: JSONRPCRequest
    ) throws -> V1Request {
        guard Set(params.keys).isSubset(of: allowedV1ParamKeys) else {
            throw JSONRPCError.invalidParams
        }
        guard Self.acceptsResponseID(id) else {
            throw JSONRPCError.invalidRequest
        }
        guard case .number(let rawVersion) = params["response_version"],
              rawVersion.isFinite,
              let version = Int(exactly: rawVersion),
              version == responseVersion else {
            throw JSONRPCError.invalidParams
        }
        guard let threadRaw = params["thread_id"]?.stringValue,
              threadRaw.utf8.count <= maxThreadIDUTF8Bytes,
              let threadUUID = UUID(uuidString: threadRaw) else {
            throw JSONRPCError.invalidParams
        }

        let pageLimit: Int
        if let maxValue = params["max_entries"] {
            guard case .number(let rawMax) = maxValue,
                  rawMax.isFinite,
                  let integral = Int(exactly: rawMax),
                  (1...Self.maxEntries).contains(integral) else {
                throw JSONRPCError.invalidParams
            }
            pageLimit = integral
        } else {
            pageLimit = Self.maxEntries
        }

        let before: AgentTurnCheckpointCursor?
        if let beforeValue = params["before"] {
            if case .null = beforeValue {
                before = nil
            } else {
                before = try parseCursor(beforeValue)
            }
        } else {
            before = nil
        }

        let catalogRevision: Int64?
        if let revValue = params["catalog_revision"] {
            guard case .number(let rawRev) = revValue,
                  rawRev.isFinite,
                  let integral = Int64(exactly: rawRev),
                  integral > 0 else {
                throw JSONRPCError.invalidParams
            }
            catalogRevision = integral
        } else {
            catalogRevision = nil
        }

        // Subsequent pages require the revision fence so two catalog generations
        // cannot be spliced into one client sequence.
        if before != nil, catalogRevision == nil {
            throw JSONRPCError.invalidParams
        }

        try preflightEncodedRequest(fullRequest)
        return V1Request(
            threadId: AgentThreadID(threadUUID),
            maxEntries: pageLimit,
            before: before,
            catalogRevision: catalogRevision
        )
    }

    public static func parseCursor(_ value: JSONValue) throws -> AgentTurnCheckpointCursor {
        guard case .object(let object) = value else {
            throw JSONRPCError.invalidParams
        }
        // Exact keyset only — no extra/missing keys, no noncanonical timestamps.
        guard Set(object.keys) == [
                "checkpoint_turn_count",
                "completed_at",
                "turn_id",
              ],
              case .number(let rawTurn) = object["checkpoint_turn_count"],
              rawTurn.isFinite,
              let turnCount = Int(exactly: rawTurn),
              turnCount >= 0,
              turnCount <= 9_007_199_254_740_991,
              let turnId = object["turn_id"]?.stringValue,
              !turnId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              AgentTurnCheckpointWireIdentity.encodedJSONStringByteCount(turnId)
                <= AgentTurnCheckpointWireIdentity.maximumEncodedTurnIDBytes,
              let completedRaw = object["completed_at"]?.stringValue,
              completedRaw.utf8.count == 24,
              let completedAt = fractionalFormatter.date(from: completedRaw),
              fractionalFormatter.string(from: completedAt) == completedRaw else {
            throw JSONRPCError.invalidParams
        }
        return AgentTurnCheckpointCursor(
            checkpointTurnCount: turnCount,
            completedAt: completedAt,
            turnId: turnId,
            completedAtToken: completedRaw
        )
    }

    public static func acceptsResponseID(_ responseID: JSONRPCID?) -> Bool {
        guard let responseID,
              let encoded = try? JSONEncoder().encode(responseID) else {
            return responseID == nil
        }
        return encoded.count <= maxEncodedResponseIDBytes
    }

    public static func preflightEncodedRequest(_ request: JSONRPCRequest) throws {
        let data = try JSONEncoder().encode(request)
        if data.count > maxEncodedRequestBytes {
            throw JSONRPCError(
                code: -32602,
                message: "Request exceeds max_request_bytes.",
                data: .object([
                    "reason": .string("max_request_bytes"),
                    "max_request_bytes": .number(Double(maxEncodedRequestBytes)),
                    "request_bytes": .number(Double(data.count)),
                ])
            )
        }
    }

    public static func preflightLegacyRequest(
        id: JSONRPCID?,
        params: [String: JSONValue],
        fullRequest: JSONRPCRequest
    ) throws -> AgentThreadID {
        // Legacy preserves prior param/response shape. No HTTP-only or batch
        // gate here — those apply only to explicit response_version 1.
        guard let threadRaw = params["thread_id"]?.stringValue,
              threadRaw.utf8.count <= maxThreadIDUTF8Bytes,
              let threadUUID = UUID(uuidString: threadRaw) else {
            throw JSONRPCError.invalidParams
        }
        _ = id
        _ = fullRequest
        return AgentThreadID(threadUUID)
    }

    // MARK: - Response ceiling

    /// Encode a complete success JSON-RPC wrapper under max_response_bytes.
    /// On overflow, emit a finite error with the real id when possible; if even
    /// the bounded error cannot fit, emit id:null without copying the hostile id.
    public static func enforceEncodedSuccessCeiling(
        id: JSONRPCID?,
        result: JSONValue
    ) -> JSONRPCResponse {
        let response = JSONRPCResponse(id: id, result: result)
        if let encoded = try? JSONEncoder().encode(response),
           encoded.count <= maxEncodedResponseBytes {
            return response
        }
        return encodeBoundedErrorResponse(
            id: id,
            error: JSONRPCError(
                code: -32603,
                message: "Response exceeds max_response_bytes.",
                data: .object([
                    "reason": .string("max_response_bytes"),
                    "max_response_bytes": .number(Double(maxEncodedResponseBytes)),
                ])
            )
        )
    }

    public static func encodeBoundedErrorResponse(
        id: JSONRPCID?,
        error: JSONRPCError
    ) -> JSONRPCResponse {
        let withID = JSONRPCResponse(id: id, error: error)
        if let encoded = try? JSONEncoder().encode(withID),
           encoded.count <= maxEncodedResponseBytes {
            return withID
        }
        let minimal = JSONRPCError(
            code: error.code,
            message: String(error.message.prefix(200)),
            data: .object(["reason": .string("response_envelope_too_large")])
        )
        let retry = JSONRPCResponse(id: id, error: minimal)
        if let encoded = try? JSONEncoder().encode(retry),
           encoded.count <= maxEncodedResponseBytes {
            return retry
        }
        return JSONRPCResponse(
            id: nil,
            error: JSONRPCError(
                code: -32603,
                message: "Response exceeds max_response_bytes.",
                data: .object([
                    "reason": .string("max_response_bytes"),
                    "max_response_bytes": .number(Double(maxEncodedResponseBytes)),
                    "id_null": .bool(true),
                ])
            )
        )
    }

    // MARK: - Linear packing (nonisolated)

    public struct FrozenItem: Sendable, Equatable {
        public let value: JSONValue
        public let encoded: Data
        public let checkpointTurnCount: Int
        public let completedAtToken: String
        public let turnID: String

        public init(
            value: JSONValue,
            encoded: Data,
            checkpointTurnCount: Int,
            completedAtToken: String,
            turnID: String
        ) {
            self.value = value
            self.encoded = encoded
            self.checkpointTurnCount = checkpointTurnCount
            self.completedAtToken = completedAtToken
            self.turnID = turnID
        }
    }

    // MARK: Pack executor probes (MainActor proof + linear encode counters)

    public static let packQueueLabel = "io.remotecode.checkpoint-list-pack"
    private static let packQueue = DispatchQueue(
        label: packQueueLabel,
        qos: .userInitiated
    )

    /// Invoked on the pack queue before freeze/pack (tests inject delay).
    nonisolated(unsafe) public static var packWillRunForTesting: (() -> Void)?
    nonisolated(unsafe) public static var packDelayNanosecondsForTesting: UInt64 = 0
    nonisolated(unsafe) public static private(set) var packCallCountForTesting: Int = 0
    nonisolated(unsafe) public static private(set) var packOnMainActorCountForTesting: Int = 0
    nonisolated(unsafe) public static private(set) var packOffMainActorCountForTesting: Int = 0
    /// Full JSONEncoder.encode of a candidate item body during freeze.
    nonisolated(unsafe) public static private(set) var freezeItemBodyEncodeCountForTesting: Int = 0
    /// Full JSONEncoder.encode of the final JSON-RPC success envelope during pack.
    nonisolated(unsafe) public static private(set) var packFinalEnvelopeEncodeCountForTesting: Int = 0
    /// Incremental cursor encode while fitting (bounded; not full-envelope re-encode).
    nonisolated(unsafe) public static private(set) var packCursorEncodeCountForTesting: Int = 0

    public static func resetPackProbesForTesting() {
        packWillRunForTesting = nil
        packDelayNanosecondsForTesting = 0
        packCallCountForTesting = 0
        packOnMainActorCountForTesting = 0
        packOffMainActorCountForTesting = 0
        freezeItemBodyEncodeCountForTesting = 0
        packFinalEnvelopeEncodeCountForTesting = 0
        packCursorEncodeCountForTesting = 0
    }

    private static func recordPackExecutorForTesting() {
        packCallCountForTesting += 1
        if Thread.isMainThread {
            packOnMainActorCountForTesting += 1
        } else {
            packOffMainActorCountForTesting += 1
        }
    }

    /// Freeze + pack a page off the MainActor on a dedicated serial queue.
    /// Returns an immutable `JSONValue` payload (Sendable).
    public static func freezeAndPackPageAsync(
        _ page: AgentTurnCheckpointPage,
        responseID: JSONRPCID?
    ) async throws -> JSONValue {
        try await withCheckedThrowingContinuation { continuation in
            packQueue.async {
                recordPackExecutorForTesting()
                packWillRunForTesting?()
                let delay = packDelayNanosecondsForTesting
                if delay > 0 {
                    Thread.sleep(forTimeInterval: TimeInterval(delay) / 1_000_000_000)
                }
                do {
                    let payload = try freezeAndPackPage(page, responseID: responseID)
                    continuation.resume(returning: payload)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous freeze + linear pack. Prefer `freezeAndPackPageAsync` from
    /// `@MainActor` call sites so packing never owns the main run loop.
    public static func freezeAndPackPage(
        _ page: AgentTurnCheckpointPage,
        responseID: JSONRPCID?
    ) throws -> JSONValue {
        let frozen = try page.items.enumerated().map { index, summary in
            let listMetadata = page.listMetadata.indices.contains(index)
                ? page.listMetadata[index]
                : nil
            let completedAtToken = page.completedAtTokens.indices.contains(index)
                ? page.completedAtTokens[index]
                : ""
            return try freezeItem(
                summary: summary,
                sourceFilesTruncated: page.filesTruncated.indices.contains(index)
                    ? page.filesTruncated[index]
                    : false,
                listMetadata: listMetadata,
                completedAtToken: completedAtToken
            )
        }
        return try packPage(
            candidates: frozen,
            sourceHasMore: page.truncated,
            catalogRevision: page.catalogRevision,
            responseID: responseID
        )
    }

    /// Freeze one bounded item once. Subsequent packing only counts/copies these
    /// bytes — never re-encodes the item or full envelope per candidate.
    public static func freezeItem(
        summary: AgentTurnCheckpointSummary,
        sourceFilesTruncated: Bool,
        listMetadata: AgentTurnCheckpointListWireProjection.Capture?,
        completedAtToken: String
    ) throws -> FrozenItem {
        let turnID: AgentTurnCheckpointListWireProjection.Field
        let checkpointRef: AgentTurnCheckpointListWireProjection.Field
        let errorMessage: AgentTurnCheckpointListWireProjection.Field
        if let listMetadata {
            turnID = listMetadata.turnId
            checkpointRef = listMetadata.checkpointRef
            errorMessage = listMetadata.errorMessage
        } else {
            turnID = AgentTurnCheckpointListWireProjection.projectTurnId(summary.turnId)
            checkpointRef = AgentTurnCheckpointListWireProjection.projectString(
                summary.checkpointRef,
                maximumEncodedBytes:
                    AgentTurnCheckpointListWireProjection.maxEncodedCheckpointRefBytes
            )
            errorMessage = AgentTurnCheckpointListWireProjection.projectString(
                summary.errorMessage,
                maximumEncodedBytes:
                    AgentTurnCheckpointListWireProjection.maxEncodedErrorMessageBytes
            )
        }
        let resolvedToken = completedAtToken.isEmpty
            ? fractionalISO8601(summary.completedAt)
            : completedAtToken
        var files = summary.files
        var filesTruncated = sourceFilesTruncated
        let fileProjection = boundFiles(files)
        files = fileProjection.files
        filesTruncated = filesTruncated || fileProjection.truncated
        let metadataTruncated = turnID.truncated
            || checkpointRef.truncated
            || errorMessage.truncated
            || (listMetadata?.metadataUnavailable ?? false)

        func makeItem(files: [AgentTurnCheckpointFile], filesTruncated: Bool) throws -> (JSONValue, Data) {
            let stripped = AgentTurnCheckpointSummary(
                threadId: summary.threadId,
                runId: summary.runId,
                turnId: turnID.value ?? "",
                checkpointTurnCount: summary.checkpointTurnCount,
                checkpointRef: checkpointRef.value ?? "",
                status: summary.status,
                files: files,
                fileSnapshots: [],
                diffPatch: nil,
                fileDiffs: [],
                assistantMessageId: summary.assistantMessageId,
                errorMessage: errorMessage.value,
                completedAt: summary.completedAt
            )
            let encoder = JSONEncoder()
            freezeItemBodyEncodeCountForTesting += 1
            let baseData = try encoder.encode(stripped)
            guard var object = try JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
                throw JSONRPCError.internalError
            }
            object["fileSnapshots"] = []
            object["diffPatch"] = NSNull()
            object["fileDiffs"] = []
            object["filesTruncated"] = filesTruncated
            object["metadataTruncated"] = metadataTruncated
            object["metadataUnavailable"] = listMetadata?.metadataUnavailable ?? false
            object["turn_id_truncated"] = turnID.truncated
            object["turn_id_total_encoded_bytes"] = turnID.totalEncodedBytes
            object["turn_id_sha256"] = turnID.sha256 as Any? ?? NSNull()
            object["checkpoint_ref_truncated"] = checkpointRef.truncated
            object["checkpoint_ref_total_encoded_bytes"] = checkpointRef.totalEncodedBytes
            object["checkpoint_ref_sha256"] = checkpointRef.sha256 as Any? ?? NSNull()
            object["error_message_truncated"] = errorMessage.truncated
            object["error_message_total_encoded_bytes"] = errorMessage.totalEncodedBytes
            object["error_message_sha256"] = errorMessage.sha256 as Any? ?? NSNull()
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return (JSONValue.from(object), data)
        }

        var item = try makeItem(files: files, filesTruncated: filesTruncated)
        while item.1.count > maxEncodedItemBytes, !files.isEmpty {
            files.removeLast()
            filesTruncated = true
            item = try makeItem(files: files, filesTruncated: true)
        }
        guard item.1.count <= maxEncodedItemBytes else {
            throw JSONRPCError.internalError
        }
        return FrozenItem(
            value: item.0,
            encoded: item.1,
            checkpointTurnCount: summary.checkpointTurnCount,
            completedAtToken: resolvedToken,
            turnID: turnID.value ?? ""
        )
    }

    /// Pack frozen items with an incremental byte counter. Encodes the final
    /// envelope once. Authoritative candidate order is preserved.
    public static func packPage(
        candidates: [FrozenItem],
        sourceHasMore: Bool,
        catalogRevision: Int64,
        responseID: JSONRPCID?
    ) throws -> JSONValue {
        let encoder = JSONEncoder()
        let idEncoded = try encodeID(responseID, encoder: encoder)
        let revisionText = String(catalogRevision)
        // Exact framing outside variable parts (items / truncated / next_before / id / rev):
        // {"jsonrpc":"2.0","id":ID,"result":{"items":ITEMS,"truncated":BOOL,"next_before":NB,"catalog_revision":REV}}
        let fixed =
            #"{"jsonrpc":"2.0","id":"#.utf8.count
            + #","result":{"items":"#.utf8.count
            + #","truncated":"#.utf8.count
            + #","next_before":"#.utf8.count
            + #","catalog_revision":"#.utf8.count
            + #"}}"#.utf8.count

        func responseBytes(
            itemsArrayBytes: Int,
            truncated: Bool,
            nextBeforeBytes: Int
        ) -> Int {
            fixed
                + idEncoded.count
                + itemsArrayBytes
                + (truncated ? 4 : 5)
                + nextBeforeBytes
                + revisionText.utf8.count
        }

        var selected: [FrozenItem] = []
        selected.reserveCapacity(candidates.count)
        // Running sum of encoded item bodies + commas between them (no brackets).
        var itemsInnerBytes = 0

        for (index, candidate) in candidates.enumerated() {
            let separator = selected.isEmpty ? 0 : 1
            let newInner = itemsInnerBytes + separator + candidate.encoded.count
            let itemsArrayBytes = newInner + 2 // brackets
            let remainingAfter = index + 1 < candidates.count
            let truncated = sourceHasMore || remainingAfter
                || false // refined after selection; provisional for fit check
            // While more candidates remain after this index OR sourceHasMore, the
            // page is truncated if we stop here OR continue with more left.
            // For the fit check of admitting this item when it is not the final
            // overall row, assume truncated=true (worst-case next_before size).
            let fitTruncated = sourceHasMore || remainingAfter || true
            // Always size next_before for the prospective last item when truncated
            // could be true. Using true is conservative and matches final semantics
            // whenever sourceHasMore or not-all-candidates fit.
            packCursorEncodeCountForTesting += 1
            let nextBefore = try encodeCursor(
                turnCount: candidate.checkpointTurnCount,
                completedAtToken: candidate.completedAtToken,
                turnID: candidate.turnID,
                encoder: encoder
            )
            // Prefer null when this would be the complete final page (no more
            // candidates and source exhausted).
            let nextBeforeBytes: Int
            let effectiveTruncated: Bool
            if sourceHasMore || remainingAfter {
                effectiveTruncated = true
                nextBeforeBytes = nextBefore.count
            } else {
                // This item would complete the catalog page.
                effectiveTruncated = false
                nextBeforeBytes = 4 // null
            }
            let size = responseBytes(
                itemsArrayBytes: itemsArrayBytes,
                truncated: effectiveTruncated,
                nextBeforeBytes: nextBeforeBytes
            )
            if size > maxEncodedResponseBytes {
                break
            }
            itemsInnerBytes = newInner
            selected.append(candidate)
            _ = fitTruncated
            _ = truncated
        }

        guard candidates.isEmpty || !selected.isEmpty else {
            throw JSONRPCError.internalError
        }

        let truncated = sourceHasMore || selected.count < candidates.count
        let nextBeforeValue: JSONValue
        if truncated, let last = selected.last {
            nextBeforeValue = .object([
                "checkpoint_turn_count": .number(Double(last.checkpointTurnCount)),
                "completed_at": .string(last.completedAtToken),
                "turn_id": .string(last.turnID),
            ])
        } else {
            nextBeforeValue = .null
        }
        let payload: JSONValue = .object([
            "items": .array(selected.map(\.value)),
            "truncated": .bool(truncated),
            "next_before": nextBeforeValue,
            "catalog_revision": .number(Double(catalogRevision)),
        ])
        // Final encode-once verification against the real wrapper.
        let response = JSONRPCResponse(id: responseID, result: payload)
        packFinalEnvelopeEncodeCountForTesting += 1
        guard let finalBytes = try? encoder.encode(response),
              finalBytes.count <= maxEncodedResponseBytes else {
            throw JSONRPCError.internalError
        }
        return payload
    }

    // MARK: - Helpers

    private static func boundFiles(
        _ files: [AgentTurnCheckpointFile]
    ) -> (files: [AgentTurnCheckpointFile], truncated: Bool) {
        let encoder = JSONEncoder()
        var kept: [AgentTurnCheckpointFile] = []
        kept.reserveCapacity(min(files.count, AgentTurnCheckpointListWireProjection.maxFiles))
        var encodedArrayBytes = 2
        for file in files {
            guard kept.count < AgentTurnCheckpointListWireProjection.maxFiles,
                  let encoded = try? encoder.encode(file) else {
                break
            }
            let separatorBytes = kept.isEmpty ? 0 : 1
            guard encodedArrayBytes + separatorBytes + encoded.count
                    <= AgentTurnCheckpointListWireProjection.maxEncodedFilesBytes else {
                break
            }
            kept.append(file)
            encodedArrayBytes += separatorBytes + encoded.count
        }
        return (kept, kept.count < files.count)
    }

    private static func encodeID(
        _ id: JSONRPCID?,
        encoder: JSONEncoder
    ) throws -> Data {
        if let id {
            return try encoder.encode(id)
        }
        return Data("null".utf8)
    }

    private static func encodeCursor(
        turnCount: Int,
        completedAtToken: String,
        turnID: String,
        encoder: JSONEncoder
    ) throws -> Data {
        let object: [String: JSONValue] = [
            "checkpoint_turn_count": .number(Double(turnCount)),
            "completed_at": .string(completedAtToken),
            "turn_id": .string(turnID),
        ]
        return try encoder.encode(JSONValue.object(object))
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func fractionalISO8601(_ date: Date) -> String {
        fractionalFormatter.string(from: date)
    }

    private static func parseCompletedAt(_ raw: String) -> Date {
        if let date = fractionalFormatter.date(from: raw) { return date }
        if let date = wholeSecondFormatter.date(from: raw) { return date }
        return Date(timeIntervalSinceReferenceDate: 0)
    }
}
