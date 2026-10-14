import Foundation

// Manual actions (host capability `agent.manual_actions_v1`). A bot that
// needs the user (login, captcha, 2FA, payment, confirm) pauses its run and
// opens a request on its thread; the Mac shows a card and the iPhone gets an
// "Waiting for you" push.
//
// - Reads: `agent.manual_action.list` (batchable, read scope); an unknown
//   `thread_id` is -32060 `not_found`. Every agent thread payload
//   (`agent.thread.list`, `agent.thread.created/updated/...` events and the
//   `sync.snapshot` `agent_threads` rows) carries `pending_manual_action`:
//   the open or taken request, or null.
// - Write: `agent.manual_action.resolve` (receipt ledger, needs
//   `client_request_id`). The store transition is single-winner across the
//   Mac card, every device and parallel calls: exactly one caller wins and
//   the bot gets exactly one follow-up message. Losers get -32061
//   `state_conflict` with the current `state`; nothing changes.
//   - `take`: open -> taken; the user drives the bot's computer. No message
//     is sent. Refused (-32062 `take_unavailable`) on a thread that runs on
//     the Mac (`can_take` false).
//   - `continue` (optional string `note`; any other type is -32602) /
//     `decline`: open or taken -> continued /
//     declined; control goes back to the bot and its follow-up message is
//     sent (`follow_up`). A follow-up that could not be sent is reported as
//     `delivered: false` with `error`; the request stays resolved.
// - Event: `agent.manual_action.updated` (`AgentManualActionUpdatedEvent`)
//   for every change made on the Mac or from a device, including a new
//   request (state `open`) and requests closed as `expired` when their bot is
//   deleted. A resolve's own event is in its receipt.
//   Apply in `seq` order: replace the thread's pending card with
//   `pending_manual_action`.
// - A taken request whose control was lost (the host restarted) reads as
//   `open` again, as on the Mac.
// Timestamps are seconds since 1970. Ids are UUID strings; compare them
// case-insensitively.
//
// Errors carry `data: {"domain": "manual_action", "kind": ...}`: kind
// `not_found` (-32060: unknown thread or request), `state_conflict` (-32061, with `state`),
// `take_unavailable` (-32062) or `store_unavailable` (-32000, nothing saved).

public struct AgentManualActionRow: Codable, Equatable, Sendable {
    public let id: String
    public let threadID: String?
    public let botID: String
    public let botName: String?
    /// `login`, `captcha`, `2fa`, `payment`, `confirm` or `other`.
    public let kind: String
    public let reason: String
    /// `open`, `taken`, `continued`, `declined` or `expired`.
    public let state: String
    public let createdAt: Double
    public let resolvedAt: Double?
    public let note: String?
    /// False when the thread runs on the Mac: hide "Take control".
    public let canTake: Bool

    public var isPending: Bool { state == "open" || state == "taken" }

    private enum CodingKeys: String, CodingKey {
        case id, kind, reason, state, note
        case threadID = "thread_id"
        case botID = "bot_id"
        case botName = "bot_name"
        case createdAt = "created_at"
        case resolvedAt = "resolved_at"
        case canTake = "can_take"
    }
}

public enum AgentManualActionList: RemoteCodeRPCContract {
    public static let method = "agent.manual_action.list"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String

        public init(threadID: String) {
            self.threadID = threadID
        }

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let threadID: String
        /// Oldest first, including resolved and expired requests.
        public let manualActions: [AgentManualActionRow]
        public let pendingManualAction: AgentManualActionRow?

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case manualActions = "manual_actions"
            case pendingManualAction = "pending_manual_action"
        }
    }
}

public enum AgentManualActionResolve: RemoteCodeRPCContract {
    public static let method = "agent.manual_action.resolve"

    public enum Action: String, Codable, Sendable {
        case take
        case `continue`
        case decline
    }

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let manualActionID: String
        public let action: Action
        /// Only used by `continue`; blank means none.
        public let note: String?

        public init(threadID: String, manualActionID: String, action: Action, note: String? = nil) {
            self.threadID = threadID
            self.manualActionID = manualActionID
            self.action = action
            self.note = note
        }

        private enum CodingKeys: String, CodingKey {
            case action, note
            case threadID = "thread_id"
            case manualActionID = "manual_action_id"
        }
    }

    public struct FollowUp: Codable, Equatable, Sendable {
        public let delivered: Bool
        /// `started` or `queued` when delivered.
        public let status: String?
        public let runID: String?
        public let queuedMessageID: String?
        public let error: String?

        private enum CodingKeys: String, CodingKey {
            case delivered, status, error
            case runID = "run_id"
            case queuedMessageID = "queued_message_id"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let threadID: String
        /// The request after this call (`taken`, `continued` or `declined`).
        public let manualAction: AgentManualActionRow
        public let pendingManualAction: AgentManualActionRow?
        /// nil for `take`.
        public let followUp: FollowUp?

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case manualAction = "manual_action"
            case pendingManualAction = "pending_manual_action"
            case followUp = "follow_up"
        }
    }
}

/// `agent.manual_action.updated` payload.
public struct AgentManualActionUpdatedEvent: Codable, Equatable, Sendable {
    public let threadID: String
    /// The request that changed, in its new state.
    public let manualAction: AgentManualActionRow
    /// The thread's pending request after the change, or nil.
    public let pendingManualAction: AgentManualActionRow?

    private enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case manualAction = "manual_action"
        case pendingManualAction = "pending_manual_action"
    }
}
