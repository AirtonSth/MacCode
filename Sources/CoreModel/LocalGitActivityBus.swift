import Foundation

public struct LocalGitActivity: Sendable, Equatable {
    public let kind: String
    public let workspaceID: WorkspaceID
    public let surfaceID: SurfaceID
    public let succeeded: Bool

    public init(kind: String, workspaceID: WorkspaceID, surfaceID: SurfaceID, succeeded: Bool) {
        self.kind = kind
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
        self.succeeded = succeeded
    }
}

/// Narrow dependency-inversion seam from the Surfaces target to AppShell's
/// EventBus owner. Payloads contain only stable IDs, operation kind, and result.
public final class LocalGitActivityBus: @unchecked Sendable {
    public static let shared = LocalGitActivityBus()

    private let lock = NSLock()
    private var _sink: (@Sendable (LocalGitActivity) -> Void)?

    public var sink: (@Sendable (LocalGitActivity) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _sink
        }
        set {
            lock.lock(); _sink = newValue; lock.unlock()
        }
    }

    public func emit(_ activity: LocalGitActivity) {
        let callback = sink
        callback?(activity)
    }
}
