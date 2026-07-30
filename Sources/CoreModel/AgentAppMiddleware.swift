import Foundation

/// Small JSON-shaped value used by the headless Agent App workflow without
/// coupling CoreModel or the `rc2` executable to SocketServer's RPC types.
public indirect enum AgentAppRPCValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AgentAppRPCValue])
    case array([AgentAppRPCValue])
    case null

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: AgentAppRPCValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var arrayValue: [AgentAppRPCValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

public struct AgentAppMiddlewareRequest: Sendable, Equatable {
    public let provider: AgentProvider
    public let prompt: String
    public let workspaceID: String?
    public let title: String?
    public let model: String?
    public let permissionMode: AgentPermissionMode
    public let reasoningEffort: AgentReasoningEffort
    public let serviceTier: AgentServiceTier

    public init(
        provider: AgentProvider,
        prompt: String,
        workspaceID: String? = nil,
        title: String? = nil,
        model: String? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        reasoningEffort: AgentReasoningEffort = .medium,
        serviceTier: AgentServiceTier = .auto
    ) {
        self.provider = provider
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.title = title
        self.model = model
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

public struct AgentAppMiddlewareOutput: Sendable, Equatable {
    public let threadID: String
    public let runID: String?
    public let response: String

    public init(threadID: String, runID: String?, response: String) {
        self.threadID = threadID
        self.runID = runID
        self.response = response
    }
}

public enum AgentAppMiddlewareError: Error, Sendable, Equatable, LocalizedError {
    case noSelectedWorkspace
    case noProviderModel(AgentProvider)
    case invalidThreadResponse
    case runNotStarted
    case timedOut
    case missingAssistantResponse

    public var errorDescription: String? {
        switch self {
        case .noSelectedWorkspace:
            return "No RemoteCode workspace is selected; pass --workspace."
        case .noProviderModel(let provider):
            return "RemoteCode returned no available \(provider.rawValue) model."
        case .invalidThreadResponse:
            return "RemoteCode returned an invalid Agent App thread response."
        case .runNotStarted:
            return "RemoteCode did not start the Agent App turn."
        case .timedOut:
            return "The Agent App turn did not finish before the middleware timeout."
        case .missingAssistantResponse:
            return "The Agent App turn finished without an assistant response."
        }
    }
}

/// Synchronous, transport-neutral workflow used by the CLI middleware.
///
/// All mutations deliberately use the existing Agent App RPCs. The host
/// therefore remains the sole owner of prompt compression, provider launch,
/// Token Saver/Graphify admission, usage accounting, persistence, and events.
public enum AgentAppMiddlewareWorkflow {
    public typealias Call = (_ method: String, _ params: [String: AgentAppRPCValue]) throws -> AgentAppRPCValue

    public static func execute(
        request: AgentAppMiddlewareRequest,
        maxPolls: Int,
        call: Call,
        wait: () -> Void
    ) throws -> AgentAppMiddlewareOutput {
        let workspaceID = try resolveWorkspaceID(request.workspaceID, call: call)
        let model = try resolveModel(request.model, provider: request.provider, call: call)
        var createParams: [String: AgentAppRPCValue] = [
            "workspace_id": .string(workspaceID),
            "title": .string(request.title ?? "Subagent · \(displayName(request.provider))"),
            "provider": .string(request.provider.rawValue),
            "model": .string(model),
            "permission_mode": .string(request.permissionMode.rawValue),
            "reasoning_effort": .string(request.reasoningEffort.rawValue),
            "service_tier": .string(request.serviceTier.rawValue)
        ]
        if request.title == nil {
            createParams["title"] = .string("Subagent · \(displayName(request.provider))")
        }
        let created = try call("agent.thread.create", createParams)
        guard let threadID = identifierString(created.objectValue?["id"]),
              UUID(uuidString: threadID) != nil else {
            throw AgentAppMiddlewareError.invalidThreadResponse
        }

        var sendCallError: Error?
        var runID: String?
        do {
            let sent = try call("agent.message.send", [
                "thread_id": .string(threadID),
                "text": .string(request.prompt),
                "provider": .string(request.provider.rawValue),
                "model": .string(model),
                "permission_mode": .string(request.permissionMode.rawValue),
                "reasoning_effort": .string(request.reasoningEffort.rawValue),
                "service_tier": .string(request.serviceTier.rawValue)
            ])
            guard let sendObject = sent.objectValue,
                  sendObject["status"]?.stringValue == "started" else {
                throw AgentAppMiddlewareError.runNotStarted
            }
            runID = identifierString(sendObject["run_id"])
        } catch {
            // A long-running send may be accepted and persisted even if the
            // one-shot socket closes before its ACK reaches the caller. Never
            // retry that ambiguous mutation: reconcile the created thread.
            sendCallError = error
        }

        let boundedPolls = max(1, maxPolls)
        for poll in 0..<boundedPolls {
            let threads: AgentAppRPCValue
            do {
                threads = try call("agent.thread.list", [
                    "workspace_id": .string(workspaceID)
                ])
            } catch {
                guard sendCallError != nil, poll < boundedPolls - 1 else { throw error }
                wait()
                continue
            }
            let thread = threads.arrayValue?
                .compactMap(\.objectValue)
                .first { identifierString($0["id"]) == threadID }
            if let thread, identifierString(thread["active_run_id"]) == nil {
                let messages: AgentAppRPCValue
                do {
                    messages = try call("agent.message.list", [
                        "thread_id": .string(threadID),
                        "limit": .number(200)
                    ])
                } catch {
                    guard sendCallError != nil, poll < boundedPolls - 1 else { throw error }
                    wait()
                    continue
                }
                if let response = messages.arrayValue?
                    .compactMap(\.objectValue)
                    .last(where: { $0["role"]?.stringValue == "assistant" })?["content"]?
                    .stringValue {
                    return AgentAppMiddlewareOutput(
                        threadID: threadID,
                        runID: runID,
                        response: response
                    )
                }
                if poll == boundedPolls - 1 {
                    if let sendCallError { throw sendCallError }
                    throw AgentAppMiddlewareError.missingAssistantResponse
                }
            }
            if poll < boundedPolls - 1 { wait() }
        }
        if let sendCallError { throw sendCallError }
        throw AgentAppMiddlewareError.timedOut
    }

    private static func resolveWorkspaceID(
        _ explicit: String?,
        call: Call
    ) throws -> String {
        if let explicit, UUID(uuidString: explicit) != nil { return explicit }
        let current = try call("agent.state.current", [:])
        guard let selected = current.objectValue?["selected_workspace_id"]?.stringValue,
              UUID(uuidString: selected) != nil else {
            throw AgentAppMiddlewareError.noSelectedWorkspace
        }
        return selected
    }

    private static func resolveModel(
        _ explicit: String?,
        provider: AgentProvider,
        call: Call
    ) throws -> String {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        let models = try call("agent.models.list", [
            "provider": .string(provider.rawValue)
        ])
        guard let model = models.arrayValue?
            .compactMap(\.objectValue)
            .compactMap({ $0["id"]?.stringValue })
            .first(where: { !$0.isEmpty }) else {
            throw AgentAppMiddlewareError.noProviderModel(provider)
        }
        return model
    }

    private static func displayName(_ provider: AgentProvider) -> String {
        provider.rawValue.prefix(1).uppercased() + provider.rawValue.dropFirst()
    }

    private static func identifierString(_ value: AgentAppRPCValue?) -> String? {
        value?.stringValue ?? value?.objectValue?["value"]?.stringValue
    }
}

public enum AgentAppMiddlewareTimeoutPolicy {
    public static func receiveTimeoutMS(
        explicitGlobalTimeoutMS: Int?,
        turnTimeoutMS: Int
    ) -> Int {
        explicitGlobalTimeoutMS ?? turnTimeoutMS
    }
}
