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
    public let parentRunID: String?
    public let parentThreadID: String?
    public let subagentNodeID: String?
    public let parentCapability: String?
    public let runtimeProfile: AgentAppRuntimeProfile?

    public init(
        provider: AgentProvider,
        prompt: String,
        workspaceID: String? = nil,
        title: String? = nil,
        model: String? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        reasoningEffort: AgentReasoningEffort = .medium,
        serviceTier: AgentServiceTier = .auto,
        parentRunID: String? = nil,
        parentThreadID: String? = nil,
        subagentNodeID: String? = nil,
        parentCapability: String? = nil,
        runtimeProfile: AgentAppRuntimeProfile? = nil
    ) {
        self.provider = provider
        self.prompt = prompt
        self.workspaceID = workspaceID
        self.title = title
        self.model = model
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.parentRunID = parentRunID
        self.parentThreadID = parentThreadID
        self.subagentNodeID = subagentNodeID
        self.parentCapability = parentCapability
        self.runtimeProfile = runtimeProfile
    }
}

/// In-memory transport contract for one delegation generation.
///
/// The plaintext value is carried only in a provider process environment and
/// the local Agent App RPC request. Admission receipts persist its SHA-256
/// digest, never this value.
public enum AgentDelegationCapabilityTransport {
    public static let environmentKey = "RC_REMOTE_CODE_DELEGATION_CAPABILITY"
    public static let rpcParameterKey = "parent_capability"

    /// Capabilities are 32 random bytes encoded as lowercase hex.
    public static func isWellFormed(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    /// A managed provider process must never downgrade a partial inherited
    /// scope into an unrelated root Agent App turn. A normal user CLI has no
    /// middleware marker and remains free to create a root turn.
    public static func permitsAgentAppLaunch(
        middlewareEnabled: Bool,
        parentRunID: String?,
        parentThreadID: String?,
        parentCapability: String?
    ) -> Bool {
        guard middlewareEnabled else { return true }
        guard let parentRunID,
              UUID(uuidString: parentRunID) != nil,
              let parentThreadID,
              UUID(uuidString: parentThreadID) != nil,
              let parentCapability else {
            return false
        }
        return isWellFormed(parentCapability)
    }
}

/// Closed host-owned profiles for nested Agent App turns. This is intentionally
/// not a generic argv channel.
public enum AgentAppRuntimeProfile: String, Sendable, Equatable {
    case samGrokWorkerV1 = "sam-grok-worker-v1"

    public static let environmentKey = "RC_REMOTE_CODE_AGENT_APP_RUNTIME_PROFILE"
}

/// Host-validated parentage for a nested Agent App turn.
///
/// The child keeps its real Agent App run id. This context only tells the host
/// which active controller owns that run in the Subagents receipt tree.
public struct AgentNestedRunContext: Sendable, Equatable {
    public let parentRunID: AgentRunID
    public let parentThreadID: AgentThreadID
    public let nodeID: String
    public let parentCapability: String
    public let runtimeProfile: AgentAppRuntimeProfile?

