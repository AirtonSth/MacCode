import CoreModel
import Foundation

/// One manual-action request (a bot asking the user to log in, solve a captcha, …)
/// as paired devices see it through `agent.manual_action.*`.
public struct ManualActionSnapshot: Equatable, Sendable {
    public let request: ManualActionRequest
    public let botName: String?
    /// False when the thread runs on the Mac: there is no bot computer to take,
    /// and the Mac card hides "Assumir controle" too.
    public let canTake: Bool

    public init(request: ManualActionRequest, botName: String?, canTake: Bool) {
        self.request = request
        self.botName = botName
        self.canTake = canTake
    }
}

/// `agent.manual_action.resolve` `action`.
public enum ManualActionResolution: String, Sendable, CaseIterable {
    case take
    case `continue`
    case decline
}

public struct ManualActionResolveOutcome: Sendable {
    public enum FollowUp: Sendable {
        /// The bot's follow-up message started a run or was queued behind one.
        case sent(AgentMessageSendResult)
        /// The request is resolved but its follow-up could not be sent.
        case failed(String)
    }

    public let manualAction: ManualActionSnapshot
    public let pending: ManualActionSnapshot?
    /// nil for `take`, which sends nothing to the bot.
    public let followUp: FollowUp?

    public init(manualAction: ManualActionSnapshot, pending: ManualActionSnapshot?, followUp: FollowUp?) {
        self.manualAction = manualAction
        self.pending = pending
        self.followUp = followUp
    }
}

public enum ManualActionWire {
    /// The request is not one of this thread's.
    public static let notFoundCode = -32060
    /// Another resolve won (the Mac card, another device or a parallel call).
    public static let stateConflictCode = -32061
    /// `take` on a thread that runs on the Mac.
    public static let takeUnavailableCode = -32062

    public static func row(_ snapshot: ManualActionSnapshot) -> JSONValue {
        let request = snapshot.request
        return .object([
            "id": .string(request.id.uuidString),
            "thread_id": request.threadID.map { .string($0.value.uuidString) } ?? .null,
            "bot_id": .string(request.botID.value.uuidString),
            "bot_name": snapshot.botName.map { .string($0) } ?? .null,
            "kind": .string(request.kind.rawValue),
            "reason": .string(request.reason),
            "state": .string(request.state.rawValue),
            "created_at": .number(request.createdAt.timeIntervalSince1970),
            "resolved_at": request.resolvedAt.map { .number($0.timeIntervalSince1970) } ?? .null,
            "note": request.note.map { .string($0) } ?? .null,
            "can_take": .bool(snapshot.canTake),
        ])
    }

    public static func pendingRow(_ snapshot: ManualActionSnapshot?) -> JSONValue {
        snapshot.map(row) ?? .null
    }

    /// `agent.manual_action.updated` payload.
    public static func updatedEvent(
        thread: AgentThreadID,
        manualAction: ManualActionSnapshot,
        pending: ManualActionSnapshot?
    ) -> JSONValue {
        .object([
            "thread_id": .string(thread.value.uuidString),
            "manual_action": row(manualAction),
            "pending_manual_action": pendingRow(pending),
        ])
    }

    /// Refusals change nothing, so the receipt ledger frees the request id.
    public static func refusal(code: Int, kind: String, message: String, state: ManualActionState? = nil) -> JSONRPCError {
        var data: [String: JSONValue] = ["domain": .string("manual_action"), "kind": .string(kind)]
        if let state { data["state"] = .string(state.rawValue) }
        return JSONRPCError(code: code, message: message, data: .object(data))
    }
}
