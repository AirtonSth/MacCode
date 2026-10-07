import CoreModel
import Foundation

/// Who runs a thread and where, as paired devices see it (host capability
/// `agent.thread_actor_v1`): one shape on every agent thread payload, plus
/// `agent.thread.actor.set` and `agent.mac_execution.*`.
public enum ThreadActorWire {
    /// The thread is identity-locked (it has messages, its actor is locked,
    /// or a run is starting or active) and the request would change it.
    public static let lockedCode = -32063
    /// `execution_target` `vm` for a bot without a VM (its desktop is not Docker).
    public static let targetUnavailableCode = -32064
    /// `agent.mac_execution.resolve` when the thread has no pending request
    /// (already answered on the Mac, by another device or a parallel call).
    public static let notPendingCode = -32065

    /// Adds `actor`, `actor_locked_at`, `execution_target`, `guest_runtime`,
    /// `runs_in_guest` and `pending_mac_execution`. `actor` keeps the
    /// Codable `botId` beside `bot_id` so a payload still decodes as an
    /// `AgentThread`.
    public static func append(
        thread: AgentThread,
        guestRuntime: String?,
        pendingMacExecutionReason: String?,
        to object: inout [String: JSONValue]
    ) {
        object["actor"] = actor(thread.actor)
        object["actor_locked_at"] = thread.actorLockedAt.map { .number($0.timeIntervalSince1970) } ?? .null
        object["execution_target"] = thread.executionTarget.map { .string($0.rawValue) } ?? .null
        let runtime = guestRuntime?.isEmpty == false ? guestRuntime : nil
        object["guest_runtime"] = runtime.map { .string($0) } ?? .null
        object["runs_in_guest"] = .bool(AgentThreadGuestPlacement(
            executionTarget: thread.executionTarget, guestRuntime: runtime
        ).runsInGuest)
        object["pending_mac_execution"] = pendingMacExecution(pendingMacExecutionReason)
    }

    public static func actor(_ actor: RunActor) -> JSONValue {
        switch actor {
        case .none:
            return .object(["kind": .string("none"), "bot_id": .null])
        case .bot(let id):
            let raw = JSONValue.string(id.value.uuidString.lowercased())
            return .object(["kind": .string("bot"), "bot_id": raw, "botId": raw])
        }
    }

    public static func pendingMacExecution(_ reason: String?) -> JSONValue {
        reason.map { .object(["reason": .string($0)]) } ?? .null
    }

    /// `agent.mac_execution.requested` payload.
    public static func macExecutionRequestedEvent(thread: AgentThreadID, reason: String) -> JSONValue {
        .object([
            "thread_id": .string(thread.value.uuidString),
            "reason": .string(reason),
            "pending_mac_execution": pendingMacExecution(reason),
        ])
    }

    /// `agent.thread.actor.set` `actor`: `{"kind":"none"}` or
    /// `{"kind":"bot","bot_id":"<uuid>"}`. nil when malformed.
    public static func parseActor(_ value: JSONValue?) -> RunActor? {
        guard let object = value?.objectValue else { return nil }
        switch object["kind"]?.stringValue {
        case "none": return RunActor.none
        case "bot":
            return object["bot_id"]?.stringValue.flatMap(UUID.init(uuidString:)).map { .bot(BotID($0)) }
        default: return nil
        }
    }

    /// Refusals change nothing, so the receipt ledger frees the request id.
    public static func refusal(domain: String, code: Int, kind: String, message: String) -> JSONRPCError {
        JSONRPCError(code: code, message: message, data: .object([
            "domain": .string(domain), "kind": .string(kind),
        ]))
    }
}

/// `agent.mac_execution.resolve` outcome.
public struct MacExecutionResolveOutcome: Sendable {
    public let thread: AgentThread
    public let approved: Bool
    /// The bot's follow-up ("approved"/"declined"), sent as a bot turn.
    public let followUp: ManualActionResolveOutcome.FollowUp

    public init(thread: AgentThread, approved: Bool, followUp: ManualActionResolveOutcome.FollowUp) {
        self.thread = thread
        self.approved = approved
        self.followUp = followUp
    }
}
