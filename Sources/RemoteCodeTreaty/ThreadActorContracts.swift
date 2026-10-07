import Foundation

// Thread actor (host capability `agent.thread_actor_v1`). A thread can run
// as a bot ("run as bot"); a bot thread runs its tools in the bot's Linux VM
// or on the Mac, and a VM bot can ask to run on the Mac, which only the user
// approves.
//
// - Every agent thread payload (`agent.thread.list`, `agent.thread.created/
//   updated/...` events, `sync.snapshot` `agent_threads` rows and the results
//   below) carries `AgentThreadActorFields`: `actor`, `actor_locked_at`,
//   `execution_target`, `guest_runtime`, `runs_in_guest` and
//   `pending_mac_execution`.
// - Write: `agent.thread.actor.set` (receipt ledger, needs
//   `client_request_id`). Same lock rules as the Mac composer's actor chip:
//   only a thread with no messages, no locked actor and no run starting or
//   active can change; otherwise -32063 `locked`. Setting the actor the
//   thread is already locked to (and, when given, its target) is a no-op
//   success. A bot actor is locked at once (the Mac locks it at the first
//   send): the thread is linked to the bot, gets its target (the bot's
//   default when `execution_target` is absent: `vm` for a Docker desktop,
//   else `mac`) and, for a Distill thread on the VM, the guest runtime marker.
//   `vm` for a bot without a VM is -32064 `target_unavailable`. `none` on an
//   unlocked thread changes nothing. Later sends to a bot-locked thread
//   (`agent.message.send`) run as that bot, like the Mac's.
// - Write: `agent.mac_execution.resolve` (receipt ledger). Single winner
//   across the Mac banner, every device and parallel calls: the winner moves
//   the thread to the Mac (`approve: true`; actor and lock kept) or leaves the
//   target alone (`false`), and the bot gets exactly one follow-up message
//   (`follow_up`, same shape as `agent.manual_action.resolve`). Losers get
//   -32065 `not_pending`; nothing changes.
// - Event: `agent.mac_execution.requested` (`AgentMacExecutionRequestedEvent`)
//   when a bot asks. The answer (from the Mac or a device) arrives as
//   `agent.thread.updated` with `pending_mac_execution: null` and the new
//   `execution_target`. A pending request lives in memory: after the host
//   restarts it is gone on the Mac and on devices alike.
// Timestamps are seconds since 1970. Ids are UUID strings; compare them
// case-insensitively.
//
// Errors carry `data: {"domain": "thread_actor" | "mac_execution", "kind": ...}`:
// `not_found` (-32060: unknown thread or bot), `locked` (-32063),
// `target_unavailable` (-32064), `not_pending` (-32065), or
// `bots_unavailable` (-32000, nothing changed).

public struct AgentThreadActor: Codable, Equatable, Sendable {
    /// `none` or `bot`.
    public let kind: String
    /// Set when `kind` is `bot`.
    public let botID: String?

    public init(kind: String, botID: String? = nil) {
        self.kind = kind
        self.botID = botID
    }

    public static let none = AgentThreadActor(kind: "none")

    public static func bot(_ id: String) -> AgentThreadActor {
        AgentThreadActor(kind: "bot", botID: id)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case botID = "bot_id"
    }
}

public struct AgentPendingMacExecution: Codable, Equatable, Sendable {
    /// The bot's own words for why it needs the Mac.
    public let reason: String
}

/// The actor fields on every agent thread payload.
public struct AgentThreadActorFields: Codable, Equatable, Sendable {
    public let actor: AgentThreadActor
    /// Set once the actor is locked; nil while the thread can still change.
    public let actorLockedAt: Double?
    /// `vm` or `mac` for a locked bot thread; nil otherwise.
    public let executionTarget: String?
    /// Guest runtime marker (`guest-v1`): the agent session of a `vm` thread
    /// lives inside the bot's guest. Kept on a thread moved to the Mac until
    /// its first Mac run.
    public let guestRuntime: String?
    /// `execution_target` is `vm` and `guest_runtime` is set.
    public let runsInGuest: Bool
    public let pendingMacExecution: AgentPendingMacExecution?

    private enum CodingKeys: String, CodingKey {
        case actor
        case actorLockedAt = "actor_locked_at"
        case executionTarget = "execution_target"
        case guestRuntime = "guest_runtime"
        case runsInGuest = "runs_in_guest"
        case pendingMacExecution = "pending_mac_execution"
    }
}

public enum AgentThreadActorSet: RemoteCodeRPCContract {
    public static let method = "agent.thread.actor.set"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let actor: AgentThreadActor
        /// `vm` or `mac`; nil uses the bot's default.
        public let executionTarget: String?

        public init(threadID: String, actor: AgentThreadActor, executionTarget: String? = nil) {
            self.threadID = threadID
            self.actor = actor
            self.executionTarget = executionTarget
        }

        private enum CodingKeys: String, CodingKey {
            case actor
            case threadID = "thread_id"
            case executionTarget = "execution_target"
        }
    }

    /// The thread's actor fields after the call; the full thread payload is
    /// also under `thread`.
    public struct Result: Codable, Equatable, Sendable {
        public let threadID: String
        public let fields: AgentThreadActorFields

        private enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
        }

        public init(from decoder: Decoder) throws {
            threadID = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .threadID)
            fields = try AgentThreadActorFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(threadID, forKey: .threadID)
            try fields.encode(to: encoder)
        }
    }
}

public enum AgentMacExecutionResolve: RemoteCodeRPCContract {
    public static let method = "agent.mac_execution.resolve"

    public struct Params: Codable, Equatable, Sendable {
        public let threadID: String
        public let approve: Bool

        public init(threadID: String, approve: Bool) {
            self.threadID = threadID
            self.approve = approve
        }

        private enum CodingKeys: String, CodingKey {
            case approve
            case threadID = "thread_id"
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public let threadID: String
        public let approved: Bool
        /// After the call: `execution_target` is `mac` when approved and
        /// `pending_mac_execution` is nil.
        public let fields: AgentThreadActorFields
        public let followUp: AgentManualActionResolve.FollowUp

        private enum CodingKeys: String, CodingKey {
            case approved
            case threadID = "thread_id"
            case followUp = "follow_up"
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            threadID = try container.decode(String.self, forKey: .threadID)
            approved = try container.decode(Bool.self, forKey: .approved)
            followUp = try container.decode(AgentManualActionResolve.FollowUp.self, forKey: .followUp)
            fields = try AgentThreadActorFields(from: decoder)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(threadID, forKey: .threadID)
            try container.encode(approved, forKey: .approved)
            try container.encode(followUp, forKey: .followUp)
            try fields.encode(to: encoder)
        }
    }
}

/// `agent.mac_execution.requested` payload.
public struct AgentMacExecutionRequestedEvent: Codable, Equatable, Sendable {
    public let threadID: String
    public let reason: String
    /// Same value the thread payload now carries.
    public let pendingMacExecution: AgentPendingMacExecution

    private enum CodingKeys: String, CodingKey {
        case reason
        case threadID = "thread_id"
        case pendingMacExecution = "pending_mac_execution"
    }
}
