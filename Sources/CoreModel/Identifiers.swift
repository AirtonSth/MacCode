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

public struct ProjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let value: UUID
    public init(_ value: UUID = UUID()) { self.value = value }
    public var description: String { value.uuidString }
}
