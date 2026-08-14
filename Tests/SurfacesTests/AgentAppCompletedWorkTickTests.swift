import XCTest
import CoreModel
@testable import Surfaces

/// Perf guard for collapse-all-on-final during `timelineUpdateTick` (~30 Hz).
///
/// WHY: the tick used to `trimmingCharacters` every finished answer on every
/// paint, including turns already collapsed. A long thread can hold thousands
/// of turns (`AssistantTimelineState.liveTurnLimit` = 5000). Already-known
/// ids must be skipped; whitespace-only finals must still match the old trim.
final class AgentAppCompletedWorkTickTests: XCTestCase {

    private func turn(
        _ id: String,
        finished: Bool = false,
        final: String? = nil
    ) -> AssistantTurnSnapshot {
        AssistantTurnSnapshot(
            turnId: id,
            finalAssistantMessage: final,
            finished: finished
        )
    }

    func test_finalAssistantHasVisibleText_matchesTrimIsEmpty() {
        XCTAssertFalse(AgentAppView.finalAssistantHasVisibleText(nil))
        XCTAssertFalse(AgentAppView.finalAssistantHasVisibleText(""))
        XCTAssertFalse(AgentAppView.finalAssistantHasVisibleText(" \n\t"))
        XCTAssertTrue(AgentAppView.finalAssistantHasVisibleText("ok"))
        XCTAssertTrue(AgentAppView.finalAssistantHasVisibleText("  ok\n"))
    }

    func test_completedWorkTurnIds_skipsKnownFinalsAndDropsPrunedTurns() {
        let first = turn("t1", finished: true, final: String(repeating: "a", count: 8_192))
        let live = turn("t2", finished: false, final: nil)
        let firstPass = AgentAppView.completedWorkTurnIds(
            turns: [first, live],
            previouslyKnown: []
        )
        XCTAssertEqual(firstPass.ids, ["t1"])
        XCTAssertTrue(firstPass.hasNewlyFinished, "first sighting of a finished turn must collapse work")

        let secondPass = AgentAppView.completedWorkTurnIds(
            turns: [first, live],
            previouslyKnown: firstPass.ids
        )
        XCTAssertEqual(secondPass.ids, ["t1"])
        XCTAssertFalse(
            secondPass.hasNewlyFinished,
            "already-known finished turns must not retrim or re-collapse on later ticks"
        )

        let afterPrune = AgentAppView.completedWorkTurnIds(
            turns: [live],
            previouslyKnown: secondPass.ids
        )
        XCTAssertTrue(afterPrune.ids.isEmpty, "turns evicted from the live timeline must leave the known set")
        XCTAssertFalse(afterPrune.hasNewlyFinished)
    }

    func test_completedWorkTurnIds_whitespaceOnlyFinalIsNotFinished() {
        let update = AgentAppView.completedWorkTurnIds(
            turns: [turn("blank", finished: false, final: "  \n")],
            previouslyKnown: []
        )
        XCTAssertTrue(update.ids.isEmpty)
        XCTAssertFalse(update.hasNewlyFinished)
    }
}

/// WHY: conversation-column rebuilds on `timelineUpdateTick` (~30 Hz) used to
/// rehash every assistant body to rebuild `hiddenPersistedAssistantContentKey`
/// even when messages/timeline were unchanged. Generation must ignore ticks.
@MainActor
final class AgentTranscriptStateGenerationTests: XCTestCase {
    func test_contentGeneration_ignoresPaintTickAndBumpsOnTranscriptAssign() {
        let state = AgentTranscriptState()
        let start = state.contentGeneration

        state.timelineUpdateTick &+= 1
        state.timelineUpdateTick &+= 1
        XCTAssertEqual(
            state.contentGeneration,
            start,
            "paint ticks must not invalidate hide-set memos"
        )

        state.messages = [
            AgentMessage(
                id: AgentMessageID(),
                threadId: AgentThreadID(),
                role: .assistant,
                content: "hello",
                createdAt: Date(timeIntervalSince1970: 1)
            )
        ]
        XCTAssertEqual(state.contentGeneration, start + 1)

        var timeline = state.timeline
        timeline.turns.append(AssistantTurnSnapshot(turnId: "t1", finished: false))
        state.timeline = timeline
        XCTAssertEqual(state.contentGeneration, start + 2)
    }
}
