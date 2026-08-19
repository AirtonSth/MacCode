import Foundation

public struct ManagedBotComputerMCP: Sendable {
    public static let serverName = BotComputerCatalog.serverName

    private let environment: [String: String]
    private let storeFactory: @Sendable ([String: String]) throws -> BotComputerStore

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storeFactory: @escaping @Sendable ([String: String]) throws -> BotComputerStore = {
            try BotComputerStore.open(environment: $0)
        }
    ) {
        self.environment = environment
        self.storeFactory = storeFactory
    }

    public func handle(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = message["method"] as? String else {
            return nil
        }
        let id = message["id"]
        if id == nil || method.hasPrefix("notifications/") {
            return nil
        }
        switch method {
        case "initialize":
            return reply(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.serverName, "version": "1"],
                "instructions": "Linux desktop in Docker on 127.0.0.1. Use bot_computer_observe then bot_computer_act. Do not run macos-harness.",
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": BotComputerCatalog.toolCatalog()])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard BotComputerCatalog.toolNames.contains(name) else {
                return errorReply(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            do {
                let store = try storeFactory(environment)
                var env = environment
                if env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] == nil {
                    env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = store.rootDirectory.deletingLastPathComponent().path
                }
                let service = try BotComputerService.make(environment: env, store: store)
                let object = try service.call(name: name, arguments: arguments)
                var content: [[String: Any]] = [
                    ["type": "text", "text": encodeJSON(object) ?? "{}"]
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
            } catch {
                return reply(id: id, result: [
                    "content": [["type": "text", "text": String(describing: error)]],
                    "isError": true,
                ])
            }
        default:
            return errorReply(id: id, code: -32601, message: "method not found: \(method)")
        }
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
