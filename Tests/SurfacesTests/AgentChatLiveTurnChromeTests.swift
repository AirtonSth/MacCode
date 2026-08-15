import XCTest
import CoreModel
@testable import Surfaces

final class AgentChatLiveTurnChromeTests: XCTestCase {

    func test_streamingReasoningUsesThinkingLabel_becauseTheUserMustSeeLiveThought() {
        // WHY: a live turn that is still reasoning is not "Working…". Agent App
        // shows Thinking… with the streaming body so the user can watch thought.
        let item = AssistantItem(
            id: "r1",
            turnId: "t1",
            type: .reasoning,
            state: .streaming,
            body: "Considering the failing test",
            startedAtMs: 1_000
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: true), "Thinking…")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(item), "Considering the failing test")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: item.state == .streaming), "Thinking…")
    }

    func test_finishedReasoningUsesThoughtLabel_becauseSettledWorkShouldCollapse() {
        // WHY: once reasoning completes, the row must collapse to Thought so
        // the final answer is not pushed down by a long chain-of-thought.
        let item = AssistantItem(
            id: "r1",
            turnId: "t1",
            type: .reasoning,
            state: .completed,
            body: "The suite is red because of a nil unwrap.",
            startedAtMs: 1_000,
            finishedAtMs: 2_000
        )
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: false), "Thought")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(item), "The suite is red because of a nil unwrap.")
        XCTAssertEqual(
            AgentChatLiveTurnChrome.reasoningTitle(isStreaming: item.state == .streaming),
            "Thought"
        )
    }

    func test_workSoFarOwnsToolsAndReasoning_becauseLiveCompositionIsUserThenWorkThenFinal() {
        // WHY: live composition is user → Work so far (all non-final items) →
        // final markdown only when finished. Tools must not leak outside the
        // disclosure the way a Supervised-run work-log card would.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "hmm", startedAtMs: 1),
                AssistantItem(id: "tool1", turnId: "t1", type: .tool, state: .streaming, summary: "Bash", body: #"{"command":"ls"}"#, startedAtMs: 2),
            ],
            finished: false
        )
        let split = AgentChatLiveTurnChrome.splitTurn(turn)
        XCTAssertEqual(split.work.map(\.id), ["r1", "tool1"])
        XCTAssertTrue(split.outside.isEmpty, "live turns keep every non-final item inside Work so far")
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: true, workBlockCount: 2),
                       "Work so far · 2 steps in this turn")
        XCTAssertFalse(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
    }

    func test_finalStaysOutsideWork_becauseTheAnswerIsTheChat() {
        // WHY: the finished answer is the chat. It must sit outside Worked,
        // left-aligned as assistant markdown, not buried in the disclosure.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .completed, body: "thought", startedAtMs: 1_000, finishedAtMs: 2_000),
                AssistantItem(id: "tool1", turnId: "t1", type: .tool, state: .completed, summary: "Bash", startedAtMs: 2_000, finishedAtMs: 3_000),
            ],
            finalAssistantMessage: "Three failing tests remain.",
            finished: true
        )
        let split = AgentChatLiveTurnChrome.splitTurn(turn)
        XCTAssertEqual(split.work.map(\.type), [.reasoning, .tool])
        XCTAssertTrue(split.outside.isEmpty, "final text lives on the turn, not as a duplicate item")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 2),
                       "Worked for 2s")
    }

    func test_hasStreamingToolsDrivesWorkingPhase_becauseAThinkingPillIsNotEnough() {
        // WHY: composer chrome must follow real timeline items. A hardcoded
        // hasStreamingTools:false always says Thinking even while tools run.
        var timeline = AssistantTimelineState()
        timeline.apply(.turnStarted(turnId: "t1"))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "…", startedAtMs: 1
        )))
        XCTAssertFalse(AgentChatLiveTurnChrome.hasStreamingTools(in: timeline))
        timeline.apply(.itemStarted(item: AssistantItem(
            id: "tool1", turnId: "t1", type: .tool, state: .streaming, summary: "Bash", startedAtMs: 2
        )))
        XCTAssertTrue(AgentChatLiveTurnChrome.hasStreamingTools(in: timeline))
        XCTAssertTrue(AgentChatLiveTurnChrome.paintsLiveTurnChrome(timeline))
    }

    func test_timelineReplayRestoresThoughtAndWorked_becauseCloseMustNotEraseTheTurn() throws {
        // WHY: stream events persist on the linked thread. Replaying them must
        // rebuild Thought + Worked without starting a second provider run.
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "t1"),
            .itemStarted(item: AssistantItem(
                id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "", startedAtMs: 1_000
            )),
            .itemDelta(itemId: "r1", bodyAppend: "Checking the suite", outputAppend: nil, summary: nil),
            .itemCompleted(itemId: "r1", finalState: .completed),
            .itemStarted(item: AssistantItem(
                id: "tool1", turnId: "t1", type: .tool, state: .completed, summary: "Bash",
                body: #"{"command":"swift test"}"#, startedAtMs: 2_000, finishedAtMs: 4_000
            )),
            .turnCompleted(turnId: "t1", finalMessage: "Three failing tests remain."),
        ]
        let timeline = AgentChatLiveTurnChrome.timelineByReplaying(events)
        XCTAssertTrue(AgentChatLiveTurnChrome.paintsLiveTurnChrome(timeline))
        let turn = try XCTUnwrap(timeline.turns.first)
        XCTAssertTrue(turn.finished)
        let reasoning = try XCTUnwrap(turn.items.first { $0.type == .reasoning })
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningTitle(isStreaming: reasoning.state == .streaming), "Thought")
        XCTAssertEqual(AgentChatLiveTurnChrome.reasoningText(reasoning), "Checking the suite")
        XCTAssertTrue(AgentChatLiveTurnChrome.workItems(in: turn).contains { $0.type == .tool })
        XCTAssertEqual(turn.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 2),
            AgentAppView.completedWorkLabel(turn, live: false, workBlockCount: 2)
        )
    }
}
