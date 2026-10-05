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

public enum BotExecutionDefault {
    /// Only a Docker desktop gives the bot a VM; every other kind runs on the Mac.
    public static func target(for revision: BotRevision?) -> ExecutionTarget {
        revision?.desktopKind == .dockerDesktop ? .vm : .mac
    }
}