    public init(
        parentRunID: AgentRunID,
        parentThreadID: AgentThreadID,
        nodeID: String,
        parentCapability: String,
        runtimeProfile: AgentAppRuntimeProfile? = nil
    ) {
        self.parentRunID = parentRunID
        self.parentThreadID = parentThreadID
        self.nodeID = nodeID
        self.parentCapability = parentCapability
        self.runtimeProfile = runtimeProfile
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
    case invalidNestedContext
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
        case .invalidNestedContext:
            return "Nested Agent App context requires parent run, parent thread, subagent node, and delegation capability together."
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

public enum AgentAppMiddlewareSendFailureDisposition: Sendable, Equatable {
    case definite
    case ambiguous
}

/// Lets a transport tell the workflow whether a failed send was rejected
/// before acceptance or may merely have lost its acknowledgement.
public protocol AgentAppMiddlewareSendFailure: Error {
    var agentAppMiddlewareSendFailureDisposition: AgentAppMiddlewareSendFailureDisposition { get }
}

/// Synchronous, transport-neutral workflow used by the CLI middleware.
///
/// All mutations deliberately use the existing Agent App RPCs. The host
/// therefore remains the sole owner of provider launch, usage accounting,
/// persistence, and events.
public enum AgentAppMiddlewareWorkflow {
    public typealias Call = (_ method: String, _ params: [String: AgentAppRPCValue]) throws -> AgentAppRPCValue

    public static func execute(
        request: AgentAppMiddlewareRequest,
        maxPolls: Int,
        call: Call,
        wait: () -> Void
    ) throws -> AgentAppMiddlewareOutput {
        let nestedContextCount = [
            request.parentRunID,
            request.parentThreadID,
            request.subagentNodeID,
            request.parentCapability
        ].compactMap { $0 }.count
        guard nestedContextCount == 0 || nestedContextCount == 4 else {
            throw AgentAppMiddlewareError.invalidNestedContext
        }
        guard request.runtimeProfile == nil || nestedContextCount == 4 else {
            throw AgentAppMiddlewareError.invalidNestedContext
        }
        let workspaceID = try resolveWorkspaceID(request.workspaceID, call: call)
        let model = try resolveModel(request.model, provider: request.provider, call: call)
        let title = request.title ?? "Subagent · \(displayName(request.provider))"
        var createParams: [String: AgentAppRPCValue] = [
            "workspace_id": .string(workspaceID),
            "title": .string(title),
            "provider": .string(request.provider.rawValue),
            "model": .string(model),
            "permission_mode": .string(request.permissionMode.rawValue),
            "reasoning_effort": .string(request.reasoningEffort.rawValue),
            "service_tier": .string(request.serviceTier.rawValue)
        ]
        if let parentRunID = request.parentRunID,
           let parentThreadID = request.parentThreadID,
           let subagentNodeID = request.subagentNodeID,
           let parentCapability = request.parentCapability {
            // The host validates this receipt-bound context and inherits
            // project/user scope before the child thread is persisted.
            createParams["parent_run_id"] = .string(parentRunID)
            createParams["parent_thread_id"] = .string(parentThreadID)
            createParams["subagent_node_id"] = .string(subagentNodeID)
            createParams[AgentDelegationCapabilityTransport.rpcParameterKey] =
                .string(parentCapability)
            if let runtimeProfile = request.runtimeProfile {
                createParams["runtime_profile"] = .string(runtimeProfile.rawValue)
            }
        }
        let created = try call("agent.thread.create", createParams)
        guard let threadID = identifierString(created.objectValue?["id"]),
              UUID(uuidString: threadID) != nil else {
            throw AgentAppMiddlewareError.invalidThreadResponse
        }

        var sendCallError: Error?
        var runID: String?
        do {
            var sendParams: [String: AgentAppRPCValue] = [
                "thread_id": .string(threadID),
                "text": .string(request.prompt),
                "provider": .string(request.provider.rawValue),
                "model": .string(model),
                "permission_mode": .string(request.permissionMode.rawValue),
                "reasoning_effort": .string(request.reasoningEffort.rawValue),
                "service_tier": .string(request.serviceTier.rawValue)
            ]
            if let parentRunID = request.parentRunID,
               let parentThreadID = request.parentThreadID,
               let subagentNodeID = request.subagentNodeID,
               let parentCapability = request.parentCapability {
                sendParams["parent_run_id"] = .string(parentRunID)
                sendParams["parent_thread_id"] = .string(parentThreadID)
                sendParams["subagent_node_id"] = .string(subagentNodeID)
                sendParams[AgentDelegationCapabilityTransport.rpcParameterKey] =
                    .string(parentCapability)
                if let runtimeProfile = request.runtimeProfile {
                    sendParams["runtime_profile"] = .string(runtimeProfile.rawValue)
                }
            }
            let sent = try call("agent.message.send", sendParams)
            guard let sendObject = sent.objectValue,
                  sendObject["status"]?.stringValue == "started" else {
                throw AgentAppMiddlewareError.runNotStarted
            }
            runID = identifierString(sendObject["run_id"])
        } catch {
            let disposition = (error as? AgentAppMiddlewareSendFailure)?
                .agentAppMiddlewareSendFailureDisposition
            if disposition == .definite || (error as? AgentAppMiddlewareError) == .runNotStarted {
                deleteCreatedThreadIfStillEmpty(
                    threadID: threadID,
                    workspaceID: workspaceID,
                    call: call
                )
                throw error
            }
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

    private static func deleteCreatedThreadIfStillEmpty(
        threadID: String,
        workspaceID: String,
        call: Call
    ) {
        guard let threads = try? call("agent.thread.list", [
            "workspace_id": .string(workspaceID)
        ]),
        let thread = threads.arrayValue?
            .compactMap(\.objectValue)
            .first(where: { identifierString($0["id"]) == threadID }),
        case .some(.null) = thread["active_run_id"],
        let messages = try? call("agent.message.list", [
            "thread_id": .string(threadID),
            "limit": .number(1)
        ]),
        messages.arrayValue?.isEmpty == true else {
            return
        }
        _ = try? call("agent.thread.delete", [
            "thread_id": .string(threadID)
        ])
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
