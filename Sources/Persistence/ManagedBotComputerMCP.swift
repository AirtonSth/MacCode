import Foundation

public struct ManagedBotComputerMCP: Sendable {
    public static let serverName = BotComputerCatalog.serverName

    /// Optional Token Saver seam: given (toolName, resultText) returns the
    /// compressed replacement text, or nil to keep the original (fail-open).
    public typealias ToolResultDistiller = @Sendable (String, String) async -> String?

    private let environment: [String: String]
    private let storeFactory: @Sendable ([String: String]) throws -> BotComputerStore
    private let distillToolResult: ToolResultDistiller?

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storeFactory: @escaping @Sendable ([String: String]) throws -> BotComputerStore = {
            try BotComputerStore.open(environment: $0)
        },
        distillToolResult: ToolResultDistiller? = nil
    ) {
        self.environment = environment
        self.storeFactory = storeFactory
        self.distillToolResult = distillToolResult
    }

    public func handle(_ line: String) async -> String? {
        switch respond(to: line) {
        case .reply(let reply):
            return reply
        case .toolResult(let id, let name, let object):
            var text = encodeJSON(object) ?? "{}"
            // Screenshot payloads are delivered as an image block; their JSON
            // envelope must stay verbatim, so only image-free results distill.
            if let distillToolResult,
               BotComputerCatalog.distillableToolNames.contains(name),
               (object["png_base64"] as? String ?? "").isEmpty,
               let compressed = await distillToolResult(name, text) {
                text = compressed
            }
            return toolReply(id: id, object: object, text: text)
        }
    }

    /// `handle` on the caller's thread, without the tool-result distiller. The
    /// in-app guest gateway calls this from its own threads: every tool here
    /// blocks on the host's pending-action channel, and that wait must never
    /// run on Swift's cooperative pool inside the app.
    public func handleSynchronously(_ line: String) -> String? {
        switch respond(to: line) {
        case .reply(let reply):
            return reply
        case .toolResult(let id, _, let object):
            return toolReply(id: id, object: object, text: encodeJSON(object) ?? "{}")
        }
    }

    private enum Response {
        case reply(String?)
        case toolResult(id: Any?, name: String, object: [String: Any])
    }

    private func respond(to line: String) -> Response {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else {
            return .reply(nil)
        }
        let id = message["id"]
        if id == nil || method.hasPrefix("notifications/") {
            return .reply(nil)
        }
        switch method {
        case "initialize":
            return .reply(reply(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": "1"],
                "instructions": "Linux desktop in Docker on 127.0.0.1. Use bot_computer_observe, bot_computer_act, bot_computer_exec, and bot_computer_rebuild. Do not run macos-harness. Do not run host docker.",
            ]))
        case "tools/list":
            return .reply(reply(id: id, result: ["tools": BotComputerCatalog.toolCatalog()]))
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard BotComputerCatalog.toolNames.contains(name) else {
                return .reply(errorReply(id: id, code: -32602, message: "unknown tool: \(name)"))
            }
            do {
                let store = try storeFactory(environment)
                var env = environment
                if env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] == nil {
                    env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = store.rootDirectory.deletingLastPathComponent().path
                }
                let service = try BotComputerService.make(environment: env, store: store)
                let object = try service.call(name: name, arguments: arguments)
                // Host refusal is a normal result carrying the fixed phrase (nothing ran).
                if let refusal = object["refusal"] as? String {
                    return .reply(reply(id: id, result: [
                        "content": [["type": "text", "text": refusal]],
                        "isError": false,
                    ]))
                }
                return .toolResult(id: id, name: name, object: object)
            } catch {
                return .reply(reply(id: id, result: [
                    "content": [["type": "text", "text": String(describing: error)]],
                    "isError": true,
                ]))
            }
        default:
            return .reply(errorReply(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    private func toolReply(id: Any?, object: [String: Any], text: String) -> String? {
        var content: [[String: Any]] = [
            ["type": "text", "text": text]
        ]
        if let b64 = object["png_base64"] as? String, !b64.isEmpty {
            content.insert(
                ["type": "image", "mimeType": "image/png", "data": b64],
                at: 0
            )
        }
        return reply(id: id, result: [
            "content": content,
            "isError": false,
        ])
    }

    private func reply(id: Any?, result: [String: Any]) -> String? {
        encodeJSON(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private func errorReply(id: Any?, code: Int, message: String) -> String? {
        encodeJSON(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func encodeJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}
