import Foundation

/// Context identity for a host's explicit Bot authority binding.
public enum BotContext: Codable, Hashable, Sendable {
    case general
    case workspace(WorkspaceID)

    public var storageKey: String {
        switch self {
        case .general: return "general:v1"
        case .workspace(let id): return "workspace:v1:\(id.value.uuidString.lowercased())"
        }
    }

    public static let contractVersion = 1
}

public struct BotConversationContextPin: Codable, Equatable, Sendable {
    public let conversationID: BotConversationID
    public let hostID: String
    public let botID: BotID
    public let context: BotContext
    public let policyRevision: Int64
    public let contextVersion: Int

    public init(conversationID: BotConversationID, hostID: String, botID: BotID, context: BotContext, policyRevision: Int64, contextVersion: Int = BotContext.contractVersion) {
        self.conversationID = conversationID
        self.hostID = hostID
        self.botID = botID
        self.context = context
        self.policyRevision = policyRevision
        self.contextVersion = contextVersion
    }
}

public enum BotContextAction: String, Codable, CaseIterable, Hashable, Sendable {
    case read, send, files, memory, configure, delegate, export, schedule
}

public enum BotContextBindingState: String, Codable, Sendable {
    case active, revoked
}

public struct BotContextBinding: Codable, Equatable, Sendable {
    public let hostID: String
    public let botID: BotID
    public let context: BotContext
    public let state: BotContextBindingState
    public let policyRevision: Int64
    public let actions: Set<BotContextAction>

    public init(hostID: String, botID: BotID, context: BotContext, state: BotContextBindingState, policyRevision: Int64, actions: Set<BotContextAction>) {
        self.hostID = hostID
        self.botID = botID
        self.context = context
        self.state = state
        self.policyRevision = policyRevision
        self.actions = actions
    }
}
