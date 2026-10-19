import XCTest
@testable import CoreModel

/// Fixtures are real Distill 2.0.48 `/loop` ACP lines from a live probe (prompt/output trimmed).
final class DistillLoopReducerTests: XCTestCase {
    private let task = "01a151da-0d0d-75f2-882c-b42cc3c6b4cf"
    private let sub1 = "01a151da-0d11-7e51-8b3a-addc2da3564e"
    private let sub2 = "01a151da-f772-7702-ae2c-15b946333290"
    private let prompt = "Run `date` in the shell. Reply with exactly one line: `PING <date output>`."

    private func created(rev: Int = 1) -> String {
        """
        {"jsonrpc": "2.0", "method": "_x.ai/scheduled_task_created", "params": {"sessionId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195", "update": {"sessionUpdate": "scheduled_task_created", "task_id": "\(task)", "prompt": "\(prompt)", "human_schedule": "every 1 minute", "next_fire_at": "2026-10-19T01:50:07.117326+00:00"}, "_meta": {"eventId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195-453", "agentTimestampMs": 1792374607117, "x.ai/schedulerGeneration": "01a151d9-5170-7802-9085-c6c89d6eb3fd", "x.ai/schedulerRevision": \(rev)}}}
        """
    }

    private func fired(sub: String, next: String, rev: Int) -> String {
        """
        {"jsonrpc": "2.0", "method": "_x.ai/scheduled_task_fired", "params": {"sessionId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195", "update": {"sessionUpdate": "scheduled_task_fired", "task_id": "\(task)", "prompt": "\(prompt)", "human_schedule": "every 1 minute", "next_fire_at": "\(next)", "subagent_id": "\(sub)"}, "_meta": {"eventId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195-735", "agentTimestampMs": 1792374667122, "x.ai/schedulerGeneration": "01a151d9-5170-7802-9085-c6c89d6eb3fd", "x.ai/schedulerRevision": \(rev)}}}
        """
    }

    private var fired1: String { fired(sub: sub1, next: "2026-10-19T01:51:07.120945+00:00", rev: 2) }
    private var fired2: String { fired(sub: sub2, next: "2026-10-19T01:52:07.122374+00:00", rev: 3) }

    private var finished1: String {
        """
        {"jsonrpc": "2.0", "method": "_x.ai/session_notification", "params": {"sessionId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195", "update": {"sessionUpdate": "subagent_finished", "subagent_id": "\(sub1)", "attempt_id": "at1.86af387fc767468c8ef4686fffe367a6", "child_session_id": "\(sub1)", "status": "completed", "tool_calls": 1, "turns": 1, "duration_ms": 10899, "tokens_used": 13369, "output": "PING 2026-10-18 22:50:17 -03", "will_wake": true}, "_meta": {"eventId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195-562", "agentTimestampMs": 1792374620051}}}
        """
    }

    private func deleted(reason: String, rev: Int = 4) -> String {
        """
        {"jsonrpc": "2.0", "method": "_x.ai/scheduled_task_deleted", "params": {"sessionId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195", "update": {"sessionUpdate": "scheduled_task_deleted", "task_id": "\(task)", "reason": "\(reason)"}, "_meta": {"eventId": "01a151d9-50f6-7d93-b7a3-9c046e0e6195-1196", "agentTimestampMs": 1792374709246, "x.ai/schedulerGeneration": "01a151d9-5170-7802-9085-c6c89d6eb3fd", "x.ai/schedulerRevision": \(rev)}}}
        """
    }

    private func fold(_ lines: [String], from start: [DistillLoopState] = []) throws -> [DistillLoopState] {
        try lines.reduce(start) { loops, line in
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return DistillLoopReducer.apply(
                method: try XCTUnwrap(obj["method"] as? String),
                params: try XCTUnwrap(obj["params"] as? [String: Any]),
                to: loops
            )
        }
    }

