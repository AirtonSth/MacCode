import Foundation
import XCTest
import CoreModel
@testable import AgentRuntime

/// Distill `/loop` through a fake `distill` that replays the line shapes captured from a real
/// agent (scheduled_task_*, subagent_*, parent wake turn tagged `subagent-completed-<id>`).
final class DistillLoopAdapterTests: ProviderProcessTestCase {
    private static let wakePromptId = "subagent-completed-sub-1"

    func test_firstRunFoldsLoopAndKeepsChildAndWakeTextOutOfTheTranscript_becauseWakeTurnsBelongToTheirOwnRun() async throws {
        let fixture = try Fixture(name: "loop-first")
        defer { fixture.cleanup() }

        let events = LoopEventBox(log: fixture.log)
        _ = try await fixture.adapter.startSession(fixture.request("/loop 1m check deploy")) { events.append($0) }
        let finished = try await events.waitForFinish()
        try await fixture.waitForCallback()

        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(events.finishedCount, 1, "exactly one terminal for the user's run")
        XCTAssertTrue(events.assistantText.contains("LOOP_CREATED"))
        XCTAssertFalse(events.assistantText.contains("CHILD_TEXT"), "child session text must not leak into the parent")
        XCTAssertFalse(events.assistantText.contains("WAKE_TEXT"), "wake turn text belongs to the wake run")

        let loop = try XCTUnwrap(fixture.lastLoops.last?.first)
        XCTAssertEqual(loop.iterations, 1)
        XCTAssertEqual(loop.lastIteration?.status, .completed)
        XCTAssertEqual(loop.lastIteration?.outputPreview, "PING")
        XCTAssertEqual(loop.humanSchedule, "every 1 minute")
        XCTAssertEqual(loop.state, .active)
    }

    func test_wakeTurnIsAnnouncedOnceAndAttachingItDeliversWakeTextWithoutASecondPrompt() async throws {
        let fixture = try Fixture(name: "loop-wake")
        defer { fixture.cleanup() }

        let first = LoopEventBox(log: fixture.log)
        _ = try await fixture.adapter.startSession(fixture.request("/loop 1m check deploy")) { first.append($0) }
        _ = try await first.waitForFinish()
        let wake = try await fixture.waitForCallback()

        XCTAssertEqual(wake.promptId, Self.wakePromptId)
        XCTAssertTrue(wake.label.contains("every 1 minute"), wake.label)
        XCTAssertTrue(wake.label.contains("iteration 1"), wake.label)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.wakeCallbacks.count, 1, "the host must be told exactly once")

        let second = LoopEventBox(log: fixture.log)
        var attach = fixture.request("")
        attach.attachToProviderPromptId = wake.promptId
        _ = try await fixture.adapter.sendTurn(attach) { second.append($0) }
        let finished = try await second.waitForFinish()

