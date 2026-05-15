import Foundation

public enum SurfaceType: String, Codable, Sendable, CaseIterable {
    case terminal
    case browser
    case agentApp
}

public enum AgentProvider: String, Codable, Sendable, CaseIterable {
    case codex
    case claude
}

public struct SurfaceDescriptor: Codable, Sendable, Hashable {
    public let id: SurfaceID
    public let type: SurfaceType
    public var title: String
    public var iconName: String
    public var isDirty: Bool
    public var hasUnreadActivity: Bool
    public var metadata: [String: String]

    public init(
        id: SurfaceID = SurfaceID(),
        type: SurfaceType,
        title: String,
        iconName: String = "",
        isDirty: Bool = false,
        hasUnreadActivity: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.iconName = iconName
        self.isDirty = isDirty
        self.hasUnreadActivity = hasUnreadActivity
        self.metadata = metadata
    }
}
