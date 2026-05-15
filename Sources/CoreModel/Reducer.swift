import Foundation

public enum LayoutAction: Sendable {
    case createWorkspace(name: String, cwd: String, initial: SurfaceDescriptor?)
    case renameWorkspace(WorkspaceID, String)
    case closeWorkspace(WorkspaceID)
    case selectWorkspace(WorkspaceID)
    case addSurface(WorkspaceID, paneID: PaneID?, descriptor: SurfaceDescriptor)
    case splitPane(WorkspaceID, paneID: PaneID, direction: SplitDirection, newSurface: SurfaceDescriptor)
    case closeSurface(WorkspaceID, SurfaceID)
    case focusSurface(WorkspaceID, SurfaceID)
    case focusPane(WorkspaceID, PaneID)
    case renameSurface(WorkspaceID, SurfaceID, String)
    case markUnread(WorkspaceID, SurfaceID, Bool)
}

public enum LayoutError: Error, Equatable {
    case workspaceNotFound
    case paneNotFound
    case surfaceNotFound
    case invalidLayout
}

public struct LayoutState: Codable, Sendable, Equatable {
    public var window: AppWindow
    public var workspaces: [WorkspaceID: Workspace]

    public init(window: AppWindow = AppWindow(), workspaces: [WorkspaceID: Workspace] = [:]) {
        self.window = window
        self.workspaces = workspaces
    }
}

public struct LayoutReducer {
    public init() {}

    public func reduce(_ state: LayoutState, _ action: LayoutAction) throws -> LayoutState {
        var next = state
        switch action {
        case let .createWorkspace(name, cwd, initial):
            var pane = PaneNode(surfaces: [])
            if let initial { pane.surfaces.append(initial); pane.selectedSurfaceID = initial.id }
            let ws = Workspace(name: name, cwd: cwd, layout: .pane(pane), focusedPaneID: pane.id)
            next.workspaces[ws.id] = ws
            next.window.workspaces.append(ws.id)
            next.window.selectedWorkspaceID = ws.id
            return next
        case let .renameWorkspace(wid, newName):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            ws.name = newName; ws.updatedAt = Date(); next.workspaces[wid] = ws
            return next
        case .closeWorkspace(let wid):
            guard next.workspaces[wid] != nil else { throw LayoutError.workspaceNotFound }
            next.workspaces.removeValue(forKey: wid)
            next.window.workspaces.removeAll { $0 == wid }
            if next.window.selectedWorkspaceID == wid {
                next.window.selectedWorkspaceID = next.window.workspaces.first
            }
            return next
        case .selectWorkspace(let wid):
            guard next.workspaces[wid] != nil else { throw LayoutError.workspaceNotFound }
            next.window.selectedWorkspaceID = wid
            return next
        case let .addSurface(wid, paneID, descriptor):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            let targetPane = paneID ?? ws.focusedPaneID ?? ws.layout.paneIDs().first
            guard let tp = targetPane else { throw LayoutError.paneNotFound }
            ws.layout = try addSurface(in: ws.layout, paneID: tp, descriptor: descriptor)
            ws.updatedAt = Date()
            next.workspaces[wid] = ws
            return next
        case let .splitPane(wid, paneID, direction, newSurface):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            let (newLayout, newPaneID) = try split(in: ws.layout, paneID: paneID, direction: direction, newSurface: newSurface)
            ws.layout = newLayout
            ws.focusedPaneID = newPaneID
            ws.updatedAt = Date()
            next.workspaces[wid] = ws
            return next
        case .closeSurface(let wid, let sid):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            ws.layout = try removeSurface(in: ws.layout, surfaceID: sid)
            if let focused = ws.focusedPaneID, ws.layout.find(paneID: focused) == nil {
                ws.focusedPaneID = ws.layout.paneIDs().first
            }
            ws.updatedAt = Date()
            next.workspaces[wid] = ws
            return next
        case .focusSurface(let wid, let sid):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            guard let pid = paneContaining(layout: ws.layout, surfaceID: sid) else { throw LayoutError.surfaceNotFound }
            ws.layout = try selectSurface(in: ws.layout, paneID: pid, surfaceID: sid)
            ws.focusedPaneID = pid
            next.workspaces[wid] = ws
            return next
        case .focusPane(let wid, let pid):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            guard ws.layout.find(paneID: pid) != nil else { throw LayoutError.paneNotFound }
            ws.focusedPaneID = pid
            next.workspaces[wid] = ws
            return next
        case .renameSurface(let wid, let sid, let title):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            ws.layout = try mutateSurface(in: ws.layout, surfaceID: sid) { $0.title = title }
            next.workspaces[wid] = ws
            return next
        case .markUnread(let wid, let sid, let unread):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            ws.layout = try mutateSurface(in: ws.layout, surfaceID: sid) { $0.hasUnreadActivity = unread }
            next.workspaces[wid] = ws
            return next
        }
    }

