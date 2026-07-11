import XCTest
@testable import AppShell
import CoreModel
import SocketServer

final class PetAttentionFocusPolicyTests: XCTestCase {
    private func event(_ kind: String, _ payload: [String: JSONValue]) -> EventBus.Event {
        EventBus.Event(seq: 1, kind: kind, payload: .object(payload), ts: 1)
    }

    func test_successIsSuppressedOnlyWhenExactDestinationIsAlreadyFocused() {
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        let success = event("project.script.finished", [
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surfaceID.value.uuidString),
            "result": .string("success")
        ])

        XCTAssertFalse(PetAttentionFocusPolicy.shouldPersist(
            event: success,
            isAppActive: true,
            isDestinationWindowFocused: true,
            selectedWorkspaceID: workspaceID,
            focusedSurfaceID: surfaceID
        ))
        XCTAssertTrue(PetAttentionFocusPolicy.shouldPersist(
            event: success,
            isAppActive: false,
            isDestinationWindowFocused: true,
            selectedWorkspaceID: workspaceID,
            focusedSurfaceID: surfaceID
        ))
        XCTAssertTrue(PetAttentionFocusPolicy.shouldPersist(
            event: success,
            isAppActive: true,
            isDestinationWindowFocused: true,
            selectedWorkspaceID: workspaceID,
            focusedSurfaceID: SurfaceID(UUID())
        ))
        XCTAssertTrue(PetAttentionFocusPolicy.shouldPersist(
            event: success,
            isAppActive: true,
            isDestinationWindowFocused: false,
            selectedWorkspaceID: workspaceID,
            focusedSurfaceID: surfaceID
        ), "A success must remain unread when Settings, the Pet popover, a hidden window, or a minimized window owns focus.")
    }

    func test_failuresAlwaysPersistEvenWhenDestinationIsFocused() {
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        let failure = event("project.script.finished", [
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surfaceID.value.uuidString),
            "result": .string("failure")
        ])
        XCTAssertTrue(PetAttentionFocusPolicy.shouldPersist(
            event: failure,
            isAppActive: true,
            isDestinationWindowFocused: true,
            selectedWorkspaceID: workspaceID,
            focusedSurfaceID: surfaceID
        ))
    }

    func test_detachedWorkspaceUsesItsOwnWindowSelectionAndFocusedSurface() {
        let mainWorkspaceID = WorkspaceID(UUID())
        let detachedWorkspaceID = WorkspaceID(UUID())
        let mainSurfaceID = SurfaceID(UUID())
        let detachedSurfaceID = SurfaceID(UUID())
        let success = event("project.script.finished", [
            "workspace_id": .string(detachedWorkspaceID.value.uuidString),
            "surface_id": .string(detachedSurfaceID.value.uuidString),
            "result": .string("success")
        ])

        let detached = PetAttentionFocusPolicy.resolveDestination(
            event: success,
            mainSelectedWorkspaceID: mainWorkspaceID,
            focusedSurfaceByWorkspace: [
                mainWorkspaceID: mainSurfaceID,
                detachedWorkspaceID: detachedSurfaceID
            ],
            detachedWorkspaceIDs: [detachedWorkspaceID]
        )
        XCTAssertEqual(detached.detachedWorkspaceID, detachedWorkspaceID)
        XCTAssertEqual(detached.selectedWorkspaceID, detachedWorkspaceID)
        XCTAssertEqual(detached.focusedSurfaceID, detachedSurfaceID)

        let mainOnly = PetAttentionFocusPolicy.resolveDestination(
            event: success,
            mainSelectedWorkspaceID: mainWorkspaceID,
            focusedSurfaceByWorkspace: [
                mainWorkspaceID: mainSurfaceID,
                detachedWorkspaceID: detachedSurfaceID
            ],
            detachedWorkspaceIDs: []
        )
        XCTAssertNil(mainOnly.detachedWorkspaceID)
        XCTAssertEqual(mainOnly.selectedWorkspaceID, mainWorkspaceID)
        XCTAssertEqual(mainOnly.focusedSurfaceID, mainSurfaceID,
            "A background workspace still owned by the main window must not borrow its hidden pane focus.")
    }
}
