import Foundation

// Bot Teams and group conversations (host capabilities `bot.teams_v1` and
// `bot.groups_v1`). Reads: `bot.team.list`, `bot.group.list`,
// `bot.group.get`. Every mutation answers with a `BotGroupReceipt`; the host
// publishes `bot.team.updated` (`BotTeamUpdatedEvent`), `bot.group.updated`
// (`BotGroupUpdatedEvent`) and `bot.group.turn.updated` (`BotGroupTurnRow`)
// for changes made on the Mac or from a remote.
// Timestamps are seconds since 1970. Ids are lowercase UUID strings.
//
// Applying events and reads:
// - `bot.group.turn.updated`: apply in event `seq` order, keyed by `turn_id`.
//   A send's or retry's own turn events are in its receipt and always come
//   before the runtime events that follow it. `updated_at` is not a version:
//   reads round it to whole seconds and a retried turn goes back to
//   `planned`, so never merge by it. `bot.group.get` returns the newest turns
//   as a snapshot: replace the group's turns with it, then keep applying the
//   events that arrive after it.
// - Room rows are `agent.message.appended` on `room_thread_id`. A turn's row
//   keeps one id (`room_message_id`) from waiting to reply; keep the copy
//   with the highest `body_revision`. Row bodies:
//   - user message: role `user`, plain text.
//   - waiting / could not answer: role `assistant`,
//     `[[rc:bot-activity:<phase>|<handle>|<name>|<title>]]` with phase
//     `waiting` or `needsAttention`.
//   - reply: role `assistant`,
//     `[[rc:bot-from:<handle>|<name>|<title>|<avatar_symbol>]]\n<reply>`.
//   - note: role `system`, `<name> (@<handle>) <text>`, where text is
//     "stopped before answering.", "did not answer: a newer message took
//     over." or "was removed before answering."
// - Attention: group items are in `bot.attention.list` only when the call
//   passes `include_kinds: ["group"]` (item `kind: "group"`, `group_id`,
//   `turn_id`, `thread_id` = room). No `bot.attention.updated` or
//   `bots.attention.changed` is published for groups: re-read
//   `bot.attention.list` when `bot.group.updated` has
//   change `attention`, `selected`, `deleted` or `bot_deleted`. Clear a
//   group's item with `bot.group.select`, never `bot.attention.ack`.
// - `bot.group.list` has no message preview; read a group's room with the
//   agent message RPCs.
//
// Errors: refusals carry `data: {"domain": "bot_group", "kind": ...}` with
// kind `not_found`, `revision_conflict`, `invalid_input`, `send_refused` or
// `runtime_unavailable`. Tell them apart by `RemoteCodeError.kind` (which
// reads that data) or by `data`, never by the code alone: -32044 here is a
// missing team or group, not a deleted bot. -32081 is the Bots control plane
// being off (create, edit, send and retry are refused; stop, select and
// delete still work).

