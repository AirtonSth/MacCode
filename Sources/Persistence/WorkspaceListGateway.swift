import Foundation
import CoreModel

/// MainActor-owned workspace/layout inputs for an authoritative workspace list.
/// `busySurfaceIDs` is captured while the live surface registry is available;
/// the gateway only combines that snapshot with durable AgentThread state.
public struct WorkspaceListReadSnapshot: Sendable {
    public let workspace: Workspace
    public let busySurfaceIDs: Set<SurfaceID>

    public init(workspace: Workspace, busySurfaceIDs: Set<SurfaceID>) {
        self.workspace = workspace
        self.busySurfaceIDs = busySurfaceIDs
    }
}

/// Off-MainActor workspace.list read path.
///
/// AgentThreadListGateway owns the SQLite read. This gateway owns the pure
/// workspace/busy projection on a separate serial queue, so an HTTP request
/// can await authoritative state without running either part on MainActor.
public final class WorkspaceListGateway: @unchecked Sendable {
    public static let projectionQueueLabel = "io.remotecode.workspace-list-projection"

    // MARK: - Test probes (executor proof, not latency alone)

    nonisolated(unsafe) public static private(set) var projectionCallCountForTesting: Int = 0
    nonisolated(unsafe) public static private(set) var projectionOnMainActorCountForTesting: Int = 0
    nonisolated(unsafe) public static private(set) var projectionOffMainActorCountForTesting: Int = 0

    public static func resetExecutionProbesForTesting() {
        projectionCallCountForTesting = 0
        projectionOnMainActorCountForTesting = 0
        projectionOffMainActorCountForTesting = 0
    }

    private let agentThreadListGateway: AgentThreadListGateway
    private let projectionQueue: DispatchQueue

    public init(agentThreadListGateway: AgentThreadListGateway) {
        self.agentThreadListGateway = agentThreadListGateway
        self.projectionQueue = DispatchQueue(label: Self.projectionQueueLabel, qos: .userInitiated)
    }

    /// Reads durable running-thread state and projects the busy metadata for
    /// the captured workspaces. Both SQLite and projection execute off MainActor.
    public func list(snapshots: [WorkspaceListReadSnapshot]) async throws -> [Workspace] {
        guard !snapshots.isEmpty else { return [] }
        let runningWorkspaceIDs = try await agentThreadListGateway.runningWorkspaceIDs(
            in: snapshots.map(\.workspace.id)
        )

        return await withCheckedContinuation { continuation in
            projectionQueue.async {
                Self.recordProjectionExecutorForTesting()
                let workspaces = snapshots.map { snapshot in
                    var workspace = snapshot.workspace
                    let busy = !snapshot.busySurfaceIDs.isEmpty
                        || runningWorkspaceIDs.contains(workspace.id)
                    if busy {
                        workspace.metadata["busy"] = "true"
                    } else {
                        workspace.metadata.removeValue(forKey: "busy")
                    }
                    return workspace
                }
                continuation.resume(returning: workspaces)
            }
        }
    }

    private static func recordProjectionExecutorForTesting() {
        projectionCallCountForTesting += 1
        if Thread.isMainThread {
            projectionOnMainActorCountForTesting += 1
        } else {
            projectionOffMainActorCountForTesting += 1
        }
    }
}
