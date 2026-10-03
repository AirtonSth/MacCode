import XCTest
@testable import Surfaces

final class DistillLiveStatusTests: XCTestCase {
    private let method = "x.ai/session_notification"

    private func send(_ s: inout DistillLiveStatus, _ session: String, _ update: [String: Any], at: Date = Date()) {
        var u = update
        u["sessionUpdate"] = u["sessionUpdate"] ?? ""
        let data = try! JSONSerialization.data(withJSONObject: ["sessionId": session, "update": u])
        s.apply(method: method, payloadJSON: String(data: data, encoding: .utf8)!, receivedAt: at)
    }

    private func spawn(_ s: inout DistillLiveStatus) {
        send(&s, "main", ["sessionUpdate": "subagent_spawned", "subagent_id": "a1", "child_session_id": "c1",
                          "subagent_type": "general-purpose", "description": "goal plan writer"])
        send(&s, "main", ["sessionUpdate": "subagent_progress", "subagent_id": "a1", "child_session_id": "c1",
                          "duration_ms": 51_000, "tokens_used": 10,
                          "active_model": "meta/muse-spark-1.3-contributor", "active_reasoning_effort": "low"])
    }

    func test_childCompaction_namesSubagentSoUserSeesWhoIsBusy() {
        var s = DistillLiveStatus()
        spawn(&s)
        send(&s, "c1", ["sessionUpdate": "auto_compact_started"])
        XCTAssertEqual(s.headline, "Subagent (goal plan writer): Compacting…")
        XCTAssertEqual(s.subagents[0].phaseText, "Compacting")
        XCTAssertEqual(s.subagents[0].typeLabel, "General")
        XCTAssertEqual(s.modelEffortText, "meta/muse-spark-1.3-contributor low")
        XCTAssertNil(s.mainCompactingSince)
    }

    func test_mainCompaction_togglesHeadlineOnStartAndComplete() {
        var s = DistillLiveStatus()
        XCTAssertNil(s.headline)
        send(&s, "main", ["sessionUpdate": "auto_compact_started"])
        XCTAssertEqual(s.headline, "Compacting…")
        send(&s, "main", ["sessionUpdate": "auto_compact_completed"])
        XCTAssertNil(s.headline)
    }

    func test_finished_marksStatusAndStopsCompactingHeadline() {
        var s = DistillLiveStatus()
        spawn(&s)
        send(&s, "c1", ["sessionUpdate": "auto_compact_started"])
        send(&s, "main", ["sessionUpdate": "subagent_finished", "subagent_id": "a1", "status": "failed"])
        XCTAssertNil(s.headline)
        XCTAssertEqual(s.subagents[0].phaseText, "Failed")
    }

    func test_unrelatedMethodIgnored_soOtherProvidersEventsDoNotChangeStrip() {
        var s = DistillLiveStatus()
        s.apply(method: "available_commands_update", payloadJSON: "{}")
        send(&s, "main", ["sessionUpdate": "plan"])
        XCTAssertTrue(s.isEmpty)
    }

    func test_tokenFormatting_matchesTuiStyle() {
        XCTAssertEqual(DistillLiveStatus.formatTokens(135_000), "135k")
        XCTAssertEqual(DistillLiveStatus.formatTokens(1_500), "1.5k")
        XCTAssertEqual(DistillLiveStatus.formatTokens(950), "950")
    }
}
