import XCTest
import CoreModel
@testable import AgentRuntime

final class ClaudeTurnLifecycleGuardTests: XCTestCase {
    func test_taskNotificationResultWithoutForegroundOwnershipCannotSynthesizeTurnLifecycle() {
        let incidentResult: [String: Any] = [
            "type": "result",
            "subtype": "success",
            "is_error": false,
            "result": "",
            "origin": ["kind": "task-notification"]
        ]
        XCTAssertTrue(ClaudeTurnLifecycleGuard.suppressesTurnLifecycle(
            for: incidentResult,
            hasForegroundOwnership: false,
            cancellationRequested: false
        ))
        XCTAssertTrue(ClaudeTurnLifecycleGuard.suppressesTurnLifecycle(
            for: incidentResult,
            hasForegroundOwnership: true,
            cancellationRequested: false
        ), "assistant-shaped notification prose must not lend ownership to an ambient result")
        XCTAssertTrue(ClaudeTurnLifecycleGuard.suppressesTurnLifecycle(
            for: [
                "type": "result",
                "subtype": "error",
                "is_error": true,
                "origin": ["kind": "task-notification"]
            ],
            hasForegroundOwnership: true,
            cancellationRequested: false
        ), "an error-shaped task notification is still ambient to the parent turn")

        let parsed = ClaudeParser().parseLine(Self.jsonLine(incidentResult))
        XCTAssertTrue(parsed.contains { if case .turnStarted = $0 { return true }; return false })
        XCTAssertTrue(parsed.contains { if case .turnCompleted = $0 { return true }; return false })

        let filtered = ClaudeTurnLifecycleGuard.filteringTurnLifecycle(parsed, suppress: true)
        XCTAssertFalse(filtered.contains { if case .turnStarted = $0 { return true }; return false })
        XCTAssertFalse(filtered.contains { if case .turnCompleted = $0 { return true }; return false })
    }

    func test_onlyCurrentInvocationAssistantActivityOwnsSuccessfulCompletion() {
        XCTAssertTrue(ClaudeTurnLifecycleGuard.hasForegroundOwnership([
            "type": "assistant",
            "message": ["content": [["type": "text", "text": "final"]]]
        ]))
        XCTAssertFalse(ClaudeTurnLifecycleGuard.hasForegroundOwnership([
            "type": "user",
            "message": ["content": [["type": "text", "text": "replay"]]]
        ]))
        XCTAssertFalse(ClaudeTurnLifecycleGuard.hasForegroundOwnership([
            "type": "system",
            "subtype": "task_notification"
        ]))
        XCTAssertFalse(ClaudeTurnLifecycleGuard.hasForegroundOwnership([
            "type": "result",
            "subtype": "success"
        ]))
    }

    func test_pendingTasksDeferUntilLaterOwnedResultAndFailuresNeverBecomeSuccess() {
        XCTAssertEqual(ClaudeTurnLifecycleGuard.completionAction(
            status: .completed,
            hasForegroundOwnership: false,
            pendingTaskCount: 0,
            allowDeferral: true
        ), .ignore)
        XCTAssertEqual(ClaudeTurnLifecycleGuard.completionAction(
            status: .completed,
            hasForegroundOwnership: true,
            pendingTaskCount: 1,
            allowDeferral: true
        ), .deferFinish)
        XCTAssertEqual(ClaudeTurnLifecycleGuard.completionAction(
            status: .completed,
            hasForegroundOwnership: true,
            pendingTaskCount: 0,
            allowDeferral: true
        ), .finish)
        XCTAssertEqual(ClaudeTurnLifecycleGuard.completionAction(
            status: .failed,
            hasForegroundOwnership: false,
            pendingTaskCount: 1,
            allowDeferral: true
        ), .finish)
        XCTAssertEqual(ClaudeTurnLifecycleGuard.completionAction(
            status: .cancelled,
            hasForegroundOwnership: false,
            pendingTaskCount: 1,
            allowDeferral: true
        ), .finish)
    }

    func test_emptyTaskSnapshotOnlyUpdatesPendingStateAndDoesNotActAsAResult() throws {
        let started = try XCTUnwrap(ClaudeTurnLifecycleGuard.updatedPendingTaskIDs(
            current: [],
            from: ["type": "system", "subtype": "task_started", "task_id": "task-1"]
        ))
        XCTAssertEqual(started, ["task-1"])

        let earlyResult: [String: Any] = ["type": "result", "subtype": "success"]
        XCTAssertNil(ClaudeTurnLifecycleGuard.updatedPendingTaskIDs(current: started, from: earlyResult))

        let empty = try XCTUnwrap(ClaudeTurnLifecycleGuard.updatedPendingTaskIDs(
            current: started,
            from: ["type": "system", "subtype": "background_tasks_changed", "tasks": []]
        ))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(ClaudeTurnLifecycleGuard.completionAction(
            status: .completed,
            hasForegroundOwnership: true,
            pendingTaskCount: empty.count,
            allowDeferral: true
        ), .finish, "only the later owned result evaluates completion after the empty snapshot")
    }

    func test_malformedTaskSnapshotsPreservePendingWorkUntilExplicitEmptySnapshot() throws {
        let pending: Set<String> = ["task-1"]
        let malformedSnapshots: [[String: Any]] = [
            ["type": "system", "subtype": "background_tasks_changed"],
            ["type": "system", "subtype": "background_tasks_changed", "tasks": "corrupt"],
            ["type": "system", "subtype": "background_tasks_changed", "tasks": [
                ["task_id": "task-1"], [:]
            ]],
            ["type": "system", "subtype": "background_tasks_changed", "tasks": [
                ["task_id": "   "]
            ]]
        ]
        for snapshot in malformedSnapshots {
            XCTAssertNil(ClaudeTurnLifecycleGuard.updatedPendingTaskIDs(
                current: pending,
                from: snapshot
            ), "ambiguous snapshots must preserve pending work: \(snapshot)")
        }

        let explicitIdle = try XCTUnwrap(ClaudeTurnLifecycleGuard.updatedPendingTaskIDs(
            current: pending,
            from: ["type": "system", "subtype": "background_tasks_changed", "tasks": []]
        ))
        XCTAssertTrue(explicitIdle.isEmpty)
    }

    func test_errorAndExplicitCancellationResultsAreNeverSuppressed() {
        XCTAssertFalse(ClaudeTurnLifecycleGuard.suppressesTurnLifecycle(
            for: ["type": "result", "subtype": "error", "is_error": true],
            hasForegroundOwnership: false,
            cancellationRequested: false
        ))
        XCTAssertFalse(ClaudeTurnLifecycleGuard.suppressesTurnLifecycle(
            for: [
                "type": "result",
                "subtype": "success",
                "is_error": false,
                "origin": ["kind": "task-notification"]
            ],
            hasForegroundOwnership: false,
            cancellationRequested: true
        ))
    }

    private static func jsonLine(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