    /// WHY: the strip must show the real schedule, countdown target, per-iteration result, then vanish on stop.
    func test_fullLifecycleFromRealTraffic() throws {
        var loops = try fold([created()])
        XCTAssertEqual(loops.count, 1)
        XCTAssertEqual(loops[0].taskID, task)
        XCTAssertEqual(loops[0].prompt, prompt)
        XCTAssertEqual(loops[0].humanSchedule, "every 1 minute")
        XCTAssertNotNil(loops[0].nextFireAt)
        XCTAssertEqual(loops[0].state, .active)
        XCTAssertEqual(loops[0].iterations, 0)

        loops = try fold([fired1], from: loops)
        XCTAssertEqual(loops[0].iterations, 1)
        XCTAssertEqual(loops[0].runningSubagentID, sub1)
        XCTAssertEqual(loops[0].lastIteration, DistillLoopIteration(subagentID: sub1, status: .running))
        let firstNext = try XCTUnwrap(loops[0].nextFireAt)

        loops = try fold([finished1], from: loops)
        XCTAssertNil(loops[0].runningSubagentID)
        XCTAssertEqual(loops[0].lastIteration, DistillLoopIteration(
            subagentID: sub1, status: .completed, durationMs: 10899, tokensUsed: 13369,
            outputPreview: "PING 2026-10-18 22:50:17 -03"))

        loops = try fold([fired2], from: loops)
        XCTAssertEqual(loops[0].iterations, 2)
        XCTAssertEqual(loops[0].runningSubagentID, sub2)
        XCTAssertEqual(try XCTUnwrap(loops[0].nextFireAt).timeIntervalSince(firstNext), 60, accuracy: 0.01)
        XCTAssertEqual(loops[0].schedulerRevision, 3)

        loops = try fold([deleted(reason: "deleted")], from: loops)
        XCTAssertTrue(loops.isEmpty)
    }

    /// WHY: out-of-order scheduler events must not roll the loop back (e.g. a late revision-2 fire).
    func test_staleRevisionIgnored() throws {
        let loops = try fold([created(), fired1, fired2])
        XCTAssertEqual(loops[0].iterations, 2)
        let again = try fold([fired1, deleted(reason: "deleted", rev: 3), created(rev: 1)], from: loops)
        XCTAssertEqual(again, loops)
    }

    /// WHY: process exit keeps the task persisted; it must show as paused, not disappear.
    func test_shutdownPausesLoop() throws {
        let loops = try fold([created(), fired1, deleted(reason: "shutdown")])
        XCTAssertEqual(loops.count, 1)
        XCTAssertEqual(loops[0].state, .paused)
        XCTAssertEqual(loops[0].pausedReason, "MacCode restarted the agent; resuming…")
        XCTAssertNil(loops[0].nextFireAt)
    }

    func test_expiredKeepsLoopMarkedExpired() throws {
        let loops = try fold([created(), deleted(reason: "expired")])
        XCTAssertEqual(loops.map(\.state), [.expired])
    }

    func test_completedAndUnknownReasonsRemove() throws {
        XCTAssertTrue(try fold([created(), deleted(reason: "completed")]).isEmpty)
        XCTAssertTrue(try fold([created(), deleted(reason: "weird")]).isEmpty)
    }

    func test_methodWithoutUnderscoreAndUnrelatedMethodsHandled() throws {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(created().utf8)) as? [String: Any])
        let params = try XCTUnwrap(obj["params"] as? [String: Any])
        XCTAssertEqual(DistillLoopReducer.apply(method: "x.ai/scheduled_task_created", params: params, to: []).count, 1)
        XCTAssertTrue(DistillLoopReducer.apply(method: "_x.ai/queue/changed", params: params, to: []).isEmpty)
    }

    /// WHY: persisted state and the iOS-mirrored payload use snake_case keys and an ISO8601 date string.
    func test_jsonRoundTripSnakeCase() throws {
        let loops = try fold([created(), fired1, finished1])
        let data = try JSONEncoder().encode(loops[0])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["task_id", "human_schedule", "next_fire_at", "last_iteration", "scheduler_revision"] {
            XCTAssertNotNil(json[key], key)
        }
        XCTAssertNil(json["paused_reason"])
        XCTAssertTrue((json["next_fire_at"] as? String)?.hasPrefix("2026-10-19T01:51:07") == true)
        let last = try XCTUnwrap(json["last_iteration"] as? [String: Any])
        XCTAssertEqual(last["subagent_id"] as? String, sub1)
        XCTAssertEqual(last["duration_ms"] as? Int, 10899)
        XCTAssertEqual(last["tokens_used"] as? Int, 13369)
        XCTAssertEqual(last["output_preview"] as? String, "PING 2026-10-18 22:50:17 -03")
        XCTAssertEqual(try JSONDecoder().decode(DistillLoopState.self, from: data), loops[0])

        let running = try fold([created(), fired1])[0]
        let runningJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(running)) as? [String: Any])
        XCTAssertEqual(runningJSON["running_subagent_id"] as? String, sub1)
    }

    func test_outputPreviewTruncatedTo280() {
        let it = DistillLoopIteration(subagentID: "s", status: .completed, outputPreview: String(repeating: "a", count: 500))
        XCTAssertEqual(it.outputPreview?.count, 280)
    }

    func test_isWakePromptID() {
        XCTAssertEqual(DistillLoopReducer.isWakePromptID("subagent-completed-\(sub1)"), sub1)
        XCTAssertNil(DistillLoopReducer.isWakePromptID("subagent-completed-"))
        XCTAssertNil(DistillLoopReducer.isWakePromptID("user-prompt-1"))
    }
}
