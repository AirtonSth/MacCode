import Foundation

public struct SessionSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion: Int = 1

    public let version: Int
    public let createdAt: Date
    public let layout: LayoutState
    public let windowFrame: WindowFrame?
    public let selectedThreadByWorkspace: [WorkspaceID: AgentThreadID]
    public let selectedProviderByWorkspace: [WorkspaceID: AgentProvider]

    public init(
        version: Int = SessionSnapshot.currentVersion,
        createdAt: Date = Date(),
        layout: LayoutState,
        windowFrame: WindowFrame? = nil,
        selectedThreadByWorkspace: [WorkspaceID: AgentThreadID] = [:],
        selectedProviderByWorkspace: [WorkspaceID: AgentProvider] = [:]
    ) {
        self.version = version
        self.createdAt = createdAt
        self.layout = layout
        self.windowFrame = windowFrame
        self.selectedThreadByWorkspace = selectedThreadByWorkspace
        self.selectedProviderByWorkspace = selectedProviderByWorkspace
    }
}

public struct WindowFrame: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}
