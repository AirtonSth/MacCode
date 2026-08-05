import XCTest
import CoreModel
@testable import AgentRuntime

/// Tests for the graceful-interrupt path in ClaudeStreamingCLIAdapter.
/// P2 requirement: on interrupt, send a stream-json control message first;
/// only fall back to process kill when that fails.
final class ClaudeStreamingCLIAdapterInterruptTests: ProviderProcessTestCase {

    // MARK: - Pure builder tests (no process, no I/O)

    /// The control-interrupt line must be valid JSON containing the fields
    /// the Claude CLI stream-json protocol requires: type="control" and
    /// action="interrupt". Verifies the builder produces a parseable, correct
    /// payload before any I/O path is exercised.
    func test_controlInterruptLine_isValidJSONWithRequiredFields() throws {
        let data = ClaudeStreamingCLIAdapter.controlInterruptLine()

        // Strip the trailing newline before parsing.
        let stripped = data.last == 0x0A ? data.dropLast() : data
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(stripped)) as? [String: Any],
            "controlInterruptLine must produce parseable JSON"
        )

        XCTAssertEqual(object["type"] as? String, "control",
                       "stream-json control message must carry type=control")
        XCTAssertEqual(object["action"] as? String, "interrupt",
                       "stream-json control message must carry action=interrupt")
    }

    /// The line must be newline-terminated so the Claude CLI's line reader
    /// flushes immediately. A missing trailing newline would block delivery.
    func test_controlInterruptLine_isNewlineTerminated() {
        let data = ClaudeStreamingCLIAdapter.controlInterruptLine()
        XCTAssertEqual(data.last, 0x0A,
                       "stream-json control messages must be newline-terminated for the CLI line reader to flush")
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

    func test_interruptGraceEscalatesOnlyCapturedRunGeneration() {
        let runA = AgentRunID()
        let runB = AgentRunID()

        XCTAssertTrue(ClaudeTurnLifecycleGuard.shouldEscalateInterrupt(
            expectedRunId: runA,
            activeRunId: runA,
            sessionIsCurrent: true
        ), "A's timer may stop A while A still owns the registered session")
        XCTAssertFalse(ClaudeTurnLifecycleGuard.shouldEscalateInterrupt(
            expectedRunId: runA,
            activeRunId: runB,
            sessionIsCurrent: true
        ), "A's late timer must not stop newer generation B")
        XCTAssertFalse(ClaudeTurnLifecycleGuard.shouldEscalateInterrupt(
            expectedRunId: runA,
            activeRunId: runA,
            sessionIsCurrent: false
        ), "A's timer must not stop a replacement session")
    }

    func test_interruptGraceAtomicallyDetachesABeforeStoppingWhileBStarts() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rc2-claude-interrupt-claim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let script = tmp.appendingPathComponent("fake-claude")
        try """
        #!/usr/bin/python3
        import json, sys
        print(json.dumps({"type":"system","subtype":"init","session_id":"interrupt-claim"}), flush=True)
        for line in sys.stdin:
            if not line.strip():
                continue
            # Deliberately ignore the graceful control interrupt so escalation runs.
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let adapter = ClaudeStreamingCLIAdapter(
            binaryNameOverride: script.path,
            interruptGracePeriod: 0.05
        )
        let threadId = AgentThreadID()
        let runA = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "run A"
        )) { _ in }
        let claimEntered = DispatchSemaphore(value: 0)
        let allowOldStop = DispatchSemaphore(value: 0)
        adapter.beforeEscalatedSessionStopForTesting = {
            claimEntered.signal()
            allowOldStop.wait()
        }
        runA.cancel()
        await Task.detached { claimEntered.wait() }.value
        XCTAssertFalse(adapter.hasSession(threadId: threadId),
                       "A must leave the registry atomically before its process teardown")

        let runB = try await adapter.sendTurn(AgentRunRequest(
            threadId: threadId,
            provider: .claude,
            model: "claude-haiku-4-5-20251001",
            cwd: tmp.path,
            prompt: "run B",
            providerThreadId: "interrupt-claim"
        )) { _ in }
        runA.cancel()
        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "stale handle A cancel must not detach replacement session B")
        adapter.beforeEscalatedSessionStopForTesting = nil
        allowOldStop.signal()
        try? await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(adapter.hasSession(threadId: threadId),
                      "A's delayed hard stop must not remove replacement session B")
        XCTAssertTrue(runB.process?.isRunning == true,
                      "A's delayed hard stop must terminate only A's detached process")
        adapter.stopAll()
    }
}

private actor EventSink {
    private var events: [AgentRunEvent] = []
    func record(_ event: AgentRunEvent) { events.append(event) }
    func snapshot() -> [AgentRunEvent] { events }
}
