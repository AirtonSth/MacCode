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
    }

    /// The line must be newline-terminated so the Claude CLI's line reader
    /// flushes immediately. A missing trailing newline would block delivery.
    func test_controlInterruptLine_isNewlineTerminated() {
        let data = ClaudeStreamingCLIAdapter.controlInterruptLine()
        XCTAssertEqual(data.last, 0x0A,
                       "stream-json control messages must be newline-terminated for the CLI line reader to flush")
    }

    // MARK: - control_response permission wire (pure)

    func test_controlPermissionResponseLine_allowMapsApproveAndApproveForSession() throws {
        for response: AgentProviderRequestResponse in [.approve, .approveForSession] {
            let data = try ClaudeStreamingCLIAdapter.controlPermissionResponseLine(
                requestId: "req-allow-1",
                response: response
            )
            XCTAssertEqual(data.last, 0x0A)
            let stripped = data.dropLast()
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(stripped)) as? [String: Any]
            )
            XCTAssertEqual(object["type"] as? String, "control_response")
            let envelope = try XCTUnwrap(object["response"] as? [String: Any])
            XCTAssertEqual(envelope["subtype"] as? String, "success")
            XCTAssertEqual(envelope["request_id"] as? String, "req-allow-1")
            let result = try XCTUnwrap(envelope["response"] as? [String: Any])
            XCTAssertEqual(result["behavior"] as? String, "allow")
            XCTAssertNil(result["message"])
        }
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

        let adapter = ClaudeStreamingCLIAdapter(binaryNameOverride: script.path)
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

        XCTAssertFalse(adapter.hasSession(threadId: threadId),
                       "closed stdin must trigger the kill fallback and remove the session")
    }
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}
