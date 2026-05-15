import Foundation
import CoreModel

public enum AgentRunEvent: Sendable {
    case event(AssistantEvent)
    case status(AgentRunStatus)
    case finished(AgentRunStatus, finalMessage: String?, providerThreadId: String?)
    case error(String)
}

public protocol AgentProviderRunner: AnyObject {
    var provider: AgentProvider { get }
    func listModels() async -> [AgentModelDescriptor]
    func startRun(_ request: AgentRunRequest, onEvent: @escaping @Sendable (AgentRunEvent) -> Void) async throws -> AgentRunHandle
}

public final class AgentRunHandle: @unchecked Sendable {
    public let runId: AgentRunID
    public let process: Process?
    private let cancelHandler: () -> Void

    public init(runId: AgentRunID, process: Process?, cancel: @escaping () -> Void) {
        self.runId = runId
        self.process = process
        self.cancelHandler = cancel
    }

    public func cancel() {
        cancelHandler()
    }
}
