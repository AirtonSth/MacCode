import XCTest
@testable import AppShell
import CoreModel
import SocketServer

final class PetEventDecoderTests: XCTestCase {
    private func event(
        _ kind: String,
        _ payload: [String: JSONValue] = [:],
        seq: Int64 = 1
    ) -> EventBus.Event {
        EventBus.Event(seq: seq, kind: kind, payload: .object(payload), ts: 100)
    }

    func test_agentLifecycleDecoder_readsOnlyTypedIdentifiersAndEnums() {
        let runID = UUID().uuidString
        let threadID = UUID().uuidString
        let cases: [(EventBus.Event, PetDomainEvent?)] = [
            (event("agent.run.started", ["run_id": .string(runID)]), .agentRunStarted(runID: runID)),
            (event("agent.turn.started", ["thread_id": .string(threadID)]), .agentTurnStarted),
            (event("agent.item.started", [
                "thread_id": .string(threadID),
                "item": .object([
                    "id": .string("item-1"),
                    "type": .string(AssistantItemType.webSearch.rawValue),
                    "body": .string("private prompt")
                ])
            ]), .agentItemStarted(itemID: "\(threadID):item-1", type: .webSearch)),
            (event("agent.item.completed", [
                "thread_id": .string(threadID),
                "item_id": .string("item-1")
            ]), .agentItemCompleted(itemID: "\(threadID):item-1")),
            (event("agent.item.delta", ["body_append": .string("secret")]), .agentItemDelta),
            (event("agent.item.progress", ["progress": .number(0.5)]), .agentItemProgress),
            (event("agent.context.compaction", ["thread_id": .string(threadID), "summary": .string("private")]), .contextCompaction),
            (event("agent.request.opened", ["thread_id": .string(threadID), "request_id": .string("approval-1")]), .approvalOpened(requestID: "\(threadID):approval-1")),
            (event("agent.request.resolved", ["thread_id": .string(threadID), "request_id": .string("approval-1")]), .approvalResolved(requestID: "\(threadID):approval-1")),
            (event("agent.user_input.requested", ["thread_id": .string(threadID), "request_id": .string("question-1"), "prompt": .string("secret")]), .questionOpened(requestID: "\(threadID):question-1")),
            (event("agent.user_input.resolved", ["thread_id": .string(threadID), "request_id": .string("question-1"), "answer": .string("secret")]), .questionResolved(requestID: "\(threadID):question-1")),
            (event("agent.run.finished", ["run_id": .string(runID), "status": .string("failed")]), .agentRunFinished(runID: runID, status: .failed)),
            (event("agent.run.error", [
                "run_id": .string(runID),
                "recoverable": .bool(true),
                "message": .string("secret prompt /Users/private token=hunter2")
            ]), .agentRunError(runID: runID, recoverable: true)),
            (event("agent.run.error", [
                "run_id": .string(runID),
                "recoverable": .bool(false),
                "message": .string("fatal private command")
            ]), .agentRunError(runID: runID, recoverable: false))
        ]

        for (input, expected) in cases {
            XCTAssertEqual(PetEventDecoder.decode(input), expected, "Unexpected mapping for \(input.kind)")
        }
    }

    func test_decoder_rejectsMalformedPayloadsAndDuplicateTerminalAliases() {
        let malformed: [EventBus.Event] = [
            event("agent.run.started"),
            event("agent.run.started", ["run_id": .string("not-a-uuid")]),
            event("agent.item.started", ["item": .object(["id": .string("item")])]),
            event("agent.item.started", [
                "thread_id": .string("not-a-uuid"),
                "item": .object(["id": .string("item"), "type": .string("tool")])
            ]),
            event("agent.item.started", ["thread_id": .string("thread"), "item": .object(["id": .string("item"), "type": .string("unknown")])]),
            event("agent.item.completed", ["item_id": .string("")]),
            event("agent.request.opened", ["request_id": .number(1)]),
            event("agent.run.finished", ["run_id": .string("run"), "status": .string("running")]),
            event("agent.run.completed", ["run_id": .string("run"), "status": .string("completed")]),
            event("agent.run.failed", ["run_id": .string("run"), "status": .string("failed")]),
            EventBus.Event(seq: 1, kind: "agent.run.started", payload: .string("bad"), ts: 100)
        ]

        for input in malformed {
            XCTAssertNil(PetEventDecoder.decode(input), "Malformed or duplicate event must be ignored: \(input.kind)")
        }
    }

