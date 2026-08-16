import Foundation

public struct ManagedBotBrowserMCP: Sendable {
    public static let serverName = BotBrowserCatalog.serverName

    private let environment: [String: String]
    private let storeFactory: @Sendable ([String: String]) throws -> BotBrowserStore

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storeFactory: @escaping @Sendable ([String: String]) throws -> BotBrowserStore = {
            try BotBrowserStore.open(environment: $0)
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
                "instructions": "This bot's own browser. Website data persist per bot. Wait for the user to finish login.",
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": BotBrowserCatalog.toolCatalog()])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard BotBrowserCatalog.toolNames.contains(name) else {
                return errorReply(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            do {
                let store = try storeFactory(environment)
                var env = environment
                if env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] == nil {
                    env["RC_REMOTE_CODE_APP_SUPPORT_DIRECTORY"] = store.rootDirectory.deletingLastPathComponent().path
                }
                let service = try BotBrowserService.make(environment: env, store: store)
                if name == BotBrowserCatalog.waitLogin {
                    let timeout = (arguments["timeout_ms"] as? Double) ?? (arguments["timeout_ms"] as? NSNumber)?.doubleValue ?? 50
                    let deadline = Date().addingTimeInterval(max(0, timeout) / 1000)
                    var result = try service.waitLogin()
                    while !result.isComplete, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.01)
                        result = try service.waitLogin()
                    }
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": encodeJSON([
                            "complete": result.isComplete,
                            "user_message": result.userMessage ?? "",
                            "url": result.url,
                        ]) ?? "{}"]],
                        "isError": false,
                    ])
                }
                let object = try service.call(name: name, arguments: arguments)
                return reply(id: id, result: [
                    "content": [["type": "text", "text": encodeJSON(object) ?? "{}"]],
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
