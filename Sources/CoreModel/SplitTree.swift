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

    public static func normalize(_ rs: [Double]) -> [Double] {
        let total = rs.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1.0 / Double(max(rs.count, 1)), count: rs.count) }
        return rs.map { $0 / total }
    }
}