    func test_externalAndNoiseDecoder_matchesExistingEventBusContracts() {
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        let cases: [(EventBus.Event, PetDomainEvent?)] = [
            (event("git.commit", ["workspace_id": .string(workspaceID), "ok": .bool(true)]), .git(.succeeded)),
            (event("git.push", ["workspace_id": .string(workspaceID), "ok": .bool(false)]), .git(.failed)),
            (event("project.script_started", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID)]), .projectScript(.started)),
            (event("project.script.finished", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "result": .string("success")]), .projectScript(.succeeded)),
            (event("project.script.finished", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "result": .string("failure")]), .projectScript(.failed)),
            (event("agent.provider.updated", ["ok": .bool(true)]), .providerUpdate(.succeeded)),
            (event("agent.provider.updated", ["ok": .bool(false)]), .providerUpdate(.failed)),
            (event("ssh.transfer.started", ["surface_id": .string(surfaceID)]), .sshTransfer(.started)),
            (event("ssh.transfer.completed", ["surface_id": .string(surfaceID)]), .sshTransfer(.succeeded)),
            (event("ssh.transfer.failed", ["surface_id": .string(surfaceID)]), .sshTransfer(.failed)),
            (event("ssh.session.updated", ["surface_id": .string(surfaceID), "status": .string("connected")]), .sshSession(.connected)),
            (event("ssh.session.updated", ["surface_id": .string(surfaceID), "status": .string("disconnected"), "reason": .string("connection_failed")]), .sshSession(.connectionFailed)),
            (event("ssh.session.updated", ["surface_id": .string(surfaceID), "status": .string("disconnected"), "reason": .string("user_requested")]), .sshSession(.explicitDisconnect)),
            (event("ssh.session.updated", ["surface_id": .string(surfaceID), "status": .string("disconnected"), "reason": .string("unexpected_child_exit")]), .sshSession(.unexpectedDisconnect)),
            (event("ssh.session.updated", ["surface_id": .string(surfaceID), "status": .string("disconnected")]), .sshSession(.explicitDisconnect)),
            (event("surface.browser", ["surface_id": .string(surfaceID), "url": .string("https://private.example")]), .browserNavigation),
            (event("files.edit.opened", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "session_id": .string("edit-1")]), .file(.opened)),
            (event("files.edit.patch_applied", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "session_id": .string("edit-1")]), .file(.saved(conflictID: nil))),
            (event("files.edit.conflict", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "session_id": .string("edit-1"), "content": .string("private")]), .file(.conflict(id: "edit-1"))),
            (event("files.edit.saved", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "session_id": .string("edit-1"), "path": .string("/private")]), .file(.saved(conflictID: "edit-1"))),
            (event("files.edit.discarded", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "session_id": .string("edit-1"), "content": .string("secret")]), .file(.discarded(conflictID: "edit-1"))),
            (event("files.edit.closed", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "session_id": .string("edit-1"), "token": .string("private")]), .file(.closed(conflictID: "edit-1"))),
            (event("files.edit.saved", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID)]), .file(.saved(conflictID: nil))),
            (event("files.edit.discarded", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID)]), .file(.discarded(conflictID: nil))),
            (event("files.edit.closed", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID)]), .file(.closed(conflictID: nil))),
            (event("surface.output", ["base64": .string("private")]), .surfaceOutput),
            (event("agent.thread.token_usage", ["total_tokens": .number(1)]), .tokenUsage),
            (event("surface.moved"), .layoutChanged),
            (event("files.state.updated", ["state": .object(["selected_path": .string("/private")])]), .filesystemChanged),
            (event("git.commit", ["ok": .bool(true)]), nil),
            (event("project.script.finished", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID), "result": .string("unknown")]), nil),
            (event("ssh.transfer.completed", ["surface_id": .string("not-a-uuid")]), nil),
            (event("files.edit.conflict", ["workspace_id": .string(workspaceID), "surface_id": .string(surfaceID)]), nil),
            (event("unknown.event"), nil)
        ]

        for (input, expected) in cases {
            XCTAssertEqual(PetEventDecoder.decode(input), expected, "Unexpected mapping for \(input.kind)")
        }
    }

    func test_acceptedKinds_includesItemCompletedAndExcludesProviderRuntimeEvent() {
        XCTAssertTrue(
            PetEventDecoder.acceptedKinds.contains("agent.item.completed"),
            "item.completed must remain a useful pet domain event"
        )
        XCTAssertFalse(
            PetEventDecoder.acceptedKinds.contains("agent.provider_runtime.event"),
            "provider runtime telemetry must not be treated as a useful pet event"
        )
        XCTAssertFalse(PetEventDecoder.acceptedKinds.contains("token_saver.digest"))
        XCTAssertFalse(PetEventDecoder.acceptedKinds.contains("agent.item.delta"))
    }

    func test_terminalRecorderEventClassification_usesBooleanOutcomeAndNeverRawFields() {
        let workspaceID = WorkspaceID(UUID())
        let surfaceID = SurfaceID(UUID())
        let git = event("git.push", [
            "workspace_id": .string(workspaceID.value.uuidString),
            "ok": .bool(true),
            "branch": .string("private")
        ], seq: 30)
        let transfer = event("ssh.transfer.failed", [
            "surface_id": .string(surfaceID.value.uuidString),
            "local_path": .string("/Users/private")
        ], seq: 31)
        let providerFailure = event("agent.provider.updated", [
            "ok": .bool(false),
            "stderr": .string("token=private")
        ], seq: 32)
        let projectFinished = event("project.script.finished", [
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surfaceID.value.uuidString),
            "result": .string("failure"),
            "name": .string("private command")
        ], seq: 33)
        let unexpectedDisconnect = event("ssh.session.updated", [
            "workspace_id": .string(workspaceID.value.uuidString),
            "surface_id": .string(surfaceID.value.uuidString),
            "status": .string("disconnected"),
            "reason": .string("unexpected_child_exit"),
            "destination": .string("private.example"),
            "password": .string("hunter2")
        ], seq: 34)

        XCTAssertEqual(
            PetTerminalNotificationRecorder.classify(git),
            PetTerminalEvent(
                sequence: 30,
                kind: .gitDelivery(.succeeded),
                workspaceID: workspaceID,
                surfaceID: nil,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertNil(PetTerminalNotificationRecorder.classify(event("git.commit", [
            "workspace_id": .string(workspaceID.value.uuidString),
            "ok": .bool(true)
        ])), "Synchronous commit activity animates but must not create a ready item.")
        XCTAssertEqual(
            PetTerminalNotificationRecorder.classify(transfer),
            PetTerminalEvent(
                sequence: 31,
                kind: .sshTransfer(.failed),
                workspaceID: nil,
                surfaceID: surfaceID,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(
            PetTerminalNotificationRecorder.classify(providerFailure),
            PetTerminalEvent(
                sequence: 32,
                kind: .providerUpdateFailed,
                workspaceID: nil,
                surfaceID: nil,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(
            PetTerminalNotificationRecorder.classify(projectFinished),
            PetTerminalEvent(
                sequence: 33,
                kind: .projectScript(.failed),
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
        XCTAssertEqual(
            PetTerminalNotificationRecorder.classify(unexpectedDisconnect),
            PetTerminalEvent(
                sequence: 34,
                kind: .sshUnexpectedDisconnect,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                createdAt: Date(timeIntervalSince1970: 100)
            )
        )
    }
}