public struct BotTeamRow: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let avatarSymbol: String
    public let sortOrder: Int
    public let revision: Int
    /// Member bots in member order. A bot may be in several teams.
    public let memberBotIDs: [String]
    public let createdAt: Double
    public let updatedAt: Double

    private enum CodingKeys: String, CodingKey {
        case id, name, description, revision
        case avatarSymbol = "avatar_symbol"
        case sortOrder = "sort_order"
        case memberBotIDs = "member_bot_ids"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public struct BotGroupParticipantRow: Codable, Equatable, Sendable {
    public let botID: String
    public let memberConversationID: String
    /// The participant's private thread; nil until its first turn.
    public let memberThreadID: String?
    public let sortOrder: Int
    public let joinedAt: Double
    /// Set when the bot left the group or was deleted.
    public let leftAt: Double?

    private enum CodingKeys: String, CodingKey {
        case botID = "bot_id"
        case memberConversationID = "member_conversation_id"
        case memberThreadID = "member_thread_id"
        case sortOrder = "sort_order"
        case joinedAt = "joined_at"
        case leftAt = "left_at"
    }
}

public struct BotGroupRow: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let teamID: String?
    /// The room transcript; read it with the agent thread RPCs.
    public let roomThreadID: String
    /// `roundtable`, `lead` or `mentions_only`.
    public let policy: String
    public let leadBotID: String?
    public let maxAutoHops: Int
    public let pinned: Bool
    public let hidden: Bool
    public let unread: Bool
    /// `none`, `working`, `unread_activity` or `needs_attention`.
    public let attentionState: String
    /// Compare-and-set token for edits. Attention, unread and turn progress
    /// change without bumping it.
    public let revision: Int
    /// Active participants first in participant order, then the ones that left.
    public let participants: [BotGroupParticipantRow]
    public let createdAt: Double
    public let updatedAt: Double

    private enum CodingKeys: String, CodingKey {
        case id, title, policy, pinned, hidden, unread, revision, participants
        case teamID = "team_id"
        case roomThreadID = "room_thread_id"
        case leadBotID = "lead_bot_id"
        case maxAutoHops = "max_auto_hops"
        case attentionState = "attention_state"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Same shape as the `bot.group.turn.updated` event payload.
public struct BotGroupTurnRow: Codable, Equatable, Sendable {
    public let groupID: String
    public let roundID: String
    public let turnID: String
    public let botID: String
    /// `planned`, `waiting_for_bot`, `running`, `completed`, `failed`,
    /// `cancelled`, `interrupted` or `skipped`.
    public let state: String
    public let ordinal: Int
    public let hop: Int
    public let roomThreadID: String
    /// The room row this turn paints: a waiting row, then the reply (same id).
    public let roomMessageID: String
    public let triggerMessageID: String?
    public let runID: String?
    public let error: String?
    public let updatedAt: Double

    private enum CodingKeys: String, CodingKey {
        case state, ordinal, hop, error
        case groupID = "group_id"
        case roundID = "round_id"
        case turnID = "turn_id"
        case botID = "bot_id"
        case roomThreadID = "room_thread_id"
        case roomMessageID = "room_message_id"
        case triggerMessageID = "trigger_message_id"
        case runID = "run_id"
        case updatedAt = "updated_at"
    }
}

/// Every team and group mutation answers with this receipt. `request_id` is
/// the caller's `client_request_id`.
public struct BotGroupReceipt<Readback: Codable & Sendable & Equatable>: Codable, Equatable, Sendable {
    public let requestID: String
    public let receiptID: String
    /// Always `completed`; a refused mutation is a JSON-RPC error instead.
    public let status: String
    public let readback: Readback

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case receiptID = "receipt_id"
        case status, readback
    }
}

public struct BotTeamReadback: Codable, Equatable, Sendable {
    public let team: BotTeamRow
}

public struct BotTeamsReadback: Codable, Equatable, Sendable {
    public let teams: [BotTeamRow]
}

public struct BotGroupReadback: Codable, Equatable, Sendable {
    public let group: BotGroupRow
}

public struct BotDeletedReadback: Codable, Equatable, Sendable {
    public let id: String
    public let deleted: Bool
}

// MARK: - Reads

public enum BotTeamList: RemoteCodeRPCContract {
    public static let method = "bot.team.list"

    public struct Params: Codable, Equatable, Sendable {
        public init() {}
    }

    public typealias Result = BotTeamsReadback
}

public enum BotGroupList: RemoteCodeRPCContract {
    public static let method = "bot.group.list"

    public struct Params: Codable, Equatable, Sendable {
        public let includeHidden: Bool?

        public init(includeHidden: Bool? = nil) {
            self.includeHidden = includeHidden
        }

        private enum CodingKeys: String, CodingKey {
            case includeHidden = "include_hidden"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let groups: [BotGroupRow]
    }
}

public enum BotGroupGet: RemoteCodeRPCContract {
    public static let method = "bot.group.get"

    public struct Params: Codable, Equatable, Sendable {
        public let groupID: String
        /// Newest turns to return (default 50, at most 200).
        public let turnsLimit: Int?

        public init(groupID: String, turnsLimit: Int? = nil) {
            self.groupID = groupID
            self.turnsLimit = turnsLimit
        }

        private enum CodingKeys: String, CodingKey {
            case groupID = "group_id"
            case turnsLimit = "turns_limit"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let group: BotGroupRow
        /// Newest turns, in ordinal order.
        public let turns: [BotGroupTurnRow]
    }
}

// MARK: - Team mutations

public enum BotTeamCreate: RemoteCodeRPCContract {
    public static let method = "bot.team.create"

    public struct Params: Codable, Equatable, Sendable {
        public let name: String
        public let description: String?
        public let avatarSymbol: String?
        public let memberBotIDs: [String]?

        public init(name: String, description: String? = nil, avatarSymbol: String? = nil, memberBotIDs: [String]? = nil) {
            self.name = name
            self.description = description
            self.avatarSymbol = avatarSymbol
            self.memberBotIDs = memberBotIDs
        }

        private enum CodingKeys: String, CodingKey {
            case name, description
            case avatarSymbol = "avatar_symbol"
            case memberBotIDs = "member_bot_ids"
        }
    }

    public typealias Result = BotGroupReceipt<BotTeamReadback>
}

public enum BotTeamUpdate: RemoteCodeRPCContract {
    public static let method = "bot.team.update"

    /// Omitted fields keep their value.
    public struct Params: Codable, Equatable, Sendable {
        public let teamID: String
        public let expectedRevision: Int
        public let name: String?
        public let description: String?
        public let avatarSymbol: String?

        public init(teamID: String, expectedRevision: Int, name: String? = nil, description: String? = nil, avatarSymbol: String? = nil) {
            self.teamID = teamID
            self.expectedRevision = expectedRevision
            self.name = name
            self.description = description
            self.avatarSymbol = avatarSymbol
        }

        private enum CodingKeys: String, CodingKey {
            case name, description
            case teamID = "team_id"
            case expectedRevision = "expected_revision"
            case avatarSymbol = "avatar_symbol"
        }
    }

    public typealias Result = BotGroupReceipt<BotTeamReadback>
}

public enum BotTeamSetMembers: RemoteCodeRPCContract {
    public static let method = "bot.team.set_members"

    public struct Params: Codable, Equatable, Sendable {
        public let teamID: String
        public let expectedRevision: Int
        /// The whole member list in order (may be empty).
        public let botIDs: [String]

        public init(teamID: String, expectedRevision: Int, botIDs: [String]) {
            self.teamID = teamID
            self.expectedRevision = expectedRevision
            self.botIDs = botIDs
        }

        private enum CodingKeys: String, CodingKey {
            case teamID = "team_id"
            case expectedRevision = "expected_revision"
            case botIDs = "bot_ids"
        }
    }

    public typealias Result = BotGroupReceipt<BotTeamReadback>
}

public enum BotTeamDelete: RemoteCodeRPCContract {
    public static let method = "bot.team.delete"

    public struct Params: Codable, Equatable, Sendable {
        public let teamID: String

        public init(teamID: String) {
            self.teamID = teamID
        }

        private enum CodingKeys: String, CodingKey {
            case teamID = "team_id"
        }
    }

    public typealias Result = BotGroupReceipt<BotDeletedReadback>
}

public enum BotTeamReorder: RemoteCodeRPCContract {
    public static let method = "bot.team.reorder"

    public struct Params: Codable, Equatable, Sendable {
        /// Every team exactly once, in the new order.
        public let teamIDs: [String]

        public init(teamIDs: [String]) {
            self.teamIDs = teamIDs
        }

        private enum CodingKeys: String, CodingKey {
            case teamIDs = "team_ids"
        }
    }

    public typealias Result = BotGroupReceipt<BotTeamsReadback>
}

// MARK: - Group mutations

public enum BotGroupCreate: RemoteCodeRPCContract {
    public static let method = "bot.group.create"

    public struct Params: Codable, Equatable, Sendable {
        public let title: String
        public let participantBotIDs: [String]
        public let teamID: String?
        public let policy: String?
        public let leadBotID: String?
        public let maxAutoHops: Int?

        public init(
            title: String,
            participantBotIDs: [String],
            teamID: String? = nil,
            policy: String? = nil,
            leadBotID: String? = nil,
            maxAutoHops: Int? = nil
        ) {
            self.title = title
            self.participantBotIDs = participantBotIDs
            self.teamID = teamID
            self.policy = policy
            self.leadBotID = leadBotID
            self.maxAutoHops = maxAutoHops
        }

        private enum CodingKeys: String, CodingKey {
            case title, policy
            case participantBotIDs = "participant_bot_ids"
            case teamID = "team_id"
            case leadBotID = "lead_bot_id"
            case maxAutoHops = "max_auto_hops"
        }
    }

    public typealias Result = BotGroupReceipt<BotGroupReadback>
}

public enum BotGroupUpdate: RemoteCodeRPCContract {
    public static let method = "bot.group.update"

    /// Omitted fields keep their value; `clear_team_id` / `clear_lead_bot_id`
    /// unset the link.
    public struct Params: Codable, Equatable, Sendable {
        public let groupID: String
        public let expectedRevision: Int
        public let title: String?
        public let teamID: String?
        public let clearTeamID: Bool?
        public let policy: String?
        public let leadBotID: String?
        public let clearLeadBotID: Bool?
        public let maxAutoHops: Int?
        public let pinned: Bool?
        public let hidden: Bool?

        public init(
            groupID: String,
            expectedRevision: Int,
            title: String? = nil,
            teamID: String? = nil,
            clearTeamID: Bool? = nil,
            policy: String? = nil,
            leadBotID: String? = nil,
            clearLeadBotID: Bool? = nil,
            maxAutoHops: Int? = nil,
            pinned: Bool? = nil,
            hidden: Bool? = nil
        ) {
            self.groupID = groupID
            self.expectedRevision = expectedRevision
            self.title = title
            self.teamID = teamID
            self.clearTeamID = clearTeamID
            self.policy = policy
            self.leadBotID = leadBotID
            self.clearLeadBotID = clearLeadBotID
            self.maxAutoHops = maxAutoHops
            self.pinned = pinned
            self.hidden = hidden
        }

        private enum CodingKeys: String, CodingKey {
            case title, policy, pinned, hidden
            case groupID = "group_id"
            case expectedRevision = "expected_revision"
            case teamID = "team_id"
            case clearTeamID = "clear_team_id"
            case leadBotID = "lead_bot_id"
            case clearLeadBotID = "clear_lead_bot_id"
            case maxAutoHops = "max_auto_hops"
        }
    }

    public typealias Result = BotGroupReceipt<BotGroupReadback>
}

public enum BotGroupSetParticipants: RemoteCodeRPCContract {
    public static let method = "bot.group.set_participants"

    public struct Params: Codable, Equatable, Sendable {
        public let groupID: String
        public let expectedRevision: Int
        /// The whole active participant list in order (1...8 bots).
        public let botIDs: [String]

        public init(groupID: String, expectedRevision: Int, botIDs: [String]) {
            self.groupID = groupID
            self.expectedRevision = expectedRevision
            self.botIDs = botIDs
        }

        private enum CodingKeys: String, CodingKey {
            case groupID = "group_id"
            case expectedRevision = "expected_revision"
            case botIDs = "bot_ids"
        }
    }

    public typealias Result = BotGroupReceipt<BotGroupReadback>
}

/// Posts a user message to the room and plans the round. Idempotent by
/// `submit_key`: a retry returns the first send's identity and writes nothing.
public enum BotGroupSend: RemoteCodeRPCContract {
    public static let method = "bot.group.send"

    public struct Params: Codable, Equatable, Sendable {
        public let groupID: String
        public let text: String
        public let submitKey: String
        /// Reserved. Any id is refused: attachments are not supported in
        /// group conversations yet.
        public let attachmentIDs: [String]

        public init(groupID: String, text: String, submitKey: String, attachmentIDs: [String] = []) {
            self.groupID = groupID
            self.text = text
            self.submitKey = submitKey
            self.attachmentIDs = attachmentIDs
        }

        private enum CodingKeys: String, CodingKey {
            case text
            case groupID = "group_id"
            case submitKey = "submit_key"
            case attachmentIDs = "attachment_ids"
        }
    }

    public struct Readback: Codable, Equatable, Sendable {
        public let groupID: String
        public let roundID: String
        public let roomThreadID: String
        /// The room row holding the user's message.
        public let userMessageID: String
        public let submitKey: String
        /// The round's turns; each already has its waiting row in the room.
        public let turns: [BotGroupTurnRow]

        private enum CodingKeys: String, CodingKey {
            case turns
            case groupID = "group_id"
            case roundID = "round_id"
            case roomThreadID = "room_thread_id"
            case userMessageID = "user_message_id"
            case submitKey = "submit_key"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            groupID = try container.decode(String.self, forKey: .groupID)
            roundID = try container.decode(String.self, forKey: .roundID)
            roomThreadID = try container.decode(String.self, forKey: .roomThreadID)
            userMessageID = try container.decode(String.self, forKey: .userMessageID)
            submitKey = try container.decode(String.self, forKey: .submitKey)
            turns = try container.decode([BotGroupTurnRow].self, forKey: .turns)
            guard !groupID.isEmpty, !roundID.isEmpty, !roomThreadID.isEmpty,
                  !userMessageID.isEmpty, !submitKey.isEmpty,
                  !turns.isEmpty,
                  turns.allSatisfy({
                      $0.groupID == groupID && $0.roundID == roundID && $0.roomThreadID == roomThreadID
                  }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .turns,
                    in: container,
                    debugDescription: "Group send receipt identity is incomplete."
                )
            }
        }
    }

    public typealias Result = BotGroupReceipt<Readback>
}

public enum BotGroupStop: RemoteCodeRPCContract {
    public static let method = "bot.group.stop"

    public struct Params: Codable, Equatable, Sendable {
        public let groupID: String

        public init(groupID: String) {
            self.groupID = groupID
        }

        private enum CodingKeys: String, CodingKey {
            case groupID = "group_id"
        }
    }

    public struct Readback: Codable, Equatable, Sendable {
        public let groupID: String
        /// Turns this stop cancelled (unstarted and running).
        public let turns: [BotGroupTurnRow]

        private enum CodingKeys: String, CodingKey {
            case turns
            case groupID = "group_id"
        }
    }

    public typealias Result = BotGroupReceipt<Readback>
}

public enum BotGroupRetryTurn: RemoteCodeRPCContract {
    public static let method = "bot.group.retry_turn"

    /// Only a `failed` or `interrupted` turn of an active participant.
    public struct Params: Codable, Equatable, Sendable {
        public let groupID: String
        public let turnID: String

        public init(groupID: String, turnID: String) {
            self.groupID = groupID
            self.turnID = turnID
        }

        private enum CodingKeys: String, CodingKey {
            case groupID = "group_id"
            case turnID = "turn_id"
        }
    }

    public struct Readback: Codable, Equatable, Sendable {
        public let turn: BotGroupTurnRow
    }

    public typealias Result = BotGroupReceipt<Readback>
}

/// The user opened the group: clears its unread and attention state.
public enum BotGroupSelect: RemoteCodeRPCContract {
    public static let method = "bot.group.select"
    public typealias Params = BotGroupStop.Params
    public typealias Result = BotGroupReceipt<BotGroupReadback>
}

/// Deletes the group, its room and its participants' private threads. Bots
/// and teams stay.
public enum BotGroupDelete: RemoteCodeRPCContract {
    public static let method = "bot.group.delete"
    public typealias Params = BotGroupStop.Params
    public typealias Result = BotGroupReceipt<BotDeletedReadback>
}

// MARK: - Events

/// `bot.team.updated`. `change` is `created`, `updated`, `members`,
/// `deleted`, `reordered` or `bot_deleted`. `team_id` and `team` are absent
/// for `reordered` (use `team_ids`, the new order) and `bot_deleted` (use
/// `bot_id`; re-read `bot.team.list`). A deleted team has `team: null`.
public struct BotTeamUpdatedEvent: Codable, Equatable, Sendable {
    public let change: BotGroupEventChange
    public let teamID: String?
    public let revision: Int?
    public let deleted: Bool
    public let team: BotTeamRow?
    public let teamIDs: [String]?
    public let botID: String?

    private enum CodingKeys: String, CodingKey {
        case change, revision, deleted, team
        case teamID = "team_id"
        case teamIDs = "team_ids"
        case botID = "bot_id"
    }
}

/// `bot.group.updated`. `change` is `created`, `updated`, `participants`,
/// `attention`, `selected`, `deleted` or `bot_deleted`. `group_id` and
/// `group` are absent for `bot_deleted` (use `bot_id`; re-read
/// `bot.group.list`). A deleted group has `group: null`.
public struct BotGroupUpdatedEvent: Codable, Equatable, Sendable {
    public let change: BotGroupEventChange
    public let groupID: String?
    public let revision: Int?
    public let deleted: Bool
    public let group: BotGroupRow?
    public let botID: String?

    private enum CodingKeys: String, CodingKey {
        case change, revision, deleted, group
        case groupID = "group_id"
        case botID = "bot_id"
    }
}

/// The `change` of a team or group event. A newer host may send a change
/// this client does not know: treat it as `unknown` and re-read the list.
public enum BotGroupEventChange: Codable, Equatable, Sendable {
    case created
    case updated
    case members
    case participants
    case attention
    case selected
    case deleted
    case reordered
    case botDeleted
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "created": self = .created
        case "updated": self = .updated
        case "members": self = .members
        case "participants": self = .participants
        case "attention": self = .attention
        case "selected": self = .selected
        case "deleted": self = .deleted
        case "reordered": self = .reordered
        case "bot_deleted": self = .botDeleted
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .created: return "created"
        case .updated: return "updated"
        case .members: return "members"
        case .participants: return "participants"
        case .attention: return "attention"
        case .selected: return "selected"
        case .deleted: return "deleted"
        case .reordered: return "reordered"
        case .botDeleted: return "bot_deleted"
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
