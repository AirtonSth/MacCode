import Foundation

/// A durable destination. A VM's identity is independent of the bots using it.
public enum BotExecutionDestination: Hashable, Sendable, Codable {
    case mac
    case ownVM
    case virtualMachine(UUID)

    public var target: ExecutionTarget { self == .mac ? .mac : .vm }

    public var virtualMachineID: UUID? {
        if case .virtualMachine(let id) = self { return id }
        return nil
    }

    public var storageValue: String {
        switch self {
        case .mac: return "mac"
        case .ownVM: return "own_vm"
        case .virtualMachine(let id): return "vm:\(id.uuidString.lowercased())"
        }
    }

    public init?(storageValue: String) {
        switch storageValue {
        case "mac": self = .mac
        case "own_vm": self = .ownVM
        default:
            guard storageValue.hasPrefix("vm:"),
                  let id = UUID(uuidString: String(storageValue.dropFirst(3))) else { return nil }
            self = .virtualMachine(id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let destination = Self(storageValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown execution destination.")
        }
        self = destination
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

public struct BotVirtualMachine: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// nil is a general VM. Workspace VMs accept only that workspace's exclusive bots.
    public let workspaceID: WorkspaceID?
    public let createdAt: Date

    public init(id: UUID = UUID(), name: String, workspaceID: WorkspaceID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.workspaceID = workspaceID
        self.createdAt = createdAt
    }

    /// The existing Docker storage format uses BotID as an opaque namespace.
    /// This must never replace a bot's actor, credentials or authorization identity.
    public var storageID: BotID { BotID(id) }

    public func allows(_ bot: BotDefinition) -> Bool {
        workspaceID == nil || workspaceID == bot.workspaceID
    }
}
