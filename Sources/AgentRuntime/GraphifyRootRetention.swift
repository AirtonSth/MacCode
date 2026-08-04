import Foundation

/// Ownership-aware Graphify root retention (plan-final W3).
/// Only managed, inactive, unpinned, regenerable roots may be quarantined.
public struct GraphifyManagedRoot: Sendable, Equatable {
    public var rootId: String
    public var path: String
    public var lastUsedAt: Date
    public var isPinned: Bool
    public var isActive: Bool
    public var isManaged: Bool
    public var isRegenerable: Bool

    public init(
        rootId: String,
        path: String,
        lastUsedAt: Date,
        isPinned: Bool = false,
        isActive: Bool = false,
        isManaged: Bool = true,
        isRegenerable: Bool = true
    ) {
        self.rootId = rootId
        self.path = path
        self.lastUsedAt = lastUsedAt
        self.isPinned = isPinned
        self.isActive = isActive
        self.isManaged = isManaged
        self.isRegenerable = isRegenerable
    }
}

public enum GraphifyRetentionDecision: String, Sendable, Equatable {
    case keep
    case quarantine
}

public enum GraphifyRootRetention {
    public static func decide(
        root: GraphifyManagedRoot,
        now: Date,
        idleAge: TimeInterval
    ) -> GraphifyRetentionDecision {
        guard root.isManaged else { return .keep }
        guard root.isRegenerable else { return .keep }
        guard !root.isPinned else { return .keep }
        guard !root.isActive else { return .keep }
        if now.timeIntervalSince(root.lastUsedAt) < max(0, idleAge) {
            return .keep
        }
        return .quarantine
    }

    /// Atomic rename target for quarantine (never rm -rf first).
    public static func quarantinePath(for rootPath: String, stamp: String) -> String {
        rootPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + ".quarantine-\(stamp)"
    }
}
