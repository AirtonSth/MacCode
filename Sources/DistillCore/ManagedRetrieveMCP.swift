import Foundation
import CoreModel

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
    private let scopedRecoveryAvailable: Bool

    public init(
        retrieve: @escaping RetrieveFn,
        search: @escaping SearchFn = { _, _ in [] },
        stats: @escaping StatsFn = { nil },
        compress: CompressFn? = nil,
        scopedRecoveryAvailable: Bool = false
    ) {
        self.retrieve = retrieve
        self.search = search
        self.stats = stats
        self.compress = compress
        self.scopedRecoveryAvailable = scopedRecoveryAvailable
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
            var tools: [[String: Any]] = [[
                "name": Self.statsToolName,
                "description": "Return local RemoteCode Token Saver measurement stats with their evidence labels.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                ],
            ]]
            if scopedRecoveryAvailable {
                tools.append([
                    "name": Self.toolName,
                    "description": "Retrieve a scoped byte-exact original using the current runtime scope.",
                    "inputSchema": [
                        "type": "object",
                        "properties": ["handle": ["type": "string"]],
                        "required": ["handle"],
                    ],
                ])
                if compress != nil {
                    tools.append([
                        "name": Self.compressToolName,
                        "description": "Compress input only after scoped durable recovery succeeds.",
                        "inputSchema": [
                            "type": "object",
                            "properties": ["input": ["type": "string"]],
                            "required": ["input"],
                        ],
                    ])
                }
            }
            return reply(id: id, result: [
                "tools": tools,
            ])
        case "tools/call":
            let params = msg["params"] as? [String: Any]
            let args = params?["arguments"] as? [String: Any]
            let name = params?["name"] as? String
            guard name == Self.statsToolName || (scopedRecoveryAvailable && (name == Self.toolName || name == Self.compressToolName)) else {
                return errorReply(
                    id: id,
                    code: -32602,
                    message: "tool unavailable: scoped recovery capability required"
                )
            }
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

    // PERF: rc_stats/rc_search replies encoded Encodable tool payloads with a
    // fresh JSONEncoder on every MCP request. Share one under a short lock
    // (JSONEncoder is not thread-safe; concurrent MCP stdio clients may share
    // a process) so wire JSON stays default-formatted without per-call alloc.
    private static let encodeLock = NSLock()
    private static let encoder = JSONEncoder()

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        Self.encodeLock.lock()
        let data = try? Self.encoder.encode(value)
        Self.encodeLock.unlock()
        guard let data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