        XCTAssertEqual(finished.status, .completed)
        XCTAssertEqual(second.finishedCount, 1, "adopted wake run finishes exactly once")
        XCTAssertTrue(second.assistantText.contains("WAKE_TEXT"))
        XCTAssertFalse(second.assistantText.contains("CHILD_TEXT"))
        XCTAssertEqual(fixture.recordedMethods().filter { $0 == "session/prompt" }.count, 1,
                       "adopting a provider-initiated turn must not send a second session/prompt")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fixture.wakeCallbacks.count, 1, "no re-announcement after the wake was adopted")
    }

    func test_wakeArrivingWhileFirstTurnIsInFlightIsAnnouncedOnlyAfterItFinishes_andDoesNotPolluteIt() async throws {
        let fixture = try Fixture(name: "loop-timing")
        defer { fixture.cleanup() }

        let first = LoopEventBox(log: fixture.log)
        _ = try await fixture.adapter.startSession(fixture.request("/loop 1m TIMING")) { first.append($0) }
        _ = try await first.waitForFinish()
        let wake = try await fixture.waitForCallback()

        XCTAssertEqual(fixture.log.entries.filter { $0 == "finished" || $0 == "wake" }, ["finished", "wake"],
                       "announcement must follow the first turn's terminal")
        XCTAssertFalse(first.assistantText.contains("WAKE_TEXT"))
        XCTAssertFalse(first.assistantText.contains("CHILD_TEXT"))
        XCTAssertEqual(first.finishedCount, 1)
        XCTAssertEqual(wake.promptId, Self.wakePromptId)

        let second = LoopEventBox(log: fixture.log)
        var attach = fixture.request("")
        attach.attachToProviderPromptId = wake.promptId
        _ = try await fixture.adapter.sendTurn(attach) { second.append($0) }
        let finished = try await second.waitForFinish()
        XCTAssertEqual(finished.status, .completed)
        XCTAssertTrue(second.assistantText.contains("WAKE_TEXT"), "buffered wake updates must replay into the adopting run")
        XCTAssertEqual(second.finishedCount, 1)
        XCTAssertEqual(fixture.recordedMethods().filter { $0 == "session/prompt" }.count, 1)
    }

    func test_activeLoopKeepsThreadListedUntilDeletedNotification_andSchedulerDeleteParsesNestedResult() async throws {
        let fixture = try Fixture(name: "loop-stop")
        defer { fixture.cleanup() }

        let first = LoopEventBox(log: fixture.log)
        _ = try await fixture.adapter.startSession(fixture.request("/loop 1m check deploy")) { first.append($0) }
        _ = try await first.waitForFinish()
        _ = try await fixture.waitForCallback()

        XCTAssertTrue(fixture.adapter.threadIdsWithActiveLoops().contains(fixture.threadId))
        let taskId = try XCTUnwrap(fixture.adapter.loops(threadId: fixture.threadId).first?.taskID)

        let deleted = try await fixture.adapter.stopLoop(threadId: fixture.threadId, taskId: taskId)
        XCTAssertTrue(deleted, "nested {result:{deleted:true}} must parse as success")
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, fixture.adapter.threadIdsWithActiveLoops().contains(fixture.threadId) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(fixture.adapter.threadIdsWithActiveLoops().contains(fixture.threadId))
        XCTAssertTrue(fixture.adapter.loops(threadId: fixture.threadId).isEmpty)
        XCTAssertEqual(fixture.lastLoops.last?.isEmpty, true, "GUI must be told the loop is gone")
    }

    func test_hasLiveSessionIsFalseWithoutASession_becauseGuestRecoveryOpensNothing() async throws {
        let fixture = try Fixture(name: "loop-wake")
        defer { fixture.cleanup() }
        XCTAssertFalse(fixture.adapter.hasLiveSession(threadId: fixture.threadId))

        let first = LoopEventBox(log: fixture.log)
        _ = try await fixture.adapter.startSession(fixture.request("/loop 1m check deploy")) { first.append($0) }
        _ = try await first.waitForFinish()
        XCTAssertTrue(fixture.adapter.hasLiveSession(threadId: fixture.threadId))
    }

    func test_failedWakeIsReleasedWithoutAHotRetry_becauseItWaitsForTheNextTurnToEnd() async throws {
        let fixture = try Fixture(name: "loop-wake")
        defer { fixture.cleanup() }

        let first = LoopEventBox(log: fixture.log)
        _ = try await fixture.adapter.startSession(fixture.request("/loop 1m check deploy")) { first.append($0) }
        _ = try await first.waitForFinish()
        let wake = try await fixture.waitForCallback()

        fixture.adapter.acknowledgeWakeFailed(threadId: fixture.threadId, promptId: wake.promptId)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(fixture.wakeCallbacks.count, 1, "a failed adoption must not re-announce in a tight loop")
    }

    func test_schedulerDeleteReturnsFalseWhenProviderReportsNotDeleted() async throws {
        let fixture = try Fixture(name: "loop-delete-false")
        defer { fixture.cleanup() }

        let first = LoopEventBox(log: fixture.log)
        _ = try await fixture.adapter.startSession(fixture.request("/loop 1m check deploy")) { first.append($0) }
        _ = try await first.waitForFinish()
        _ = try await fixture.waitForCallback()

        let deleted = try await fixture.adapter.stopLoop(threadId: fixture.threadId, taskId: "unknown-task")
        XCTAssertFalse(deleted)
        XCTAssertTrue(fixture.adapter.threadIdsWithActiveLoops().contains(fixture.threadId),
                      "a refused delete must not drop the loop")
    }
}

// MARK: - Fixture

private final class Fixture: @unchecked Sendable {
    let root: URL
    let requests: URL
    let adapter: DistillACPAdapter
    let threadId = AgentThreadID()
    let log = OrderLog()
    private let lock = NSLock()
    private var loopSnapshots: [[DistillLoopState]] = []
    private var wakes: [(promptId: String, label: String)] = []

