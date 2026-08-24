import XCTest
@testable import AppShell
@testable import SocketServer
@testable import CoreModel

final class AgentEventWorkspaceFilterTests: XCTestCase {
    private let workspaceID = WorkspaceID(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!)
    private let foreignWorkspaceID = WorkspaceID(UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)

    func test_foreignWorkspaceEventIsRejectedBeforeMainDispatch() {
        let payload: JSONValue = .object([
            "workspace_id": .string(foreignWorkspaceID.value.uuidString),
            "thread_id": .string("foreign-thread")
        ])

        XCTAssertFalse(
            AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
            "a known foreign workspace must be rejected before the lifecycle callback schedules main-queue work"
        )
    }

    func test_matchingWorkspaceEventKeepsExistingDispatchPath() {
        let payload: JSONValue = .object([
            "workspace_id": .string(workspaceID.value.uuidString),
            "thread_id": .string("matching-thread")
        ])

        XCTAssertTrue(
            AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
            "a matching workspace event must continue through the existing lifecycle and queue handlers"
        )
    }

    func test_missingWorkspaceIdentityFailsOpenForLegacyEvents() {
        let payload: JSONValue = .object([
            "thread_id": .string("legacy-thread")
        ])

        XCTAssertTrue(
            AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
            "workspace-less legacy events must preserve existing handling"
        )
    }

    func test_malformedWorkspaceIdentityFailsOpen() {
        let payloads: [JSONValue] = [
            .object(["workspace_id": .string("not-a-uuid")]),
            .object(["workspace_id": .number(42)]),
            .object(["workspace_id": .null])
        ]

        for payload in payloads {
            XCTAssertTrue(
                AppCommandRouter.shouldAdmitAgentLifecycleEvent(payload: payload, workspaceID: workspaceID),
                "malformed workspace identity must preserve existing handling: \(payload)"
            )
        }
    }
}
