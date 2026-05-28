import Foundation

public enum LayoutAction: Sendable {
    case createWorkspace(name: String, cwd: String, initial: SurfaceDescriptor?)
    case renameWorkspace(WorkspaceID, String)
    case setWorkspaceDescription(WorkspaceID, String)
    case setWorkspaceColor(WorkspaceID, String)
    case setWorkspacePinned(WorkspaceID, Bool)
    case reorderWorkspace(WorkspaceID, position: Int)
    case promoteWorkspace(WorkspaceID)
    case setSurfaceColor(WorkspaceID, SurfaceID, String)
    case closeWorkspace(WorkspaceID)
    case selectWorkspace(WorkspaceID)
    case addSurface(WorkspaceID, paneID: PaneID?, descriptor: SurfaceDescriptor)
    case splitPane(WorkspaceID, paneID: PaneID, direction: SplitDirection, newSurface: SurfaceDescriptor)
    case closeSurface(WorkspaceID, SurfaceID)
    case focusSurface(WorkspaceID, SurfaceID)
    case focusPane(WorkspaceID, PaneID)
    case renameSurface(WorkspaceID, SurfaceID, String)
    case markUnread(WorkspaceID, SurfaceID, Bool)
    case reorderSurface(WorkspaceID, surface: SurfaceID, toPane: PaneID, position: Int)
    case moveSurfaceToPane(WorkspaceID, surface: SurfaceID, targetPane: PaneID)
    case splitSurface(WorkspaceID, paneID: PaneID, surface: SurfaceID, direction: SplitDirection)
    case resizeSplit(WorkspaceID, splitID: UUID, ratios: [Double])
    case createWindow(title: String?)
    case focusWindow(WindowID)
    case closeWindow(WindowID)
    case moveWorkspaceToWindow(WorkspaceID, WindowID)
    case swapPanes(WorkspaceID, PaneID, PaneID)
}

public enum LayoutError: Error, Equatable {
    case workspaceNotFound
    case paneNotFound
    case surfaceNotFound
    case invalidLayout
}

public struct LayoutState: Codable, Sendable, Equatable {
    public var windows: [AppWindow]
    public var focusedWindowID: WindowID
    public var workspaces: [WorkspaceID: Workspace]

    /// Legacy single-window accessor: returns the focused window or the
    /// first window. Setting it replaces the focused window.
    public var window: AppWindow {
        get { windows.first(where: { $0.id == focusedWindowID }) ?? windows[0] }
        set {
            if let idx = windows.firstIndex(where: { $0.id == newValue.id }) {
                windows[idx] = newValue
            } else {
                windows.append(newValue)
            }
            focusedWindowID = newValue.id
        }
    }

    public init(window: AppWindow = AppWindow(), workspaces: [WorkspaceID: Workspace] = [:]) {
        self.windows = [window]
        self.focusedWindowID = window.id
        self.workspaces = workspaces
    }

    public init(windows: [AppWindow], focusedWindowID: WindowID, workspaces: [WorkspaceID: Workspace] = [:]) {
        precondition(!windows.isEmpty)
        self.windows = windows
        self.focusedWindowID = focusedWindowID
        self.workspaces = workspaces
    }