    init(name: String, cancellationGracePeriod: TimeInterval = 2, turnInactivityTimeout: TimeInterval = 900) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        requests = root.appendingPathComponent("requests.jsonl")
        let harnessURL = root.appendingPathComponent("distill-agent")
        try Self.harness(requests: requests).write(to: harnessURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harnessURL.path)
        adapter = DistillACPAdapter(
            binaryNameOverride: harnessURL.path,
            cancellationGracePeriod: cancellationGracePeriod,
            turnInactivityTimeout: turnInactivityTimeout
        )
        adapter.onLoopsChanged = { [weak self] _, loops in
            guard let self else { return }
            self.lock.lock(); self.loopSnapshots.append(loops); self.lock.unlock()
        }
        let log = log
        adapter.onProviderInitiatedTurn = { [weak self] _, promptId, label in
            guard let self else { return }
            log.append("wake")
            self.lock.lock(); self.wakes.append((promptId, label)); self.lock.unlock()
        }
    }

    func cleanup() {
        adapter.stopAll()
        try? FileManager.default.removeItem(at: root)
    }

    func request(_ prompt: String) -> AgentRunRequest {
        AgentRunRequest(threadId: threadId, provider: .distill, model: "claude/claude-opus-5-5", cwd: root.path, prompt: prompt)
    }

    var lastLoops: [[DistillLoopState]] {
        lock.lock(); defer { lock.unlock() }
        return loopSnapshots
    }

    var wakeCallbacks: [(promptId: String, label: String)] {
        lock.lock(); defer { lock.unlock() }
        return wakes
    }

    @discardableResult
    func waitForCallback(timeout: TimeInterval = 5) async throws -> (promptId: String, label: String) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = wakeCallbacks.first { return first }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LoopTestError.timedOut
    }

    func recordedMethods() -> [String] {
        guard let text = try? String(contentsOf: requests, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["method"] as? String
        }
    }

    /// Replays real Distill 2.0.x shapes. `TIMING` in the prompt sends the wake turn before the prompt response.
    private static func harness(requests: URL) -> String {
        #"""
        #!/usr/bin/env python3
        import json, pathlib, sys, time
        requests = pathlib.Path(\#(String(reflecting: requests.path)))
        SID = "loop-session"
        CHILD = "loop-child-session"
        TASK = "task-1"
        SUB = "sub-1"
        WAKE = "subagent-completed-" + SUB
        rev = [0]
        def send(value): print(json.dumps(value), flush=True)
        def record(method): 
            with requests.open("a") as out: out.write(json.dumps({"method": method}) + "\n")
        def meta(extra=None):
            rev[0] += 1
            m = {"eventId": "e-%d" % rev[0], "agentTimestampMs": 1792374607117, "x.ai/schedulerGeneration": "gen", "x.ai/schedulerRevision": rev[0]}
            if extra: m.update(extra)
            return m
        def chunk(session, text, extra_meta=None):
            params = {"sessionId": session, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}
            if extra_meta: params["_meta"] = extra_meta
            send({"jsonrpc": "2.0", "method": "session/update", "params": params})
        def ext(method, update, with_meta=True):
            params = {"sessionId": SID, "update": update}
            if with_meta: params["_meta"] = meta()
            send({"jsonrpc": "2.0", "method": method, "params": params})
        def sched(kind, extra=None):
            update = {"sessionUpdate": kind, "task_id": TASK, "prompt": "check deploy", "human_schedule": "every 1 minute", "next_fire_at": "2026-10-19T01:50:07.117326+00:00"}
            if extra: update.update(extra)
            ext("_x.ai/scheduled_task_" + kind.replace("scheduled_task_", ""), update)
        def wake_lines():
            ext("_x.ai/session_notification", {"sessionUpdate": "subagent_finished", "subagent_id": SUB, "status": "completed", "duration_ms": 10899, "tokens_used": 13369, "output": "PING", "will_wake": True}, with_meta=False)
            send({"jsonrpc": "2.0", "method": "_x.ai/queue/changed", "params": {"sessionId": SID, "entries": [], "runningPromptId": WAKE}})
            chunk(SID, "WAKE_TEXT", {"promptId": WAKE, "eventId": "w-1"})
            ext("_x.ai/session_notification", {"sessionUpdate": "turn_completed", "prompt_id": WAKE, "stop_reason": "end_turn", "usage": {"inputTokens": 1, "outputTokens": 1}, "elapsed_ms": 5}, with_meta=False)
        def loop_lines():
            sched("scheduled_task_created")
            sched("scheduled_task_fired", {"subagent_id": SUB, "next_fire_at": "2026-10-19T01:51:07.120945+00:00"})
            ext("_x.ai/session_notification", {"sessionUpdate": "subagent_spawned", "subagent_id": SUB, "child_session_id": CHILD, "description": "loop: check deploy (every 1 minute)", "model": "m"}, with_meta=False)
            chunk(CHILD, "CHILD_TEXT")
        pending_prompt = [None, False]
        def wake_chunks(promptId, texts, pause=0.0):
            send({"jsonrpc": "2.0", "method": "_x.ai/queue/changed", "params": {"sessionId": SID, "entries": [], "runningPromptId": promptId}})
            for text in texts:
                chunk(SID, text, {"promptId": promptId})
                time.sleep(pause)
        def wake_done(promptId):
            ext("_x.ai/session_notification", {"sessionUpdate": "turn_completed", "prompt_id": promptId, "stop_reason": "end_turn", "usage": {"inputTokens": 1, "outputTokens": 1}, "elapsed_ms": 5}, with_meta=False)
        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            params = message.get("params", {}) or {}
            if method == "session/cancel":
                record("session/cancel")
                if pending_prompt[0] is not None and not pending_prompt[1]:
                    send({"jsonrpc": "2.0", "id": pending_prompt[0], "result": {"stopReason": "cancelled"}})
                continue
            if "id" not in message:
                continue
            record(method)
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": message["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"loadSession": True, "promptCapabilities": {}}}})
            elif method in ("session/new", "session/load"):
                send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": SID, "update": {"sessionUpdate": "available_commands_update", "availableCommands": []}}})
                send({"jsonrpc": "2.0", "id": message["id"], "result": {"sessionId": SID, "models": {"availableModels": [], "currentModelId": "m"}}})
            elif method == "session/set_model":
                send({"jsonrpc": "2.0", "id": message["id"], "result": {"meta": {"model": params.get("modelId"), "canonicalModelId": params.get("modelId")}}})
            elif method == "session/prompt":
                text = json.dumps(params.get("prompt", ""))
                chunk(SID, "LOOP_CREATED")
                loop_lines()
                pending_prompt[0] = message["id"]
                pending_prompt[1] = "STUCK" in text
                if "CANCELME" in text or "STUCK" in text:
                    pass
                elif "SLOWWAKE" in text:
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"stopReason": "end_turn"}})
                    time.sleep(0.3)
                    wake_chunks(WAKE, ["W1"], 1.0)
                    wake_chunks(WAKE, ["W2"])
                    wake_done(WAKE)
                elif "OPENTOOL" in text:
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"stopReason": "end_turn"}})
                    time.sleep(0.3)
                    send({"jsonrpc": "2.0", "method": "_x.ai/queue/changed", "params": {"sessionId": SID, "entries": [], "runningPromptId": WAKE}})
                    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": SID, "_meta": {"promptId": WAKE}, "update": {"sessionUpdate": "tool_call", "toolCallId": "wake-tool-1", "title": "sleep", "kind": "execute", "status": "in_progress", "rawInput": {"command": "sleep 100"}}}})
                    time.sleep(1.5)
                    wake_done(WAKE)
                elif "WAKES" in text:
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"stopReason": "end_turn"}})
                    time.sleep(0.3)
                    count = int(text.split("WAKES")[1].split()[0].strip('"\\'))
                    for i in range(count):
                        wake_chunks("subagent-completed-w%d" % i, ["w%d" % i])
                elif "TIMING" in text:
                    wake_lines()
                    time.sleep(0.2)
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"stopReason": "end_turn"}})
                else:
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"stopReason": "end_turn"}})
                    time.sleep(0.3)
                    wake_lines()
            elif method == "_x.ai/scheduler/delete":
                if params.get("taskId") == TASK:
                    ext("_x.ai/scheduled_task_deleted", {"sessionUpdate": "scheduled_task_deleted", "task_id": TASK, "reason": "deleted"})
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"result": {"taskId": TASK, "deleted": True}}})
                else:
                    send({"jsonrpc": "2.0", "id": message["id"], "result": {"result": {"taskId": params.get("taskId"), "deleted": False}}})
            else:
                send({"jsonrpc": "2.0", "id": message["id"], "result": {}})
        """#
    }
}

private enum LoopTestError: Error { case timedOut }

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
    var entries: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class LoopEventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [AgentRunEvent] = []
    private let log: OrderLog

    init(log: OrderLog) { self.log = log }

    func append(_ event: AgentRunEvent) {
        lock.lock(); values.append(event); lock.unlock()
        if case .finished = event { log.append("finished") }
    }

    var assistantText: String {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event in
            guard case .event(.itemDelta(_, let body, _, _)) = event else { return nil }
            return body
        }.joined()
    }

    var finishedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return values.filter { if case .finished = $0 { return true } else { return false } }.count
    }

    private func finishResult() -> (AgentRunStatus, String?)? {
        lock.lock(); defer { lock.unlock() }
        return values.compactMap { event -> (AgentRunStatus, String?)? in
            guard case .finished(let status, let message, _) = event else { return nil }
            return (status, message)
        }.first
    }

    func waitForFinish(timeout: TimeInterval = 8) async throws -> (status: AgentRunStatus, finalMessage: String?) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let result = finishResult() { return result }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw LoopTestError.timedOut
    }
}
