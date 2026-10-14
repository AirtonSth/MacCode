import Foundation

/// Who executes an Agent App thread. `.none` is the plain provider run.
public enum RunActor: Codable, Sendable, Equatable, Hashable {
    case none
    case bot(BotID)

    public var botID: BotID? {
        if case .bot(let id) = self { return id }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case botId
    }

    private enum Kind: String, Codable {
        case none
        case bot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .none:
            self = .none
        case .bot:
            let raw = try container.decode(String.self, forKey: .botId)
            guard let uuid = UUID(uuidString: raw) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .botId,
                    in: container,
                    debugDescription: "Invalid bot UUID"
                )
            }
            self = .bot(BotID(uuid))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case .bot(let id):
            try container.encode(Kind.bot, forKey: .kind)
            try container.encode(id.value.uuidString.lowercased(), forKey: .botId)
        }
    }
}

/// Where a bot-run thread's tools execute.
public enum ExecutionTarget: String, Codable, Sendable, Equatable, Hashable {
    case mac
    case vm
}

/// Durable marker of a bot thread whose agent runs inside the bot's Linux
/// guest. A `.vm` thread without it is a legacy thread: its agent session lives
/// on the Mac and it keeps running there.
public enum BotGuestRuntime {
    /// Distill inside the guest. The only runtime this build can launch.
    public static let distillV1 = "guest-v1"
}

/// A thread's VM placement as stored: target and guest runtime marker.
public struct AgentThreadGuestPlacement: Equatable, Sendable {
    public var executionTarget: ExecutionTarget?
    public var guestRuntime: String?

    public init(executionTarget: ExecutionTarget?, guestRuntime: String?) {
        self.executionTarget = executionTarget
        self.guestRuntime = guestRuntime
    }

    /// The agent runs inside the bot's guest, never on the Mac. Any marker
    /// counts, including one a newer build wrote: such a thread must fail,
    /// not fall back to the Mac. Moving a thread to the Mac (`.mac`) is the
    /// user's explicit choice and wins over the marker.
    public var runsInGuest: Bool {
        executionTarget == .vm && guestRuntime?.isEmpty == false
    }

    /// A guest thread the user moved to the Mac ("Run this thread on the Mac",
    /// an approved Mac-execution request) keeps its marker until the provider
    /// accepts a Mac run: each run until then drops the guest session, which
    /// the Mac cannot load, and carries a handoff summary instead. Deferred to
    /// the run start because a guest run still finishing would write its
    /// session back, and kept past a failed or stopped start so no Mac
    /// session ever opens without the conversation.
    public var macHandoffPending: Bool {
        executionTarget == .mac && guestRuntime?.isEmpty == false
    }
}

public enum BotExecutionDefault {
    /// Only a Docker desktop gives the bot a VM; every other kind runs on the Mac.
    public static func target(for revision: BotRevision?) -> ExecutionTarget {
        revision?.desktopKind == .dockerDesktop ? .vm : .mac
    }
}
