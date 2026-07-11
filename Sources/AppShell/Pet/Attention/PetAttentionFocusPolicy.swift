import CoreModel
import Foundation
import SocketServer

public struct PetAttentionFocusDestination: Sendable, Equatable {
    public let detachedWorkspaceID: WorkspaceID?
    public let selectedWorkspaceID: WorkspaceID?
    public let focusedSurfaceID: SurfaceID?
}

public enum PetAttentionFocusPolicy {
    public static func resolveDestination(
        event: EventBus.Event,
        mainSelectedWorkspaceID: WorkspaceID?,
        focusedSurfaceByWorkspace: [WorkspaceID: SurfaceID],
        detachedWorkspaceIDs: Set<WorkspaceID>
    ) -> PetAttentionFocusDestination {
        let eventWorkspaceID: WorkspaceID? = {
            guard case .object(let payload) = event.payload else { return nil }
            return payload["workspace_id"]?.stringValue
                .flatMap(UUID.init(uuidString:))
                .map(WorkspaceID.init)
        }()
        let detachedWorkspaceID = eventWorkspaceID.flatMap {
            detachedWorkspaceIDs.contains($0) ? $0 : nil
        }
        let selectedWorkspaceID = detachedWorkspaceID ?? mainSelectedWorkspaceID
        return PetAttentionFocusDestination(
            detachedWorkspaceID: detachedWorkspaceID,
            selectedWorkspaceID: selectedWorkspaceID,
            focusedSurfaceID: selectedWorkspaceID.flatMap { focusedSurfaceByWorkspace[$0] }
        )
    }

    public static func shouldPersist(
        event: EventBus.Event,
        isAppActive: Bool,
        isDestinationWindowFocused: Bool,
        selectedWorkspaceID: WorkspaceID?,
        focusedSurfaceID: SurfaceID?
    ) -> Bool {
        guard isAppActive, isDestinationWindowFocused, isSuccessfulTerminalOutcome(event),
              case .object(let payload) = event.payload else { return true }

        if let surfaceID = payload["surface_id"]?.stringValue
            .flatMap(UUID.init(uuidString:))
            .map(SurfaceID.init) {
            return surfaceID != focusedSurfaceID
        }
        if let workspaceID = payload["workspace_id"]?.stringValue
            .flatMap(UUID.init(uuidString:))
            .map(WorkspaceID.init) {
            return workspaceID != selectedWorkspaceID
        }
        return true
    }

    private static func isSuccessfulTerminalOutcome(_ event: EventBus.Event) -> Bool {
        guard case .object(let payload) = event.payload else { return false }
        switch event.kind {
        case "git.push", "git.deliver":
            return payload["ok"]?.boolValue == true
        case "project.script.finished":
            return payload["result"]?.stringValue == "success"
        case "ssh.transfer.completed":
            return true
        default:
            return false
        }
    }
}
