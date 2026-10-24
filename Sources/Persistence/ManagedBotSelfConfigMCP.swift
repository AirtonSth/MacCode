import Foundation
import CoreModel

/// MCP stdio handler so a bot can read and change its own Studio settings.
public struct ManagedBotSelfConfigMCP: Sendable {
    public static let serverName = BotSelfConfigCatalog.serverName

    private let environment: [String: String]
    private let storeFactory: @Sendable ([String: String]) throws -> BotStore
    private let secretStore: any BotSecretStore

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        storeFactory: @escaping @Sendable ([String: String]) throws -> BotStore = {
            try BotSelfConfigService.openStore(environment: $0)
        },
        secretStore: any BotSecretStore = BotKeychainSecretStore()
    ) {
        self.environment = environment
        self.storeFactory = storeFactory
        self.secretStore = secretStore
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
                "instructions": "Delegate to RemoteCode Bots with AI-authored prompts. Bot-owned runs can also read and change their own Studio settings and protected secrets; an Agent App run may target settings only at a Bot consulted by that exact active run, while secret tools may target a Bot created or consulted by that exact active run. Built-in RemoteCode workspace, thread, Bot, and owned-skill intents must use the named rc_* host tools and must not fall back to Computer Use, macos-harness, or Accessibility.",
            ])
        case "tools/list":
            return reply(id: id, result: ["tools": BotSelfConfigCatalog.toolCatalog() + RemoteCodeHostCatalog.toolCatalog()])
        case "tools/call":
            let params = message["params"] as? [String: Any]
            let name = params?["name"] as? String ?? ""
            let arguments = params?["arguments"] as? [String: Any] ?? [:]
            guard BotSelfConfigCatalog.toolNames.contains(name)
                    || RemoteCodeHostCatalog.toolNames.contains(name) else {
                return errorReply(id: id, code: -32602, message: "unknown tool: \(name)")
            }
            do {
                if let rpcMethod = RemoteCodeHostCatalog.rpcMethod(for: name) {
                    var hostArguments = arguments
                    if RemoteCodeHostCatalog.isMutation(name) {
                        guard let operationID = (hostArguments[RemoteCodeHostCatalog.operationIDKey] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                              !operationID.isEmpty else {
                            throw BotSelfConfigError.invalid("operation_id is required.")
                        }
                        hostArguments["client_request_id"] = operationID
                        hostArguments.removeValue(forKey: RemoteCodeHostCatalog.operationIDKey)
                        RemoteCodeHostCatalogDiagnostics.receipt(
                            decision: "dispatch",
                            method: name,
                            operationID: operationID
                        )
                    }
                    let object = try BotPeerRPCClient(environment: environment).call(
                        method: rpcMethod,
                        arguments: hostArguments,
                        budget: .hostOperation
                    )
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": encodeJSON(object) ?? "{}"]],
                        "isError": false,
                    ])
                }
                let peerMethods = [BotSelfConfigCatalog.listPeers: "bot.peer.list",
                    BotSelfConfigCatalog.askPeer: "bot.peer.ask", BotSelfConfigCatalog.peerStatus: "bot.peer.status",
                    BotSelfConfigCatalog.cancelPeer: "bot.peer.cancel"]
                if let method = peerMethods[name] {
                    var peerArguments = arguments
                    if let operationID = peerArguments.removeValue(forKey: "operation_id") as? String {
                        guard !operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            throw BotSelfConfigError.invalid("operation_id cannot be empty.")
                        }
                        peerArguments["client_request_id"] = operationID
                    }
                    let object = try BotPeerRPCClient(environment: environment).call(
                        method: method, arguments: peerArguments
                    )
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": encodeJSON(object) ?? "{}"]],
                        "isError": false,
                    ])
                }
                let callerID = BotSelfConfigService.callerID(from: environment)
                let requestedID = (arguments["bot_id"] as? String)
                    .flatMap(UUID.init)
                    .map(BotID.init)
                let usesDelegatedSelfConfigGrant = [
                    BotSelfConfigCatalog.getSettings,
                    BotSelfConfigCatalog.setSettings,
                    BotSelfConfigCatalog.listSecrets,
                    BotSelfConfigCatalog.saveSecret,
                    BotSelfConfigCatalog.deleteSecret,
                ].contains(name)
                    && (callerID == nil || requestedID.map { $0 != callerID } == true)
                if usesDelegatedSelfConfigGrant {
                    let object = try BotPeerRPCClient(environment: environment).call(
                        method: "bot.peer.self_config",
                        arguments: ["tool_name": name, "arguments": arguments]
                    )
                    return reply(id: id, result: [
                        "content": [["type": "text", "text": encodeJSON(object) ?? "{}"]],
                        "isError": false,
                    ])
                }
                guard callerID != nil else { throw BotSelfConfigError.callerMissing }
                let store = try storeFactory(environment)
                let service = try BotSelfConfigService.make(
                    environment: environment,
                    store: store,
                    secretStore: secretStore
                )
                let object = try service.invoke(name: name, arguments: arguments)
                return reply(id: id, result: [
                    "content": [["type": "text", "text": encode(object) ?? "{}"]],
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
        encodeJSON(object)
    }

    private func encodeJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
