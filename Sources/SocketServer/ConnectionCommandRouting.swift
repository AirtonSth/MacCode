import CoreModel

@MainActor
public protocol ConnectionCommandRouting: AnyObject {
    func connectionMCP(message: [String: JSONValue], threadID: AgentThreadID, runID: AgentRunID, capability: String?) async throws -> JSONValue
}
