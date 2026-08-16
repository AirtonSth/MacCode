import Foundation

/// MCP stdio handler so a bot can read and change its own Studio settings.
public struct ManagedBotSelfConfigMCP: Sendable {
    public static let serverName = BotSelfConfigCatalog.serverName

    private let environment: [String: String]
    private let storeFactory: @Sendable ([String: String]) throws -> BotStore

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storeFactory: @escaping @Sendable ([String: String]) throws -> BotStore = {
            try BotSelfConfigService.openStore(environment: $0)
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
                "instructions": "Read and change this bot's own Studio settings. Cross-bot ids are rejected.",
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": BotSelfConfigCatalog.toolCatalog()])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard BotSelfConfigCatalog.toolNames.contains(name) else {
                return errorReply(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            do {
                let store = try storeFactory(environment)
                let service = try BotSelfConfigService.make(environment: environment, store: store)
                let snapshot = try service.call(name: name, arguments: arguments)
                return reply(id: id, result: [
                    "content": [["type": "text", "text": try service.encodeSnapshot(snapshot)]],
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
        return text
    }
}
