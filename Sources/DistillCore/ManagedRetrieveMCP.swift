import Foundation

/// MCP server core (P3-T5): a native tool surface so Claude/Codex can fetch the byte-exact
/// original behind a `[[rc:HANDLE]]` marker without shelling out. It exposes read-only
/// retrieve/search/stats tools plus a gated compression tool that only runs when the caller's
/// estimated savings exceed the MCP round-trip cost.
///
/// Speaks newline-delimited JSON-RPC 2.0 (MCP stdio framing). The transport-bearing loop
/// lives in the executable; this type is the pure, testable message handler.
public struct ManagedRetrieveMCP: Sendable {
    public typealias RetrieveFn = @Sendable (_ handle: String) async -> String?
    public typealias SearchFn = @Sendable (_ query: String, _ topK: Int) async -> [CCRSearchResult]
    public typealias StatsFn = @Sendable () async -> DistillStatsSnapshot?
    public typealias CompressFn = @Sendable (_ request: DistillRequest) async -> DistillResponse?

    public static let toolName = "rc_retrieve"
    public static let searchToolName = "rc_search"
    public static let statsToolName = "rc_stats"
    public static let compressToolName = "rc_compress"
    private let retrieve: RetrieveFn
    private let search: SearchFn
    private let stats: StatsFn
    private let compress: CompressFn?

    public init(
        retrieve: @escaping RetrieveFn,
        search: @escaping SearchFn = { _, _ in [] },
        stats: @escaping StatsFn = { nil },
        compress: CompressFn? = nil
    ) {
        self.retrieve = retrieve
        self.search = search
        self.stats = stats
        self.compress = compress
    }

    /// Handle one JSON-RPC request line. Returns the response line, or nil for notifications
    /// (which get no reply) and unparseable input.
    public func handle(_ line: String) async -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = msg["method"] as? String else {
            return nil
        }
        let id = msg["id"] // may be Int, String, or absent (notification)

        // Notifications (no id, or notifications/*) get no response.
        if id == nil || method.hasPrefix("notifications/") {
            return nil
        }

        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "remotecode-distill-retrieve", "version": "1"],
            ])
        case "tools/list":
            return reply(id: id, result: [
                "tools": [[
                    "name": Self.toolName,
                    "description": "Retrieve the byte-exact original text behind a [[rc:HANDLE]] marker produced by RemoteCode Token Saver.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["handle": ["type": "string", "description": "The handle from a [[rc:HANDLE]] marker."]],
                        "required": ["handle"],
                    ],
                ], [
                    "name": Self.searchToolName,
                    "description": "Search stored RemoteCode Token Saver originals by query and return read-only retrieve handles.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "query": ["type": "string", "description": "Search query."],
                            "topK": ["type": "integer", "description": "Maximum result count."],
                        ],
                        "required": ["query"],
                    ],
                ], [
                    "name": Self.statsToolName,
                    "description": "Return local RemoteCode Token Saver savings stats.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [String: Any](),
                    ],
                ], [
                    "name": Self.compressToolName,
                    "description": "Compress text only when estimated savings exceed the MCP tool round-trip cost; returns a retrieve handle when available.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "input": ["type": "string", "description": "Text to compress."],
                            "question": ["type": "string", "description": "Extraction/compression contract."],
                            "estimatedInputTokens": ["type": "integer", "description": "Estimated raw input tokens."],
                            "toolRoundTripTokens": ["type": "integer", "description": "Estimated MCP call overhead."],
                        ],
                        "required": ["input"],
                    ],
                ]],
            ])
        case "tools/call":
            let params = msg["params"] as? [String: Any]
            let args = params?["arguments"] as? [String: Any]
            let name = params?["name"] as? String
            if name == Self.statsToolName {
                guard let snapshot = await stats() else {
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": "stats unavailable"]],
                        "isError": true,
                    ])
                }
                return reply(id: id, result: [
                    "content": [["type": "text", "text": encodeJSON(snapshot) ?? "{}"]],
                    "isError": false,
                ])
            }
            if name == Self.searchToolName {
                guard let query = args?["query"] as? String else {
                    return errorReply(id: id, code: -32602, message: "missing query")
                }
                let topK = args?["topK"] as? Int ?? 5
                let results = await search(query, max(1, min(20, topK)))
                return reply(id: id, result: [
                    "content": [["type": "text", "text": encodeJSON(results) ?? "[]"]],
                    "isError": false,
                ])
            }
            if name == Self.compressToolName {
                guard let input = args?["input"] as? String else {
                    return errorReply(id: id, code: -32602, message: "missing input")
                }
                let estimatedInputTokens = args?["estimatedInputTokens"] as? Int ?? TokenEstimator.estimate(input)
                let toolRoundTripTokens = args?["toolRoundTripTokens"] as? Int ?? 200
                guard estimatedInputTokens > toolRoundTripTokens else {
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": "skipped: estimated savings do not exceed MCP round-trip cost"]],
                        "isError": false,
                    ])
                }
                guard let compress else {
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": "compression unavailable"]],
                        "isError": true,
                    ])
                }
                let request = DistillRequest(
                    mode: .commandOutput,
                    priority: .agent,
                    input: input,
                    question: args?["question"] as? String,
                    provider: args?["provider"] as? String,
                    recordSavings: true,
                    maxOutputCharacters: args?["maxOutputCharacters"] as? Int ?? 4_000,
                    reversibleStoreMinBytes: args?["reversibleStoreMinBytes"] as? Int ?? 256
                )
                guard let response = await compress(request) else {
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": "compression unavailable"]],
                        "isError": true,
                    ])
                }
                var text = response.output
                if let handle = response.originalHandle, !handle.isEmpty {
                    text += "\n[[rc:\(handle)]]"
                }
                return reply(id: id, result: [
                    "content": [["type": "text", "text": text]],
                    "isError": false,
                ])
            }
            guard name == Self.toolName, let handleArg = args?["handle"] as? String else {
                return errorReply(id: id, code: -32602, message: "unknown tool or missing handle")
            }
            let original = await retrieve(handleArg)
            return reply(id: id, result: [
                "content": [["type": "text", "text": original ?? "original unavailable; the visible summary is all that remains"]],
                "isError": original == nil,
            ])
        default:
            return errorReply(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    private func reply(id: Any?, result: [String: Any]) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func errorReply(id: Any?, code: Int, message: String) -> String? {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encode(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text // single line (no embedded newlines from JSONSerialization default)
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
