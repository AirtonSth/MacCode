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

    func test_twoEntryPending_anchorsAtUserMessage_notPriorAssistant() {
        // WHY: the old count<=2 early-return bypassed k=0 and re-showed the
        // prior assistant answer next to the new user bubble.
        let entries = [
            assistantMessage(seconds: 1),
            userMessage(seconds: 2, text: "follow up"),
        ]
        let visible = AgentAppView.visibleTranscriptWindow(
            entries: entries, status: .pending, runStartedAt: nil
        )
        XCTAssertEqual(visible.map(\.id), [entries[1].id],
                       "two-entry pending follow-up must show only the new user bubble")
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

    func test_shouldRenderActivePlan_hidesAllDoneEvenWhileRunning() {
        // WHY: screenshot regression — all-Done prior checklist reappeared under a
        // new user bubble while the next run was already "Working for Ns".
        let userAt = Date(timeIntervalSince1970: 10_000)
        let allDone = AssistantActivePlan(
            steps: [
                AssistantPlanStep(id: "1", title: "Old", status: .completed),
                AssistantPlanStep(id: "2", title: "Also old", status: .completed),
            ],
            // Even a re-stamped "now" timestamp must not resurrect a finished plan.
            updatedAtMs: Int64(userAt.timeIntervalSince1970 * 1000) + 5_000
        )
        XCTAssertFalse(
            AgentAppView.shouldRenderActivePlan(
                plan: allDone,
                status: .running,
                runStartedAt: userAt,
                newestUserMessageAt: userAt
            ),
            "all-Done plans are history — never paint under a live follow-up"
        )
        XCTAssertFalse(
            AgentAppView.shouldAcceptActivePlanForFollowUp(
                plan: allDone,
                newestUserMessageAt: userAt,
                runStartedAt: userAt,
                hasQueuedFollowUp: false
            ),
            "stream must not re-admit all-Done plans after a follow-up clear"
        )
    }

    func test_shouldRenderActivePlan_hidesStalePlanUnderNewUserMessage() {
        let userAt = Date(timeIntervalSince1970: 10_000)
        let stale = AssistantActivePlan(
            steps: [
                AssistantPlanStep(id: "1", title: "Old", status: .pending),
                AssistantPlanStep(id: "2", title: "Also old", status: .inProgress),
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

    func test_itemsAfterFollowUpAnchor_dropsPriorTurnTools() {
        // WHY: long provider turns keep pre-message tools in the same turnId;
        // chat UX must only count work that started after the user spoke.
        var items: [AssistantItem] = [
            AssistantItem(id: "old-1", turnId: "t", type: .commandExecution, state: .completed,
                          body: "", startedAtMs: 1_000),
            AssistantItem(id: "old-2", turnId: "t", type: .tool, state: .completed,
                          body: "", startedAtMs: 2_000),
        ]
        // Enough post-anchor completed tools that the live tail (3) leaves settled work.
        for i in 0..<5 {
            items.append(AssistantItem(
                id: "new-\(i)", turnId: "t", type: .commandExecution, state: .completed,
                body: "", startedAtMs: 10_000 + Int64(i)
            ))
        }
        items.append(AssistantItem(
            id: "new-stream", turnId: "t", type: .tool, state: .streaming,
            body: "", startedAtMs: 20_000
        ))
        let scoped = AgentAppView.itemsAfterFollowUpAnchor(items, anchorMs: 9_500)
        XCTAssertEqual(scoped.count, 6, "only the six post-anchor items remain")
        XCTAssertFalse(scoped.contains { $0.id == "old-1" })

        let turn = AssistantTurnSnapshot(turnId: "t", items: items, finished: false)
        let inputs = AgentAppView.computeTurnRenderInputs(
            turn: turn,
            persistedAssistantTexts: [],
            proposedPlans: [],
            running: true,
            expandCompletedWork: false,
            followUpWorkAnchorMs: 9_500
        )
        XCTAssertGreaterThan(inputs.completedWorkBlockCount, 0,
                             "post-anchor settled tools must count toward Work so far")
        let visibleIds = inputs.visibleBlocks.flatMap { block -> [String] in
            switch block {
            case .item(let i): return [i.id]
            case .toolGroup(_, let group): return group.map(\.id)
            }
        }
        XCTAssertTrue(visibleIds.contains("new-stream"))
        XCTAssertFalse(visibleIds.contains("old-1"),
                       "pre-anchor tools must never paint under the new user message")
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
