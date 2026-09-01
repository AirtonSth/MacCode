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

    func test_liveCompositionKeepsReasoningAndToolsInOneOrderedActivity() {
        // WHY: reasoning and tools share one provider timeline. Splitting them
        // into type buckets lets later thoughts jump above earlier tool work.
        let turn = AssistantTurnSnapshot(
            turnId: "t1",
            items: [
                AssistantItem(id: "r1", turnId: "t1", type: .reasoning, state: .streaming, body: "hmm", startedAtMs: 1),
                AssistantItem(id: "tool1", turnId: "t1", type: .tool, state: .streaming, summary: "Bash", body: #"{"command":"ls"}"#, startedAtMs: 2),
            ],
            finished: false
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(composition.activity.map(\.id), ["r1", "tool1"])
        XCTAssertTrue(composition.outside.isEmpty, "live turns keep all activity in append order")
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: true, workBlockCount: 2),
                       "Work so far · 2 steps in this turn")
        XCTAssertFalse(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
    }

    func test_liveCompositionPreservesAppendOrder_becauseLateThoughtMustStayAfterPriorWork() {
        // WHY: Grok interleaves reasoning, tools, and progress text. Rendering
        // type-specific buckets moves every later Thought above work that was
        // already visible instead of appending it at the bottom of the turn.
        let turn = AssistantTurnSnapshot(
            turnId: "t-interleaved",
            items: [
                AssistantItem(id: "r1", turnId: "t-interleaved", type: .reasoning, state: .completed, body: "first", startedAtMs: 1, finishedAtMs: 2),
                AssistantItem(id: "tool1", turnId: "t-interleaved", type: .tool, state: .completed, summary: "Bash", startedAtMs: 3, finishedAtMs: 4),
                AssistantItem(id: "progress1", turnId: "t-interleaved", type: .assistantMessage, state: .completed, body: "Still working", startedAtMs: 5, finishedAtMs: 6),
                AssistantItem(id: "r2", turnId: "t-interleaved", type: .reasoning, state: .streaming, body: "next", startedAtMs: 7),
            ],
            finished: false
        )

        let composition = AgentChatLiveTurnChrome.compose(turn)
        let renderedIDs = (composition.activity + composition.outside).map(\.id)

        XCTAssertEqual(
            renderedIDs,
            turn.items.map(\.id),
            "live activity must render in append order instead of hoisting every Thought"
        )
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
        XCTAssertEqual(composition.activity.map(\.type), [.reasoning, .tool])
        XCTAssertTrue(composition.outside.isEmpty, "final text lives on the turn, not as a duplicate item")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 2),
                       "Worked for 2s")
    }

    func test_finishedCompositionKeepsProgressInOrderAndRemovesOnlyFinalDuplicate() {
        // WHY: Grok can emit progress prose between thought phases. Finishing
        // the turn must not reclassify every assistantMessage as a final reply.
        let final = "All checks passed."
        let turn = AssistantTurnSnapshot(
            turnId: "t-finished-interleaved",
            items: [
                AssistantItem(id: "r1", turnId: "t-finished-interleaved", type: .reasoning, state: .completed, body: "first", startedAtMs: 1, finishedAtMs: 2),
                AssistantItem(id: "progress", turnId: "t-finished-interleaved", type: .assistantMessage, state: .completed, body: "Running one more check", startedAtMs: 3, finishedAtMs: 4),
                AssistantItem(id: "r2", turnId: "t-finished-interleaved", type: .reasoning, state: .completed, body: "second", startedAtMs: 5, finishedAtMs: 6),
                AssistantItem(id: "final-copy", turnId: "t-finished-interleaved", type: .assistantMessage, state: .completed, body: final, startedAtMs: 7, finishedAtMs: 8),
            ],
            finalAssistantMessage: final,
            finished: true
        )

        let composition = AgentChatLiveTurnChrome.compose(turn)

        XCTAssertEqual(composition.activity.map(\.id), ["r1", "progress", "r2"])
        XCTAssertTrue(composition.outside.isEmpty, "the authoritative turn final paints exactly once")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
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
        XCTAssertTrue(AgentChatLiveTurnChrome.compose(turn).activity.contains { $0.type == .reasoning })
        XCTAssertTrue(AgentChatLiveTurnChrome.workItems(in: turn).contains { $0.type == .tool })
        XCTAssertEqual(turn.finalAssistantMessage, "Three failing tests remain.")
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(turn, live: false, workBlockCount: 1),
            AgentAppView.completedWorkLabel(turn, live: false, workBlockCount: 1)
        )
    }

    func test_replayDoesNotInventWallClockFinish_becauseDeskMustNotGrowWorkedHours() throws {
        // WHY: Bots Desk replays persisted itemCompleted events on every open.
        // apply() used Date() for missing finishedAtMs, so "Worked for 12s"
        // became "Worked for 1230m" and grew each time the user left Studio.
        let start: Int64 = 1_700_000_000_000
        let events: [AssistantEvent] = [
            .turnStarted(turnId: "t1"),
            .itemStarted(item: AssistantItem(
                id: "r1", turnId: "t1", type: .reasoning, state: .streaming,
                body: "hmm", startedAtMs: start
            )),
            .itemCompleted(itemId: "r1", finalState: .completed),
            .itemStarted(item: AssistantItem(
                id: "tool1", turnId: "t1", type: .tool, state: .completed,
                summary: "Bash", startedAtMs: start + 2_000, finishedAtMs: start + 4_000
            )),
            .turnCompleted(turnId: "t1", finalMessage: "done"),
        ]
        let first = AgentChatLiveTurnChrome.timelineByReplaying(events)
        let second = AgentChatLiveTurnChrome.timelineByReplaying(events)
        let firstTurn = try XCTUnwrap(first.turns.first)
        let secondTurn = try XCTUnwrap(second.turns.first)
        let firstReasoning = try XCTUnwrap(firstTurn.items.first { $0.id == "r1" })
        XCTAssertNil(
            firstReasoning.finishedAtMs,
            "replay must not stamp wall-clock now onto a completed item that never recorded a finish"
        )
        XCTAssertNil(
            AgentChatLiveTurnChrome.turnDurationLabel(firstTurn),
            "unknown finish must omit duration instead of now-minus-start"
        )
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(firstTurn, live: false, workBlockCount: 1),
            "Worked"
        )
        XCTAssertEqual(
            AgentChatLiveTurnChrome.completedWorkLabel(firstTurn, live: false, workBlockCount: 1),
            AgentChatLiveTurnChrome.completedWorkLabel(secondTurn, live: false, workBlockCount: 1),
            "two replays hours apart must not change the Worked label"
        )
        XCTAssertEqual(
            AgentAppViewModel.timelineByReplaying(events).turns.first?.items.first { $0.id == "r1" }?.finishedAtMs,
            firstReasoning.finishedAtMs,
            "Agent App replay must share the same no-Date() finish rule"
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

    func test_composeKeepsOneAssistantWhenClaudeEmitsStreamAndSnapshot() {
        // WHY: a real Claude Desk turn writes a streaming assistantMessage
        // and then a snapshot item with the same body. Two replies is a lie.
        let answer = "Sou Batatilson da Silva, Gerente de Marketing, e não alterei nenhum arquivo."
        let turn = AssistantTurnSnapshot(
            turnId: "F18B4835-C8AC-4C5B-8D0D-FD8A915CA0EF",
            items: [
                AssistantItem(
                    id: "483520EA-C4E5-471D-A409-1B8501E14F90",
                    turnId: "F18B4835-C8AC-4C5B-8D0D-FD8A915CA0EF",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
                AssistantItem(
                    id: "793AAE89-A3B1-4F24-962E-A5D76186A18E",
                    turnId: "F18B4835-C8AC-4C5B-8D0D-FD8A915CA0EF",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 2,
                    finishedAtMs: 3
                ),
            ],
            finalAssistantMessage: answer,
            finished: true
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertTrue(
            composition.outside.isEmpty,
            "assistant items that match the turn final must not paint beside it"
        )
        XCTAssertTrue(
            AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn),
            "the turn final is the single chat answer after Work so far"
        )
    }

    func test_workThenMatchingItemAndFinalPaintsAnswerOnce() {
        // WHY: Agent App showed Ran N commands, then the same paragraph twice —
        // live assistant item plus turn final (and often a persisted copy).
        let answer = "Confirmed all three blockers in code."
        let turn = AssistantTurnSnapshot(
            turnId: "t-dup",
            items: [
                AssistantItem(
                    id: "cmd-1",
                    turnId: "t-dup",
                    type: .commandExecution,
                    state: .completed,
                    summary: "Bash",
                    startedAtMs: 1,
                    finishedAtMs: 2
                ),
                AssistantItem(
                    id: "msg-1",
                    turnId: "t-dup",
                    type: .assistantMessage,
                    state: .completed,
                    body: answer,
                    startedAtMs: 3,
                    finishedAtMs: 4
                ),
            ],
            finalAssistantMessage: answer,
            finished: true
        )
        let composition = AgentChatLiveTurnChrome.compose(turn)
        XCTAssertEqual(composition.activity.map(\.id), ["cmd-1"])
        XCTAssertTrue(composition.outside.isEmpty)
        XCTAssertTrue(AgentChatLiveTurnChrome.shouldRenderFinalMessage(turn))
        XCTAssertTrue(AgentChatLiveTurnChrome.messageDuplicatesTurn(answer, turns: [turn]))
    }

    /// WHY: screenshot class — live Thinking… body hugged its unwrapped width,
    /// then AppKit wrapped at the column and drew extra lines over "Working for".
    /// Column-filling reasoning must pin maxWidth so sizeThatFits gets the column.
    func test_reasoningPlainTextPinsToColumnWidth() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let chrome = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentChatLiveTurnChrome.swift"),
            encoding: .utf8
        )
        let marker = try XCTUnwrap(chrome.range(of: "public struct AgentChatReasoningRow"))
        let rest = chrome[marker.lowerBound...]
        let end = rest.range(of: "\n// MARK: - Tool rows")?.lowerBound ?? rest.endIndex
        let chunk = String(chrome[marker.lowerBound..<end])
        XCTAssertTrue(chunk.contains("AgentSelectablePlainText("))
        XCTAssertTrue(
            chunk.contains("lineSpacing: 3\n                )\n                .frame(maxWidth: .infinity, alignment: .leading)"),
            "Thinking… body must take the chat column, not hug one long line"
        )

        let app = try String(
            contentsOf: root.appendingPathComponent("Sources/Surfaces/AgentAppSurface.swift"),
            encoding: .utf8
        )
        let row = try XCTUnwrap(app.range(of: "private func reasoningRow(_ item: AssistantItem)"))
        let rowRest = app[row.lowerBound...]
        let rowEnd = rowRest.range(of: "\n    private func reasoningText")?.lowerBound ?? rowRest.endIndex
        let rowChunk = String(app[row.lowerBound..<rowEnd])
        XCTAssertTrue(rowChunk.contains("AgentSelectablePlainText("))
        XCTAssertTrue(
            rowChunk.contains("lineSpacing: 3\n                )\n                .frame(maxWidth: .infinity, alignment: .leading)"),
            "Agent App reasoningRow must pin the same column width as live-turn chrome"
        )
    }

    func test_elapsedTickSchedule_lowFrequencyPinsThe5sCadence() {
        // WHY (perf CH-12): TimelineView keeps ticking while its window is
        // occluded or minimized; several live working strips at a forced 1s
        // cadence were a steady idle wake-up source. lowFrequency (which
        // SwiftUI passes for non-visible views) must fall back to 5s.
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = AgentChatElapsedTickSchedule(start: start)
        let early = start.addingTimeInterval(10)

        var regular = schedule.entries(from: early, mode: .normal)
        XCTAssertEqual(regular.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(regular.next()?.timeIntervalSince(early), 1,
                       "a visible strip inside the first minute ticks every second")

        var lowFrequency = schedule.entries(from: early, mode: .lowFrequency)
        XCTAssertEqual(lowFrequency.next()?.timeIntervalSince(early), 0)
        XCTAssertEqual(lowFrequency.next()?.timeIntervalSince(early), 5,
                       "an occluded/minimized strip must not tick every second")
    }
}
