import Foundation

public struct Workspace: Codable, Sendable, Equatable, Identifiable {
    public let id: WorkspaceID
    public var name: String
    public var cwd: String
    public var createdAt: Date
    public var updatedAt: Date
    public var layout: LayoutNode
    public var focusedPaneID: PaneID?
    public var notificationsUnread: Int
    public var metadata: [String: String]

    public init(
        id: WorkspaceID = WorkspaceID(),
        name: String,
        cwd: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        layout: LayoutNode,
        focusedPaneID: PaneID? = nil,
        notificationsUnread: Int = 0,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.layout = layout
        self.focusedPaneID = focusedPaneID ?? layout.paneIDs().first
        self.notificationsUnread = notificationsUnread
        self.metadata = metadata
    }

    public static func empty(name: String, cwd: String) -> Workspace {
        let pane = PaneNode(surfaces: [])
        return Workspace(name: name, cwd: cwd, layout: .pane(pane), focusedPaneID: pane.id)
    }
}

public struct AppWindow: Codable, Sendable, Equatable, Identifiable {
    public let id: WindowID
    public var workspaces: [WorkspaceID]
    public var selectedWorkspaceID: WorkspaceID?
    public var title: String

    public init(id: WindowID = WindowID(), workspaces: [WorkspaceID] = [], selectedWorkspaceID: WorkspaceID? = nil, title: String = "RemoteCode 2") {
        self.id = id
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
        self.title = title
    }
}