    public func findWindow(_ id: WindowID) -> AppWindow? { windows.first(where: { $0.id == id }) }
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
        case let .setWorkspaceDescription(wid, text):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            if text.isEmpty { ws.metadata.removeValue(forKey: "description") }
            else { ws.metadata["description"] = text }
            ws.updatedAt = Date()
            next.workspaces[wid] = ws
            return next
        case let .setWorkspaceColor(wid, color):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            if color.isEmpty { ws.metadata.removeValue(forKey: "color") }
            else { ws.metadata["color"] = color }
            ws.updatedAt = Date()
            next.workspaces[wid] = ws
            return next
        case let .setWorkspacePinned(wid, pinned):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            if pinned { ws.metadata["pinned"] = "true" }
            else { ws.metadata.removeValue(forKey: "pinned") }
            ws.updatedAt = Date()
            next.workspaces[wid] = ws
            next.window.workspaces = pinSorted(next.window.workspaces, workspaces: next.workspaces)
            return next
        case let .reorderWorkspace(wid, position):
            guard next.workspaces[wid] != nil else { throw LayoutError.workspaceNotFound }
            guard let current = next.window.workspaces.firstIndex(of: wid) else { throw LayoutError.workspaceNotFound }
            var order = next.window.workspaces
            order.remove(at: current)
            order.insert(wid, at: max(0, min(position, order.count)))
            next.window.workspaces = pinSorted(order, workspaces: next.workspaces)
            return next
        case let .promoteWorkspace(wid):
            guard next.workspaces[wid] != nil else { throw LayoutError.workspaceNotFound }
            guard next.window.workspaces.contains(wid) else { throw LayoutError.workspaceNotFound }
            next.window.workspaces = promote(wid, in: next.window.workspaces, workspaces: next.workspaces)
            return next
        case let .setSurfaceColor(wid, sid, color):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            ws.layout = try mutateSurface(in: ws.layout, surfaceID: sid) {
                if color.isEmpty { $0.metadata.removeValue(forKey: "color") }
                else { $0.metadata["color"] = color }
            }
            next.workspaces[wid] = ws
            return next
        case .closeWorkspace(let wid):
            guard next.workspaces[wid] != nil else { throw LayoutError.workspaceNotFound }
            next.workspaces.removeValue(forKey: wid)
            for index in next.windows.indices {
                next.windows[index].workspaces.removeAll { $0 == wid }
                if next.windows[index].selectedWorkspaceID == wid {
                    next.windows[index].selectedWorkspaceID = next.windows[index].workspaces.first
                }
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
        case .reorderSurface(let wid, let sid, let toPane, let position):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            guard let desc = findSurface(in: ws.layout, id: sid) else { throw LayoutError.surfaceNotFound }
            ws.layout = try removeSurface(in: ws.layout, surfaceID: sid)
            ws.layout = try insertSurface(in: ws.layout, paneID: toPane, descriptor: desc, position: position)
            next.workspaces[wid] = ws
            return next
        case .moveSurfaceToPane(let wid, let sid, let target):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            guard let desc = findSurface(in: ws.layout, id: sid) else { throw LayoutError.surfaceNotFound }
            ws.layout = try removeSurface(in: ws.layout, surfaceID: sid)
            ws.layout = try addSurface(in: ws.layout, paneID: target, descriptor: desc)
            next.workspaces[wid] = ws
            return next
        case .splitSurface(let wid, let paneID, let sid, let direction):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            let (layout, newPaneID) = try splitMovingSurface(in: ws.layout, paneID: paneID, surfaceID: sid, direction: direction)
            ws.layout = layout
            ws.focusedPaneID = newPaneID
            next.workspaces[wid] = ws
            return next
        case .resizeSplit(let wid, let splitID, let ratios):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            ws.layout = updateSplitRatios(node: ws.layout, splitID: splitID, ratios: ratios)
            next.workspaces[wid] = ws
            return next
        case .createWindow(let title):
            let w = AppWindow(title: title ?? "RemoteCode")
            next.windows.append(w)
            next.focusedWindowID = w.id
            return next
        case .focusWindow(let wid):
            guard next.windows.contains(where: { $0.id == wid }) else { throw LayoutError.workspaceNotFound }
            next.focusedWindowID = wid
            return next
        case .closeWindow(let wid):
            guard next.windows.contains(where: { $0.id == wid }) else { throw LayoutError.workspaceNotFound }
            // Move workspaces back to first remaining window; never strand them.
            if let idx = next.windows.firstIndex(where: { $0.id == wid }) {
                let removed = next.windows.remove(at: idx)
                if next.windows.isEmpty {
                    next.windows = [AppWindow()]
                }
                next.windows[0].workspaces.append(contentsOf: removed.workspaces)
                if next.focusedWindowID == wid { next.focusedWindowID = next.windows[0].id }
            }
            return next
        case .moveWorkspaceToWindow(let workspaceId, let targetWindowID):
            guard next.windows.contains(where: { $0.id == targetWindowID }) else { throw LayoutError.workspaceNotFound }
            for i in next.windows.indices {
                next.windows[i].workspaces.removeAll { $0 == workspaceId }
                if next.windows[i].selectedWorkspaceID == workspaceId {
                    next.windows[i].selectedWorkspaceID = next.windows[i].workspaces.first
                }
            }
            if let idx = next.windows.firstIndex(where: { $0.id == targetWindowID }) {
                next.windows[idx].workspaces.append(workspaceId)
                next.windows[idx].selectedWorkspaceID = workspaceId
            }
            return next
        case .swapPanes(let wid, let a, let b):
            guard var ws = next.workspaces[wid] else { throw LayoutError.workspaceNotFound }
            guard let nodeA = ws.layout.find(paneID: a), let nodeB = ws.layout.find(paneID: b) else { throw LayoutError.paneNotFound }
            // Swap surface contents between the two panes.
            ws.layout = swap(in: ws.layout, paneIDA: a, paneIDB: b, paneA: nodeA, paneB: nodeB)
            next.workspaces[wid] = ws
            return next
        }
    }

    private func swap(in node: LayoutNode, paneIDA: PaneID, paneIDB: PaneID, paneA: PaneNode, paneB: PaneNode) -> LayoutNode {
        switch node {
        case .pane(var p):
            if p.id == paneIDA {
                p.surfaces = paneB.surfaces
                p.selectedSurfaceID = paneB.selectedSurfaceID
            } else if p.id == paneIDB {
                p.surfaces = paneA.surfaces
                p.selectedSurfaceID = paneA.selectedSurfaceID
            }
            return .pane(p)
        case .split(var s):
            s.children = s.children.map { swap(in: $0, paneIDA: paneIDA, paneIDB: paneIDB, paneA: paneA, paneB: paneB) }
            return .split(s)
        }
    }

    private func findSurface(in node: LayoutNode, id: SurfaceID) -> SurfaceDescriptor? {
        switch node {
        case .pane(let p): return p.surfaces.first { $0.id == id }
        case .split(let s):
            for c in s.children { if let r = findSurface(in: c, id: id) { return r } }
            return nil
        }
    }

    private func insertSurface(in node: LayoutNode, paneID: PaneID, descriptor: SurfaceDescriptor, position: Int) throws -> LayoutNode {
        switch node {
        case .pane(var p):
            if p.id == paneID {
                let idx = max(0, min(position, p.surfaces.count))
                p.surfaces.insert(descriptor, at: idx)
                p.selectedSurfaceID = descriptor.id
                return .pane(p)
            }
            return .pane(p)
        case .split(var s):
            s.children = try s.children.map { try insertSurface(in: $0, paneID: paneID, descriptor: descriptor, position: position) }
            return .split(s)
        }
    }

    private func updateSplitRatios(node: LayoutNode, splitID: UUID, ratios: [Double]) -> LayoutNode {
        switch node {
        case .pane: return node
        case .split(var s):
            if s.id == splitID, ratios.count == s.children.count {
                s.ratios = SplitNode.normalize(ratios)
            } else {
                s.children = s.children.map { updateSplitRatios(node: $0, splitID: splitID, ratios: ratios) }
            }
            return .split(s)
        }
    }

    // MARK: helpers

    private func isPinned(_ id: WorkspaceID, workspaces: [WorkspaceID: Workspace]) -> Bool {
        workspaces[id]?.metadata["pinned"] == "true"
    }

    private func pinSorted(_ ids: [WorkspaceID], workspaces: [WorkspaceID: Workspace]) -> [WorkspaceID] {
        ids.filter { isPinned($0, workspaces: workspaces) }
            + ids.filter { !isPinned($0, workspaces: workspaces) }
    }

    private func promote(_ id: WorkspaceID, in ids: [WorkspaceID], workspaces: [WorkspaceID: Workspace]) -> [WorkspaceID] {
        let pinned = isPinned(id, workspaces: workspaces)
        let sameGroup = ids.filter { $0 != id && isPinned($0, workspaces: workspaces) == pinned }
        let otherGroup = ids.filter { isPinned($0, workspaces: workspaces) != pinned }
        return pinned ? [id] + sameGroup + otherGroup : otherGroup + [id] + sameGroup
    }

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

    private func splitExistingSurface(in node: LayoutNode, paneID: PaneID, surfaceID: SurfaceID, direction: SplitDirection) throws -> (LayoutNode, PaneID) {
        let neededOrientation: SplitOrientation = (direction == .right || direction == .left) ? .horizontal : .vertical
        switch node {
        case .pane(var p):
            guard p.id == paneID else { return (.pane(p), paneID) }
            guard let idx = p.surfaces.firstIndex(where: { $0.id == surfaceID }) else {
                throw LayoutError.surfaceNotFound
            }
            guard p.surfaces.count > 1 else {
                throw LayoutError.invalidLayout
            }
            let moved = p.surfaces.remove(at: idx)
            if p.selectedSurfaceID == surfaceID {
                p.selectedSurfaceID = p.surfaces.first?.id
            }
            let newPane = PaneNode(surfaces: [moved], selectedSurfaceID: moved.id)
            let originalChild = LayoutNode.pane(p)
            let newChild = LayoutNode.pane(newPane)
            let kids: [LayoutNode] = (direction == .right || direction == .down) ? [originalChild, newChild] : [newChild, originalChild]
            let split = SplitNode(orientation: neededOrientation, children: kids)
            return (.split(split), newPane.id)
        case .split(var s):
            var newID = paneID
            var found = false
            s.children = try s.children.map { child in
                let (mapped, candidateID) = try splitExistingSurface(in: child, paneID: paneID, surfaceID: surfaceID, direction: direction)
                if candidateID != paneID {
                    newID = candidateID
                    found = true
                }
                return mapped
            }
            if found { return (.split(s), newID) }
            return (.split(s), paneID)
        }
    }

    private func splitMovingSurface(in node: LayoutNode, paneID: PaneID, surfaceID: SurfaceID, direction: SplitDirection) throws -> (LayoutNode, PaneID) {
        if node.find(paneID: paneID)?.surfaces.contains(where: { $0.id == surfaceID }) == true {
            return try splitExistingSurface(in: node, paneID: paneID, surfaceID: surfaceID, direction: direction)
        }
        guard let moved = findSurface(in: node, id: surfaceID) else { throw LayoutError.surfaceNotFound }
        let withoutMoved = try removeSurface(in: node, surfaceID: surfaceID)
        guard withoutMoved.find(paneID: paneID) != nil else { throw LayoutError.paneNotFound }
        return try split(in: withoutMoved, paneID: paneID, direction: direction, newSurface: moved)
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
