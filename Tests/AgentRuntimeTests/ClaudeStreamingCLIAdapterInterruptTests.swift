import XCTest
import CoreModel
@testable import AgentRuntime

/// Tests for the graceful-interrupt path in ClaudeStreamingCLIAdapter.
/// P2 requirement: on interrupt, send a stream-json control message first;
/// only fall back to process kill when that fails.
final class ClaudeStreamingCLIAdapterInterruptTests: ProviderProcessTestCase {

    // MARK: - Pure builder tests (no process, no I/O)

    /// The control-interrupt line must be valid JSON matching Agent SDK /
    /// Claude CLI control channel: type=control_request, request.subtype=interrupt,
    /// and a non-empty request_id. Wrong shape is silently ignored by the CLI.
    func test_controlInterruptLine_isValidJSONWithRequiredFields() throws {
        let data = ClaudeStreamingCLIAdapter.controlInterruptLine()

        // Strip the trailing newline before parsing.
        let stripped = data.last == 0x0A ? data.dropLast() : data
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stripped)) as? [String: Any],
            "controlInterruptLine must produce parseable JSON"
        )

        XCTAssertEqual(object["type"] as? String, "control_request",
                       "stream-json interrupt must carry type=control_request")
        let requestId = try XCTUnwrap(object["request_id"] as? String)
        XCTAssertFalse(requestId.isEmpty, "control_request interrupt needs a request_id")
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "interrupt",
                       "stream-json interrupt request.subtype must be interrupt")
        XCTAssertNil(request["cancel_queued"],
                     "cancel_queued must be omitted unless interrupt_cancel_queued_v1 is advertised")
    }

    /// CLAUDE-INT-001: advertised interrupt_cancel_queued_v1 requires cancel_queued true.
    func test_controlInterruptLine_includesCancelQueuedWhenRequested() throws {
        let data = ClaudeStreamingCLIAdapter.controlInterruptLine(cancelQueued: true)
        let stripped = data.last == 0x0A ? data.dropLast() : data
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stripped)) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "control_request")
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["subtype"] as? String, "interrupt")
        let cancelQueued = request["cancel_queued"] as? Bool
            ?? (request["cancel_queued"] as? NSNumber)?.boolValue
        XCTAssertEqual(cancelQueued, true,
                       "interrupt_cancel_queued_v1 must set request.cancel_queued true")
        let requestId = try XCTUnwrap(
            ClaudeStreamingCLIAdapter.controlRequestId(fromInterruptLine: data)
        )
        XCTAssertEqual(object["request_id"] as? String, requestId)
    }

    func test_initCapabilities_fromSystemInitFixture() {
        let object: [String: Any] = [
            "type": "system",
            "subtype": "init",
            "capabilities": [
                "interrupt_receipt_v1",
                "interrupt_cancel_queued_v1",
                "msg_lifecycle_v1"
            ]
        ]
        let caps = ClaudeStreamingCLIAdapter.initCapabilities(from: object)
        XCTAssertEqual(
            caps,
            ["interrupt_receipt_v1", "interrupt_cancel_queued_v1", "msg_lifecycle_v1"]
        )
        XCTAssertNil(
            ClaudeStreamingCLIAdapter.initCapabilities(from: ["type": "assistant"]),
            "non-init lines must not be treated as a capabilities snapshot"
        )
    }

    /// CLAUDE-INT-002: only a successful receipt for the pending interrupt cancels the grace kill.
    func test_shouldCancelInterruptGraceKill_onlyOnMatchingSuccessfulReceipt() {
        XCTAssertTrue(
            ClaudeStreamingCLIAdapter.shouldCancelInterruptGraceKill(
                pendingRequestId: "3ad25933-b695-4e02-9b43-0ad5c0cf0fcd",
                receiptRequestId: "3ad25933-b695-4e02-9b43-0ad5c0cf0fcd",
                receiptSuccess: true
            )
        )
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldCancelInterruptGraceKill(
                pendingRequestId: "pending-1",
                receiptRequestId: "other-id",
                receiptSuccess: true
            ),
            "permission or unrelated control_response must not cancel the interrupt kill"
        )
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldCancelInterruptGraceKill(
                pendingRequestId: "pending-1",
                receiptRequestId: "pending-1",
                receiptSuccess: false
            ),
            "failed interrupt receipt must keep the grace kill fallback"
        )
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldCancelInterruptGraceKill(
                pendingRequestId: nil,
                receiptRequestId: "pending-1",
                receiptSuccess: true
            )
        )
    }

    /// The line must be newline-terminated so the Claude CLI's line reader
    /// flushes immediately. A missing trailing newline would block delivery.
    func test_controlInterruptLine_isNewlineTerminated() {
        let data = ClaudeStreamingCLIAdapter.controlInterruptLine()
        XCTAssertEqual(data.last, 0x0A,
                       "stream-json control messages must be newline-terminated for the CLI line reader to flush")
    }

    func test_userPromptPayload_textOnlyWhenAttachmentsEmpty() throws {
        let payload = try ClaudeStreamingCLIAdapter.userPromptPayload(text: "hello", attachments: [])
        XCTAssertEqual(payload["type"] as? String, "user")
        // CLAUDE-CLI-015: SDKUserMessage requires parent_tool_use_id (null for host turns).
        XCTAssertTrue(payload["parent_tool_use_id"] is NSNull,
                      "CLI stdin user lines must include parent_tool_use_id: null like the bridge")
        let origin = try XCTUnwrap(payload["origin"] as? [String: Any])
        XCTAssertEqual(origin["kind"] as? String, "human",
                       "CLAUDE-ORIGIN-001: host-typed stdin must set origin.kind=human")
        let uuid = try XCTUnwrap(payload["uuid"] as? String)
        XCTAssertFalse(uuid.isEmpty, "CLAUDE-ORIGIN-001: host user lines need a uuid for reply binding")
        let message = try XCTUnwrap(payload["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1, "empty attachments must stay a single text block")
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[0]["text"] as? String, "hello")
    }

    /// CLAUDE-ORIGIN-001: SDK pushPrompt must match CLI stdin origin+uuid so
    /// ultracode / queued_turn_count human gates work on both hosts.
    func test_sdkBridgePushPrompt_includesHumanOriginAndUuid() throws {
        let testsDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDir.deletingLastPathComponent().deletingLastPathComponent()
        let bridge = repoRoot.appendingPathComponent("Sources/AgentRuntime/ClaudeAgentSDKBridge.mjs")
        let source = try String(contentsOf: bridge, encoding: .utf8)
        guard let start = source.range(of: "function pushPrompt(") else {
            return XCTFail("ClaudeAgentSDKBridge.mjs must define pushPrompt")
        }
        let after = source[start.lowerBound...]
        let end = after.range(of: "\nfunction ")?.lowerBound ?? after.endIndex
        let body = String(after[..<end])
        XCTAssertTrue(body.contains("origin: { kind: 'human' }"),
                      "SDK pushPrompt must set origin.kind=human like CLI stdin")
        XCTAssertTrue(body.contains("uuid: randomUUID()"),
                      "SDK pushPrompt must stamp a uuid on host user messages")
    }

    func test_userPromptPayload_includesImageAndFileBlocks() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rc-claude-cli-attach-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pngData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let png = tmp.appendingPathComponent("dot.png")
        try pngData.write(to: png)
        let note = tmp.appendingPathComponent("note.txt")
        try "hello file".write(to: note, atomically: true, encoding: .utf8)

        let payload = try ClaudeStreamingCLIAdapter.userPromptPayload(
            text: "see these",
            attachments: [
                AgentAttachment(path: png.path, displayName: "dot.png", kind: .image, mimeType: "image/png"),
                AgentAttachment(path: note.path, displayName: "note.txt", kind: .file, mimeType: "text/plain")
            ]
        )
        let content = try XCTUnwrap((payload["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        XCTAssertEqual(content[1]["type"] as? String, "image")
        let source = try XCTUnwrap(content[1]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        XCTAssertEqual(source["data"] as? String, pngData.base64EncodedString())
        XCTAssertEqual(content[2]["type"] as? String, "text")
        let fileText = try XCTUnwrap(content[2]["text"] as? String)
        XCTAssertTrue(fileText.contains("note.txt"))
        XCTAssertTrue(fileText.contains(note.path))
    }

    func test_userPromptPayload_rejectsUnsupportedImageMIME() {
        do {
            _ = try ClaudeStreamingCLIAdapter.userPromptPayload(
                text: "nope",
                attachments: [AgentAttachment(path: "/tmp/x.svg", kind: .image, mimeType: "image/svg+xml")]
            )
            XCTFail("unsupported image MIME must throw before stdin write")
        } catch let AgentProviderAdapterError.unsupported(message) {
            XCTAssertTrue(message.contains("image/svg+xml"))
        } catch {
            XCTFail("expected AgentProviderAdapterError.unsupported, got \(error)")
        }
    }

    // MARK: - control_response permission wire (pure)

    func test_controlPermissionResponseLine_approveIsOneShotAllow() throws {
        let data = try ClaudeStreamingCLIAdapter.controlPermissionResponseLine(
            requestId: "req-allow-1",
            response: .approve,
            updatedInput: ["command": "ls"]
        )
        XCTAssertEqual(data.last, 0x0A)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "control_response")
        let envelope = try XCTUnwrap(object["response"] as? [String: Any])
        XCTAssertEqual(envelope["subtype"] as? String, "success")
        XCTAssertEqual(envelope["request_id"] as? String, "req-allow-1")
        let result = try XCTUnwrap(envelope["response"] as? [String: Any])
        XCTAssertEqual(result["behavior"] as? String, "allow")
        XCTAssertNil(result["message"])
        XCTAssertNil(result["updatedPermissions"],
                     "one-shot approve must not persist session rules")
        // CLAUDE-CLI-017: allow must echo updatedInput (bridge parity).
        let updated = try XCTUnwrap(result["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["command"] as? String, "ls")
    }

    /// CLAUDE-CLI-006: Approve for session must carry updatedPermissions so the CLI
    /// session permission set grows; bare behavior:allow re-prompts every call.
    func test_controlPermissionResponseLine_approveForSessionIncludesUpdatedPermissions() throws {
        let withSuggestions = try ClaudeStreamingCLIAdapter.controlPermissionResponseLine(
            requestId: "req-session-1",
            response: .approveForSession,
            toolName: "Bash",
            permissionSuggestionsJSON: #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls *"}],"behavior":"allow","destination":"session"}]"#
        )
        let suggestedResult = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(withSuggestions.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        XCTAssertEqual(suggestedResult["behavior"] as? String, "allow")
        let echoed = try XCTUnwrap(suggestedResult["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(echoed.count, 1)
        XCTAssertEqual(echoed[0]["type"] as? String, "addRules")
        XCTAssertEqual(echoed[0]["destination"] as? String, "session")
        let rules = try XCTUnwrap(echoed[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["ruleContent"] as? String, "ls *",
                       "permission_suggestions must be echoed, not re-synthesized")

        let synthesized = try ClaudeStreamingCLIAdapter.controlPermissionResponseLine(
            requestId: "req-session-2",
            response: .approveForSession,
            toolName: "Edit"
        )
        let synthResult = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(synthesized.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        let synthPerms = try XCTUnwrap(synthResult["updatedPermissions"] as? [[String: Any]])
        XCTAssertEqual(synthPerms[0]["type"] as? String, "addRules")
        XCTAssertEqual(synthPerms[0]["behavior"] as? String, "allow")
        XCTAssertEqual(synthPerms[0]["destination"] as? String, "session")
        let synthRules = try XCTUnwrap(synthPerms[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(synthRules[0]["toolName"] as? String, "Edit",
                       "without suggestions, synthesize addRules for the tool_name")
    }

    func test_controlPermissionResponseLine_denyRequiresMessage() throws {
        let declined = try ClaudeStreamingCLIAdapter.controlPermissionResponseLine(
            requestId: "req-deny-1",
            response: .decline("not in plan")
        )
        let declinedObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(declined.dropLast())) as? [String: Any]
        )
        let declinedResult = try XCTUnwrap(
            (declinedObj["response"] as? [String: Any])?["response"] as? [String: Any]
        )
        XCTAssertEqual(declinedResult["behavior"] as? String, "deny")
        XCTAssertEqual(declinedResult["message"] as? String, "not in plan")

        let cancelled = try ClaudeStreamingCLIAdapter.controlPermissionResponseLine(
            requestId: "req-cancel-1",
            response: .cancel
        )
        let cancelledObj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(cancelled.dropLast())) as? [String: Any]
        )
        let cancelledResult = try XCTUnwrap(
            (cancelledObj["response"] as? [String: Any])?["response"] as? [String: Any]
        )
        XCTAssertEqual(cancelledResult["behavior"] as? String, "deny")
        XCTAssertEqual(cancelledResult["message"] as? String, "Cancelled")
    }

    // MARK: - control_response user-input wire (pure, CLAUDE-CLI-004/005)

    func test_controlUserInputResponseLine_askUserQuestionAllowCarriesAnswers() throws {
        let data = try ClaudeStreamingCLIAdapter.controlUserInputResponseLine(
            requestId: "req-ask-1",
            kind: .askUserQuestion(toolUseID: "toolu-ask-1"),
            text: #"{"0":"OAuth"}"#,
            decision: .accept
        )
        XCTAssertEqual(data.last, 0x0A)
        let result = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        XCTAssertEqual(result["behavior"] as? String, "allow")
        XCTAssertEqual(result["toolUseID"] as? String, "toolu-ask-1")
        let updated = try XCTUnwrap(result["updatedInput"] as? [String: Any])
        let answers = try XCTUnwrap(updated["answers"] as? [String: Any])
        XCTAssertEqual(answers["0"] as? String, "OAuth",
                       "JSON answers must land in updatedInput.answers (PermissionResult allow path)")
    }

    func test_controlUserInputResponseLine_askUserQuestionCancelIsDeny() throws {
        let data = try ClaudeStreamingCLIAdapter.controlUserInputResponseLine(
            requestId: "req-ask-2",
            kind: .askUserQuestion(toolUseID: nil),
            text: nil,
            decision: .cancel
        )
        let result = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(data.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        XCTAssertEqual(result["behavior"] as? String, "deny")
        XCTAssertEqual(result["message"] as? String, "Cancelled")
        XCTAssertEqual(result["toolUseID"] as? String, "req-ask-2")
    }

    func test_controlUserInputResponseLine_elicitationAcceptAndCancel() throws {
        let accept = try ClaudeStreamingCLIAdapter.controlUserInputResponseLine(
            requestId: "req-elicit-1",
            kind: .elicitation,
            text: #"{"environment":"staging"}"#,
            decision: .accept
        )
        let acceptBody = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(accept.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        XCTAssertEqual(acceptBody["action"] as? String, "accept")
        let content = try XCTUnwrap(acceptBody["content"] as? [String: Any])
        XCTAssertEqual(content["environment"] as? String, "staging")

        let cancel = try ClaudeStreamingCLIAdapter.controlUserInputResponseLine(
            requestId: "req-elicit-2",
            kind: .elicitation,
            text: nil,
            decision: .cancel
        )
        let cancelBody = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(cancel.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        XCTAssertEqual(cancelBody["action"] as? String, "cancel")
    }

    /// CLAUDE-CLI-016: request_user_dialog must complete via control_response.
    func test_controlUserInputResponseLine_userDialogAcceptAndCancel() throws {
        let accept = try ClaudeStreamingCLIAdapter.controlUserInputResponseLine(
            requestId: "req-dialog-1",
            kind: .userDialog(dialogKind: "computer_use_approval"),
            text: #"{"approved":true}"#,
            decision: .accept
        )
        let acceptBody = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(accept.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        XCTAssertEqual(acceptBody["approved"] as? Bool, true)
        XCTAssertEqual(acceptBody["dialog_kind"] as? String, "computer_use_approval")

        let cancel = try ClaudeStreamingCLIAdapter.controlUserInputResponseLine(
            requestId: "req-dialog-2",
            kind: .userDialog(dialogKind: "computer_use_approval"),
            text: nil,
            decision: .cancel
        )
        let cancelBody = try XCTUnwrap(
            (try JSONSerialization.jsonObject(with: Data(cancel.dropLast())) as? [String: Any])
                .flatMap { ($0["response"] as? [String: Any])?["response"] as? [String: Any] }
        )
        XCTAssertEqual(cancelBody["cancelled"] as? Bool, true)
        XCTAssertEqual(cancelBody["dialog_kind"] as? String, "computer_use_approval")
    }

    // MARK: - needsSessionResume pure seam tests

    /// WHY: when an interrupt killed the session and the next turn carries a
    /// providerThreadId (= Claude CLI will resume the conversation), the UI must
    /// see "resuming session..." so the user knows a fresh process is spawning
    /// rather than the UI silently hanging.
    func test_needsSessionResume_trueWhenInterruptedAndHasPersistentSession() {
        XCTAssertTrue(
            ClaudeStreamingCLIAdapter.needsSessionResume(afterInterrupt: true, hasPersistentSession: true),
            "interrupted + providerThreadId present => must signal session resumption"
        )
    }

    /// WHY: a normal (non-interrupted) sendTurn must not emit the resuming event.
    func test_needsSessionResume_falseWhenNotInterrupted() {
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.needsSessionResume(afterInterrupt: false, hasPersistentSession: true),
            "no prior interrupt => no resuming signal, regardless of providerThreadId"
        )
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.needsSessionResume(afterInterrupt: false, hasPersistentSession: false),
            "no prior interrupt + no session => no resuming signal"
        )
    }

    /// WHY: if the request has no providerThreadId the CLI starts fresh (not a
    /// resume), so the "resuming session..." label would be misleading.
    func test_needsSessionResume_falseWhenInterruptedButNoPersistentSession() {
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.needsSessionResume(afterInterrupt: true, hasPersistentSession: false),
            "interrupted but no providerThreadId => CLI starts fresh, not a resume"
        )
    }

    // MARK: - Fallback path test (process + real pipe)

    /// When the provider closes stdin while its process remains alive, the
    /// graceful interrupt write receives EPIPE. interruptTurn must fall back to
    /// stopSession, which removes the session without crashing the app.
    func test_interruptTurn_fallsBackToKillWhenProviderClosesStdin() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-interrupt-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let script = tmp.appendingPathComponent("fake-claude")

        let stdinClosed = tmp.appendingPathComponent("stdin-closed")
        // Accept the initial prompt, then close stdin while staying alive. This
        // deterministically exercises the adapter's EPIPE fallback boundary.
        try """
        #!/usr/bin/env python3
        import json, os, pathlib, sys, time
        print(json.dumps({"type":"system","subtype":"init","session_id":"interrupt-fallback-session"}), flush=True)
        sys.stdin.readline()
        os.close(0)
        pathlib.Path(\"\(stdinClosed.path)\").touch()
        time.sleep(5)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(
            binaryNameOverride: script.path,
            interruptGracePeriod: 0.05
        )
        let threadId = AgentThreadID()
        let sink = EventSink()
        _ = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "hello"
        )) { event in
            Task { await sink.record(event) }
        }

        // Wait until the fake provider confirms stdin is closed but the warm
        // session is still registered.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !FileManager.default.fileExists(atPath: stdinClosed.path) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stdinClosed.path))
        XCTAssertTrue(adapter.hasSession(threadId: threadId))

        try adapter.interruptTurn(threadId: threadId)

        // EPIPE fails the write and stopSession is synchronous. If the write
        // still reports success (parent still holds the pipe read end), the
        // short grace kill removes the session.
        let goneDeadline = Date().addingTimeInterval(1)
        while Date() < goneDeadline && adapter.hasSession(threadId: threadId) {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(adapter.hasSession(threadId: threadId),
                       "closed stdin must trigger the kill fallback and remove the session")
    }

    /// CLAUDE-INT-002: do not schedule grace kill after a receipt cleared the pending id.
    func test_shouldScheduleInterruptGraceKill_onlyWhilePendingOwnsWorkItem() {
        XCTAssertTrue(
            ClaudeStreamingCLIAdapter.shouldScheduleInterruptGraceKill(
                pendingRequestId: "pending-1",
                scheduledRequestId: "pending-1",
                killWorkStillInstalled: true
            )
        )
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldScheduleInterruptGraceKill(
                pendingRequestId: nil,
                scheduledRequestId: "pending-1",
                killWorkStillInstalled: true
            ),
            "receipt-cleared pending must not schedule the grace kill"
        )
        XCTAssertFalse(
            ClaudeStreamingCLIAdapter.shouldScheduleInterruptGraceKill(
                pendingRequestId: "pending-1",
                scheduledRequestId: "pending-1",
                killWorkStillInstalled: false
            ),
            "cancelled work item must not be rescheduled"
        )
    }
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}