    // MARK: helpers

    private func addSurface(in node: LayoutNode, paneID: PaneID, descriptor: SurfaceDescriptor) throws -> LayoutNode {
        switch node {
        case .pane(var p):
            if p.id == paneID {
                p.surfaces.append(descriptor)
                p.selectedSurfaceID = descriptor.id
                return .pane(p)
            }
            return .pane(p)
        case .split(var s):
            s.children = try s.children.map { try addSurface(in: $0, paneID: paneID, descriptor: descriptor) }
            return .split(s)
        }
    }

    private func split(in node: LayoutNode, paneID: PaneID, direction: SplitDirection, newSurface: SurfaceDescriptor) throws -> (LayoutNode, PaneID) {
        let neededOrientation: SplitOrientation = (direction == .right || direction == .left) ? .horizontal : .vertical
        switch node {
        case .pane(let p):
            if p.id == paneID {
                let newPane = PaneNode(surfaces: [newSurface], selectedSurfaceID: newSurface.id)
                let originalChild = LayoutNode.pane(p)
                let newChild = LayoutNode.pane(newPane)
                let kids: [LayoutNode] = (direction == .right || direction == .down) ? [originalChild, newChild] : [newChild, originalChild]
                let s = SplitNode(orientation: neededOrientation, children: kids)
                return (.split(s), newPane.id)
            }
            return (.pane(p), paneID)
        case .split(var s):
            var newID = paneID
            s.children = try s.children.map { child -> LayoutNode in
                let (mapped, nid) = try split(in: child, paneID: paneID, direction: direction, newSurface: newSurface)
                if nid != paneID { newID = nid }
                return mapped
            }
            return (.split(s), newID)
        }
    }

    private func removeSurface(in node: LayoutNode, surfaceID: SurfaceID) throws -> LayoutNode {
        switch node {
        case .pane(var p):
            if let idx = p.surfaces.firstIndex(where: { $0.id == surfaceID }) {
                p.surfaces.remove(at: idx)
                if p.selectedSurfaceID == surfaceID {
                    p.selectedSurfaceID = p.surfaces.first?.id
                }
            }
            return .pane(p)
        case .split(var s):
            s.children = try s.children.map { try removeSurface(in: $0, surfaceID: surfaceID) }
            // collapse empty panes inside splits
            s.children = s.children.compactMap { child -> LayoutNode? in
                if case .pane(let p) = child, p.surfaces.isEmpty { return nil }
                return child
            }
            // recompute ratios
            if s.children.isEmpty { return .pane(PaneNode()) }
            if s.children.count == 1 { return s.children[0] }
            s.ratios = Array(repeating: 1.0 / Double(s.children.count), count: s.children.count)
            return .split(s)
        }
    }

    private func selectSurface(in node: LayoutNode, paneID: PaneID, surfaceID: SurfaceID) throws -> LayoutNode {
        switch node {
        case .pane(var p):
            if p.id == paneID, p.surfaces.contains(where: { $0.id == surfaceID }) {
                p.selectedSurfaceID = surfaceID
            }
            return .pane(p)
        case .split(var s):
            s.children = try s.children.map { try selectSurface(in: $0, paneID: paneID, surfaceID: surfaceID) }
            return .split(s)
        }
    }

    private func mutateSurface(in node: LayoutNode, surfaceID: SurfaceID, _ mutator: (inout SurfaceDescriptor) -> Void) throws -> LayoutNode {
        switch node {
        case .pane(var p):
            if let idx = p.surfaces.firstIndex(where: { $0.id == surfaceID }) {
                mutator(&p.surfaces[idx])
            }
            return .pane(p)
        case .split(var s):
            s.children = try s.children.map { try mutateSurface(in: $0, surfaceID: surfaceID, mutator) }
            return .split(s)
        }
    }

    private func paneContaining(layout: LayoutNode, surfaceID: SurfaceID) -> PaneID? {
        switch layout {
        case .pane(let p):
            return p.surfaces.contains(where: { $0.id == surfaceID }) ? p.id : nil
        case .split(let s):
            for c in s.children { if let r = paneContaining(layout: c, surfaceID: surfaceID) { return r } }
            return nil
        }
    }
}
