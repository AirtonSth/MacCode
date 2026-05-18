import Foundation

public enum AgentPermissionMode: String, Codable, Sendable, CaseIterable {
    case supervised
    case autoAcceptEdits = "auto_accept_edits"
    case fullAccess = "full_access"
}

public enum AgentReasoningEffort: String, Codable, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
    case xhigh

    public static var supportedCases: [AgentReasoningEffort] {
        [.low, .medium, .high, .xhigh]
    }

    /// Human label for menus. `xhigh` is shown as "Extra High" to match
    /// the Codex CLI's effort picker.
    public var displayName: String {
        switch self {
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        }
    }
}

public struct AgentRunRequest: Codable, Sendable, Equatable {
    public let runId: AgentRunID
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let model: String
    public let cwd: String
    public let prompt: String
    public let providerThreadId: String?
    public let permissionMode: AgentPermissionMode
    public let reasoningEffort: AgentReasoningEffort?
    public let extraArgs: [String]

    public init(
        runId: AgentRunID = AgentRunID(),
        threadId: AgentThreadID,
        provider: AgentProvider,
        model: String,
        cwd: String,
        prompt: String,
        providerThreadId: String? = nil,
        permissionMode: AgentPermissionMode = .supervised,
        reasoningEffort: AgentReasoningEffort? = nil,
        extraArgs: [String] = []
    ) {
        self.runId = runId
        self.threadId = threadId
        self.provider = provider
        self.model = model
        self.cwd = cwd
        self.prompt = prompt
        self.providerThreadId = providerThreadId
        self.permissionMode = permissionMode
        self.reasoningEffort = reasoningEffort
        self.extraArgs = extraArgs
    }
}

public enum AgentRunStatus: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
    case interrupted
}

public struct AgentModelDescriptor: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let provider: AgentProvider
    public let supportsReasoning: Bool

    public init(id: String, label: String, provider: AgentProvider, supportsReasoning: Bool = false) {
        self.id = id; self.label = label; self.provider = provider; self.supportsReasoning = supportsReasoning
    }
}

public struct AgentThread: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentThreadID
    public var projectId: ProjectID?
    public var workspaceId: WorkspaceID?
    public var title: String
    public var provider: AgentProvider
    public var model: String
    public var providerThreadId: String?
    public var status: AgentRunStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var diffAdditions: Int
    public var diffDeletions: Int
    public var hasUnread: Bool
    public var color: String?
    public var pinned: Bool
    public var sortOrder: Int

    public init(
        id: AgentThreadID = AgentThreadID(),
        projectId: ProjectID? = nil,
        workspaceId: WorkspaceID? = nil,
        title: String,
        provider: AgentProvider,
        model: String,
        providerThreadId: String? = nil,
        status: AgentRunStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        diffAdditions: Int = 0,
        diffDeletions: Int = 0,
        hasUnread: Bool = false,
        color: String? = nil,
        pinned: Bool = false,
        sortOrder: Int = 0
    ) {
        self.id = id
        self.projectId = projectId
        self.workspaceId = workspaceId
        self.title = title
        self.provider = provider
        self.model = model
        self.providerThreadId = providerThreadId
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.diffAdditions = diffAdditions
        self.diffDeletions = diffDeletions
        self.hasUnread = hasUnread
        self.color = color
        self.pinned = pinned
        self.sortOrder = sortOrder
    }
}

public enum AgentMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
}

public struct AgentMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentMessageID
    public let threadId: AgentThreadID
    public let role: AgentMessageRole
    public var content: String
    public let createdAt: Date

    public init(
        id: AgentMessageID = AgentMessageID(),
        threadId: AgentThreadID,
        role: AgentMessageRole,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }
}

public struct AgentRun: Codable, Sendable, Equatable, Identifiable {
    public let id: AgentRunID
    public let threadId: AgentThreadID
    public let provider: AgentProvider
    public let model: String
    public var status: AgentRunStatus
    public var startedAt: Date
    public var finishedAt: Date?
    public var errorMessage: String?

    public init(
        id: AgentRunID = AgentRunID(),
        threadId: AgentThreadID,
        provider: AgentProvider,
        model: String,
        status: AgentRunStatus = .running,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id; self.threadId = threadId; self.provider = provider; self.model = model
        self.status = status; self.startedAt = startedAt; self.finishedAt = finishedAt
        self.errorMessage = errorMessage
    }
}
