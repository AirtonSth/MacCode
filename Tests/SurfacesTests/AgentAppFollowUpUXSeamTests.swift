import XCTest
import CoreModel
@testable import Surfaces

/// Pure-seam tests for follow-up UX: clean transcript window from the newest
/// user message, Active plan paint gate, and reveal/work labels.
///
/// WHY: after a long thread, sending the next message re-painted prior history
/// and a completed Active plan under the new bubble, and live turns paid full
/// work-block derivation while the disclosure stayed collapsed.
final class AgentAppFollowUpUXSeamTests: XCTestCase {

    private static let threadID = AgentThreadID()

    private func userMessage(seconds: TimeInterval, text: String = "hi") -> AgentAppView.TranscriptEntry {
        .message(AgentMessage(
            id: AgentMessageID(UUID()),
            threadId: Self.threadID,
            role: .user,
            content: text,
            createdAt: Date(timeIntervalSince1970: seconds)
        ))
    }

    private func assistantMessage(seconds: TimeInterval) -> AgentAppView.TranscriptEntry {
        .message(AgentMessage(
            id: AgentMessageID(UUID()),
            threadId: Self.threadID,
            role: .assistant,
            content: "ans-\(seconds)",
            createdAt: Date(timeIntervalSince1970: seconds)
        ))
    }

    private func turnEntry(turnId: String, startMs: Int64) -> AgentAppView.TranscriptEntry {
        .turn(AssistantTurnSnapshot(
            turnId: turnId,
            items: [AssistantItem(id: "item-\(turnId)", turnId: turnId, type: .tool,
                                  state: .completed, body: "", startedAtMs: startMs)]
        ))
    }

    // MARK: Follow-up window anchor

    func test_pendingFollowUp_anchorsAtNewestUserMessage() {
        // WHY: pending must not flash the last 30 historical entries between
        // send and running — the new user bubble is the start of the turn.
        var entries: [AgentAppView.TranscriptEntry] = (0..<40).map {
            assistantMessage(seconds: TimeInterval($0))
        }
        entries.append(userMessage(seconds: 100, text: "new follow-up"))
        entries.append(turnEntry(turnId: "live", startMs: 100_500))

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .pending, runStartedAt: nil
        )

        XCTAssertEqual(visible.first?.id, entries[40].id,
                       "pending follow-up must start at the newest user message")
        XCTAssertEqual(visible.count, 2,
                       "only the user bubble and subsequent live turn stay in the default window")
        XCTAssertFalse(visible.contains { $0.id == entries[0].id },
                       "historical assistant messages stay behind the reveal row")
    }

    func test_runningFollowUp_anchorsAtNewestUserMessage_evenWithRunStartedAt() {
        // WHY: time-cutoff alone still left prior turns near the run start in
        // view; anchoring at the user message is the clean-follow-up contract.
        let started = Date(timeIntervalSince1970: 1_000)
        var entries: [AgentAppView.TranscriptEntry] = (0..<10).map {
            turnEntry(turnId: "old-\($0)", startMs: Int64(($0 + 990) * 1_000))
        }
        entries.append(userMessage(seconds: 1_000, text: "go"))
        entries.append(turnEntry(turnId: "new", startMs: Int64(1_001_000)))

        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .running, runStartedAt: started
        )

        XCTAssertEqual(visible.map(\.id).first, entries[10].id,
                       "running follow-up starts at the user message")
        XCTAssertFalse(visible.contains { $0.id == entries[0].id })
    }

    func test_runningWithoutUserMessage_keepsTimeCutoffFallback() {
        // WHY: regression guard for threads that only have turns (tests/fixtures).
        let started = Date(timeIntervalSince1970: 1_000)
        let old = (0..<3).map { turnEntry(turnId: "old-\($0)", startMs: Int64(($0 + 1) * 1_000)) }
        let live = [
            turnEntry(turnId: "live-0", startMs: Int64(started.timeIntervalSince1970 * 1_000)),
            turnEntry(turnId: "live-1", startMs: Int64((started.timeIntervalSince1970 + 5) * 1_000)),
        ]
        let entries = old + live
        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .running, runStartedAt: started
        )
        XCTAssertEqual(visible.map(\.id), live.map(\.id))
    }

    // MARK: Active plan paint gate

    func test_shouldRenderActivePlan_hidesAllDoneWhenIdle() {
        let plan = AssistantActivePlan(
            steps: [AssistantPlanStep(id: "1", title: "Done", status: .completed)],
            updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        XCTAssertFalse(
            AgentAppView.shouldRenderActivePlan(
                plan: plan, status: .completed, runStartedAt: nil, newestUserMessageAt: Date()
            ),
            "a fully completed plan must not stick under the transcript after the run ends"
        )
    }

    func test_shouldRenderActivePlan_hidesStalePlanUnderNewUserMessage() {
        let userAt = Date(timeIntervalSince1970: 10_000)
        let stale = AssistantActivePlan(
            steps: [
                AssistantPlanStep(id: "1", title: "Old", status: .completed),
                AssistantPlanStep(id: "2", title: "Also old", status: .completed),
            ],
            updatedAtMs: 1_000 // long before the user message
        )
        XCTAssertFalse(
            AgentAppView.shouldRenderActivePlan(
                plan: stale,
                status: .running,
                runStartedAt: userAt,
                newestUserMessageAt: userAt
            ),
            "plan timestamps before the follow-up anchor must not paint under the new bubble"
        )
    }

    func test_shouldRenderActivePlan_keepsFreshInProgressPlan() {
        let userAt = Date(timeIntervalSince1970: 10_000)
        let fresh = AssistantActivePlan(
            steps: [
                AssistantPlanStep(id: "1", title: "Done", status: .completed),
                AssistantPlanStep(id: "2", title: "Working", status: .inProgress),
            ],
            updatedAtMs: Int64(userAt.timeIntervalSince1970 * 1000) + 500
        )
        XCTAssertTrue(
            AgentAppView.shouldRenderActivePlan(
                plan: fresh,
                status: .running,
                runStartedAt: userAt,
                newestUserMessageAt: userAt
            ),
            "a plan updated after the follow-up anchor must still render"
        )
    }

    func test_isActivePlanFreshForFollowUp_acceptsPlanAtAnchorMinusSlack() {
        let userAt = Date(timeIntervalSince1970: 10_000)
        let plan = AssistantActivePlan(
            steps: [AssistantPlanStep(id: "1", title: "x", status: .pending)],
            updatedAtMs: Int64((userAt.timeIntervalSince1970 - 1.5) * 1000)
        )
        XCTAssertTrue(
            AgentAppView.isActivePlanFreshForFollowUp(
                plan: plan, newestUserMessageAt: userAt, runStartedAt: userAt
            ),
            "within runningTranscriptContextSlack the plan is still treated as this turn"
        )
    }

    // MARK: Labels

    func test_hiddenTranscriptRevealLabel_isQuietCopy() {
        let label = AgentAppView.hiddenTranscriptRevealLabel(count: 32, revealedCount: 0, nextCount: 32)
        XCTAssertEqual(label, "Earlier in this thread · show 32 more")
        XCTAssertFalse(label.contains("hidden - tap"),
                       "reveal copy must not read like data loss")
    }

    func test_completedWorkLabel_live_mentionsThisTurn() {
        let turn = AssistantTurnSnapshot(turnId: "t", items: [], finished: false)
        XCTAssertEqual(
            AgentAppView.completedWorkLabel(turn, live: true, workBlockCount: 228),
            "Work so far · 228 steps in this turn"
        )
    }
}
