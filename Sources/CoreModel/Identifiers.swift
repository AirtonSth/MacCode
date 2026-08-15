import Foundation

public struct WindowID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct WorkspaceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct SurfaceID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct SSHHostID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct AgentThreadID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct AgentRunID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct AgentMessageID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct AgentQueuedMessageID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct ProjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct BotID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct BotRevisionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct BotConversationID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct BotMemoryItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct BotRoutineID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

public struct BotAttentionItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}

/// Normalized unique handle (`piper`). Leading `@` is never stored.
public struct BotHandle: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { value }
}
