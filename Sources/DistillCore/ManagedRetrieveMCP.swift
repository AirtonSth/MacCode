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
    /// One catalog-op invocation with every argument a workspace / host op may
    /// need. `rc_ask`, `rc_extract`, `rc_digest` and `rc_pick` all funnel here so
    /// op behavior lives in exactly one dispatch path.
    public struct OpCall: Sendable {
        public var op: String
        public var input: String
        public var question: String?
        public var handle: String?
        public var paths: [String]
        public var root: String?
        public var symbol: String?
        public var pattern: String?
        public var fileName: String?
        public var baseRef: String?
        public var since: String?
        public var locale: String?
        public var payload: String?
        public var navigation: String?
        public var arguments: [String]
        public var topK: Int?
        public var budgetTokens: Int?

        public init(
            op: String,
            input: String = "",
            question: String? = nil,
            handle: String? = nil,
            paths: [String] = [],
            root: String? = nil,
            symbol: String? = nil,
            pattern: String? = nil,
            fileName: String? = nil,
            baseRef: String? = nil,
            since: String? = nil,
            locale: String? = nil,
            payload: String? = nil,
            navigation: String? = nil,
            arguments: [String] = [],
            topK: Int? = nil,
            budgetTokens: Int? = nil
        ) {
            self.op = op
            self.input = input
            self.question = question
            self.handle = handle
            self.paths = paths
            self.root = root
            self.symbol = symbol
            self.pattern = pattern
            self.fileName = fileName
            self.baseRef = baseRef
            self.since = since
            self.locale = locale
            self.payload = payload
            self.navigation = navigation
            self.arguments = arguments
            self.topK = topK
            self.budgetTokens = budgetTokens
        }
    }

    public struct OpAnswer: Sendable {
        public let status: String
        public let text: String
        public let envelope: String?
        public let savedTokens: Int
        public let mode: String

        public init(status: String, text: String, envelope: String? = nil, savedTokens: Int = 0, mode: String = "") {
            self.status = status
            self.text = text
            self.envelope = envelope
            self.savedTokens = savedTokens
            self.mode = mode
        }
    }

    public typealias AskFn = @Sendable (_ call: OpCall) async -> OpAnswer?
    public typealias DistillAdmission = @Sendable () -> Bool
    public typealias DeferredSideEffect = @Sendable () async -> Void

    public struct HandleResult: Sendable {
        public let response: String?
        public let deferredSideEffect: DeferredSideEffect?

        public init(response: String?, deferredSideEffect: DeferredSideEffect? = nil) {
            self.response = response
            self.deferredSideEffect = deferredSideEffect
        }
    }

    public static let toolName = "rc_retrieve"
    public static let searchToolName = "rc_search"
    public static let statsToolName = "rc_stats"
    public static let catalogToolName = "rc_catalog"
    public static let compressToolName = "rc_compress"
    public static let askToolName = "rc_ask"
    public static let extractToolName = "rc_extract"
    public static let digestToolName = "rc_digest"
    public static let pickToolName = "rc_pick"
    /// Every tool a catalog `mcp:` reference can name.
    public static let catalogOpToolNames = [askToolName, extractToolName, digestToolName, pickToolName]
    private let retrieve: RetrieveFn
    private let search: SearchFn
    private let stats: StatsFn
    private let compress: CompressFn?
    private let ask: AskFn?
    private let scopedRecoveryAvailable: Bool
    private let rootRunID: String?
    private let receiptKey: Data?
    private let distillAdmission: DistillAdmission

    public init(
        retrieve: @escaping RetrieveFn,
        search: @escaping SearchFn = { _, _ in [] },
        stats: @escaping StatsFn = { nil },
        compress: CompressFn? = nil,
        ask: AskFn? = nil,
        scopedRecoveryAvailable: Bool = false,
        rootRunID: String? = nil,
        receiptKey: Data? = nil,
        distillAdmission: @escaping DistillAdmission = { false }
    ) {
        self.retrieve = retrieve
        self.search = search
        self.stats = stats
        self.compress = compress
        self.ask = ask
        self.scopedRecoveryAvailable = scopedRecoveryAvailable
        let trimmedRootRunID = rootRunID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootRunID = trimmedRootRunID?.isEmpty == false ? trimmedRootRunID : nil
        self.receiptKey = receiptKey.flatMap {
            DistillAppliedReceipt.encodeReceiptKey($0) == nil ? nil : $0
        }
        self.distillAdmission = distillAdmission
    }

    /// Production transport seam: callers write `response` first, then await the
    /// deferred ledger side effect. Non-compress tools have no deferred work.
    /// Argument surface shared by rc_ask / rc_extract / rc_digest / rc_pick: the
    /// op id plus whatever the op needs (payload, handle, workspace root, path…).
    static func opToolProperties() -> [String: Any] {
        [
            "op": [
                "type": "string",
                "description": "Catalog id. Common: \(LibrarianCatalog.hotHintIDs.joined(separator: ", ")). Use rc_catalog for the complete enabled list.",
            ],
            "input": ["type": "string"],
            "question": ["type": "string"],
            "handle": ["type": "string"],
            "paths": ["type": "array", "items": ["type": "string"]],
            "root": ["type": "string", "description": "Workspace root for workspace/navigation ops."],
            "symbol": ["type": "string"],
            "pattern": ["type": "string"],
            "file_name": ["type": "string"],
            "base_ref": ["type": "string"],
            "since": ["type": "string"],
            "locale": ["type": "string"],
            "payload": ["type": "string", "description": "Structured op payload (JSON) for batch_codemod_apply and friends."],
            "navigation": ["type": "string", "description": "LSP operation (documentSymbol|definition|references|hover) or graphify subcommand (query|path|explain)."],
            "arguments": ["type": "array", "items": ["type": "string"]],
            "top_k": ["type": "integer"],
            "budget_tokens": ["type": "integer"],
        ]
    }

    /// Map MCP tool arguments onto the shared op call.
    static func opCall(op: String, arguments: [String: Any]?) -> OpCall {
        let paths = (arguments?["paths"] as? [String]) ?? []
        return OpCall(
            op: op,
            input: (arguments?["input"] as? String) ?? "",
            question: arguments?["question"] as? String,
            handle: arguments?["handle"] as? String,
            paths: paths,
            root: arguments?["root"] as? String,
            symbol: arguments?["symbol"] as? String,
            pattern: arguments?["pattern"] as? String,
            fileName: (arguments?["file_name"] as? String) ?? (arguments?["fileName"] as? String),
            baseRef: (arguments?["base_ref"] as? String) ?? (arguments?["baseRef"] as? String),
            since: arguments?["since"] as? String,
            locale: arguments?["locale"] as? String,
            payload: arguments?["payload"] as? String,
            navigation: arguments?["navigation"] as? String,
            arguments: (arguments?["arguments"] as? [String]) ?? [],
            topK: (arguments?["top_k"] as? Int) ?? (arguments?["topK"] as? Int),
            budgetTokens: (arguments?["budget_tokens"] as? Int) ?? (arguments?["budgetTokens"] as? Int)
        )
    }

    /// In-process dispatch for hosts that inject no sidecar transport (tests and
    /// the standalone `mcp` probe): the same dispatcher the server uses.
    static func dispatchLocally(call: OpCall, retrieve: RetrieveFn) async -> OpAnswer? {
        let store = LibrarianHandleStore()
        if !call.input.isEmpty {
            _ = store.put(call.input, handle: call.handle)
        } else if let handle = call.handle, let recovered = await retrieve(handle) {
            _ = store.put(recovered, handle: handle)
        }
        let dispatcher = LibrarianDispatcher(store: store, environment: .live)
        let request = LibrarianRequest(
            id: call.op,
            input: call.input,
            question: call.question,
            handle: call.handle,
            admitted: true,
            retrieveAvailable: true,
            verifiedRecoveryHandle: call.handle,
            command: call.arguments.first,
            schema: call.payload,
            startLine: nil,
            endLine: nil,
            pattern: call.pattern,
            root: call.root,
            paths: call.paths,
            symbol: call.symbol,
            fileName: call.fileName,
            baseRef: call.baseRef,
            since: call.since,
            locale: call.locale,
            payload: call.payload,
            navigationOperation: call.navigation,
            arguments: call.arguments,
            topK: call.topK,
            budgetTokens: call.budgetTokens
        )
        let result = await dispatcher.dispatch(request)
        return OpAnswer(
            status: result.status.rawValue,
            text: result.text,
            envelope: result.envelope?.jsonString(),
            savedTokens: result.analytics.savedTokens,
            mode: result.analytics.mode
        )
    }

    public func handleForDelivery(_ line: String) async -> HandleResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = msg["id"],
              msg["method"] as? String == "tools/call",
              let params = msg["params"] as? [String: Any],
              params["name"] as? String == Self.compressToolName else {
            return HandleResult(response: await handle(line))
        }
        return await compressResult(id: id, args: params["arguments"] as? [String: Any])
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
            tools.append([
                "name": Self.searchToolName,
                "description": "Search Token Saver reversible handles by query. Miss is not evidence of absence.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string"],
                        "topK": ["type": "integer"],
                    ],
                    "required": ["query"],
                ],
            ])
            tools.append([
                "name": Self.catalogToolName,
                "description": "Discover enabled Token Saver catalog operations by id or summary. Results are deterministic, local, and paginated.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": "Optional case-insensitive id or summary search.",
                        ],
                        "cursor": [
                            "type": "string",
                            "description": "Opaque continuation returned by the preceding page for the same query.",
                        ],
                        "limit": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": 20,
                        ],
                    ],
                ],
            ])
            tools.append([
                "name": Self.askToolName,
                "description": "Run an enabled Token Saver catalog operation. Discover cold operations with rc_catalog; host-only operations return unavailable.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "op": [
                            "type": "string",
                            "description": "Catalog id. Common: \(LibrarianCatalog.hotHintIDs.joined(separator: ", ")). Use rc_catalog for the complete enabled list.",
                        ],
                        "input": ["type": "string"],
                        "question": ["type": "string"],
                        "handle": ["type": "string"],
                    ],
                    "required": ["op"],
                ],
            ])

            for (toolName, toolDescription) in [
                (Self.extractToolName, "Run an extraction catalog op over input or a handle and return only the extracted fields. Discover ops with rc_catalog."),
                (Self.digestToolName, "Run a digest/summarize catalog op over input or a handle. Discover ops with rc_catalog."),
                (Self.pickToolName, "Run a ranking/selection catalog op (encoder_rank, chunk_select, grep_hits_rank, context_pack…) over input or a handle."),
            ] {
                tools.append([
                    "name": toolName,
                    "description": toolDescription,
                    "inputSchema": [
                        "type": "object",
                        "properties": Self.opToolProperties(),
                        "required": ["op"],
                    ],
                ])
            }
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
                if trustedCompressionAvailable {
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
            ], sortedKeys: true)
        case "tools/call":
            let params = msg["params"] as? [String: Any]
            let args = params?["arguments"] as? [String: Any]
            let name = params?["name"] as? String
            guard name == Self.statsToolName
                    || name == Self.searchToolName
                    || name == Self.catalogToolName
                    || Self.catalogOpToolNames.contains(name ?? "")
                    || name == Self.compressToolName
                    || (scopedRecoveryAvailable && name == Self.toolName) else {
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
            if name == Self.catalogToolName {
                let query: String?
                if let rawQuery = args?["query"] {
                    guard let value = rawQuery as? String else {
                        return errorReply(id: id, code: -32602, message: "invalid catalog query")
                    }
                    query = value
                } else {
                    query = nil
                }
                let cursor: String?
                if let rawCursor = args?["cursor"] {
                    guard let value = rawCursor as? String else {
                        return errorReply(id: id, code: -32602, message: "invalid catalog cursor")
                    }
                    cursor = value
                } else {
                    cursor = nil
                }
                let limit: Int
                if let rawLimit = args?["limit"] {
                    guard let value = rawLimit as? Int, (1...20).contains(value) else {
                        return errorReply(id: id, code: -32602, message: "catalog limit must be 1...20")
                    }
                    limit = value
                } else {
                    limit = 10
                }
                do {
                    let page = try LibrarianCatalog.page(query: query, cursor: cursor, limit: limit)
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": encodeJSON(page) ?? "{}"]],
                        "isError": false,
                    ])
                } catch {
                    return errorReply(id: id, code: -32602, message: "invalid catalog cursor")
                }
            }
            if let name, Self.catalogOpToolNames.contains(name) {
                guard let op = args?["op"] as? String, !op.isEmpty else {
                    return errorReply(id: id, code: -32602, message: "missing op")
                }
                guard LibrarianCatalog.implementedIDs.contains(op) else {
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": "catalog op unavailable"]],
                        "isError": true,
                    ])
                }
                let call = Self.opCall(op: op, arguments: args)
                var answer: OpAnswer?
                if let ask {
                    answer = await ask(call)
                }
                if answer == nil {
                    // No sidecar lease (standalone `mcp` child, test harness) or the
                    // sidecar is down: the shipped dispatcher still serves every
                    // deterministic and workspace op locally.
                    answer = await Self.dispatchLocally(call: call, retrieve: retrieve)
                }
                guard let answer else {
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": "catalog op unavailable: \(op)"]],
                        "isError": true,
                    ])
                }
                let payload = answer.envelope ?? answer.text
                return reply(id: id, result: [
                    "content": [["type": "text", "text": payload]],
                    "isError": false,
                ])
            }
            if name == Self.compressToolName {
                return await compressResult(id: id, args: args).response
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

    private var trustedCompressionAvailable: Bool {
        scopedRecoveryAvailable
            && compress != nil
            && rootRunID != nil
            && receiptKey != nil
            && distillAdmission()
    }

    private func compressResult(id: Any?, args: [String: Any]?) async -> HandleResult {
        guard let input = args?["input"] as? String else {
            return HandleResult(response: errorReply(id: id, code: -32602, message: "missing input"))
        }
        func failOpen() -> HandleResult {
            HandleResult(response: reply(id: id, result: [
                "content": [["type": "text", "text": input]],
                "isError": false,
            ]))
        }

        let estimatedInputTokens = args?["estimatedInputTokens"] as? Int ?? TokenEstimator.estimate(input)
        let toolRoundTripTokens = args?["toolRoundTripTokens"] as? Int ?? 200
        guard estimatedInputTokens > toolRoundTripTokens,
              trustedCompressionAvailable,
              let compress,
              let rootRunID,
              let receiptKey else {
            return failOpen()
        }

        let maxOutputCharacters = args?["maxOutputCharacters"] as? Int ?? 4_000
        let reversibleStoreMinBytes = args?["reversibleStoreMinBytes"] as? Int ?? 256
        let request = DistillRequest(
            mode: .commandOutput,
            priority: .agent,
            input: input,
            question: args?["question"] as? String,
            provider: args?["provider"] as? String,
            recordSavings: true,
            maxOutputCharacters: maxOutputCharacters,
            reversibleStoreMinBytes: reversibleStoreMinBytes
        )
        guard let response = await compress(request),
              trustedCompressionAvailable,
              response.routeStage != .verbatim,
              !response.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let handle = response.originalHandle, !handle.isEmpty,
              let recoveryIdempotencyKey = response.recoveryIdempotencyKey,
              !recoveryIdempotencyKey.isEmpty else {
            return failOpen()
        }

        let outputSeparator = response.output.hasSuffix("\n") ? "" : "\n"
        let signedPayload = Data((response.output + outputSeparator + "[[rc:\(handle)]]\n").utf8)
        guard let marker = DistillAppliedReceipt.makeV2Marker(
            rootRunID: rootRunID,
            payload: signedPayload,
            key: receiptKey
        ) else {
            return failOpen()
        }
        let deliveredData = signedPayload + Data((marker + "\n").utf8)
        guard deliveredData.count < Data(input.utf8).count,
              let delivered = String(data: deliveredData, encoding: .utf8) else {
            return failOpen()
        }
        guard let responseLine = reply(id: id, result: [
            "content": [["type": "text", "text": delivered]],
            "isError": false,
        ]) else {
            return failOpen()
        }

        let ledgerRequest = DistillRequest(
            mode: .commandOutput,
            priority: .agent,
            input: input,
            question: args?["question"] as? String,
            provider: args?["provider"] as? String,
            recordSavings: false,
            maxOutputCharacters: maxOutputCharacters,
            reversibleStoreMinBytes: reversibleStoreMinBytes,
            precomputedOutput: delivered,
            precomputedRouteStage: response.routeStage,
            precomputedRecoveryConfirmations: [
                .init(capability: handle, idempotencyKey: recoveryIdempotencyKey),
            ]
        )
        let admission = distillAdmission
        return HandleResult(
            response: responseLine,
            deferredSideEffect: {
                guard admission() else { return }
                _ = await compress(ledgerRequest)
            }
        )
    }

    private func reply(
        id: Any?,
        result: [String: Any],
        sortedKeys: Bool = true
    ) -> String? {
        encode(
            ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result],
            sortedKeys: sortedKeys
        )
    }

    private func errorReply(id: Any?, code: Int, message: String) -> String? {
        encode(
            ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]],
            sortedKeys: true
        )
    }

    private func encode(_ object: [String: Any], sortedKeys: Bool = false) -> String? {
        let options: JSONSerialization.WritingOptions = sortedKeys ? [.sortedKeys] : []
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
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
