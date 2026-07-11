import Foundation

public enum SplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical
}

public enum SplitDirection: String, Codable, Sendable {
    case right
    case down
    case left
    case up
}

public indirect enum LayoutNode: Codable, Sendable, Equatable {
    case pane(PaneNode)
    case split(SplitNode)

    public var isPane: Bool {
        if case .pane = self { return true } else { return false }
    }

    public func find(paneID: PaneID) -> PaneNode? {
        switch self {
        case .pane(let p): return p.id == paneID ? p : nil
        case .split(let s): return s.children.compactMap { $0.find(paneID: paneID) }.first
        }
    }

    public func paneIDs() -> [PaneID] {
        switch self {
        case .pane(let p): return [p.id]
        case .split(let s): return s.children.flatMap { $0.paneIDs() }
        }
    }

    public func contains(surfaceID: SurfaceID) -> Bool {
        switch self {
        case .pane(let p): return p.surfaces.contains(where: { $0.id == surfaceID })
        case .split(let s): return s.children.contains(where: { $0.contains(surfaceID: surfaceID) })
        }
    }

    /// The first pane in visual order (leftmost/topmost leaf) of this subtree.
    public func firstPane() -> PaneNode? {
        switch self {
        case .pane(let p): return p
        case .split(let s): return s.children.lazy.compactMap { $0.firstPane() }.first
        }
    }

    /// The pane immediately to the visual right of `paneID`: the nearest ancestor
    /// horizontal split in which the subtree holding the pane has a right sibling
    /// decides, and the sibling's leftmost pane is returned. nil when the pane is
    /// already right-most (or not in this tree). Horizontal splits lay children
    /// left→right in array order (see MainWindowController.buildLayoutView).
    public func rightNeighborPane(of paneID: PaneID) -> PaneNode? {
        func search(_ node: LayoutNode) -> (found: Bool, neighbor: PaneNode?) {
            switch node {
            case .pane(let pane):
                return (pane.id == paneID, nil)
            case .split(let split):
                for (index, child) in split.children.enumerated() {
                    let result = search(child)
                    guard result.found else { continue }
                    if let neighbor = result.neighbor { return (true, neighbor) }
                    if split.orientation == .horizontal, index + 1 < split.children.count {
                        return (true, split.children[index + 1].firstPane())
                    }
                    return (true, nil)
                }
                return (false, nil)
            }
        }
        return search(self).neighbor
    }
}

public struct PaneNode: Codable, Sendable, Equatable {
    public let id: PaneID
    public var surfaces: [SurfaceDescriptor]
    public var selectedSurfaceID: SurfaceID?

    public init(id: PaneID = PaneID(), surfaces: [SurfaceDescriptor] = [], selectedSurfaceID: SurfaceID? = nil) {
        self.id = id
        self.surfaces = surfaces
        self.selectedSurfaceID = selectedSurfaceID ?? surfaces.first?.id
    }
}

public struct SplitNode: Codable, Sendable, Equatable {
    public let id: UUID
    public var orientation: SplitOrientation
    public var children: [LayoutNode]
    /// Normalized ratios summing to ~1.0; same count as children.
    public var ratios: [Double]

    public init(id: UUID = UUID(), orientation: SplitOrientation, children: [LayoutNode], ratios: [Double]? = nil) {
        self.id = id
        self.orientation = orientation
        self.children = children
        if let ratios, ratios.count == children.count {
            self.ratios = SplitNode.normalize(ratios)
        } else {
            let equal = Array(repeating: 1.0 / Double(max(children.count, 1)), count: children.count)
            self.ratios = equal
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case orientation
        case children
        case ratios
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        orientation = try container.decode(SplitOrientation.self, forKey: .orientation)
        children = try container.decode([LayoutNode].self, forKey: .children)
        let decodedRatios = try container.decodeIfPresent([Double].self, forKey: .ratios)
        if let decodedRatios, decodedRatios.count == children.count {
            ratios = SplitNode.normalize(decodedRatios)
        } else {
            ratios = Array(repeating: 1.0 / Double(max(children.count, 1)), count: children.count)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(orientation, forKey: .orientation)
        try container.encode(children, forKey: .children)
        try container.encode(ratios, forKey: .ratios)
    }

    public static func normalize(_ rs: [Double]) -> [Double] {
        let total = rs.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1.0 / Double(max(rs.count, 1)), count: rs.count) }
        return rs.map { $0 / total }
    }
}
