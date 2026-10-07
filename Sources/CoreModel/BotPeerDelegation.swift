import Foundation

/// Provider-visible contract for AI-authored Bot delegation.
///
/// RemoteCode never derives a peer prompt from the user's prose. The active
/// provider reads the complete user turn and supplies the exact focused prompt
/// to `bot_ask_peer` itself.
public enum BotPeerDelegation: Sendable {
    public enum ReplyMode: String, Codable, Sendable {
        case consult
        case replyOnly = "reply_only"
    }

    public static let listTool = "bot_list_peers"
    public static let askTool = "bot_ask_peer"

    public static let threadEnvironmentKey = "RC_REMOTE_CODE_SUBAGENT_THREAD_ID"
    public static let runEnvironmentKey = "RC_REMOTE_CODE_ROOT_RUN_ID"
    public static let socketEnvironmentKey = "RC_REMOTE_CODE_AGENT_APP_SOCKET_PATH"
    public static let turnContextEnvironmentKey = "RC_REMOTE_CODE_BOT_TURN_CONTEXT"
    public static let capabilityEnvironmentKey = AgentDelegationCapabilityTransport.environmentKey
    public static let capabilityRPCParameterKey = "delegation_capability"
    public static let consultationIDParameterKey = "consultation_id"
    /// Idle window for `bot_ask_peer`. Peer run events restart it; silence
    /// for this long times out. This is not a wall-clock cap on a live Bot.
    public static let peerConsultationTimeout: TimeInterval = 600
    /// Space byte written on the Unix socket so the MCP child can reset its
    /// idle read deadline without completing the JSON-RPC line.
    public static let peerConsultationKeepaliveByte: UInt8 = 0x20
    public static let hostOperationTimeout: TimeInterval = RemoteCodeHostCatalog.unixClientDeadline

    public static func peerConsultationStillActive(
        now: Date = Date(),
        lastProgress: Date,
        idle: TimeInterval = peerConsultationTimeout
    ) -> Bool {
        now.timeIntervalSince(lastProgress) < idle
    }

    /// Delegation rules alone. A bot run inside its Linux guest gets only
    /// these: its gateway offers the peer tools but not the `rc_*` host
    /// catalog that `providerDirective` also describes.
    public static let peerDirective = """
    RemoteCode Bot delegation: an @handle names a RemoteCode Bot, but RemoteCode never forwards or rewrites the user's text automatically. You are the primary agent: first interpret the complete user request. When a turn includes RemoteCode-resolved Bot identity metadata, use it only to know which handles are other Bots; RemoteCode has not decided the user's intent. If the request asks one of those Bots to answer, act, provide input, or participate, you MUST call `bot_ask_peer`; never answer as that Bot or simulate its reply. If the mention is merely quoted, descriptive, or negated, do not delegate. Write a new focused `prompt` containing only what that Bot needs to answer or do; do not copy unrelated remainder of the user's instruction. Choose `consult` when you must use the reply and continue reasoning or acting. For multi-Bot comparison, debate, mediation, or consensus, call `bot_ask_peer` with `consult` as often as the request requires, including repeatedly for the same or different Bots. After each real reply, author any follow-up prompt yourself and include only the prior-reply context relevant to the next Bot. You remain responsible for mediation and final synthesis. RemoteCode does not semantically route, sequence, or set a fixed iteration count for these consultations. `reply_only` is terminal: never choose it while comparison, follow-up, mediation, or synthesis remains. Choose `reply_only` only when the user's whole turn is addressed to that Bot and its reply will itself be the complete user-facing answer; RemoteCode then displays the attributed Bot reply and suppresses your duplicate final answer. After a successful consultation, `bot_get_settings` and `bot_set_settings` may operate only on the Bot consulted by this exact active run; pass the returned Bot id when the run itself belongs to another Bot. Never claim that you contacted a Bot unless the tool call succeeded.

    A successful `bot_ask_peer` returns an opaque `consultation_id`. Omit `consultation_id` for a clean, independent review with a new Bot conversation and thread. To discuss or follow up on the same consultation, pass only the id returned by that successful call, keep the same requested Bot, and author a focused continuation prompt; the id is valid only for this exact active host run. Never invent, reuse across runs, or use another Bot's id. A continuation reuses that Bot's conversation and transcript while starting a new peer run. The primary agent remains responsible for deciding whether to continue or start a clean independent review.
    """

    public static let providerDirective = peerDirective + "\n\n" + RemoteCodeHostCatalog.providerDirective

    /// Identity-only turn context. The host resolves exact @handles so the
    /// provider cannot mistake a peer for itself, but leaves every semantic
    /// decision and the peer prompt itself to the provider.
    public static func turnDirective(mentionedBots: [BotDefinition]) -> String? {
        var seen = Set<BotID>()
        let peers = mentionedBots.filter { seen.insert($0.id).inserted }
        guard !peers.isEmpty else { return nil }
        let identities = peers.map {
            "- @\($0.handle) is \($0.name), RemoteCode Bot id \($0.id.value.uuidString.lowercased())"
        }.joined(separator: "\n")
        return """
        RemoteCode-resolved Bot identities for this exact turn:
        \(identities)

        This is identity metadata only. RemoteCode has not interpreted the request, selected a task, extracted text, or generated a peer prompt. Interpret the complete user request yourself. If it asks a listed Bot to answer, act, provide input, or participate, call `bot_ask_peer` for that Bot and author a new focused prompt containing only what it needs. Never answer on behalf of a listed Bot. Do not delegate a mention that is merely quoted, descriptive, or negated. If you are following up on the same Bot discussion, pass the exact successful `consultation_id`; omit it when you want a clean independent review.
        """
    }

    /// Carry identity separately from the user's prompt so provider transport
    /// cannot rewrite the user's words or drop the
    /// identity context. This is metadata only; the provider owns all semantics.
    public static func environment(
        addingTurnContextTo base: [String: String],
        mentionedBots: [BotDefinition]
    ) -> [String: String] {
        var environment = base
        if let directive = turnDirective(mentionedBots: mentionedBots) {
            environment[turnContextEnvironmentKey] = directive
        } else {
            environment.removeValue(forKey: turnContextEnvironmentKey)
        }
        return environment
    }

    /// Append only host-resolved identity metadata to provider instructions.
    /// No user prose is inspected here and no peer prompt is manufactured.
    public static func appendingTurnContext(
        to directives: String,
        environment: [String: String]
    ) -> String {
        guard let context = environment[turnContextEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !context.isEmpty else {
            return directives
        }
        return directives.isEmpty ? context : directives + "\n\n" + context
    }
}
