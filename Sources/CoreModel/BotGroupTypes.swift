import Foundation

/// A named set of bots. Many-to-many: a bot may belong to several teams.
public struct BotTeam: Codable, Sendable, Equatable {
    public var id: BotTeamID
    public var name: String
    public var description: String
    public var avatarSymbol: String
    public var sortOrder: Int
    /// Bumped on every team or membership write; callers compare-and-set on it.
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: BotTeamID = BotTeamID(),
        name: String,
        description: String = "",
        avatarSymbol: String = "person.3.fill",
        sortOrder: Int = 0,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.avatarSymbol = avatarSymbol
        self.sortOrder = sortOrder
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BotTeamMember: Codable, Sendable, Equatable {
    public var teamID: BotTeamID
    public var botID: BotID
    public var sortOrder: Int
    public var addedAt: Date

    public init(teamID: BotTeamID, botID: BotID, sortOrder: Int, addedAt: Date) {
        self.teamID = teamID
        self.botID = botID
        self.sortOrder = sortOrder
        self.addedAt = addedAt
    }
}

/// Who answers a user message that mentions no participant.
public enum BotGroupPolicy: String, Codable, Sendable, CaseIterable {
    /// Every active participant answers, in participant order.
    case roundtable
    /// Only the lead bot answers.
    case lead
    /// The send is rejected unless it @mentions a participant.
    case mentionsOnly = "mentions_only"
}

/// A multi-bot conversation. Its transcript lives in one quiet "room" thread
/// that never runs a provider; each participant runs on its own member thread.
public struct BotGroupConversation: Codable, Sendable, Equatable {
    public static let maxParticipants = 8
    public static let defaultMaxAutoHops = 4
    public static let maxAutoHopsCap = 8

    public var id: BotGroupID
    public var title: String
    public var teamID: BotTeamID?
    public var roomThreadID: AgentThreadID
    public var policy: BotGroupPolicy
    public var leadBotID: BotID?
    public var maxAutoHops: Int
    public var pinned: Bool
    public var hidden: Bool
    public var unread: Bool
    public var attentionState: BotAttentionState
    /// Bumped on every group or participant write; callers compare-and-set on it.
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: BotGroupID = BotGroupID(),
        title: String,
        teamID: BotTeamID? = nil,
        roomThreadID: AgentThreadID,
        policy: BotGroupPolicy = .roundtable,
        leadBotID: BotID? = nil,
        maxAutoHops: Int = BotGroupConversation.defaultMaxAutoHops,
        pinned: Bool = false,
        hidden: Bool = false,
        unread: Bool = false,
        attentionState: BotAttentionState = .none,
        revision: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.teamID = teamID
        self.roomThreadID = roomThreadID
        self.policy = policy
        self.leadBotID = leadBotID
        self.maxAutoHops = maxAutoHops
        self.pinned = pinned
        self.hidden = hidden
        self.unread = unread
        self.attentionState = attentionState
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct BotGroupParticipant: Codable, Sendable, Equatable {
    public var groupID: BotGroupID
    public var botID: BotID
    /// The hidden member conversation (`bot_conversations.group_id` set).
    public var memberConversationID: BotConversationID
    public var sortOrder: Int
    public var joinedAt: Date
    /// Set when the bot was removed from the group or deleted.
    public var leftAt: Date?
    /// Last room message this bot has been shown (prompt delta watermark).
    public var seenRoomMessageID: AgentMessageID?
    public var seenRoomCreatedAt: Date?

    public init(
        groupID: BotGroupID,
        botID: BotID,
        memberConversationID: BotConversationID,
        sortOrder: Int,
        joinedAt: Date,
        leftAt: Date? = nil,
        seenRoomMessageID: AgentMessageID? = nil,
        seenRoomCreatedAt: Date? = nil
    ) {
        self.groupID = groupID
        self.botID = botID
        self.memberConversationID = memberConversationID
        self.sortOrder = sortOrder
        self.joinedAt = joinedAt
        self.leftAt = leftAt
        self.seenRoomMessageID = seenRoomMessageID
        self.seenRoomCreatedAt = seenRoomCreatedAt
    }

    public var isActive: Bool { leftAt == nil }
}

/// One bot's answer slot within a group round.
public struct BotGroupTurn: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case planned
        /// The bot's VM is busy in another thread (D12); queued, not started.
        case waitingForBot = "waiting_for_bot"
        case running
        case completed
        case failed
        case cancelled
        /// The app closed while this turn ran; never re-run automatically.
        case interrupted
        case skipped

        /// Planned or waiting turns have not started a run yet.
        public static let pending: [State] = [.planned, .waitingForBot]

        public var isTerminal: Bool {
            switch self {
            case .planned, .waitingForBot, .running: return false
            case .completed, .failed, .cancelled, .interrupted, .skipped: return true
            }
        }
    }

    public var id: BotGroupTurnID
    public var groupID: BotGroupID
    public var roundID: BotGroupRoundID
    /// Room message that started the round (user line or the mentioning reply).
    public var triggerMessageID: AgentMessageID?
    public var botID: BotID
    /// Monotonic order within the group.
    public var ordinal: Int
    /// 0 for the user's round; +1 per @mention hand-off.
    public var hop: Int
    public var state: State
    /// The room row (waiting row, then reply) this turn projects into.
    public var roomMessageID: AgentMessageID
    public var memberRunID: AgentRunID?
    public var submitKey: String?
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: BotGroupTurnID = BotGroupTurnID(),
        groupID: BotGroupID,
        roundID: BotGroupRoundID,
        triggerMessageID: AgentMessageID? = nil,
        botID: BotID,
        ordinal: Int,
        hop: Int = 0,
        state: State = .planned,
        roomMessageID: AgentMessageID = AgentMessageID(),
        memberRunID: AgentRunID? = nil,
        submitKey: String? = nil,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.groupID = groupID
        self.roundID = roundID
        self.triggerMessageID = triggerMessageID
        self.botID = botID
        self.ordinal = ordinal
        self.hop = hop
        self.state = state
        self.roomMessageID = roomMessageID
        self.memberRunID = memberRunID
        self.submitKey = submitKey
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
