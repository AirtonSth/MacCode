import Foundation

/// Retrieve-only MCP server core (P3-T5): a native tool surface so Claude/Codex can fetch
/// the byte-exact original behind a `[[rc:HANDLE]]` marker without shelling out. It exposes
/// exactly one tool, `rc_retrieve`. It is RETRIEVE-ONLY by design — there is no compress
/// tool, because compressing via an MCP round-trip would send raw output through the model
/// and pay for the tokens twice.
///
/// Speaks newline-delimited JSON-RPC 2.0 (MCP stdio framing). The transport-bearing loop
/// lives in the executable; this type is the pure, testable message handler.
public struct ManagedRetrieveMCP: Sendable {
    public typealias RetrieveFn = @Sendable (_ handle: String) async -> String?

    public static let toolName = "rc_retrieve"
    private let retrieve: RetrieveFn

    public init(retrieve: @escaping RetrieveFn) {
        self.retrieve = retrieve
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
                ]],
            ])
        case "tools/call":
            let params = msg["params"] as? [String: Any]
            let args = params?["arguments"] as? [String: Any]
            guard (params?["name"] as? String) == Self.toolName, let handleArg = args?["handle"] as? String else {
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
}
