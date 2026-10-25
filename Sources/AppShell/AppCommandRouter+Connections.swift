import Foundation
import CoreModel
import Persistence
import AgentRuntime
import SocketServer

extension AppCommandRouter: ConnectionCommandRouting {
    public func connectionMCP(message: [String: JSONValue], threadID: AgentThreadID, runID: AgentRunID, capability: String?) async throws -> JSONValue {
        guard let ctx = context else { throw ConnectionError.unavailable }
        // Generic service schemas and readOnlyHint annotations are not authority.
        // Execution requires captured native write authority, independently of provider MCP UI approvals.
        let executesServiceTool = message["method"]?.stringValue == "tools/call"
            && message["params"]?.objectValue?["name"]?.stringValue == ConnectionMCPCatalog.call
        let validate: @Sendable () async throws -> Void = { [weak self] in
            guard let self else { throw ConnectionError.accessDenied }
            try await MainActor.run {
                guard let context = self.context else { throw ConnectionError.accessDenied }
                do {
                    try self.authenticateManagedHostCall(threadID: threadID, runID: runID, delegationCapability: capability, mutation: executesServiceTool, method: ConnectionMCPCatalog.rpcMethod)
                } catch let error as JSONRPCError where error.code == -32048 {
                    throw JSONRPCError(code: -32048, message: ConnectionError.supervised.description)
                }
                if let pin = try context.botStore.conversationContextPin(linkedTo: threadID) {
                    guard try context.botStore.authorizes(hostID: pin.hostID, botID: pin.botID, context: pin.context, action: .read, policyRevision: pin.policyRevision),
                          try context.botStore.authorizesContextDelegation(hostID: pin.hostID, runID: runID, threadID: threadID) else { throw ConnectionError.accessDenied }
                }
            }
        }
        try await validate()
        guard let thread = try ctx.threadRepo.get(id: threadID) else { throw ConnectionError.accessDenied }
        let actorBot = thread.actor.botID
        let conversationBot = try ctx.botStore.conversationLinked(to: threadID)?.botID
        if let actorBot, let conversationBot, actorBot != conversationBot { throw ConnectionError.accessDenied }
        let bot = (actorBot ?? conversationBot)?.value.uuidString
        let workspace = try ctx.threadRepo.workspaceId(of: threadID)?.value.uuidString
        let task = try ConnectionStore(db: ctx.db).scheduledTaskID(forThreadID: threadID, activeRunID: runID)
        let scope = ConnectionScope(botID: bot, workspaceID: workspace, threadID: threadID.value.uuidString, taskID: task)
        let wire = try JSONDecoder().decode([String: ConnectionJSONValue].self, from: JSONEncoder().encode(message))
        let result = try await ctx.connectionBroker.handle(wire, scope: scope, runID: runID.value.uuidString, authorize: validate)
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ConnectionJSONValue.object(result)))
    }
}
