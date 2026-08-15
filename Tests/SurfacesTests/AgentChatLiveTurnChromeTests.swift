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
        // WHY: live composition is user → Thinking…/Thought → Work so far
        // (non-final tools) → final markdown. Tools must not leak outside the
        // disclosure the way a Supervised-run work-log card would, and thought
        // must not hide inside a collapsed Work so far row.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "hmm", startedAtMs: 1),
                AssistantItem(id: "tool1", turnId: "t1", type: .tool, state: .streaming, summary: "Bash", body: #"{"command":"ls"}"#, startedAtMs: 2),
            ],
            finished: false
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(composition.reasoning.map(\.id), ["r1"])
        XCTAssertEqual(composition.work.map(\.id), ["tool1"])
        XCTAssertTrue(composition.outside.isEmpty, "live turns keep tools inside Work so far")
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: true, workBlockCount: 1),
                       "Work so far")
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
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(composition.reasoning.map(\.type), [.reasoning])
        XCTAssertEqual(composition.work.map(\.type), [.tool])
        XCTAssertTrue(composition.outside.isEmpty, "final text lives on the turn, not as a duplicate item")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 1),
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
        XCTAssertTrue(AgentChatLiveTurnChrome.compose(turn).reasoning.contains { $0.type == .reasoning })
        XCTAssertTrue(AgentChatLiveTurnChrome.workItems(in: turn).contains { $0.type == .tool })
        XCTAssertEqual(turn.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 1),
            AgentAppView.completedWorkLabel(turn, live: false, workBlockCount: 1)
        )
    }

    func test_messageDuplicatesTurnHidesPersistedAnswer_becauseDeskMustNotPaintTheReplyTwice() {
        // WHY: messageRepo stores the assistant row and the live turn stores
        // the same final. Painting both is the duplicate the user reported.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(
                    id: "a1",
                    turnId: "t1",
                    type: .assistantMessage,
                    state: .completed,
                    body: "Oi! Como posso ajudar?",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        XCTAssertTrue(
            AgentChatLiveTurnChrome.messageDuplicatesTurn("Oi! Como posso ajudar?", turns: [turn])
        )
        XCTAssertFalse(
            AgentChatLiveTurnChrome.messageDuplicatesTurn("Qual sua função?", turns: [turn])
        )
    }

    func test_turnSortDatePrefersItemTimestamps_becauseReplayTurnStartedIsNow() {
        // WHY: turnStarted replay stamps startedAtMs with Date(), which stacked
        // every historical Worked row under the latest user bubble.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(
                    id: "r1",
                    turnId: "t1",
                    type: .reasoning,
                    state: .completed,
                    body: "x",
                    startedAtMs: 1_700_000_001_000,
                    finishedAtMs: 1_700_000_002_000
                ),
            ],
            finished: true,
            startedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        )
        XCTAssertEqual(
            AgentChatLiveTurnChrome.turnSortDate(turn),
            Date(timeIntervalSince1970: 1_700_000_001),
            "item start must win over the replay wall-clock on turn.startedAtMs"
        )
    }

    func test_laterTurnHidesRepeatedFinal_becauseTwoTurnsMustNotStackTheSameReply() {
        // WHY: a reused Claude session can emit two finished turns with the
        // same greeting. The second Worked row can stay; the second answer cannot.
        let first = AssistantTurnSnapshot(
            turnId: "t1",
            items: [],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        let second = AssistantTurnSnapshot(
            turnId: "t2",
            items: [
                AssistantItem(
                    id: "tool1",
                    turnId: "t2",
                    type: .tool,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
            ],
            finalAssistantMessage: "Oi! Como posso ajudar?",
            finished: true
        )
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldHideAssistantOutput(second, previousTurns: [first]))
        XCTAssertFalse(AgentChatLiveTurnChrome.shouldHideAssistantOutput(first, previousTurns: []))
    }

    func test_isRicherKeepsLiveThoughtAheadOfLaggingPersist_becauseFlushMustNotEraseThinking() {
        // WHY: Desk applies coordinator events immediately. A later SQLite
        // replay that has not flushed the reasoning delta must not wipe the row.
        var live = AssistantTimelineState()
        live.apply(.turnStarted(turnId: "t1"))
        live.apply(.itemStarted(item: AssistantItem(
            id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
            body: "Checking the suite", startedAtMs: 1
        )))
        var persisted = AssistantTimelineState()
        persisted.apply(.turnStarted(turnId: "t1"))
        persisted.apply(.itemStarted(item: AssistantItem(
            id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
            body: "", startedAtMs: 1
        )))
        XCTAssertTrue(AgentChatLiveTurnChrome.isRicher(live, than: persisted))
        XCTAssertFalse(AgentChatLiveTurnChrome.isRicher(persisted, than: live))
    }
}
